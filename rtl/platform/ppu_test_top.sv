// PPU display test — solid black screen via PPU tile rendering.
// All tilemap entries point to tile 1 (all 0xFF = black).
// If the display shows solid black in the game window, PPU rendering works.
module ppu_test_top (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset
    input  logic       btn_s2,     // unused
    output logic [5:0] led,

    output logic       lcd_rst,
    output logic       lcd_cs,
    output logic       lcd_dc,
    output logic       lcd_sclk,
    output logic       lcd_mosi,
    output logic       lcd_bl
);

    // -----------------------------------------------------------------
    // Power-on reset
    // -----------------------------------------------------------------
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];

    // -----------------------------------------------------------------
    // Pixel interface wires
    // -----------------------------------------------------------------
    logic [7:0]  pixel_x, pixel_y;
    logic        pixel_req;

    // -----------------------------------------------------------------
    // Init FSM: write tile data + tilemap + PPU registers
    // -----------------------------------------------------------------
    // cnt 0-15:    Tile 0 data (0x00) at VRAM 0x0000-0x000F
    // cnt 16-31:   Tile 1 data (0xFF) at VRAM 0x0010-0x001F
    // cnt 32-1055: Tilemap — ALL entries = tile 1 (solid black)
    // cnt 1056:    LCDC = 0x91 (LCD on, BG on, unsigned tile data)
    // cnt 1057:    BGP  = 0xE4 (standard palette)
    // cnt >= 1058: Done
    logic [10:0] init_cnt;
    wire         init_done = (init_cnt >= 11'd1058);

    always_ff @(posedge clk) begin
        if (reset)
            init_cnt <= 11'd0;
        else if (!init_done)
            init_cnt <= init_cnt + 11'd1;
    end

    logic [12:0] vram_addr;
    logic [7:0]  vram_wdata;
    logic        vram_we;
    logic        io_cs, io_wr;
    logic [6:0]  io_addr;
    logic [7:0]  io_wdata;

    wire [9:0] map_idx = init_cnt[9:0] - 10'd32;

    always_comb begin
        vram_addr  = 13'd0;
        vram_wdata = 8'd0;
        vram_we    = 1'b0;
        io_cs      = 1'b0;
        io_wr      = 1'b0;
        io_addr    = 7'd0;
        io_wdata   = 8'd0;

        if (!init_done && !reset) begin
            if (init_cnt < 11'd32) begin
                // Tile data: tile 0 = 0x00 (white), tile 1 = 0xFF (black)
                vram_we    = 1'b1;
                vram_addr  = {8'd0, init_cnt[4:0]};
                vram_wdata = (init_cnt < 11'd16) ? 8'h00 : 8'hFF;
            end else if (init_cnt < 11'd1056) begin
                // Tilemap: L-shape (col<10 or row<4 = black, else white)
                vram_we    = 1'b1;
                vram_addr  = 13'h1800 + {3'b000, map_idx};
                vram_wdata = (map_idx[4:0] < 5'd10 || map_idx[9:5] < 5'd4)
                             ? 8'd1 : 8'd0;
            end else if (init_cnt == 11'd1056) begin
                io_cs = 1'b1; io_wr = 1'b1;
                io_addr = 7'h40; io_wdata = 8'h91;
            end else if (init_cnt == 11'd1057) begin
                io_cs = 1'b1; io_wr = 1'b1;
                io_addr = 7'h47; io_wdata = 8'hE4;
            end
        end
    end

    // -----------------------------------------------------------------
    // PPU
    // -----------------------------------------------------------------
    logic [15:0] ppu_pixel_data;
    logic        ppu_pixel_valid;

    ppu #(.PPU_PRESCALE(88)) u_ppu (
        .clk(clk), .reset(reset), .cpu_stall(1'b0),
        .dbg_lcdc(), .dbg_ly(), .dbg_bgp(),
        .cpu_vram_addr(vram_addr), .cpu_vram_cs(vram_we),
        .cpu_vram_we(vram_we), .cpu_vram_wdata(vram_wdata),
        .cpu_vram_rdata(),
        .cpu_oam_addr(8'd0), .cpu_oam_cs(1'b0),
        .cpu_oam_we(1'b0), .cpu_oam_wdata(8'd0), .cpu_oam_rdata(),
        .io_cs(io_cs), .io_addr(io_addr), .io_wr(io_wr),
        .io_rd(1'b0), .io_wdata(io_wdata),
        .io_rdata(), .io_rdata_valid(),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .pixel_fetch(pixel_req),
        .pixel_data(ppu_pixel_data),
        .pixel_data_valid(ppu_pixel_valid),
        .irq_vblank(), .irq_stat()
    );

    // -----------------------------------------------------------------
    // ST7789 LCD controller — directly wired to PPU (no mux)
    // -----------------------------------------------------------------
    logic lcd_busy;

    st7789 u_lcd (
        .clk(clk), .reset(reset),
        .lcd_rst(lcd_rst), .lcd_cs(lcd_cs), .lcd_dc(lcd_dc),
        .lcd_sclk(lcd_sclk), .lcd_mosi(lcd_mosi), .lcd_bl(lcd_bl),
        .pixel_data(ppu_pixel_data),
        .pixel_ready(ppu_pixel_valid),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .pixel_req(pixel_req),
        .busy(lcd_busy)
    );

    // LED 0: init done, LED 1: streaming
    assign led = {4'b1111, lcd_busy, ~init_done};

endmodule
