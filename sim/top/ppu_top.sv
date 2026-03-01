// Simulation wrapper for the PPU — standalone with direct VRAM/register access.
//
// The testbench preloads VRAM with tile data and tile maps, sets PPU
// registers, then drives pixel coordinates to verify pixel output.
// No CPU needed — all access is direct through the wrapper ports.
module ppu_top (
    input  logic        clk,
    input  logic        reset,

    // VRAM write/read port (testbench preloads tiles and maps)
    input  logic [12:0] vram_addr,
    input  logic        vram_wr,
    input  logic [7:0]  vram_wdata,
    output logic [7:0]  vram_rdata,

    // Register interface (testbench writes PPU registers)
    input  logic [6:0]  io_addr,
    input  logic        io_wr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,

    // Pixel interface (testbench drives x/y, reads pixel_data)
    input  logic [7:0]  pixel_x,
    input  logic [7:0]  pixel_y,
    output logic [15:0] pixel_data,

    // Debug outputs
    output logic [7:0]  dbg_lcdc,
    output logic [7:0]  dbg_scy,
    output logic [7:0]  dbg_scx,
    output logic [7:0]  dbg_bgp,
    output logic [7:0]  dbg_ly,
    output logic [7:0]  dbg_wy,
    output logic [7:0]  dbg_wx,
    output logic        dbg_irq_vblank
);

    // I/O rdata_valid not needed at wrapper level
    logic io_rdata_valid;

    ppu u_ppu (
        .clk            (clk),
        .reset          (reset),

        // VRAM: testbench drives directly
        .cpu_vram_addr  (vram_addr),
        .cpu_vram_cs    (1'b1),        // always selected
        .cpu_vram_we    (vram_wr),
        .cpu_vram_wdata (vram_wdata),
        .cpu_vram_rdata (vram_rdata),

        // I/O registers: testbench drives directly
        .io_cs          (1'b1),        // always selected
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_rd          (1'b0),
        .io_wdata       (io_wdata),
        .io_rdata       (io_rdata),
        .io_rdata_valid (io_rdata_valid),

        // Pixel interface
        .pixel_x        (pixel_x),
        .pixel_y        (pixel_y),
        .pixel_data     (pixel_data),

        // Interrupts
        .irq_vblank     (dbg_irq_vblank)
    );

    // Debug: read registers back via io bus
    // (The testbench can read by setting io_addr and checking io_rdata)
    assign dbg_lcdc = 8'h00; // placeholder — read via io_rdata
    assign dbg_scy  = 8'h00;
    assign dbg_scx  = 8'h00;
    assign dbg_bgp  = 8'h00;
    assign dbg_ly   = 8'h00;
    assign dbg_wy   = 8'h00;
    assign dbg_wx   = 8'h00;

endmodule
