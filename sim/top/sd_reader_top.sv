// Test wrapper for sd_reader — includes sd_spi and sd_card_model.
//
// The sd_card_model acts as a simulated SD card, responding to SPI
// commands. Sector data can be preloaded by the test wrapper's
// initial block (accessed via sector_mem in the model).
module sd_reader_top #(
    parameter int NUM_SECTORS = 16
) (
    input  logic        clk,
    input  logic        reset,

    // Sector read interface (directly from sd_reader)
    input  logic [31:0] sector,
    input  logic        read_start,
    output logic [7:0]  read_data,
    output logic        read_valid,
    output logic        read_done,
    output logic        ready,
    output logic        err,
    output logic        sdhc
);

    // sd_spi ↔ sd_reader wires
    logic [7:0] spi_tx;
    logic       spi_start;
    logic [7:0] spi_rx;
    logic       spi_busy;
    logic       spi_done;
    logic       spi_cs_en;
    logic       spi_slow_clk;

    // SPI physical wires
    logic       sclk, mosi, miso, cs_n;

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
        .sector       (sector),
        .read_start   (read_start),
        .read_data    (read_data),
        .read_valid   (read_valid),
        .read_done    (read_done),
        .ready        (ready),
        .err          (err),
        .sdhc         (sdhc)
    );

    sd_card_model #(
        .NUM_SECTORS  (NUM_SECTORS),
        .ACMD41_DELAY (2)
    ) u_sd_card (
        .clk  (clk),
        .sclk (sclk),
        .mosi (mosi),
        .miso (miso),
        .cs_n (cs_n)
    );

    // Preload sector 0 with a known pattern: byte[i] = i[7:0]
    initial begin
        for (int i = 0; i < 512; i++)
            u_sd_card.sector_mem[i] = i[7:0];
        // Sector 1: all 0xAA
        for (int i = 0; i < 512; i++)
            u_sd_card.sector_mem[512 + i] = 8'hAA;
    end

endmodule
