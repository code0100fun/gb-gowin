// Minimal LCD test — ST7789 with color bar pattern, no CPU/PPU.
// Use this to verify the SPI driver works on real hardware.
module lcd_test_top (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset
    input  logic       btn_s2,
    output logic [5:0] led,

    output logic       lcd_rst,
    output logic       lcd_cs,
    output logic       lcd_dc,
    output logic       lcd_sclk,
    output logic       lcd_mosi,
    output logic       lcd_bl
);

    // Power-on reset
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];

    // LEDs show state: turn on one LED when init done
    logic busy;
    assign led = busy ? 6'b111111 : 6'b111110; // LED 0 on when streaming

    // Pixel interface
    logic [15:0] pixel_data;
    logic [7:0]  pixel_x, pixel_y;
    logic        pixel_req;

    // Simple test pattern: vertical color bars
    always_comb begin
        unique case (pixel_x[7:5])
            3'd0: pixel_data = 16'hF800; // red
            3'd1: pixel_data = 16'h07E0; // green
            3'd2: pixel_data = 16'h001F; // blue
            3'd3: pixel_data = 16'hFFE0; // yellow
            3'd4: pixel_data = 16'hF81F; // magenta
            3'd5: pixel_data = 16'h07FF; // cyan
            3'd6: pixel_data = 16'hFFFF; // white
            3'd7: pixel_data = 16'h0000; // black
        endcase
    end

    st7789 u_lcd (
        .clk        (clk),
        .reset      (reset),
        .lcd_rst    (lcd_rst),
        .lcd_cs     (lcd_cs),
        .lcd_dc     (lcd_dc),
        .lcd_sclk   (lcd_sclk),
        .lcd_mosi   (lcd_mosi),
        .lcd_bl     (lcd_bl),
        .ppu_vblank (1'b0),
        .pixel_data (pixel_data),
        .pixel_ready(1'b1),        // always ready
        .pixel_x    (pixel_x),
        .pixel_y    (pixel_y),
        .pixel_req  (pixel_req),
        .busy       (busy)
    );

endmodule
