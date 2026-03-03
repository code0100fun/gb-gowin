// Test wrapper for sd_boot — full SD boot stack with FAT32 test image.
//
// Includes sd_spi, sd_reader, sd_boot, sd_card_model, and a
// 32 KB ROM BSRAM. The sd_card_model is preloaded with a minimal
// FAT32 filesystem containing a test .gb file.
module sd_boot_top (
    input  logic        clk,
    input  logic        reset,

    // Status outputs
    output logic        done,
    output logic        boot_error,
    output logic [2:0]  error_code,

    // ROM read port (for verification)
    input  logic [14:0] rom_rd_addr,
    output logic [7:0]  rom_rd_data
);

    // --- sd_spi ↔ sd_reader wires ---
    logic [7:0] spi_tx;
    logic       spi_start;
    logic [7:0] spi_rx;
    logic       spi_busy;
    logic       spi_done;
    logic       spi_cs_en;
    logic       spi_slow_clk;

    // --- SPI physical wires ---
    logic       sclk, mosi, miso, cs_n;

    // --- sd_reader ↔ sd_boot wires ---
    logic [31:0] sd_sector;
    logic        sd_read_start;
    logic [7:0]  sd_read_data;
    logic        sd_read_valid;
    logic        sd_read_done;
    logic        sd_ready;
    logic        sd_error;
    logic        sd_sdhc;

    // --- ROM write port (from sd_boot — SDRAM address width) ---
    logic [22:0] rom_wr_addr;
    logic [7:0]  rom_wr_data;
    logic        rom_wr;

    // --- ROM BSRAM (32 KB) ---
    logic [7:0] rom_mem [0:32767];

    // Write port (use low 15 bits — test data fits in 32 KB)
    always_ff @(posedge clk) begin
        if (rom_wr)
            rom_mem[rom_wr_addr[14:0]] <= rom_wr_data;
    end

    // Read port
    always_ff @(posedge clk) begin
        rom_rd_data <= rom_mem[rom_rd_addr];
    end

    // --- Module instances ---

    sd_spi u_spi (
        .clk      (clk),
        .reset    (reset),
        .sclk     (sclk),
        .mosi     (mosi),
        .miso     (miso),
        .cs_n     (cs_n),
        .tx_data  (spi_tx),
        .start    (spi_start),
        .rx_data  (spi_rx),
        .busy     (spi_busy),
        .done     (spi_done),
        .cs_en    (spi_cs_en),
        .slow_clk (spi_slow_clk)
    );

    sd_reader u_reader (
        .clk          (clk),
        .reset        (reset),
        .spi_tx       (spi_tx),
        .spi_start    (spi_start),
        .spi_rx       (spi_rx),
        .spi_busy     (spi_busy),
        .spi_done     (spi_done),
        .spi_cs_en    (spi_cs_en),
        .spi_slow_clk (spi_slow_clk),
        .sector       (sd_sector),
        .read_start   (sd_read_start),
        .read_data    (sd_read_data),
        .read_valid   (sd_read_valid),
        .read_done    (sd_read_done),
        .ready        (sd_ready),
        .err          (sd_error),
        .sdhc         (sd_sdhc)
    );

    sd_boot u_boot (
        .clk           (clk),
        .reset         (reset),
        .sd_sector     (sd_sector),
        .sd_read_start (sd_read_start),
        .sd_read_data  (sd_read_data),
        .sd_read_valid (sd_read_valid),
        .sd_read_done  (sd_read_done),
        .sd_ready      (sd_ready),
        .sd_error      (sd_error),
        .rom_addr      (rom_wr_addr),
        .rom_data      (rom_wr_data),
        .rom_wr        (rom_wr),
        .sdram_busy    (1'b0),         // no backpressure in test
        .done          (done),
        .boot_error    (boot_error),
        .error_code    (error_code)
    );

    sd_card_model #(
        .NUM_SECTORS  (8192),
        .ACMD41_DELAY (2)
    ) u_sd_card (
        .clk  (clk),
        .sclk (sclk),
        .mosi (mosi),
        .miso (miso),
        .cs_n (cs_n)
    );

    // =========================================================================
    // Preload minimal FAT32 filesystem
    // =========================================================================
    //
    // Layout:
    //   Sector 0:       MBR (partition 1 starts at LBA 2048, type 0x0C)
    //   Sector 2048:    VBR (BPB: 8 sectors/cluster, 32 reserved, 2 FATs)
    //   Sector 2080:    FAT1 (cluster 2 → chain for root dir, cluster 3 → ROM)
    //   Sector 2080+N:  FAT2 (mirror, not used)
    //   Sector 4128:    Root dir (cluster 2) with "TETRIS  GB " entry
    //   Sector 4136:    ROM data (cluster 3) — 8 sectors = 4096 bytes
    //   Sector 4144:    ROM data (cluster 4) — 8 sectors = 4096 bytes
    //
    // FAT32 parameters:
    //   sectors_per_cluster = 8
    //   reserved_sectors = 32
    //   num_fats = 2
    //   fat_size = 1024 sectors
    //   root_cluster = 2
    //   fat_start = 2048 + 32 = 2080
    //   data_start = 2080 + 2*1024 = 4128
    //   cluster 2 LBA = 4128 + (2-2)*8 = 4128 (root dir)
    //   cluster 3 LBA = 4128 + (3-2)*8 = 4136 (ROM data 1)
    //   cluster 4 LBA = 4128 + (4-2)*8 = 4144 (ROM data 2)

    initial begin
        // --- MBR (sector 0) ---
        // Partition entry 1 at offset 446 (14 bytes used):
        //   [0]: boot indicator (0x00)
        //   [4]: partition type (0x0C = FAT32 LBA)
        //   [8-11]: LBA start (2048 = 0x00000800, little-endian)
        u_sd_card.sector_mem[450] = 8'h0C;  // type = FAT32 LBA
        u_sd_card.sector_mem[454] = 8'h00;  // LBA start byte 0
        u_sd_card.sector_mem[455] = 8'h08;  // LBA start byte 1
        u_sd_card.sector_mem[456] = 8'h00;  // LBA start byte 2
        u_sd_card.sector_mem[457] = 8'h00;  // LBA start byte 3
        // MBR signature
        u_sd_card.sector_mem[510] = 8'h55;
        u_sd_card.sector_mem[511] = 8'hAA;

        // --- VBR (sector 2048) ---
        // Jump instruction
        u_sd_card.sector_mem[2048*512 + 0] = 8'hEB;
        u_sd_card.sector_mem[2048*512 + 1] = 8'h58;
        u_sd_card.sector_mem[2048*512 + 2] = 8'h90;
        // Bytes per sector = 512 (offset 11-12)
        u_sd_card.sector_mem[2048*512 + 11] = 8'h00;
        u_sd_card.sector_mem[2048*512 + 12] = 8'h02;
        // Sectors per cluster = 8 (offset 13)
        u_sd_card.sector_mem[2048*512 + 13] = 8'h08;
        // Reserved sectors = 32 (offset 14-15, little-endian)
        u_sd_card.sector_mem[2048*512 + 14] = 8'h20;
        u_sd_card.sector_mem[2048*512 + 15] = 8'h00;
        // Number of FATs = 2 (offset 16)
        u_sd_card.sector_mem[2048*512 + 16] = 8'h02;
        // FAT size 32 = 1024 (offset 36-39, little-endian)
        u_sd_card.sector_mem[2048*512 + 36] = 8'h00;
        u_sd_card.sector_mem[2048*512 + 37] = 8'h04;
        u_sd_card.sector_mem[2048*512 + 38] = 8'h00;
        u_sd_card.sector_mem[2048*512 + 39] = 8'h00;
        // Root cluster = 2 (offset 44-47, little-endian)
        u_sd_card.sector_mem[2048*512 + 44] = 8'h02;
        u_sd_card.sector_mem[2048*512 + 45] = 8'h00;
        u_sd_card.sector_mem[2048*512 + 46] = 8'h00;
        u_sd_card.sector_mem[2048*512 + 47] = 8'h00;

        // --- FAT (sector 2080) ---
        // Each FAT entry is 4 bytes, 128 entries per sector
        // Entry 0: media type (0x0FFFFFF8)
        u_sd_card.sector_mem[2080*512 + 0] = 8'hF8;
        u_sd_card.sector_mem[2080*512 + 1] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 2] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 3] = 8'h0F;
        // Entry 1: end of chain marker
        u_sd_card.sector_mem[2080*512 + 4] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 5] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 6] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 7] = 8'h0F;
        // Entry 2 (root dir cluster): end of chain
        u_sd_card.sector_mem[2080*512 + 8]  = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 9]  = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 10] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 11] = 8'h0F;
        // Entry 3 (ROM cluster 1): points to cluster 4
        u_sd_card.sector_mem[2080*512 + 12] = 8'h04;
        u_sd_card.sector_mem[2080*512 + 13] = 8'h00;
        u_sd_card.sector_mem[2080*512 + 14] = 8'h00;
        u_sd_card.sector_mem[2080*512 + 15] = 8'h00;
        // Entry 4 (ROM cluster 2): end of chain
        u_sd_card.sector_mem[2080*512 + 16] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 17] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 18] = 8'hFF;
        u_sd_card.sector_mem[2080*512 + 19] = 8'h0F;

        // --- Root directory (sector 4128 = cluster 2) ---
        // Entry 1: "TETRIS  GB " — 32 bytes
        //   Bytes 0-7: filename "TETRIS  "
        //   Bytes 8-10: extension "GB "
        //   Byte 11: attributes (0x20 = archive)
        //   Bytes 20-21: cluster high (0x0000)
        //   Bytes 26-27: cluster low (0x0003)
        //   Bytes 28-31: file size (8192 = 0x00002000)
        u_sd_card.sector_mem[4128*512 + 0]  = "T";
        u_sd_card.sector_mem[4128*512 + 1]  = "E";
        u_sd_card.sector_mem[4128*512 + 2]  = "T";
        u_sd_card.sector_mem[4128*512 + 3]  = "R";
        u_sd_card.sector_mem[4128*512 + 4]  = "I";
        u_sd_card.sector_mem[4128*512 + 5]  = "S";
        u_sd_card.sector_mem[4128*512 + 6]  = " ";
        u_sd_card.sector_mem[4128*512 + 7]  = " ";
        u_sd_card.sector_mem[4128*512 + 8]  = "G";
        u_sd_card.sector_mem[4128*512 + 9]  = "B";
        u_sd_card.sector_mem[4128*512 + 10] = " ";
        u_sd_card.sector_mem[4128*512 + 11] = 8'h20; // archive attribute
        // Cluster high = 0x0000 (bytes 20-21)
        u_sd_card.sector_mem[4128*512 + 20] = 8'h00;
        u_sd_card.sector_mem[4128*512 + 21] = 8'h00;
        // Cluster low = 0x0003 (bytes 26-27)
        u_sd_card.sector_mem[4128*512 + 26] = 8'h03;
        u_sd_card.sector_mem[4128*512 + 27] = 8'h00;
        // File size = 8192 = 0x00002000 (bytes 28-31)
        u_sd_card.sector_mem[4128*512 + 28] = 8'h00;
        u_sd_card.sector_mem[4128*512 + 29] = 8'h20;
        u_sd_card.sector_mem[4128*512 + 30] = 8'h00;
        u_sd_card.sector_mem[4128*512 + 31] = 8'h00;

        // --- ROM data (clusters 3-4, sectors 4136-4151) ---
        // Pattern: rom[i] = i[7:0]
        for (int i = 0; i < 8192; i++) begin
            u_sd_card.sector_mem[4136*512 + i] = i[7:0];
        end
    end

endmodule
