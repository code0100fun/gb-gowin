// Game Boy PPU — Background and Window renderer.
//
// VRAM (8 KB) is stored in a dual-port BSRAM: Port A for CPU read/write,
// Port B for PPU tile fetches. Since BSRAM has synchronous reads (1-cycle
// latency), the PPU uses a pipeline FSM to fetch tile data over multiple
// cycles instead of the previous combinational lookup chain.
//
// The ST7789 LCD controller pulses pixel_fetch when it needs a new pixel.
// The PPU latches pixel_x/pixel_y, walks the tile fetch pipeline (4 cycles
// for BG only, 7 cycles for BG + window), then asserts pixel_data_valid.
//
// Implements registers: LCDC (FF40), STAT (FF41), SCY (FF42), SCX (FF43),
// LY (FF44), LYC (FF45), BGP (FF47), WY (FF4A), WX (FF4B).
//
// Simplified timing: LY tracks pixel_y from the display controller.
// Accurate mode transitions and STAT interrupts come in a later tutorial.
module ppu (
    input  logic        clk,
    input  logic        reset,

    // CPU VRAM access (from bus) — dual_port_ram Port A
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
    input  logic        pixel_fetch,      // pulse: start tile fetch pipeline
    output logic [15:0] pixel_data,
    output logic        pixel_data_valid, // level: pixel_data is ready

    // Interrupts
    output logic        irq_vblank
);

    // -----------------------------------------------------------------
    // VRAM — 8 KB dual-port BSRAM
    // Port A: CPU read/write (synchronous)
    // Port B: PPU pipeline read-only (synchronous)
    // -----------------------------------------------------------------
    logic [12:0] ppu_vram_addr;
    logic [7:0]  ppu_vram_rdata;

    dual_port_ram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_vram (
        .clk_a  (clk),
        .we_a   (cpu_vram_cs && cpu_vram_we),
        .addr_a (cpu_vram_addr),
        .wdata_a(cpu_vram_wdata),
        .rdata_a(cpu_vram_rdata),
        .clk_b  (clk),
        .we_b   (1'b0),
        .addr_b (ppu_vram_addr),
        .wdata_b(8'd0),
        .rdata_b(ppu_vram_rdata)
    );

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
        reg_bgp  = 8'hFC;  // default palette: 3,3,2,0 -> shades 11,10,01,00
        reg_wy   = 8'h00;
        reg_wx   = 8'h00;
    end

    // LY = pixel_y (simplified -- accurate timing in a later tutorial)
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
    logic [7:0] win_line;
    logic [7:0] prev_pixel_y;

    initial begin
        win_line     = 8'd0;
        prev_pixel_y = 8'd0;
    end

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
                if (reg_lcdc[5] && prev_pixel_y >= reg_wy && reg_wx <= 8'd166) begin
                    win_line <= win_line + 8'd1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // VBlank IRQ -- pulse when frame completes (pixel_y: 143 -> 0)
    // -----------------------------------------------------------------
    logic prev_vblank;
    initial prev_vblank = 1'b0;

    always_ff @(posedge clk) begin
        if (reset)
            prev_vblank <= 1'b0;
        else
            prev_vblank <= (pixel_y == 8'd0 && prev_pixel_y != 8'd0);
    end

    assign irq_vblank = (pixel_y == 8'd0 && prev_pixel_y != 8'd0) && !prev_vblank;

    // -----------------------------------------------------------------
    // LCDC bit aliases
    // -----------------------------------------------------------------
    wire lcd_on        = reg_lcdc[7];
    wire win_map_hi    = reg_lcdc[6]; // 0 = 9800, 1 = 9C00
    wire win_enable    = reg_lcdc[5];
    wire tile_data_sel = reg_lcdc[4]; // 0 = 8800/signed, 1 = 8000/unsigned
    wire bg_map_hi     = reg_lcdc[3]; // 0 = 9800, 1 = 9C00
    wire bg_enable     = reg_lcdc[0];

    // DMG shade -> RGB565 lookup
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
            tile_data_addr = 13'h1000 + {tile_idx[7], tile_idx, row, 1'b0};
        end
    endfunction

    // -----------------------------------------------------------------
    // Tile fetch pipeline FSM
    // -----------------------------------------------------------------
    // BSRAM has 1-cycle read latency: set address in cycle N, data
    // available in cycle N+1. The FSM walks through tile map and tile
    // data reads for BG (3 reads = 4 cycles) and optionally window
    // (3 more reads = 7 cycles total).
    //
    // ppu_vram_addr is driven COMBINATIONALLY from the FSM state and
    // ppu_vram_rdata (which is a registered BSRAM output — no loop).

    typedef enum logic [2:0] {
        PX_IDLE,
        PX_BG_MAP,
        PX_BG_LO,
        PX_BG_HI,
        PX_WIN_MAP,
        PX_WIN_LO,
        PX_WIN_HI,
        PX_DONE
    } px_state_t;

    px_state_t px_state;

    // Latched pixel coordinates (frozen when pipeline starts)
    logic [7:0] px_x, px_y;

    // Pipeline intermediate values
    logic [7:0]  px_bg_tile_idx;
    logic [12:0] px_bg_data_base;
    logic [7:0]  px_bg_tile_lo;

    logic [7:0]  px_win_tile_idx;
    logic [12:0] px_win_data_base;
    logic [7:0]  px_win_tile_lo;

    // Whether window is active for this pixel (latched)
    logic px_win_active;

    initial begin
        px_state         = PX_IDLE;
        pixel_data       = 16'hFFFF;
        pixel_data_valid = 1'b0;
    end

    // Derived values from latched coordinates (used mid-pipeline)
    wire [7:0]  pipe_bg_x = px_x + reg_scx;
    wire [7:0]  pipe_bg_y = px_y + reg_scy;

    wire [7:0]  pipe_win_x = px_x + 8'd7 - reg_wx;
    wire [7:0]  pipe_win_y = win_line;
    wire [12:0] pipe_win_map_addr = (win_map_hi ? 13'h1C00 : 13'h1800)
                                   + {3'b000, pipe_win_y[7:3], pipe_win_x[7:3]};

    // BG map address from raw pixel inputs (used in IDLE/DONE to pre-load BSRAM)
    wire [7:0]  fetch_bg_x = pixel_x + reg_scx;
    wire [7:0]  fetch_bg_y = pixel_y + reg_scy;
    wire [12:0] fetch_bg_map_addr = (bg_map_hi ? 13'h1C00 : 13'h1800)
                                   + {3'b000, fetch_bg_y[7:3], fetch_bg_x[7:3]};

    // Combinational VRAM address mux — driven by FSM state.
    // IDLE/DONE use raw pixel inputs to pre-load the bg map entry;
    // mid-pipeline states use latched coordinates and BSRAM read data.
    always_comb begin
        case (px_state)
            PX_IDLE:    ppu_vram_addr = fetch_bg_map_addr;
            PX_BG_MAP:  ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_bg_y[2:0]);
            PX_BG_LO:   ppu_vram_addr = px_bg_data_base + 13'd1;
            PX_BG_HI:   ppu_vram_addr = pipe_win_map_addr;
            PX_WIN_MAP: ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_win_y[2:0]);
            PX_WIN_LO:  ppu_vram_addr = px_win_data_base + 13'd1;
            PX_DONE:    ppu_vram_addr = fetch_bg_map_addr;
            default:     ppu_vram_addr = 13'd0;
        endcase
    end

    // Combinational pixel decode — used by FSM to register pixel_data.
    // In PX_BG_HI: ppu_vram_rdata = bg tile hi, px_bg_tile_lo = bg tile lo
    // In PX_WIN_HI: ppu_vram_rdata = win tile hi, px_win_tile_lo = win tile lo
    wire [2:0] bg_bit_pos    = 3'd7 - pipe_bg_x[2:0];
    wire [1:0] bg_color_id   = {ppu_vram_rdata[bg_bit_pos], px_bg_tile_lo[bg_bit_pos]};
    wire [1:0] bg_shade      = reg_bgp[bg_color_id * 2 +: 2];
    wire [15:0] bg_rgb565    = shade_to_rgb565(bg_shade);

    wire [2:0] win_bit_pos   = 3'd7 - pipe_win_x[2:0];
    wire [1:0] win_color_id  = {ppu_vram_rdata[win_bit_pos], px_win_tile_lo[win_bit_pos]};
    wire [1:0] win_shade     = reg_bgp[win_color_id * 2 +: 2];
    wire [15:0] win_rgb565   = shade_to_rgb565(win_shade);

    // Pipeline FSM
    always_ff @(posedge clk) begin
        if (reset) begin
            px_state         <= PX_IDLE;
            pixel_data       <= 16'hFFFF;
            pixel_data_valid <= 1'b0;
        end else begin
            case (px_state)
                PX_IDLE: begin
                    if (pixel_fetch) begin
                        px_x <= pixel_x;
                        px_y <= pixel_y;
                        px_win_active <= win_enable
                                      && (pixel_y >= reg_wy)
                                      && (pixel_x + 8'd7 >= reg_wx);
                        pixel_data_valid <= 1'b0;
                        // ppu_vram_addr = bg_map_addr (combinational)
                        px_state <= PX_BG_MAP;
                    end
                end

                PX_BG_MAP: begin
                    // rdata_b has bg tile index
                    px_bg_tile_idx <= ppu_vram_rdata;
                    px_bg_data_base <= tile_data_addr(ppu_vram_rdata, pipe_bg_y[2:0]);
                    // ppu_vram_addr = tile_data_lo (combinational)
                    px_state <= PX_BG_LO;
                end

                PX_BG_LO: begin
                    // rdata_b has bg tile low byte
                    px_bg_tile_lo <= ppu_vram_rdata;
                    // ppu_vram_addr = tile_data_hi (combinational, uses px_bg_data_base)
                    px_state <= PX_BG_HI;
                end

                PX_BG_HI: begin
                    // rdata_b has bg tile high byte — compute BG pixel
                    if (!lcd_on || !bg_enable) begin
                        // LCD off or BG disabled
                        pixel_data <= 16'hFFFF;
                        pixel_data_valid <= 1'b1;
                        px_state <= PX_DONE;
                    end else if (px_win_active) begin
                        // Need window data — save BG result and start window fetch
                        // ppu_vram_addr = win_map_addr (combinational)
                        px_state <= PX_WIN_MAP;
                    end else begin
                        // BG only — compute final pixel
                        pixel_data <= bg_rgb565;
                        pixel_data_valid <= 1'b1;
                        px_state <= PX_DONE;
                    end
                end

                PX_WIN_MAP: begin
                    // rdata_b has window tile index
                    px_win_tile_idx <= ppu_vram_rdata;
                    px_win_data_base <= tile_data_addr(ppu_vram_rdata, pipe_win_y[2:0]);
                    // ppu_vram_addr = win tile_data_lo (combinational)
                    px_state <= PX_WIN_LO;
                end

                PX_WIN_LO: begin
                    // rdata_b has window tile low byte
                    px_win_tile_lo <= ppu_vram_rdata;
                    // ppu_vram_addr = win tile_data_hi (combinational)
                    px_state <= PX_WIN_HI;
                end

                PX_WIN_HI: begin
                    // rdata_b has window tile high byte — compute window pixel
                    pixel_data <= win_rgb565;
                    pixel_data_valid <= 1'b1;
                    px_state <= PX_DONE;
                end

                PX_DONE: begin
                    // Hold pixel_data valid until next fetch
                    if (pixel_fetch) begin
                        px_x <= pixel_x;
                        px_y <= pixel_y;
                        px_win_active <= win_enable
                                      && (pixel_y >= reg_wy)
                                      && (pixel_x + 8'd7 >= reg_wx);
                        pixel_data_valid <= 1'b0;
                        px_state <= PX_BG_MAP;
                    end
                end

                default: px_state <= PX_IDLE;
            endcase
        end
    end

endmodule
