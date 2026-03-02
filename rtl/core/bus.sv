// Game Boy address decoder and read multiplexer.
//
// Purely combinational — no clock, no registered state. Maps the CPU's
// 16-bit address space onto individual device chip-select lines, local
// addresses, and a read-data mux.
//
// Memory map (active regions this tutorial):
//   0000-7FFF  ROM (32 KB)        — active
//   8000-9FFF  VRAM (8 KB)        — active
//   A000-BFFF  External RAM       — stub (returns FF)
//   C000-DFFF  WRAM (8 KB)        — active
//   E000-FDFF  Echo RAM           — mirrors WRAM
//   FE00-FE9F  OAM (160 bytes)    — active
//   FEA0-FEFF  Unusable           — returns FF
//   FF00-FF7F  I/O registers      — active (active select, no logic yet)
//   FF80-FFFE  HRAM (127 bytes)   — active
//   FFFF       IE register        — active (active select)
module bus (
    // CPU side
    input  logic [15:0] cpu_addr,
    input  logic        cpu_rd,
    input  logic        cpu_wr,
    input  logic [7:0]  cpu_wdata,
    output logic [7:0]  cpu_rdata,

    // ROM (0000-7FFF)
    output logic [14:0] rom_addr,
    output logic        rom_cs,
    input  logic [7:0]  rom_rdata,

    // WRAM (C000-DFFF, echoed at E000-FDFF)
    output logic [12:0] wram_addr,
    output logic        wram_cs,
    output logic        wram_we,
    output logic [7:0]  wram_wdata,
    input  logic [7:0]  wram_rdata,

    // HRAM (FF80-FFFE)
    output logic [6:0]  hram_addr,
    output logic        hram_cs,
    output logic        hram_we,
    output logic [7:0]  hram_wdata,
    input  logic [7:0]  hram_rdata,

    // I/O registers (FF00-FF7F)
    output logic [6:0]  io_addr,
    output logic        io_cs,
    output logic        io_rd,
    output logic        io_wr,
    output logic [7:0]  io_wdata,
    input  logic [7:0]  io_rdata,

    // VRAM (8000-9FFF)
    output logic [12:0] vram_addr,
    output logic        vram_cs,
    output logic        vram_we,
    output logic [7:0]  vram_wdata,
    input  logic [7:0]  vram_rdata,

    // OAM (FE00-FE9F)
    output logic [7:0]  oam_addr,
    output logic        oam_cs,
    output logic        oam_we,
    output logic [7:0]  oam_wdata,
    input  logic [7:0]  oam_rdata,

    // IE register (FFFF)
    output logic        ie_cs,
    output logic        ie_we,
    output logic [7:0]  ie_wdata,
    input  logic [7:0]  ie_rdata
);

    // Write data is always the CPU's write data, regardless of device
    assign vram_wdata = cpu_wdata;
    assign wram_wdata = cpu_wdata;
    assign hram_wdata = cpu_wdata;
    assign io_wdata   = cpu_wdata;
    assign oam_wdata  = cpu_wdata;
    assign ie_wdata   = cpu_wdata;

    always_comb begin
        // Defaults: nothing selected, open bus
        rom_cs   = 1'b0;
        vram_cs  = 1'b0;
        wram_cs  = 1'b0;
        hram_cs  = 1'b0;
        io_cs    = 1'b0;
        oam_cs   = 1'b0;
        ie_cs    = 1'b0;

        rom_addr  = cpu_addr[14:0];
        vram_addr = cpu_addr[12:0];
        wram_addr = cpu_addr[12:0];
        hram_addr = cpu_addr[6:0];
        io_addr   = cpu_addr[6:0];
        oam_addr  = cpu_addr[7:0];

        vram_we = 1'b0;
        wram_we = 1'b0;
        hram_we = 1'b0;
        oam_we  = 1'b0;
        io_rd   = 1'b0;
        io_wr   = 1'b0;
        ie_we   = 1'b0;

        cpu_rdata = 8'hFF;  // open bus default

        // Address decode (priority: most specific first)
        casez (cpu_addr)
            // ROM: 0000-7FFF
            16'b0???_????_????_????: begin
                rom_cs    = 1'b1;
                rom_addr  = cpu_addr[14:0];
                cpu_rdata = rom_rdata;
            end

            // VRAM: 8000-9FFF
            16'b100?_????_????_????: begin
                vram_cs   = 1'b1;
                vram_addr = cpu_addr[12:0];
                vram_we   = cpu_wr;
                cpu_rdata = vram_rdata;
            end

            // External RAM: A000-BFFF (stub)
            16'b101?_????_????_????: begin
                cpu_rdata = 8'hFF;
            end

            // WRAM: C000-DFFF
            16'b110?_????_????_????: begin
                wram_cs   = 1'b1;
                wram_addr = cpu_addr[12:0];
                wram_we   = cpu_wr;
                cpu_rdata = wram_rdata;
            end

            // Echo RAM: E000-FDFF (mirrors C000-DDFF)
            16'b111?_????_????_????: begin
                if (cpu_addr <= 16'hFDFF) begin
                    wram_cs   = 1'b1;
                    wram_addr = cpu_addr[12:0];  // bottom 13 bits same as WRAM
                    wram_we   = cpu_wr;
                    cpu_rdata = wram_rdata;
                end else if (cpu_addr <= 16'hFE9F) begin
                    // OAM: FE00-FE9F
                    oam_cs    = 1'b1;
                    oam_addr  = cpu_addr[7:0];
                    oam_we    = cpu_wr;
                    cpu_rdata = oam_rdata;
                end else if (cpu_addr <= 16'hFEFF) begin
                    // Unusable: FEA0-FEFF
                    cpu_rdata = 8'hFF;
                end else if (cpu_addr <= 16'hFF7F) begin
                    // I/O: FF00-FF7F
                    io_cs     = 1'b1;
                    io_addr   = cpu_addr[6:0];
                    io_rd     = cpu_rd;
                    io_wr     = cpu_wr;
                    cpu_rdata = io_rdata;
                end else if (cpu_addr <= 16'hFFFE) begin
                    // HRAM: FF80-FFFE
                    hram_cs   = 1'b1;
                    hram_addr = cpu_addr[6:0];
                    hram_we   = cpu_wr;
                    cpu_rdata = hram_rdata;
                end else begin
                    // IE register: FFFF
                    ie_cs     = 1'b1;
                    ie_we     = cpu_wr;
                    cpu_rdata = ie_rdata;
                end
            end

            default: begin
                cpu_rdata = 8'hFF;
            end
        endcase
    end

endmodule
