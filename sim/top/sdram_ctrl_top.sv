// Test wrapper for sdram_ctrl — includes sdram_model.
//
// Exposes the user-side interface (rd/wr/refresh/addr/din/dout/busy/
// data_ready) to the Zig testbench. Internally wires the controller
// to the behavioral SDRAM model.
module sdram_ctrl_top (
    input  logic        clk,
    input  logic        reset,

    // User interface
    input  logic        rd,
    input  logic        wr,
    input  logic        refresh,
    input  logic [22:0] addr,
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        data_ready,
    output logic        busy
);

    // Controller ↔ model wires
    logic        sdram_clk;
    logic        sdram_cke;
    logic        sdram_cs_n;
    logic        sdram_ras_n;
    logic        sdram_cas_n;
    logic        sdram_we_n;
    logic [10:0] sdram_addr_w;
    logic [1:0]  sdram_ba;
    logic [3:0]  sdram_dqm;
    logic [31:0] sdram_dq_out;
    logic        sdram_dq_oe;
    logic [31:0] sdram_dq_in;

    sdram_ctrl u_ctrl (
        .clk        (clk),
        .reset      (reset),
        .rd         (rd),
        .wr         (wr),
        .refresh    (refresh),
        .addr       (addr),
        .din        (din),
        .dout       (dout),
        .data_ready (data_ready),
        .busy       (busy),
        .sdram_clk  (sdram_clk),
        .sdram_cke  (sdram_cke),
        .sdram_cs_n (sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n (sdram_we_n),
        .sdram_addr (sdram_addr_w),
        .sdram_ba   (sdram_ba),
        .sdram_dqm  (sdram_dqm),
        .sdram_dq_out(sdram_dq_out),
        .sdram_dq_oe (sdram_dq_oe),
        .sdram_dq_in (sdram_dq_in)
    );

    sdram_model u_sdram (
        .clk        (clk),
        .sdram_clk  (sdram_clk),
        .sdram_cke  (sdram_cke),
        .sdram_cs_n (sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n (sdram_we_n),
        .sdram_addr (sdram_addr_w),
        .sdram_ba   (sdram_ba),
        .sdram_dqm  (sdram_dqm),
        .sdram_dq_out(sdram_dq_out),
        .sdram_dq_oe (sdram_dq_oe),
        .sdram_dq_in (sdram_dq_in)
    );

endmodule
