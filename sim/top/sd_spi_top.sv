// Test wrapper for sd_spi module.
//
// Exposes the SPI signals directly so the Zig testbench can
// drive MISO and verify MOSI/SCLK/CS timing.
module sd_spi_top (
    input  logic       clk,
    input  logic       reset,

    // Control inputs
    input  logic [7:0] tx_data,
    input  logic       start,
    input  logic       cs_en,
    input  logic       slow_clk,
    input  logic       miso_in,    // testbench drives this

    // Outputs
    output logic       sclk_out,
    output logic       mosi_out,
    output logic       cs_n_out,
    output logic [7:0] rx_data,
    output logic       busy,
    output logic       done
);

    sd_spi u_sd_spi (
        .clk      (clk),
        .reset    (reset),
        .sclk     (sclk_out),
        .mosi     (mosi_out),
        .miso     (miso_in),
        .cs_n     (cs_n_out),
        .tx_data  (tx_data),
        .start    (start),
        .rx_data  (rx_data),
        .busy     (busy),
        .done     (done),
        .cs_en    (cs_en),
        .slow_clk (slow_clk)
    );

endmodule
