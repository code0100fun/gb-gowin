// Debug console test wrapper.
//
// Uses CYCLES_PER_BIT=4 for fast simulation. Exposes UART pins and
// all debug signal inputs for the testbench to drive directly.
module debug_console_top #(
    parameter int CYCLES_PER_BIT = 4
) (
    input  logic        clk,
    input  logic        reset,

    // UART pins (directly exposed for bit-banging)
    input  logic        uart_rx_pin,
    output logic        uart_tx_pin,

    // CPU debug signals
    input  logic [15:0] dbg_pc,
    input  logic [15:0] dbg_sp,
    input  logic [7:0]  dbg_a, dbg_f,
    input  logic [7:0]  dbg_b, dbg_c,
    input  logic [7:0]  dbg_d, dbg_e,
    input  logic [7:0]  dbg_h, dbg_l,
    input  logic        dbg_halted,

    // Interrupt debug
    input  logic [7:0]  dbg_if,
    input  logic [7:0]  dbg_ie
);

    debug_console #(
        .CYCLES_PER_BIT(CYCLES_PER_BIT)
    ) u_console (
        .clk         (clk),
        .reset       (reset),
        .uart_rx_pin (uart_rx_pin),
        .uart_tx_pin (uart_tx_pin),
        .dbg_pc      (dbg_pc),
        .dbg_sp      (dbg_sp),
        .dbg_a       (dbg_a),
        .dbg_f       (dbg_f),
        .dbg_b       (dbg_b),
        .dbg_c       (dbg_c),
        .dbg_d       (dbg_d),
        .dbg_e       (dbg_e),
        .dbg_h       (dbg_h),
        .dbg_l       (dbg_l),
        .dbg_halted  (dbg_halted),
        .dbg_if      (dbg_if),
        .dbg_ie      (dbg_ie)
    );

endmodule
