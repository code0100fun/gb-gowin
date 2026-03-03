// Standalone serial port test wrapper — no CPU needed.
//
// Directly exposes I/O bus signals for the testbench to drive.
// io_cs is hardwired to 1 so writes always register.
// Uses CLOCKS_PER_BIT=4 for fast simulation (vs 128 for hardware).
module serial_top #(
    parameter int CLOCKS_PER_BIT = 4
) (
    input  logic       clk,
    input  logic       reset,

    // Direct I/O bus control
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,

    // Debug
    output logic       dbg_irq,
    output logic [7:0] dbg_sb,
    output logic [7:0] dbg_sc
);

    serial #(
        .CLOCKS_PER_BIT(CLOCKS_PER_BIT)
    ) u_serial (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (1'b1),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (io_rdata),
        .io_rdata_valid (),
        .irq            (dbg_irq),
        .dbg_sb         (dbg_sb),
        .dbg_sc         (dbg_sc)
    );

endmodule
