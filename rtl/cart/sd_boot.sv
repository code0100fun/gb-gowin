// SD boot loader — FAT32 parser and ROM loader.
//
// Waits for sd_reader initialization, then reads sector 0, auto-
// detects MBR vs VBR (super floppy), parses FAT32 parameters, scans
// root directory to find the first .gb file. Loads the ROM data into
// BSRAM via a write port. Minimal FAT32: root directory only,
// 8.3 names, follows cluster chain.
module sd_boot (
    input  logic        clk,
    input  logic        reset,

    // sd_reader interface
    output logic [31:0] sd_sector,
    output logic        sd_read_start,
    input  logic [7:0]  sd_read_data,
    input  logic        sd_read_valid,
    input  logic        sd_read_done,
    input  logic        sd_ready,
    input  logic        sd_error,

    // ROM BSRAM write port
    output logic [14:0] rom_addr,
    output logic [7:0]  rom_data,
    output logic        rom_wr,

    // Status
    output logic        done,         // ROM loaded, CPU can start
    output logic        boot_error,   // couldn't find/load ROM
    output logic [2:0]  error_code    // debug: which stage failed
);

    // Error codes
    localparam logic [2:0] ERR_NONE     = 3'd0;
    localparam logic [2:0] ERR_SD_INIT  = 3'd1;
    localparam logic [2:0] ERR_MBR      = 3'd2;
    localparam logic [2:0] ERR_VBR      = 3'd3;
    localparam logic [2:0] ERR_NO_FILE  = 3'd4;
    localparam logic [2:0] ERR_READ     = 3'd5;

    // State machine
    typedef enum logic [3:0] {
        S_WAIT_READY,
        S_READ_MBR,
        S_PARSE_MBR,
        S_READ_VBR,
        S_PARSE_VBR,
        S_READ_ROOT,
        S_PARSE_ROOT,
        S_READ_FAT,
        S_LOAD_ROM,
        S_DONE,
        S_ERROR
    } state_t;

    state_t state;

    // Sector read state
    logic [8:0]  byte_cnt;       // 0-511 within current sector
    logic        sector_reading; // actively reading a sector
    logic        is_vbr;         // sector 0 is VBR (no MBR)
    logic [7:0]  bps_lo;         // bytes_per_sector low byte (VBR detection)

    // FAT32 parameters (captured from VBR)
    logic [7:0]  sectors_per_cluster;
    logic [31:0] fat_start;      // first FAT sector LBA
    logic [31:0] data_start;     // first data sector LBA
    logic [31:0] root_cluster;   // root directory start cluster
    logic [31:0] part_lba;       // partition start LBA

    // Parsing temporaries
    logic [31:0] temp32;         // for building 32-bit values
    logic [15:0] temp16;         // for building 16-bit values
    logic [15:0] reserved_sectors;
    logic [7:0]  num_fats;
    logic [31:0] fat_size;

    // Directory scanning
    logic [4:0]  dir_entry_byte; // 0-31 within 32-byte dir entry
    logic [7:0]  dir_attr;       // attribute byte
    logic [15:0] file_cluster_hi;
    logic [15:0] file_cluster_lo;
    logic [31:0] file_size;
    logic [31:0] file_cluster;   // current cluster being loaded
    logic [7:0]  dir_name [0:10]; // 11-byte 8.3 name
    logic        file_found;

    // ROM loading
    logic [31:0] rom_bytes_loaded;
    logic [31:0] rom_file_size;
    logic [7:0]  cluster_sector; // sector within current cluster
    logic [31:0] next_cluster;   // from FAT lookup

    // Helper: cluster to LBA
    function automatic [31:0] cluster_to_lba(input logic [31:0] cluster);
        cluster_to_lba = data_start + (cluster - 32'd2) * {24'd0, sectors_per_cluster};
    endfunction

    // Start a sector read
    task automatic start_sector_read(input logic [31:0] sec);
        sd_sector     <= sec;
        sd_read_start <= 1'b1;
        byte_cnt      <= 9'd0;
        sector_reading <= 1'b1;
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_WAIT_READY;
            sd_read_start  <= 1'b0;
            sd_sector      <= 32'd0;
            rom_addr       <= 15'd0;
            rom_data       <= 8'd0;
            rom_wr         <= 1'b0;
            done           <= 1'b0;
            boot_error     <= 1'b0;
            error_code     <= ERR_NONE;
            sector_reading <= 1'b0;
            is_vbr         <= 1'b0;
            bps_lo         <= 8'd0;
            byte_cnt       <= 9'd0;
            file_found     <= 1'b0;
            rom_bytes_loaded <= 32'd0;
        end else begin
            sd_read_start <= 1'b0;
            rom_wr        <= 1'b0;

            // Track byte position within sector
            if (sd_read_valid && sector_reading)
                byte_cnt <= byte_cnt + 9'd1;
            if (sd_read_done)
                sector_reading <= 1'b0;

            case (state)

                // =============================================================
                // Wait for SD card initialization
                // =============================================================
                S_WAIT_READY: begin
                    if (sd_error) begin
                        state      <= S_ERROR;
                        error_code <= ERR_SD_INIT;
                    end else if (sd_ready) begin
                        state <= S_READ_MBR;
                    end
                end

                // =============================================================
                // Read MBR (sector 0)
                // =============================================================
                S_READ_MBR: begin
                    if (!sector_reading && !sd_read_start) begin
                        start_sector_read(32'd0);
                        state <= S_PARSE_MBR;
                    end
                end

                // =============================================================
                // Parse sector 0 — detect MBR vs VBR, extract partition LBA
                // or FAT32 params directly (super floppy / no-MBR cards)
                // =============================================================
                S_PARSE_MBR: begin
                    if (sd_read_valid) begin
                        case (byte_cnt)
                            // Bytes 11-12: bytes_per_sector. If 0x0200 (512),
                            // sector 0 is a FAT BPB (VBR), not an MBR.
                            9'd11: bps_lo <= sd_read_data;
                            9'd12: is_vbr <= (bps_lo == 8'h00 &&
                                              sd_read_data == 8'h02);
                            // VBR fields (captured in case sector 0 IS the VBR)
                            9'd13: sectors_per_cluster    <= sd_read_data;
                            9'd14: reserved_sectors[7:0]  <= sd_read_data;
                            9'd15: reserved_sectors[15:8] <= sd_read_data;
                            9'd16: num_fats               <= sd_read_data;
                            9'd36: fat_size[7:0]          <= sd_read_data;
                            9'd37: fat_size[15:8]         <= sd_read_data;
                            9'd38: fat_size[23:16]        <= sd_read_data;
                            9'd39: fat_size[31:24]        <= sd_read_data;
                            9'd44: root_cluster[7:0]      <= sd_read_data;
                            9'd45: root_cluster[15:8]     <= sd_read_data;
                            9'd46: root_cluster[23:16]    <= sd_read_data;
                            9'd47: root_cluster[31:24]    <= sd_read_data;
                            // MBR partition LBA (offsets 454–457)
                            9'd454: part_lba[7:0]   <= sd_read_data;
                            9'd455: part_lba[15:8]  <= sd_read_data;
                            9'd456: part_lba[23:16] <= sd_read_data;
                            9'd457: part_lba[31:24] <= sd_read_data;
                            default: ;
                        endcase
                    end
                    if (sd_read_done) begin
                        if (state != S_ERROR) begin
                            if (is_vbr) begin
                                // No MBR — sector 0 is VBR (super floppy format)
                                part_lba  <= 32'd0;
                                fat_start <= {16'd0, reserved_sectors};
                                state     <= S_READ_ROOT;
                            end else begin
                                state <= S_READ_VBR;
                            end
                        end
                    end
                end

                // =============================================================
                // Read VBR (partition boot record)
                // =============================================================
                S_READ_VBR: begin
                    if (!sector_reading && !sd_read_start) begin
                        start_sector_read(part_lba);
                        state <= S_PARSE_VBR;
                    end
                end

                // =============================================================
                // Parse VBR — extract FAT32 parameters
                // =============================================================
                S_PARSE_VBR: begin
                    if (sd_read_valid) begin
                        case (byte_cnt)
                            // Sectors per cluster (offset 13)
                            9'd13: sectors_per_cluster <= sd_read_data;
                            // Reserved sectors (offset 14-15, little-endian)
                            9'd14: reserved_sectors[7:0]  <= sd_read_data;
                            9'd15: reserved_sectors[15:8] <= sd_read_data;
                            // Number of FATs (offset 16)
                            9'd16: num_fats <= sd_read_data;
                            // FAT size 32 (offset 36-39, little-endian)
                            9'd36: fat_size[7:0]   <= sd_read_data;
                            9'd37: fat_size[15:8]  <= sd_read_data;
                            9'd38: fat_size[23:16] <= sd_read_data;
                            9'd39: fat_size[31:24] <= sd_read_data;
                            // Root cluster (offset 44-47, little-endian)
                            9'd44: root_cluster[7:0]   <= sd_read_data;
                            9'd45: root_cluster[15:8]  <= sd_read_data;
                            9'd46: root_cluster[23:16] <= sd_read_data;
                            9'd47: root_cluster[31:24] <= sd_read_data;
                            default: ;
                        endcase
                    end
                    if (sd_read_done) begin
                        // Compute derived values
                        fat_start  <= part_lba + {16'd0, reserved_sectors};
                        // data_start computed next cycle (needs fat_start)
                        state <= S_READ_ROOT;
                    end
                end

                // =============================================================
                // Read root directory cluster
                // =============================================================
                S_READ_ROOT: begin
                    if (!sector_reading && !sd_read_start) begin
                        // Compute data_start on first entry
                        if (data_start == 32'd0 || !file_found) begin
                            data_start <= fat_start + {24'd0, num_fats} * fat_size;
                        end
                        // Read first sector of root cluster
                        start_sector_read(
                            fat_start + {24'd0, num_fats} * fat_size +
                            (root_cluster - 32'd2) * {24'd0, sectors_per_cluster}
                        );
                        dir_entry_byte <= 5'd0;
                        state <= S_PARSE_ROOT;
                    end
                end

                // =============================================================
                // Parse root directory — find first .gb file
                // =============================================================
                S_PARSE_ROOT: begin
                    if (sd_read_valid) begin
                        // Track position within 32-byte directory entry
                        if (dir_entry_byte == 5'd31)
                            dir_entry_byte <= 5'd0;
                        else
                            dir_entry_byte <= dir_entry_byte + 5'd1;

                        // Only parse if we haven't found a file yet
                        if (!file_found)
                        case (dir_entry_byte)
                            // Bytes 0-10: filename (8.3 format)
                            5'd0: begin
                                dir_name[0] <= sd_read_data;
                                // 0x00 = end of directory (only error if no file found yet)
                                if (sd_read_data == 8'h00 && !file_found) begin
                                    state      <= S_ERROR;
                                    error_code <= ERR_NO_FILE;
                                end
                            end
                            5'd1:  dir_name[1]  <= sd_read_data;
                            5'd2:  dir_name[2]  <= sd_read_data;
                            5'd3:  dir_name[3]  <= sd_read_data;
                            5'd4:  dir_name[4]  <= sd_read_data;
                            5'd5:  dir_name[5]  <= sd_read_data;
                            5'd6:  dir_name[6]  <= sd_read_data;
                            5'd7:  dir_name[7]  <= sd_read_data;
                            5'd8:  dir_name[8]  <= sd_read_data;  // extension
                            5'd9:  dir_name[9]  <= sd_read_data;
                            5'd10: dir_name[10] <= sd_read_data;
                            // Byte 11: attributes
                            5'd11: dir_attr <= sd_read_data;
                            // Bytes 20-21: cluster high (little-endian)
                            5'd20: file_cluster_hi[7:0]  <= sd_read_data;
                            5'd21: file_cluster_hi[15:8] <= sd_read_data;
                            // Bytes 26-27: cluster low (little-endian)
                            5'd26: file_cluster_lo[7:0]  <= sd_read_data;
                            5'd27: file_cluster_lo[15:8] <= sd_read_data;
                            // Bytes 28-31: file size (little-endian)
                            5'd28: file_size[7:0]   <= sd_read_data;
                            5'd29: file_size[15:8]  <= sd_read_data;
                            5'd30: file_size[23:16] <= sd_read_data;
                            5'd31: begin
                                file_size[31:24] <= sd_read_data;
                                // End of directory entry — check if it's a .gb file
                                // Skip: deleted (0xE5), LFN (attr & 0x0F == 0x0F),
                                //        directory (attr & 0x10), volume label (attr & 0x08)
                                if (dir_name[0] != 8'hE5 &&
                                    dir_attr[3:0] != 4'hF &&
                                    !dir_attr[4] && !dir_attr[3]) begin
                                    // Check extension = "GB " (case-insensitive)
                                    if ((dir_name[8] == "G" || dir_name[8] == "g") &&
                                        (dir_name[9] == "B" || dir_name[9] == "b") &&
                                        dir_name[10] == " ") begin
                                        file_found <= 1'b1;
                                    end
                                end
                            end
                            default: ;
                        endcase
                    end

                    // After sector is done, check if we found a file
                    if (sd_read_done) begin
                        if (file_found) begin
                            // Set up for ROM loading
                            file_cluster <= {file_cluster_hi, file_cluster_lo};
                            rom_file_size <= file_size;
                            rom_bytes_loaded <= 32'd0;
                            cluster_sector <= 8'd0;
                            state <= S_LOAD_ROM;
                        end else if (state != S_ERROR) begin
                            // No .gb found in this sector
                            state      <= S_ERROR;
                            error_code <= ERR_NO_FILE;
                        end
                    end
                end

                // =============================================================
                // Load ROM data — read cluster chain
                // =============================================================
                S_LOAD_ROM: begin
                    if (!sector_reading && !sd_read_start) begin
                        if (rom_bytes_loaded >= rom_file_size ||
                            rom_bytes_loaded >= 32'd32768) begin
                            // Done loading
                            state <= S_DONE;
                        end else begin
                            // Read next sector of current cluster
                            start_sector_read(
                                cluster_to_lba(file_cluster) +
                                {24'd0, cluster_sector}
                            );
                        end
                    end

                    if (sd_read_valid) begin
                        if (rom_bytes_loaded < 32'd32768 &&
                            rom_bytes_loaded < rom_file_size) begin
                            rom_addr <= rom_bytes_loaded[14:0];
                            rom_data <= sd_read_data;
                            rom_wr   <= 1'b1;
                            rom_bytes_loaded <= rom_bytes_loaded + 32'd1;
                        end
                    end

                    if (sd_read_done) begin
                        if (cluster_sector + 8'd1 < sectors_per_cluster) begin
                            // More sectors in this cluster
                            cluster_sector <= cluster_sector + 8'd1;
                        end else begin
                            // End of cluster — read FAT to find next
                            cluster_sector <= 8'd0;
                            state <= S_READ_FAT;
                        end
                    end
                end

                // =============================================================
                // Read FAT entry for current cluster
                // =============================================================
                S_READ_FAT: begin
                    if (!sector_reading && !sd_read_start) begin
                        // FAT32: 4 bytes per entry, 128 entries per sector
                        // FAT sector = fat_start + (cluster / 128)
                        // Offset within sector = (cluster % 128) * 4
                        start_sector_read(
                            fat_start + (file_cluster >> 7)
                        );
                        next_cluster <= 32'd0;
                        state <= S_READ_FAT; // stay in state while reading
                    end

                    if (sd_read_valid) begin
                        // FAT entry offset = (file_cluster[6:0]) * 4
                        // We need bytes at offsets: base, base+1, base+2, base+3
                        automatic logic [8:0] fat_offset = {file_cluster[6:0], 2'b00};
                        if (byte_cnt == fat_offset)
                            next_cluster[7:0]   <= sd_read_data;
                        if (byte_cnt == fat_offset + 9'd1)
                            next_cluster[15:8]  <= sd_read_data;
                        if (byte_cnt == fat_offset + 9'd2)
                            next_cluster[23:16] <= sd_read_data;
                        if (byte_cnt == fat_offset + 9'd3)
                            next_cluster[31:24] <= sd_read_data;
                    end

                    if (sd_read_done) begin
                        // Check if end of chain
                        if (next_cluster[27:0] >= 28'h0FFFFFF8) begin
                            state <= S_DONE;
                        end else begin
                            file_cluster <= next_cluster & 32'h0FFFFFFF;
                            state <= S_LOAD_ROM;
                        end
                    end
                end

                // =============================================================
                S_DONE: begin
                    done <= 1'b1;
                end

                S_ERROR: begin
                    boot_error <= 1'b1;
                end

                default: state <= S_ERROR;
            endcase
        end
    end

endmodule
