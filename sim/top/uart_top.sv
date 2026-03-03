// UART TX + RX test wrapper.
//
// Uses CYCLES_PER_BIT=4 for fast simulation (vs 234 for 27 MHz/115200).
// Exposes TX and RX interfaces independently so the testbench can test
// each module alone or wire them together for loopback.
module uart_top #(
    parameter int CYCLES_PER_BIT = 4
) (
    input  logic       clk,
    input  logic       reset,

    // TX interface
    input  logic [7:0] tx_data,
    input  logic       tx_valid,
    output logic       tx_ready,
    output logic       tx_pin,

    // RX interface
    input  logic       rx_pin,
    output logic [7:0] rx_data,
    output logic       rx_valid
);

    uart_tx #(
        .CYCLES_PER_BIT(CYCLES_PER_BIT)
    ) u_tx (
        .clk  (clk),
        .reset(reset),
        .data (tx_data),
        .valid(tx_valid),
        .ready(tx_ready),
        .tx   (tx_pin)
    );

    uart_rx #(
        .CYCLES_PER_BIT(CYCLES_PER_BIT)
    ) u_rx (
        .clk  (clk),
        .reset(reset),
        .rx   (rx_pin),
        .data (rx_data),
        .valid(rx_valid)
    );

endmodule
