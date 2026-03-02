// Simulation wrapper for the PPU — standalone with direct VRAM/OAM/register access.
//
// The testbench preloads VRAM with tile data and tile maps, writes OAM
// entries, sets PPU registers, then drives pixel_fetch to trigger the
// tile-fetch pipeline and waits for pixel_data_valid before reading
// pixel_data.
module ppu_top (
    input  logic        clk,
    input  logic        reset,

    // VRAM write/read port (testbench preloads tiles and maps)
    input  logic [12:0] vram_addr,
    input  logic        vram_wr,
    input  logic [7:0]  vram_wdata,
    output logic [7:0]  vram_rdata,

    // OAM write/read port (testbench writes sprite entries)
    input  logic [7:0]  oam_addr,
    input  logic        oam_wr,
    input  logic [7:0]  oam_wdata,
    output logic [7:0]  oam_rdata,

    // Register interface (testbench writes PPU registers)
    input  logic [6:0]  io_addr,
    input  logic        io_wr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,

    // Pixel interface (testbench drives x/y and pixel_fetch)
    input  logic [7:0]  pixel_x,
    input  logic [7:0]  pixel_y,
    input  logic        pixel_fetch,
    output logic [15:0] pixel_data,
    output logic        pixel_data_valid,

    // Debug outputs
    output logic [7:0]  dbg_lcdc,
    output logic [7:0]  dbg_scy,
    output logic [7:0]  dbg_scx,
    output logic [7:0]  dbg_bgp,
    output logic [7:0]  dbg_ly,
    output logic [7:0]  dbg_wy,
    output logic [7:0]  dbg_wx,
    output logic        dbg_irq_vblank,
    output logic        dbg_irq_stat
);

    // I/O rdata_valid not needed at wrapper level
    logic io_rdata_valid;

    ppu u_ppu (
        .clk            (clk),
        .reset          (reset),

        // VRAM: testbench drives directly (Port A of dual_port_ram)
        .cpu_vram_addr  (vram_addr),
        .cpu_vram_cs    (1'b1),        // always selected
        .cpu_vram_we    (vram_wr),
        .cpu_vram_wdata (vram_wdata),
        .cpu_vram_rdata (vram_rdata),

        // OAM: testbench drives directly
        .cpu_oam_addr   (oam_addr),
        .cpu_oam_cs     (1'b1),        // always selected
        .cpu_oam_we     (oam_wr),
        .cpu_oam_wdata  (oam_wdata),
        .cpu_oam_rdata  (oam_rdata),

        // I/O registers: testbench drives directly
        .io_cs          (1'b1),        // always selected
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_rd          (1'b0),
        .io_wdata       (io_wdata),
        .io_rdata       (io_rdata),
        .io_rdata_valid (io_rdata_valid),

        // Pixel interface
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pixel_fetch      (pixel_fetch),
        .pixel_data       (pixel_data),
        .pixel_data_valid (pixel_data_valid),

        // Interrupts
        .irq_vblank     (dbg_irq_vblank),
        .irq_stat       (dbg_irq_stat)
    );

    // Debug: read registers back via io bus
    assign dbg_lcdc = 8'h00;
    assign dbg_scy  = 8'h00;
    assign dbg_scx  = 8'h00;
    assign dbg_bgp  = 8'h00;
    assign dbg_ly   = 8'h00;
    assign dbg_wy   = 8'h00;
    assign dbg_wx   = 8'h00;

endmodule
