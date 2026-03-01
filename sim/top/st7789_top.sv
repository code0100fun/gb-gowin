// Simulation wrapper for the ST7789 SPI LCD controller.
//
// Instantiates the st7789 module with a simple color-bar test pattern
// generator and exposes debug outputs for testbench observation.
module st7789_top (
    input  logic        clk,
    input  logic        reset,

    // SPI pins (directly from st7789)
    output logic        lcd_rst,
    output logic        lcd_cs,
    output logic        lcd_dc,
    output logic        lcd_sclk,
    output logic        lcd_mosi,
    output logic        lcd_bl,

    // Debug / status
    output logic        busy,
    output logic [7:0]  dbg_pixel_x,
    output logic [7:0]  dbg_pixel_y,
    output logic        dbg_pixel_req,
    output logic [15:0] dbg_pixel_data
);

    // Pixel interface wires
    logic [15:0] pixel_data;
    logic [7:0]  pixel_x;
    logic [7:0]  pixel_y;
    logic        pixel_req;

    // ---------------------------------------------------------------
    // Test pattern: vertical color bars (8 bars across 160 pixels)
    // ---------------------------------------------------------------
    logic [2:0] bar;
    assign bar = pixel_x[7:5]; // 160/8 = 20 pixels per bar (5 bits select)

    always_comb begin
        unique case (bar)
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

    // ---------------------------------------------------------------
    // ST7789 instance
    // ---------------------------------------------------------------
    st7789 u_lcd (
        .clk        (clk),
        .reset      (reset),
        .lcd_rst    (lcd_rst),
        .lcd_cs     (lcd_cs),
        .lcd_dc     (lcd_dc),
        .lcd_sclk   (lcd_sclk),
        .lcd_mosi   (lcd_mosi),
        .lcd_bl     (lcd_bl),
        .pixel_data (pixel_data),
        .pixel_ready(1'b1),       // test pattern is always ready
        .pixel_x    (pixel_x),
        .pixel_y    (pixel_y),
        .pixel_req  (pixel_req),
        .busy       (busy)
    );

    // Debug
    assign dbg_pixel_x    = pixel_x;
    assign dbg_pixel_y    = pixel_y;
    assign dbg_pixel_req  = pixel_req;
    assign dbg_pixel_data = pixel_data;

endmodule
