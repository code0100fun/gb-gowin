// SD card test — reads FAT32 root directory and prints filenames over UART.
//
// Handles both MBR-partitioned and "super floppy" (no MBR) SD cards.
// Detects VBR at sector 0 by checking for 0xEB/0xE9 JMP instruction.
//
// Diagnostic output (milestone chars + 2-char error codes):
//   >    boot started (UART works)
//   R    SD card initialized
//   M    MBR parsed OK (skipped if no MBR)
//   V    VBR parsed OK
//   !I   SD init error
//   !1   sector 0 read failed
//   !2   VBR sector read failed
//   !3   Root dir sector read failed
//
// Then prints "SD files:\r\n" followed by one line per file:
//   FILENAME.EXT 12345678\r\n
//
// Flash and test:
//   mise run flash -- sd_test_top
//   picocom -b 115200 /dev/ttyUSB1
//   (press S1 to re-read and re-print)
module sd_test_top (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset / re-scan
    input  logic       btn_s2,     // unused
    output logic [5:0] led,        // onboard LEDs (active low)

    // SD card (built-in microSD slot, SPI mode)
    output logic       sd_clk,
    output logic       sd_cmd,     // MOSI
    input  logic       sd_dat0,    // MISO
    output logic       sd_dat1,    // unused, tie high
    output logic       sd_dat2,    // unused, tie high
    output logic       sd_dat3,    // CS

    // UART
    output logic       uart_tx,
    input  logic       uart_rx     // unused
);

    // ---------------------------------------------------------------
    // Power-on reset (btn_s1 re-asserts)
    // ---------------------------------------------------------------
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];

    // ---------------------------------------------------------------
    // SD card SPI + reader
    // ---------------------------------------------------------------
    logic [7:0] spi_tx_data, spi_rx_data;
    logic       spi_start, spi_busy, spi_done;
    logic       spi_cs_en, spi_slow_clk;
    logic       spi_sclk_w, spi_mosi_w, spi_cs_n_w;

    sd_spi u_sd_spi (
        .clk(clk), .reset(reset),
        .sclk(spi_sclk_w), .mosi(spi_mosi_w), .miso(sd_dat0), .cs_n(spi_cs_n_w),
        .tx_data(spi_tx_data), .start(spi_start),
        .rx_data(spi_rx_data), .busy(spi_busy), .done(spi_done),
        .cs_en(spi_cs_en), .slow_clk(spi_slow_clk)
    );

    assign sd_clk  = spi_sclk_w;
    assign sd_cmd  = spi_mosi_w;
    assign sd_dat3 = spi_cs_n_w;
    assign sd_dat1 = 1'b1;
    assign sd_dat2 = 1'b1;

    logic [31:0] rd_sector;
    logic        rd_start;
    logic [7:0]  rd_data;
    logic        rd_valid, rd_done;
    logic        sd_ready, sd_err;

    sd_reader u_sd_reader (
        .clk(clk), .reset(reset),
        .spi_tx(spi_tx_data), .spi_start(spi_start),
        .spi_rx(spi_rx_data), .spi_busy(spi_busy), .spi_done(spi_done),
        .spi_cs_en(spi_cs_en), .spi_slow_clk(spi_slow_clk),
        .sector(rd_sector), .read_start(rd_start),
        .read_data(rd_data), .read_valid(rd_valid), .read_done(rd_done),
        .ready(sd_ready), .err(sd_err), .sdhc()
    );

    // ---------------------------------------------------------------
    // UART TX
    // ---------------------------------------------------------------
    logic [7:0] tx_byte;
    logic       tx_valid;
    logic       tx_ready;

    uart_tx u_uart (
        .clk(clk), .reset(reset),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready),
        .tx(uart_tx)
    );

    // ---------------------------------------------------------------
    // Sector buffer (512 bytes — for root directory)
    // ---------------------------------------------------------------
    logic [7:0] sec_buf [0:511];
    logic [8:0] buf_idx;

    // ---------------------------------------------------------------
    // FAT32 parameters (captured from MBR + VBR)
    // ---------------------------------------------------------------
    logic [31:0] part_lba;
    logic [7:0]  sectors_per_cluster;
    logic [15:0] reserved_sectors;
    logic [7:0]  num_fats;
    logic [31:0] fat_size;
    logic [31:0] root_cluster;
    logic [31:0] fat_start;

    // ---------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------
    typedef enum logic [4:0] {
        S_PRINT_CHAR,   // Reusable: print pending_char, then goto return_state
        S_WAIT_READY,
        S_READ_SEC0,
        S_BUF_SEC0,     // Buffer sector 0 into sec_buf
        S_DUMP_SEC0,    // Print hex dump of key sector 0 bytes
        S_ANALYZE_SEC0, // Detect VBR vs MBR, extract fields from sec_buf
        S_READ_VBR,
        S_PARSE_VBR,
        S_READ_ROOT,
        S_BUF_ROOT,
        S_PRINT_HDR,
        S_SCAN_ENTRY,
        S_PRINT_BYTE,
        S_NEXT_ENTRY,
        S_PRINT_ERR2,   // Print second error char (err_char2), then goto S_ERROR
        S_IDLE,
        S_ERROR
    } state_t;

    state_t state;
    state_t return_state;          // where S_PRINT_CHAR returns to
    logic [7:0]  pending_char;     // char for S_PRINT_CHAR to send
    logic [7:0]  err_char2;        // second error char for S_PRINT_ERR2
    logic [8:0]  byte_cnt;
    logic        sector_active;
    logic [4:0]  diag_idx;         // index within hex dump output
    logic [3:0]  entry_idx;        // 0–15 entries per sector
    logic [4:0]  print_idx;        // byte index within print sequence
    logic [3:0]  hdr_idx;          // byte index within header string
    logic [5:0]  file_count;

    // Entry base address in sector buffer
    wire [8:0] entry_base = {entry_idx, 5'b00000};

    // Hex digit: 0–9 → '0'–'9', 10–15 → 'A'–'F'
    function automatic [7:0] to_hex(input [3:0] v);
        if (v < 4'd10)
            to_hex = 8'h30 + {4'd0, v};
        else
            to_hex = 8'h37 + {4'd0, v};
    endfunction

    // Trigger 2-char error: prints "!" then err_ch, then S_ERROR
    // (call as NBA assignments within the always_ff)
    `define TRIGGER_ERR(err_ch) \
        pending_char <= "!";    \
        err_char2    <= (err_ch); \
        return_state <= S_PRINT_ERR2; \
        state        <= S_PRINT_CHAR

    // Header: "\r\nSD files:\r\n" (13 bytes, indices 0–12)
    function automatic [7:0] hdr_char(input [3:0] idx);
        case (idx)
            4'd0:  hdr_char = 8'h0D;
            4'd1:  hdr_char = 8'h0A;
            4'd2:  hdr_char = "S";
            4'd3:  hdr_char = "D";
            4'd4:  hdr_char = " ";
            4'd5:  hdr_char = "f";
            4'd6:  hdr_char = "i";
            4'd7:  hdr_char = "l";
            4'd8:  hdr_char = "e";
            4'd9:  hdr_char = "s";
            4'd10: hdr_char = ":";
            4'd11: hdr_char = 8'h0D;
            4'd12: hdr_char = 8'h0A;
            default: hdr_char = 8'h00;
        endcase
    endfunction

    // Entry print format: "FILENAME.EXT 12345678\r\n" (23 bytes, indices 0–22)
    logic [7:0] entry_char;
    always_comb begin
        case (print_idx)
            5'd0:  entry_char = sec_buf[entry_base + 9'd0];
            5'd1:  entry_char = sec_buf[entry_base + 9'd1];
            5'd2:  entry_char = sec_buf[entry_base + 9'd2];
            5'd3:  entry_char = sec_buf[entry_base + 9'd3];
            5'd4:  entry_char = sec_buf[entry_base + 9'd4];
            5'd5:  entry_char = sec_buf[entry_base + 9'd5];
            5'd6:  entry_char = sec_buf[entry_base + 9'd6];
            5'd7:  entry_char = sec_buf[entry_base + 9'd7];
            5'd8:  entry_char = ".";
            5'd9:  entry_char = sec_buf[entry_base + 9'd8];
            5'd10: entry_char = sec_buf[entry_base + 9'd9];
            5'd11: entry_char = sec_buf[entry_base + 9'd10];
            5'd12: entry_char = " ";
            5'd13: entry_char = to_hex(sec_buf[entry_base + 9'd31][7:4]);
            5'd14: entry_char = to_hex(sec_buf[entry_base + 9'd31][3:0]);
            5'd15: entry_char = to_hex(sec_buf[entry_base + 9'd30][7:4]);
            5'd16: entry_char = to_hex(sec_buf[entry_base + 9'd30][3:0]);
            5'd17: entry_char = to_hex(sec_buf[entry_base + 9'd29][7:4]);
            5'd18: entry_char = to_hex(sec_buf[entry_base + 9'd29][3:0]);
            5'd19: entry_char = to_hex(sec_buf[entry_base + 9'd28][7:4]);
            5'd20: entry_char = to_hex(sec_buf[entry_base + 9'd28][3:0]);
            5'd21: entry_char = 8'h0D;
            5'd22: entry_char = 8'h0A;
            default: entry_char = " ";
        endcase
    end

    // Sector 0 hex dump: "XX XXXX XXXXXXXX XXXXXXXX\r\n"
    //  byte0  bps  types1-4   entry1_lba
    logic [7:0] diag_char;
    always_comb begin
        case (diag_idx)
            // Byte 0
            5'd0:  diag_char = to_hex(sec_buf[0][7:4]);
            5'd1:  diag_char = to_hex(sec_buf[0][3:0]);
            5'd2:  diag_char = " ";
            // Bytes 11-12 (bytes_per_sector)
            5'd3:  diag_char = to_hex(sec_buf[11][7:4]);
            5'd4:  diag_char = to_hex(sec_buf[11][3:0]);
            5'd5:  diag_char = to_hex(sec_buf[12][7:4]);
            5'd6:  diag_char = to_hex(sec_buf[12][3:0]);
            5'd7:  diag_char = " ";
            // 4 partition type bytes (offsets 450, 466, 482, 498)
            5'd8:  diag_char = to_hex(sec_buf[450][7:4]);
            5'd9:  diag_char = to_hex(sec_buf[450][3:0]);
            5'd10: diag_char = to_hex(sec_buf[466][7:4]);
            5'd11: diag_char = to_hex(sec_buf[466][3:0]);
            5'd12: diag_char = to_hex(sec_buf[482][7:4]);
            5'd13: diag_char = to_hex(sec_buf[482][3:0]);
            5'd14: diag_char = to_hex(sec_buf[498][7:4]);
            5'd15: diag_char = to_hex(sec_buf[498][3:0]);
            5'd16: diag_char = " ";
            // Partition 1 LBA (offsets 454-457, big-endian display)
            5'd17: diag_char = to_hex(sec_buf[457][7:4]);
            5'd18: diag_char = to_hex(sec_buf[457][3:0]);
            5'd19: diag_char = to_hex(sec_buf[456][7:4]);
            5'd20: diag_char = to_hex(sec_buf[456][3:0]);
            5'd21: diag_char = to_hex(sec_buf[455][7:4]);
            5'd22: diag_char = to_hex(sec_buf[455][3:0]);
            5'd23: diag_char = to_hex(sec_buf[454][7:4]);
            5'd24: diag_char = to_hex(sec_buf[454][3:0]);
            5'd25: diag_char = 8'h0D;
            5'd26: diag_char = 8'h0A;
            default: diag_char = " ";
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= S_PRINT_CHAR;
            return_state  <= S_WAIT_READY;
            pending_char  <= ">";           // boot banner
            err_char2     <= 8'd0;
            rd_start      <= 1'b0;
            rd_sector     <= 32'd0;
            tx_valid      <= 1'b0;
            sector_active <= 1'b0;
            diag_idx      <= 5'd0;
            byte_cnt      <= 9'd0;
            buf_idx       <= 9'd0;
            entry_idx     <= 4'd0;
            print_idx     <= 5'd0;
            hdr_idx       <= 4'd0;
            file_count    <= 6'd0;
        end else begin
            rd_start <= 1'b0;
            tx_valid <= 1'b0;

            // Byte counter for inline sector parsing
            if (rd_valid && sector_active)
                byte_cnt <= byte_cnt + 9'd1;
            if (rd_done)
                sector_active <= 1'b0;

            case (state)

                // =============================================================
                // Reusable: print one char, then goto return_state
                // =============================================================
                S_PRINT_CHAR: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= pending_char;
                        tx_valid <= 1'b1;
                        state    <= return_state;
                    end
                end

                // =============================================================
                // Print second error char, then goto S_ERROR
                // =============================================================
                S_PRINT_ERR2: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= err_char2;
                        tx_valid <= 1'b1;
                        state    <= S_ERROR;
                    end
                end

                // =============================================================
                // Wait for SD card initialization
                // =============================================================
                S_WAIT_READY: begin
                    if (sd_err) begin
                        `TRIGGER_ERR("I");
                    end else if (sd_ready) begin
                        pending_char <= "R";
                        return_state <= S_READ_SEC0;
                        state        <= S_PRINT_CHAR;
                    end
                end

                // =============================================================
                // Read sector 0 into sec_buf
                // =============================================================
                S_READ_SEC0: begin
                    if (!sector_active && !rd_start) begin
                        rd_sector     <= 32'd0;
                        rd_start      <= 1'b1;
                        byte_cnt      <= 9'd0;
                        buf_idx       <= 9'd0;
                        sector_active <= 1'b1;
                        state         <= S_BUF_SEC0;
                    end
                end

                S_BUF_SEC0: begin
                    if (sd_err) begin
                        `TRIGGER_ERR("1");
                    end else begin
                        if (rd_valid) begin
                            sec_buf[buf_idx] <= rd_data;
                            buf_idx <= buf_idx + 9'd1;
                        end
                        if (rd_done) begin
                            diag_idx <= 5'd0;
                            state    <= S_DUMP_SEC0;
                        end
                    end
                end

                // =============================================================
                // Print hex dump of sector 0 key bytes for diagnostics
                // Format: "XX XXXX XXXXXXXX XXXXXXXX\r\n"
                //          b0 bps  types1-4 entry1LBA
                // =============================================================
                S_DUMP_SEC0: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= diag_char;
                        tx_valid <= 1'b1;
                        if (diag_idx == 5'd26)
                            state <= S_ANALYZE_SEC0;
                        else
                            diag_idx <= diag_idx + 5'd1;
                    end
                end

                // =============================================================
                // Analyze sector 0: VBR (super floppy) or MBR?
                // =============================================================
                S_ANALYZE_SEC0: begin
                    if (sec_buf[11] == 8'h00 && sec_buf[12] == 8'h02) begin
                        // bytes_per_sector == 512 → sector 0 IS the VBR
                        part_lba           <= 32'd0;
                        sectors_per_cluster <= sec_buf[13];
                        reserved_sectors    <= {sec_buf[15], sec_buf[14]};
                        num_fats            <= sec_buf[16];
                        fat_size            <= {sec_buf[39], sec_buf[38],
                                                sec_buf[37], sec_buf[36]};
                        root_cluster        <= {sec_buf[47], sec_buf[46],
                                                sec_buf[45], sec_buf[44]};
                        fat_start           <= {16'd0, sec_buf[15], sec_buf[14]};
                        pending_char <= "V";
                        return_state <= S_READ_ROOT;
                        state        <= S_PRINT_CHAR;
                    end else if (sec_buf[450] != 8'h00) begin
                        // MBR partition entry 1
                        part_lba <= {sec_buf[457], sec_buf[456],
                                     sec_buf[455], sec_buf[454]};
                        pending_char <= "M";
                        return_state <= S_READ_VBR;
                        state        <= S_PRINT_CHAR;
                    end else if (sec_buf[466] != 8'h00) begin
                        // MBR partition entry 2
                        part_lba <= {sec_buf[473], sec_buf[472],
                                     sec_buf[471], sec_buf[470]};
                        pending_char <= "M";
                        return_state <= S_READ_VBR;
                        state        <= S_PRINT_CHAR;
                    end else if (sec_buf[482] != 8'h00) begin
                        // MBR partition entry 3
                        part_lba <= {sec_buf[489], sec_buf[488],
                                     sec_buf[487], sec_buf[486]};
                        pending_char <= "M";
                        return_state <= S_READ_VBR;
                        state        <= S_PRINT_CHAR;
                    end else if (sec_buf[498] != 8'h00) begin
                        // MBR partition entry 4
                        part_lba <= {sec_buf[505], sec_buf[504],
                                     sec_buf[503], sec_buf[502]};
                        pending_char <= "M";
                        return_state <= S_READ_VBR;
                        state        <= S_PRINT_CHAR;
                    end else begin
                        // No valid partition found
                        `TRIGGER_ERR("M");
                    end
                end

                // =============================================================
                // Read + parse VBR
                // =============================================================
                S_READ_VBR: begin
                    if (!sector_active && !rd_start) begin
                        rd_sector     <= part_lba;
                        rd_start      <= 1'b1;
                        byte_cnt      <= 9'd0;
                        sector_active <= 1'b1;
                        state         <= S_PARSE_VBR;
                    end
                end

                S_PARSE_VBR: begin
                    if (sd_err) begin
                        `TRIGGER_ERR("2");
                    end else begin
                        if (rd_valid) begin
                            case (byte_cnt)
                                9'd13: sectors_per_cluster    <= rd_data;
                                9'd14: reserved_sectors[7:0]  <= rd_data;
                                9'd15: reserved_sectors[15:8] <= rd_data;
                                9'd16: num_fats               <= rd_data;
                                9'd36: fat_size[7:0]          <= rd_data;
                                9'd37: fat_size[15:8]         <= rd_data;
                                9'd38: fat_size[23:16]        <= rd_data;
                                9'd39: fat_size[31:24]        <= rd_data;
                                9'd44: root_cluster[7:0]      <= rd_data;
                                9'd45: root_cluster[15:8]     <= rd_data;
                                9'd46: root_cluster[23:16]    <= rd_data;
                                9'd47: root_cluster[31:24]    <= rd_data;
                                default: ;
                            endcase
                        end
                        if (rd_done) begin
                            fat_start <= part_lba + {16'd0, reserved_sectors};
                            pending_char <= "V";
                            return_state <= S_READ_ROOT;
                            state        <= S_PRINT_CHAR;
                        end
                    end
                end

                // =============================================================
                // Read root directory sector into buffer
                // =============================================================
                S_READ_ROOT: begin
                    if (!sector_active && !rd_start) begin
                        rd_sector <= fat_start + {24'd0, num_fats} * fat_size +
                            (root_cluster - 32'd2) * {24'd0, sectors_per_cluster};
                        rd_start      <= 1'b1;
                        byte_cnt      <= 9'd0;
                        buf_idx       <= 9'd0;
                        sector_active <= 1'b1;
                        state         <= S_BUF_ROOT;
                    end
                end

                S_BUF_ROOT: begin
                    if (sd_err) begin
                        `TRIGGER_ERR("3");
                    end else begin
                        if (rd_valid) begin
                            sec_buf[buf_idx] <= rd_data;
                            buf_idx <= buf_idx + 9'd1;
                        end
                        if (rd_done) begin
                            entry_idx  <= 4'd0;
                            file_count <= 6'd0;
                            hdr_idx    <= 4'd0;
                            state      <= S_PRINT_HDR;
                        end
                    end
                end

                // =============================================================
                // Print header: "\r\nSD files:\r\n"
                // =============================================================
                S_PRINT_HDR: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= hdr_char(hdr_idx);
                        tx_valid <= 1'b1;
                        if (hdr_idx == 4'd12)
                            state <= S_SCAN_ENTRY;
                        else
                            hdr_idx <= hdr_idx + 4'd1;
                    end
                end

                // =============================================================
                // Check directory entry validity
                // =============================================================
                S_SCAN_ENTRY: begin
                    if (sec_buf[entry_base] == 8'h00) begin
                        // End of directory
                        state <= S_IDLE;
                    end else if (sec_buf[entry_base] == 8'hE5 ||
                                 sec_buf[entry_base + 9'd11][3:0] == 4'hF ||
                                 sec_buf[entry_base + 9'd11][4] ||
                                 sec_buf[entry_base + 9'd11][3]) begin
                        // Skip: deleted, LFN, directory, volume label
                        state <= S_NEXT_ENTRY;
                    end else begin
                        print_idx <= 5'd0;
                        state     <= S_PRINT_BYTE;
                    end
                end

                // =============================================================
                // Print entry: "FILENAME.EXT 12345678\r\n"
                // =============================================================
                S_PRINT_BYTE: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= entry_char;
                        tx_valid <= 1'b1;
                        if (print_idx == 5'd22) begin
                            file_count <= file_count + 6'd1;
                            state      <= S_NEXT_ENTRY;
                        end else begin
                            print_idx <= print_idx + 5'd1;
                        end
                    end
                end

                // =============================================================
                // Advance to next entry
                // =============================================================
                S_NEXT_ENTRY: begin
                    if (entry_idx == 4'd15)
                        state <= S_IDLE;
                    else begin
                        entry_idx <= entry_idx + 4'd1;
                        state     <= S_SCAN_ENTRY;
                    end
                end

                // =============================================================
                S_IDLE: begin
                    // Done — press btn_s1 to re-scan
                end

                S_ERROR: begin
                    // Error — press btn_s1 to retry
                end

                default: state <= S_ERROR;
            endcase
        end
    end

    // LEDs (active low): file count when idle, state during boot, all-on on error
    assign led = (state == S_ERROR) ? 6'b000000 :
                 (state == S_IDLE)  ? ~file_count[5:0] :
                                      ~{1'b0, state};

endmodule
