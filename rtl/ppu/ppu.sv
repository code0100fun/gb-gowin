// Game Boy PPU — Background, Window, and Sprite renderer.
//
// VRAM (8 KB) is stored in a dual-port BSRAM: Port A for CPU read/write,
// Port B for PPU tile fetches. OAM (160 bytes) is stored in distributed
// RAM with combinational reads for fast scanline sprite scanning.
//
// The ST7789 LCD controller pulses pixel_fetch when it needs a new pixel.
// On the first pixel of each scanline, the PPU scans OAM (40 cycles) and
// pre-fetches sprite tile data from VRAM (3 cycles per sprite, max 10).
// Then the BG/window pipeline runs (4–7 cycles) with sprite mixing at the
// end.
//
// Implements registers: LCDC (FF40), STAT (FF41), SCY (FF42), SCX (FF43),
// LY (FF44), LYC (FF45), BGP (FF47), OBP0 (FF48), OBP1 (FF49),
// WY (FF4A), WX (FF4B).
//
// Timing: autonomous mcycle/scanline counters provide accurate LY,
// mode transitions (0/1/2/3), and STAT interrupts. Rendering is still
// LCD-driven (pixel_fetch from ST7789 controller).
module ppu #(
    // Prescaler for PPU timing counters. Slows mcycle_ctr/ly_ctr to
    // match the LCD SPI frame rate. Set to 1 for simulation (1:1 with
    // system clock) or 88 for hardware (matches ST7789 SPI ÷4 rate).
    parameter int PPU_PRESCALE = 88,
    // LCDC value after reset. Set to 8'h91 when skipping the boot ROM
    // (LCD on, BG on, unsigned tile data) so that LY advances and games
    // can detect VBlank during their init sequence.
    parameter logic [7:0] BOOT_LCDC = 8'h00
) (
    input  logic        clk,
    input  logic        reset,

    // CPU VRAM access (from bus) — dual_port_ram Port A
    input  logic [12:0] cpu_vram_addr,
    input  logic        cpu_vram_cs,
    input  logic        cpu_vram_we,
    input  logic [7:0]  cpu_vram_wdata,
    output logic [7:0]  cpu_vram_rdata,

    // CPU OAM access (from bus) — distributed RAM
    input  logic [7:0]  cpu_oam_addr,
    input  logic        cpu_oam_cs,
    input  logic        cpu_oam_we,
    input  logic [7:0]  cpu_oam_wdata,
    output logic [7:0]  cpu_oam_rdata,

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

    // CPU stall — freeze PPU timing when CPU is stalled on SDRAM
    input  logic        cpu_stall,

    // Interrupts
    output logic        irq_vblank,
    output logic        irq_stat,

    // Debug outputs
    output logic [7:0]  dbg_lcdc,
    output logic [7:0]  dbg_ly,
    output logic [7:0]  dbg_bgp
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
    // OAM — 160 bytes distributed RAM (40 sprites × 4 bytes)
    // Combinational reads (no wait states), synchronous writes.
    // -----------------------------------------------------------------
    logic [7:0] oam [0:159];

    assign cpu_oam_rdata = oam[cpu_oam_addr];

    always_ff @(posedge clk) begin
        if (cpu_oam_cs && cpu_oam_we)
            oam[cpu_oam_addr] <= cpu_oam_wdata;
    end

    // -----------------------------------------------------------------
    // PPU registers
    // -----------------------------------------------------------------
    logic [7:0] reg_lcdc;   // FF40
    logic [7:0] reg_stat;   // FF41
    logic [7:0] reg_scy;    // FF42
    logic [7:0] reg_scx;    // FF43
    // LY (FF44) is read-only, derived from timing counter (ly_ctr)
    logic [7:0] reg_lyc;    // FF45
    logic [7:0] reg_bgp;    // FF47
    logic [7:0] reg_obp0;   // FF48
    logic [7:0] reg_obp1;   // FF49
    logic [7:0] reg_wy;     // FF4A
    logic [7:0] reg_wx;     // FF4B

    initial begin
        reg_lcdc = 8'h00;
        reg_stat = 8'h00;
        reg_scy  = 8'h00;
        reg_scx  = 8'h00;
        reg_lyc  = 8'h00;
        reg_bgp  = 8'hFC;  // default palette: 3,3,2,0 -> shades 11,10,01,00
        reg_obp0 = 8'h00;
        reg_obp1 = 8'h00;
        reg_wy   = 8'h00;
        reg_wx   = 8'h00;
    end

    // LY = ly_ctr (from autonomous timing counters, see below)
    wire [7:0] ly = ly_ctr;

    // STAT register: bits [1:0] = mode, bit 2 = LY==LYC
    wire [7:0] stat_read = {1'b1, reg_stat[6:3], (ly == reg_lyc) ? 1'b1 : 1'b0, ppu_mode};

    // Register writes
    always_ff @(posedge clk) begin
        if (reset) begin
            reg_lcdc <= BOOT_LCDC;
            reg_stat <= 8'h00;
            reg_scy  <= 8'h00;
            reg_scx  <= 8'h00;
            reg_lyc  <= 8'h00;
            reg_bgp  <= 8'hFC;
            reg_obp0 <= 8'h00;
            reg_obp1 <= 8'h00;
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
                7'h48: reg_obp0 <= io_wdata;
                7'h49: reg_obp1 <= io_wdata;
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
            7'h48:   io_rdata = reg_obp0;
            7'h49:   io_rdata = reg_obp1;
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
    // VBlank IRQ — pulse when ly_ctr transitions to 144
    // -----------------------------------------------------------------
    logic prev_vblank_line;
    initial prev_vblank_line = 1'b0;

    always_ff @(posedge clk) begin
        if (reset)
            prev_vblank_line <= 1'b0;
        else
            prev_vblank_line <= (ly_ctr == 8'd144);
    end

    assign irq_vblank = (ly_ctr == 8'd144) && !prev_vblank_line;

    // -----------------------------------------------------------------
    // LCDC bit aliases
    // -----------------------------------------------------------------
    wire lcd_on        = reg_lcdc[7];
    wire win_map_hi    = reg_lcdc[6]; // 0 = 9800, 1 = 9C00
    wire win_enable    = reg_lcdc[5];
    wire tile_data_sel = 1'b1; // DIAGNOSTIC: force unsigned mode // reg_lcdc[4]
    wire bg_map_hi     = reg_lcdc[3]; // 0 = 9800, 1 = 9C00
    wire obj_tall      = reg_lcdc[2]; // 0 = 8×8, 1 = 8×16
    wire obj_enable    = reg_lcdc[1];
    wire bg_enable     = reg_lcdc[0];

    // Debug outputs
    assign dbg_lcdc = reg_lcdc;
    assign dbg_ly   = ly;
    assign dbg_bgp  = reg_bgp;

    // -----------------------------------------------------------------
    // Timing counters — autonomous PPU timing
    // -----------------------------------------------------------------
    // mcycle_ctr: 0–113 (114 M-cycles per scanline = 456 dots)
    // ly_ctr:     0–153 (154 scanlines per frame)
    // ppu_mode:   derived combinationally from counters
    //
    // A prescaler slows these counters to match the LCD SPI frame rate.
    // The ST7789 outputs ~67 system clocks per pixel (SPI ÷4, 16 bits).
    // LCD frame = 160×144×67 ≈ 1,543,680 clocks.
    // PPU frame = 154×114 = 17,556 M-cycles.
    // Prescaler = 1,543,680 / 17,556 ≈ 88.
    // -----------------------------------------------------------------
    logic [6:0] mcycle_ctr;
    logic [7:0] ly_ctr;
    logic [1:0] ppu_mode;
    logic [6:0] prescale_ctr;

    initial begin
        mcycle_ctr   = 7'd0;
        ly_ctr       = 8'd0;
        prescale_ctr = 7'd0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin  // DIAGNOSTIC: removed !lcd_on gate so PPU keeps counting
            mcycle_ctr   <= 7'd0;
            ly_ctr       <= 8'd0;
            prescale_ctr <= 7'd0;
        end else if (!cpu_stall) begin
            // Freeze PPU timing when CPU is stalled on SDRAM — keeps
            // CPU and PPU synchronized (same approach as Game Bub, GBTang)
            if (prescale_ctr == PPU_PRESCALE[6:0] - 7'd1) begin
                prescale_ctr <= 7'd0;
                // Advance M-cycle counter
                if (mcycle_ctr == 7'd113) begin
                    mcycle_ctr <= 7'd0;
                    ly_ctr <= (ly_ctr == 8'd153) ? 8'd0 : ly_ctr + 8'd1;
                end else begin
                    mcycle_ctr <= mcycle_ctr + 7'd1;
                end
            end else begin
                prescale_ctr <= prescale_ctr + 7'd1;
            end
        end
    end

    always_comb begin
        if (ly_ctr >= 8'd144)
            ppu_mode = 2'd1;  // VBlank
        else if (mcycle_ctr < 7'd20)
            ppu_mode = 2'd2;  // OAM scan
        else if (mcycle_ctr < 7'd63)
            ppu_mode = 2'd3;  // Pixel transfer
        else
            ppu_mode = 2'd0;  // HBlank
    end

    // -----------------------------------------------------------------
    // STAT interrupt — rising edge of composite "STAT line"
    // -----------------------------------------------------------------
    // The STAT interrupt fires on the rising edge of the OR of all
    // enabled STAT conditions. Gated by lcd_on to prevent spurious
    // interrupts when LCD is off (ppu_mode=0 would match HBlank).
    // -----------------------------------------------------------------
    wire stat_line = lcd_on && (
        (reg_stat[3] && ppu_mode == 2'd0) ||  // Mode 0 HBlank
        (reg_stat[4] && ppu_mode == 2'd1) ||  // Mode 1 VBlank
        (reg_stat[5] && ppu_mode == 2'd2) ||  // Mode 2 OAM scan
        (reg_stat[6] && ly == reg_lyc));       // LYC=LY coincidence

    logic prev_stat_line;
    initial prev_stat_line = 1'b0;

    always_ff @(posedge clk) begin
        if (reset)
            prev_stat_line <= 1'b0;
        else
            prev_stat_line <= stat_line;
    end

    assign irq_stat = stat_line && !prev_stat_line;

    // DMG shade -> RGB565 lookup
    function logic [15:0] shade_to_rgb565(logic [1:0] shade);
        case (shade)
            2'd0: shade_to_rgb565 = 16'hFFFF; // white
            2'd1: shade_to_rgb565 = 16'hAD55; // light gray
            2'd2: shade_to_rgb565 = 16'h52AA; // dark gray
            2'd3: shade_to_rgb565 = 16'h0000; // black
        endcase
    endfunction

    // Compute tile data address from tile index and row (BG/window)
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
    // Scanline sprite buffer
    // -----------------------------------------------------------------
    // Filled during SPR_SCAN, consumed during pixel mixing.
    logic [7:0]  spr_buf_x      [0:9];
    logic [7:0]  spr_buf_tile   [0:9];
    logic [7:0]  spr_buf_attr   [0:9];
    logic [3:0]  spr_buf_row    [0:9];  // pre-computed row (after Y-flip)
    logic [7:0]  spr_buf_row_lo [0:9];  // pre-fetched tile data
    logic [7:0]  spr_buf_row_hi [0:9];
    logic [3:0]  spr_count;             // number of sprites found (0–10)
    logic [7:0]  last_scanned_y;        // scanline for which sprite scan is valid

    initial begin
        spr_count      = 4'd0;
        last_scanned_y = 8'hFF;
    end

    // -----------------------------------------------------------------
    // Tile fetch pipeline FSM
    // -----------------------------------------------------------------
    // BSRAM has 1-cycle read latency: set address in cycle N, data
    // available in cycle N+1. The FSM walks through:
    //   1. Sprite scan (40 cycles, once per scanline)
    //   2. Sprite tile pre-fetch (3 cycles per sprite, max 30)
    //   3. BG tile map + data (3 reads = 4 cycles)
    //   4. Optionally window tile map + data (3 more reads = 7 total)
    //   5. Sprite mixing (combinational, in PX_BG_HI or PX_WIN_HI)
    //
    // ppu_vram_addr is driven COMBINATIONALLY from the FSM state and
    // ppu_vram_rdata (which is a registered BSRAM output — no loop).

    typedef enum logic [3:0] {
        PX_IDLE,
        PX_BG_MAP,
        PX_BG_LO,
        PX_BG_HI,
        PX_WIN_MAP,
        PX_WIN_LO,
        PX_WIN_HI,
        PX_DONE,
        SPR_SCAN,
        SPR_FETCH_LO,
        SPR_FETCH_HI,
        SPR_FETCH_DONE
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

    // Sprite scan/fetch indices
    logic [5:0] scan_idx;     // 0–39: current OAM entry being checked
    logic [3:0] fetch_idx;    // 0–9: current sprite being fetched

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

    // -----------------------------------------------------------------
    // Sprite tile address for pre-fetch
    // -----------------------------------------------------------------
    // Sprites always use unsigned tile data area (VRAM 0x0000 = GB 0x8000).
    wire [7:0]  fetch_spr_tile = spr_buf_tile[fetch_idx];
    wire [3:0]  fetch_spr_row  = spr_buf_row[fetch_idx];
    // In 8×16 mode, tile index bit 0 selects top/bottom half
    wire [7:0]  fetch_spr_tile_adj = obj_tall
        ? (fetch_spr_row[3] ? (fetch_spr_tile | 8'h01) : (fetch_spr_tile & 8'hFE))
        : fetch_spr_tile;
    wire [12:0] spr_tile_lo_addr = {1'b0, fetch_spr_tile_adj, fetch_spr_row[2:0], 1'b0};
    wire [12:0] spr_tile_hi_addr = spr_tile_lo_addr + 13'd1;

    // -----------------------------------------------------------------
    // OAM scan — combinational reads for current scan_idx
    // -----------------------------------------------------------------
    wire [7:0] scan_oam_y    = oam[{scan_idx, 2'd0}];
    wire [7:0] scan_oam_x    = oam[{scan_idx, 2'd1}];
    wire [7:0] scan_oam_tile = oam[{scan_idx, 2'd2}];
    wire [7:0] scan_oam_attr = oam[{scan_idx, 2'd3}];

    // Sprite row within tile: pixel_y + 16 - oam_y (unsigned)
    wire [8:0] scan_spr_row_raw = {1'b0, pixel_y} + 9'd16 - {1'b0, scan_oam_y};
    wire [3:0] scan_spr_height  = obj_tall ? 4'd15 : 4'd7;
    wire       scan_spr_hit     = (scan_spr_row_raw[8:4] == 5'd0)
                                && (scan_spr_row_raw[3:0] <= scan_spr_height);
    // Apply Y-flip
    wire [3:0] scan_spr_row_flip = scan_oam_attr[6]
        ? (scan_spr_height - scan_spr_row_raw[3:0])
        : scan_spr_row_raw[3:0];

    // -----------------------------------------------------------------
    // Combinational VRAM address mux — driven by FSM state
    // -----------------------------------------------------------------
    always_comb begin
        case (px_state)
            PX_IDLE:        ppu_vram_addr = fetch_bg_map_addr;
            PX_BG_MAP:      ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_bg_y[2:0]);
            PX_BG_LO:       ppu_vram_addr = px_bg_data_base + 13'd1;
            PX_BG_HI:       ppu_vram_addr = pipe_win_map_addr;
            PX_WIN_MAP:     ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_win_y[2:0]);
            PX_WIN_LO:      ppu_vram_addr = px_win_data_base + 13'd1;
            PX_DONE:        ppu_vram_addr = fetch_bg_map_addr;
            SPR_SCAN:       ppu_vram_addr = 13'd0;
            SPR_FETCH_LO:   ppu_vram_addr = spr_tile_lo_addr;
            SPR_FETCH_HI:   ppu_vram_addr = spr_tile_hi_addr;
            SPR_FETCH_DONE: ppu_vram_addr = fetch_bg_map_addr;
            default:        ppu_vram_addr = 13'd0;
        endcase
    end

    // -----------------------------------------------------------------
    // Combinational pixel decode
    // -----------------------------------------------------------------
    wire [2:0] bg_bit_pos    = 3'd7 - pipe_bg_x[2:0];
    wire [1:0] bg_color_id   = {ppu_vram_rdata[bg_bit_pos], px_bg_tile_lo[bg_bit_pos]};
    wire [1:0] bg_shade      = reg_bgp[bg_color_id * 2 +: 2];
    wire [15:0] bg_rgb565    = shade_to_rgb565(bg_shade);

    wire [2:0] win_bit_pos   = 3'd7 - pipe_win_x[2:0];
    wire [1:0] win_color_id  = {ppu_vram_rdata[win_bit_pos], px_win_tile_lo[win_bit_pos]};
    wire [1:0] win_shade     = reg_bgp[win_color_id * 2 +: 2];
    wire [15:0] win_rgb565   = shade_to_rgb565(win_shade);

    // -----------------------------------------------------------------
    // Sprite pixel mixing — combinational priority encoder
    // -----------------------------------------------------------------
    // Checks all 10 sprite buffer slots against the current pixel X.
    // First (lowest OAM index) opaque sprite wins (DMG priority).
    //
    // Pre-compute per-slot hit/color with a generate block (wires),
    // then use a simple priority encoder in always_comb.
    // -----------------------------------------------------------------

    // Per-slot sprite hit and color (combinational wires)
    logic [8:0] spr_col   [0:9];
    logic       spr_hit   [0:9];
    logic [2:0] spr_bpos  [0:9];
    logic [1:0] spr_color [0:9];

    for (genvar gi = 0; gi < 10; gi++) begin : gen_spr
        assign spr_col[gi]  = {1'b0, px_x} + 9'd8 - {1'b0, spr_buf_x[gi]};
        assign spr_hit[gi]  = (spr_col[gi][8:3] == 6'd0);
        assign spr_bpos[gi] = spr_buf_attr[gi][5]
                             ? spr_col[gi][2:0]         // X-flip
                             : (3'd7 - spr_col[gi][2:0]);
        assign spr_color[gi] = {spr_buf_row_hi[gi][spr_bpos[gi]],
                                spr_buf_row_lo[gi][spr_bpos[gi]]};
    end

    // Priority encoder: find first opaque sprite
    logic        spr_pixel_found;
    logic [1:0]  spr_pixel_color;
    logic        spr_pixel_behind_bg;
    logic [7:0]  spr_pixel_palette;

    always_comb begin
        spr_pixel_found     = 1'b0;
        spr_pixel_color     = 2'd0;
        spr_pixel_behind_bg = 1'b0;
        spr_pixel_palette   = reg_obp0;

        for (int i = 0; i < 10; i++) begin
            if (!spr_pixel_found && i < int'(spr_count)
                && spr_hit[i] && spr_color[i] != 2'd0) begin
                spr_pixel_found     = 1'b1;
                spr_pixel_color     = spr_color[i];
                spr_pixel_behind_bg = spr_buf_attr[i][7];
                spr_pixel_palette   = spr_buf_attr[i][4] ? reg_obp1 : reg_obp0;
            end
        end
    end

    wire [1:0]  spr_shade   = spr_pixel_palette[spr_pixel_color * 2 +: 2];
    wire [15:0] spr_rgb565  = shade_to_rgb565(spr_shade);

    // Compute final pixel given BG/window color_id and rgb565
    function logic [15:0] mix_sprite(logic [1:0] under_color_id, logic [15:0] under_rgb565);
        if (obj_enable && spr_pixel_found) begin
            if (spr_pixel_behind_bg && under_color_id != 2'd0)
                mix_sprite = under_rgb565;
            else
                mix_sprite = spr_rgb565;
        end else begin
            mix_sprite = under_rgb565;
        end
    endfunction

    // -----------------------------------------------------------------
    // Pipeline FSM
    // -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            px_state         <= PX_IDLE;
            pixel_data       <= 16'hFFFF;
            pixel_data_valid <= 1'b0;
            spr_count        <= 4'd0;
            last_scanned_y   <= 8'hFF;
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

                        if (obj_enable && pixel_y != last_scanned_y) begin
                            // New scanline — scan OAM for sprites
                            scan_idx       <= 6'd0;
                            spr_count      <= 4'd0;
                            last_scanned_y <= pixel_y;
                            px_state       <= SPR_SCAN;
                        end else begin
                            // Same scanline (or sprites off) — go to BG
                            px_state <= PX_BG_MAP;
                        end
                    end
                end

                // =============================================================
                // Sprite scan: check one OAM entry per cycle (40 cycles)
                // =============================================================
                SPR_SCAN: begin
                    if (scan_spr_hit && spr_count < 4'd10) begin
                        spr_buf_x[spr_count]    <= scan_oam_x;
                        spr_buf_tile[spr_count]  <= scan_oam_tile;
                        spr_buf_attr[spr_count]  <= scan_oam_attr;
                        spr_buf_row[spr_count]   <= scan_spr_row_flip;
                        spr_count                <= spr_count + 4'd1;
                    end

                    if (scan_idx == 6'd39) begin
                        // Scan complete — fetch tile data or start BG
                        // Check if we found any sprites (account for potential
                        // hit on this final cycle)
                        if (spr_count > 4'd0 || (scan_spr_hit && spr_count < 4'd10)) begin
                            fetch_idx <= 4'd0;
                            // ppu_vram_addr = spr_tile_lo_addr (combinational)
                            px_state  <= SPR_FETCH_LO;
                        end else begin
                            // No sprites — go to BG pipeline
                            // ppu_vram_addr = fetch_bg_map_addr (combinational)
                            px_state <= PX_BG_MAP;
                        end
                    end else begin
                        scan_idx <= scan_idx + 6'd1;
                    end
                end

                // =============================================================
                // Sprite tile pre-fetch: 3 cycles per sprite
                // =============================================================
                SPR_FETCH_LO: begin
                    // VRAM addr set to spr_tile_lo_addr (combinational)
                    // Next cycle: rdata_b = tile low byte
                    px_state <= SPR_FETCH_HI;
                end

                SPR_FETCH_HI: begin
                    // Latch tile low byte from VRAM
                    spr_buf_row_lo[fetch_idx] <= ppu_vram_rdata;
                    // VRAM addr set to spr_tile_hi_addr (combinational)
                    px_state <= SPR_FETCH_DONE;
                end

                SPR_FETCH_DONE: begin
                    // Latch tile high byte from VRAM
                    spr_buf_row_hi[fetch_idx] <= ppu_vram_rdata;

                    if (fetch_idx + 4'd1 >= spr_count) begin
                        // All sprites fetched — start BG pipeline
                        // ppu_vram_addr = fetch_bg_map_addr (combinational)
                        px_state <= PX_BG_MAP;
                    end else begin
                        fetch_idx <= fetch_idx + 4'd1;
                        px_state  <= SPR_FETCH_LO;
                    end
                end

                // =============================================================
                // BG/Window pipeline (unchanged, with sprite mixing at end)
                // =============================================================
                PX_BG_MAP: begin
                    // rdata_b has bg tile index
                    px_bg_tile_idx <= ppu_vram_rdata;
                    px_bg_data_base <= tile_data_addr(ppu_vram_rdata, pipe_bg_y[2:0]);
                    px_state <= PX_BG_LO;
                end

                PX_BG_LO: begin
                    // rdata_b has bg tile low byte
                    px_bg_tile_lo <= ppu_vram_rdata;
                    px_state <= PX_BG_HI;
                end

                PX_BG_HI: begin
                    // rdata_b has bg tile high byte — compute BG pixel
                    // DIAGNOSTIC: removed !lcd_on && !bg_enable checks
                    if (px_win_active) begin
                        // Need window data — start window fetch
                        px_state <= PX_WIN_MAP;
                    end else begin
                        // BG only — mix with sprite and output
                        pixel_data <= mix_sprite(bg_color_id, bg_rgb565);
                        pixel_data_valid <= 1'b1;
                        px_state <= PX_DONE;
                    end
                end

                PX_WIN_MAP: begin
                    px_win_tile_idx <= ppu_vram_rdata;
                    px_win_data_base <= tile_data_addr(ppu_vram_rdata, pipe_win_y[2:0]);
                    px_state <= PX_WIN_LO;
                end

                PX_WIN_LO: begin
                    px_win_tile_lo <= ppu_vram_rdata;
                    px_state <= PX_WIN_HI;
                end

                PX_WIN_HI: begin
                    // Window pixel — mix with sprite and output
                    pixel_data <= mix_sprite(win_color_id, win_rgb565);
                    pixel_data_valid <= 1'b1;
                    px_state <= PX_DONE;
                end

                PX_DONE: begin
                    if (pixel_fetch) begin
                        px_x <= pixel_x;
                        px_y <= pixel_y;
                        px_win_active <= win_enable
                                      && (pixel_y >= reg_wy)
                                      && (pixel_x + 8'd7 >= reg_wx);
                        pixel_data_valid <= 1'b0;

                        if (obj_enable && pixel_y != last_scanned_y) begin
                            scan_idx       <= 6'd0;
                            spr_count      <= 4'd0;
                            last_scanned_y <= pixel_y;
                            px_state       <= SPR_SCAN;
                        end else begin
                            px_state <= PX_BG_MAP;
                        end
                    end
                end

                default: px_state <= PX_IDLE;
            endcase
        end
    end

endmodule
