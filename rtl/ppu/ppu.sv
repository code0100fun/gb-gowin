// Game Boy PPU — Background and Window renderer.
//
// Combinational pixel pipeline: for a given (pixel_x, pixel_y) from the
// ST7789 LCD controller, fetches tile data from VRAM, decodes 2bpp pixels,
// applies the BGP palette, and outputs RGB565.
//
// VRAM (8 KB) lives inside this module. The CPU writes via the bus ports;
// the PPU reads internally through combinational array lookups.
//
// Implements registers: LCDC (FF40), STAT (FF41), SCY (FF42), SCX (FF43),
// LY (FF44), LYC (FF45), BGP (FF47), WY (FF4A), WX (FF4B).
//
// Simplified timing: LY tracks pixel_y from the display controller.
// Accurate mode transitions and STAT interrupts come in Tutorial 15.
module ppu (
    input  logic        clk,
    input  logic        reset,

    // CPU VRAM access (from bus)
    input  logic [12:0] cpu_vram_addr,
    input  logic        cpu_vram_cs,
    input  logic        cpu_vram_we,
    input  logic [7:0]  cpu_vram_wdata,
    output logic [7:0]  cpu_vram_rdata,

    // I/O registers (from bus, same pattern as timer)
    input  logic        io_cs,
    input  logic [6:0]  io_addr,
    input  logic        io_wr,
    input  logic        io_rd,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    output logic        io_rdata_valid,

    // Pixel interface (from/to ST7789 controller)
    input  logic [7:0]  pixel_x,
    input  logic [7:0]  pixel_y,
    output logic [15:0] pixel_data,

    // Interrupts
    output logic        irq_vblank
);

    // -----------------------------------------------------------------
    // VRAM — 8 KB array, combinational reads, synchronous writes
    // -----------------------------------------------------------------
    logic [7:0] vram [0:8191];
    initial for (int i = 0; i < 8192; i++) vram[i] = 8'h00;

    // CPU read port (combinational)
    assign cpu_vram_rdata = vram[cpu_vram_addr];

    // CPU write port (synchronous)
    always_ff @(posedge clk) begin
        if (cpu_vram_cs && cpu_vram_we)
            vram[cpu_vram_addr] <= cpu_vram_wdata;
    end

    // -----------------------------------------------------------------
    // PPU registers
    // -----------------------------------------------------------------
    logic [7:0] reg_lcdc;   // FF40
    logic [7:0] reg_stat;   // FF41
    logic [7:0] reg_scy;    // FF42
    logic [7:0] reg_scx;    // FF43
    // LY (FF44) is read-only, derived from pixel_y
    logic [7:0] reg_lyc;    // FF45
    logic [7:0] reg_bgp;    // FF47
    logic [7:0] reg_wy;     // FF4A
    logic [7:0] reg_wx;     // FF4B

    initial begin
        reg_lcdc = 8'h00;
        reg_stat = 8'h00;
        reg_scy  = 8'h00;
        reg_scx  = 8'h00;
        reg_lyc  = 8'h00;
        reg_bgp  = 8'hFC;  // default palette: 3,3,2,0 → shades 11,10,01,00
        reg_wy   = 8'h00;
        reg_wx   = 8'h00;
    end

    // LY = pixel_y (simplified — accurate timing in Tutorial 15)
    wire [7:0] ly = pixel_y;

    // STAT register: bits [1:0] = mode (always 3 for now), bit 2 = LY==LYC
    wire [7:0] stat_read = {1'b1, reg_stat[6:3], (ly == reg_lyc) ? 1'b1 : 1'b0, 2'b11};

    // Register writes
    always_ff @(posedge clk) begin
        if (reset) begin
            reg_lcdc <= 8'h00;
            reg_stat <= 8'h00;
            reg_scy  <= 8'h00;
            reg_scx  <= 8'h00;
            reg_lyc  <= 8'h00;
            reg_bgp  <= 8'hFC;
            reg_wy   <= 8'h00;
            reg_wx   <= 8'h00;
        end else if (io_cs && io_wr) begin
            case (io_addr)
                7'h40: reg_lcdc <= io_wdata;
                7'h41: reg_stat <= io_wdata;
                7'h42: reg_scy  <= io_wdata;
                7'h43: reg_scx  <= io_wdata;
                // 7'h44: LY is read-only
                7'h45: reg_lyc  <= io_wdata;
                7'h47: reg_bgp  <= io_wdata;
                7'h4A: reg_wy   <= io_wdata;
                7'h4B: reg_wx   <= io_wdata;
                default: ;
            endcase
        end
    end

    // Register reads
    assign io_rdata_valid = io_cs && (io_addr >= 7'h40) && (io_addr <= 7'h4B);

    always_comb begin
        case (io_addr)
            7'h40:   io_rdata = reg_lcdc;
            7'h41:   io_rdata = stat_read;
            7'h42:   io_rdata = reg_scy;
            7'h43:   io_rdata = reg_scx;
            7'h44:   io_rdata = ly;
            7'h45:   io_rdata = reg_lyc;
            7'h47:   io_rdata = reg_bgp;
            7'h4A:   io_rdata = reg_wy;
            7'h4B:   io_rdata = reg_wx;
            default: io_rdata = 8'hFF;
        endcase
    end

    // -----------------------------------------------------------------
    // Window line counter
    // -----------------------------------------------------------------
    // The window has its own internal line counter that only increments
    // when the window was visible on a completed scanline.
    logic [7:0] win_line;
    logic [7:0] prev_pixel_y;

    initial begin
        win_line     = 8'd0;
        prev_pixel_y = 8'd0;
    end

    // Detect scanline transitions and frame start
    always_ff @(posedge clk) begin
        if (reset) begin
            win_line     <= 8'd0;
            prev_pixel_y <= 8'd0;
        end else begin
            prev_pixel_y <= pixel_y;

            // Frame start: pixel_y went from non-zero back to 0
            if (pixel_y == 8'd0 && prev_pixel_y != 8'd0) begin
                win_line <= 8'd0;
            end
            // Scanline transition: pixel_y incremented
            else if (pixel_y != prev_pixel_y && pixel_y != 8'd0) begin
                // If window was active on the previous scanline
                if (reg_lcdc[5] && prev_pixel_y >= reg_wy && reg_wx <= 8'd166) begin
                    win_line <= win_line + 8'd1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // VBlank IRQ — pulse when frame completes (pixel_y: 143 → 0)
    // -----------------------------------------------------------------
    logic prev_vblank;
    initial prev_vblank = 1'b0;

    always_ff @(posedge clk) begin
        if (reset)
            prev_vblank <= 1'b0;
        else
            prev_vblank <= (pixel_y == 8'd0 && prev_pixel_y != 8'd0);
    end

    // Single-cycle pulse
    assign irq_vblank = (pixel_y == 8'd0 && prev_pixel_y != 8'd0) && !prev_vblank;

    // -----------------------------------------------------------------
    // Combinational pixel pipeline
    // -----------------------------------------------------------------

    // LCDC bit aliases
    wire lcd_on     = reg_lcdc[7];
    wire win_map_hi = reg_lcdc[6]; // 0 = 9800, 1 = 9C00
    wire win_enable = reg_lcdc[5];
    wire tile_data_sel = reg_lcdc[4]; // 0 = 8800/signed, 1 = 8000/unsigned
    wire bg_map_hi  = reg_lcdc[3]; // 0 = 9800, 1 = 9C00
    wire bg_enable  = reg_lcdc[0];

    // DMG shade → RGB565 lookup
    function logic [15:0] shade_to_rgb565(logic [1:0] shade);
        case (shade)
            2'd0: shade_to_rgb565 = 16'hFFFF; // white
            2'd1: shade_to_rgb565 = 16'hAD55; // light gray
            2'd2: shade_to_rgb565 = 16'h52AA; // dark gray
            2'd3: shade_to_rgb565 = 16'h0000; // black
        endcase
    endfunction

    // Compute tile data address from tile index and row
    function logic [12:0] tile_data_addr(logic [7:0] tile_idx, logic [2:0] row);
        if (tile_data_sel) begin
            // Unsigned mode (LCDC.4=1): base 0x0000
            tile_data_addr = {1'b0, tile_idx, row, 1'b0};
        end else begin
            // Signed mode (LCDC.4=0): base 0x1000, tile_idx is signed
            // 0x1000 + signed(tile_idx) * 16 + row * 2
            tile_data_addr = 13'h1000 + {tile_idx[7], tile_idx, row, 1'b0};
        end
    endfunction

    // Background pixel calculation
    wire [7:0] bg_y = pixel_y + reg_scy;
    wire [7:0] bg_x = pixel_x + reg_scx;
    wire [12:0] bg_map_addr = (bg_map_hi ? 13'h1C00 : 13'h1800)
                             + {3'b000, bg_y[7:3], bg_x[7:3]};
    wire [7:0] bg_tile_idx = vram[bg_map_addr];
    wire [12:0] bg_data_base = tile_data_addr(bg_tile_idx, bg_y[2:0]);
    wire [7:0] bg_tile_lo = vram[bg_data_base];
    wire [7:0] bg_tile_hi = vram[bg_data_base + 13'd1];
    wire [2:0] bg_bit_pos = 3'd7 - bg_x[2:0];
    wire [1:0] bg_color_id = {bg_tile_hi[bg_bit_pos], bg_tile_lo[bg_bit_pos]};
    wire [1:0] bg_shade = reg_bgp[bg_color_id * 2 +: 2];

    // Window pixel calculation
    wire win_active = win_enable
                   && (pixel_y >= reg_wy)
                   && (pixel_x + 8'd7 >= reg_wx);
    wire [7:0] win_x = pixel_x + 8'd7 - reg_wx;
    wire [7:0] win_y = win_line;
    wire [12:0] win_map_addr = (win_map_hi ? 13'h1C00 : 13'h1800)
                              + {3'b000, win_y[7:3], win_x[7:3]};
    wire [7:0] win_tile_idx = vram[win_map_addr];
    wire [12:0] win_data_base = tile_data_addr(win_tile_idx, win_y[2:0]);
    wire [7:0] win_tile_lo = vram[win_data_base];
    wire [7:0] win_tile_hi = vram[win_data_base + 13'd1];
    wire [2:0] win_bit_pos = 3'd7 - win_x[2:0];
    wire [1:0] win_color_id = {win_tile_hi[win_bit_pos], win_tile_lo[win_bit_pos]};
    wire [1:0] win_shade = reg_bgp[win_color_id * 2 +: 2];

    // Final pixel output
    always_comb begin
        if (!lcd_on) begin
            // LCD off — white screen
            pixel_data = 16'hFFFF;
        end else if (!bg_enable) begin
            // BG disabled — white (DMG behavior)
            pixel_data = 16'hFFFF;
        end else if (win_active) begin
            // Window overrides background
            pixel_data = shade_to_rgb565(win_shade);
        end else begin
            // Background
            pixel_data = shade_to_rgb565(bg_shade);
        end
    end

endmodule
