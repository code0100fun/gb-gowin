// Standalone joypad test wrapper — no CPU needed.
//
// Directly exposes I/O bus signals for the testbench to drive.
// io_cs is hardwired to 1 so writes always register.
// Uses DEBOUNCE_CYCLES=4 for fast simulation (vs 27000 for hardware).
module joypad_top #(
    parameter int DEBOUNCE_CYCLES = 4
) (
    input  logic       clk,
    input  logic       reset,

    // Direct I/O bus control
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,

    // Button inputs {start, select, b, a, down, up, left, right}
    input  logic [7:0] btn,

    // Debug
    output logic       dbg_irq
);

    joypad #(
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) u_joypad (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (1'b1),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (io_rdata),
        .io_rdata_valid (),
        .btn            (btn),
        .irq            (dbg_irq)
    );

endmodule
