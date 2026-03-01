// ST7789 SPI LCD controller — 240×240 display with 160×144 Game Boy window.
//
// Drives a 4-wire SPI interface (Mode 3: CPOL=1, CPHA=1) to initialize
// the display and continuously stream pixels.  The pixel data input is
// provided externally (test pattern or framebuffer); this module handles
// the SPI protocol, initialization sequence, and coordinate tracking.
//
// SPI clock = system clock / 4 (~6.75 MHz at 27 MHz input).
module st7789 (
    input  logic        clk,        // 27 MHz system clock
    input  logic        reset,

    // SPI + control pins
    output logic        lcd_rst,    // active-low hardware reset
    output logic        lcd_cs,     // active-low chip select
    output logic        lcd_dc,     // 0 = command, 1 = data
    output logic        lcd_sclk,   // SPI clock (idles high, Mode 3)
    output logic        lcd_mosi,   // SPI data out
    output logic        lcd_bl,     // backlight enable

    // Pixel interface
    input  logic [15:0] pixel_data, // RGB565 pixel to send
    output logic [7:0]  pixel_x,    // current column (0–159)
    output logic [7:0]  pixel_y,    // current row (0–143)
    output logic        pixel_req,  // high for 1 cycle when pixel_data is sampled

    // Status
    output logic        busy        // high during init, low when streaming
);

    // -----------------------------------------------------------------
    // Timing constants (27 MHz clock)
    // -----------------------------------------------------------------
    localparam int CLK_HZ    = 27_000_000;
    localparam int T_10MS    = CLK_HZ / 100;      // 270,000
    localparam int T_120MS   = CLK_HZ * 12 / 100; // 3,240,000

    localparam int FB_W      = 160;
    localparam int FB_H      = 144;

    // -----------------------------------------------------------------
    // SPI clock divider (÷4)
    // -----------------------------------------------------------------
    logic [1:0] spi_div;
    wire spi_falling = (spi_div == 2'b01); // MOSI changes here
    wire spi_rising  = (spi_div == 2'b11); // display samples here

    always_ff @(posedge clk) begin
        if (reset)
            spi_div <= 2'b00;
        else
            spi_div <= spi_div + 2'd1;
    end

    // -----------------------------------------------------------------
    // SPI byte shifter
    // -----------------------------------------------------------------
    logic [7:0]  shift_reg;
    logic [3:0]  bit_cnt;     // 0 = idle, 1–8 = shifting
    logic        spi_busy;
    logic        spi_start;   // pulse to begin sending shift_reg
    logic        spi_done;    // pulse when byte is complete

    assign spi_busy = (bit_cnt != 4'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            bit_cnt   <= 4'd0;
            lcd_sclk  <= 1'b1; // idle high (CPOL=1)
            lcd_mosi  <= 1'b0;
            spi_done  <= 1'b0;
        end else begin
            spi_done <= 1'b0;

            if (spi_start && !spi_busy) begin
                bit_cnt  <= 4'd1;
                lcd_sclk <= 1'b1;
            end else if (spi_busy) begin
                if (spi_falling) begin
                    // Drive MOSI on falling edge
                    lcd_sclk <= 1'b0;
                    lcd_mosi <= shift_reg[7];
                end else if (spi_rising) begin
                    // Rising edge — display samples MOSI
                    lcd_sclk <= 1'b1;
                    shift_reg <= {shift_reg[6:0], 1'b0};
                    if (bit_cnt == 4'd8) begin
                        bit_cnt  <= 4'd0;
                        spi_done <= 1'b1;
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // Init command table
    // -----------------------------------------------------------------
    // Format: {type[1:0], data[7:0]}
    //   type 00 = command byte (DC=0)
    //   type 01 = data byte    (DC=1)
    //   type 10 = delay (data = index: 0=10ms, 1=120ms)
    //   type 11 = end marker
    localparam int INIT_LEN = 22;
    logic [9:0] init_rom [0:INIT_LEN-1];

    initial begin
        init_rom[ 0] = {2'b00, 8'h11};       // SLPOUT
        init_rom[ 1] = {2'b10, 8'h01};       // delay 120ms
        init_rom[ 2] = {2'b00, 8'h3A};       // COLMOD
        init_rom[ 3] = {2'b01, 8'h55};       //   param: RGB565
        init_rom[ 4] = {2'b00, 8'h36};       // MADCTL
        init_rom[ 5] = {2'b01, 8'h00};       //   param: no rotation
        init_rom[ 6] = {2'b00, 8'h21};       // INVON
        init_rom[ 7] = {2'b00, 8'h2A};       // CASET
        init_rom[ 8] = {2'b01, 8'h00};       //   x_start high
        init_rom[ 9] = {2'b01, 8'h28};       //   x_start low  (40)
        init_rom[10] = {2'b01, 8'h00};       //   x_end high
        init_rom[11] = {2'b01, 8'hC7};       //   x_end low    (199)
        init_rom[12] = {2'b00, 8'h2B};       // RASET
        init_rom[13] = {2'b01, 8'h00};       //   y_start high
        init_rom[14] = {2'b01, 8'h30};       //   y_start low  (48)
        init_rom[15] = {2'b01, 8'h00};       //   y_end high
        init_rom[16] = {2'b01, 8'hBF};       //   y_end low    (191)
        init_rom[17] = {2'b00, 8'h29};       // DISPON
        init_rom[18] = {2'b10, 8'h01};       // delay 120ms
        init_rom[19] = {2'b00, 8'h2C};       // RAMWR
        init_rom[20] = {2'b11, 8'h00};       // end
        init_rom[21] = {2'b11, 8'h00};       // padding
    end

    // -----------------------------------------------------------------
    // Main state machine
    // -----------------------------------------------------------------
    typedef enum logic [2:0] {
        S_RESET_LO,    // hold RST low
        S_RESET_HI,    // wait after RST release
        S_INIT,        // walk init_rom, send bytes / delay
        S_INIT_WAIT,   // waiting for SPI byte to finish
        S_DELAY,       // timed delay
        S_STREAM_HI,   // send pixel high byte
        S_STREAM_LO,   // send pixel low byte
        S_STREAM_WAIT  // wait for low byte to finish, advance coords
    } state_t;

    state_t      state;
    logic [21:0] delay_ctr;  // up to ~4M cycles
    logic [4:0]  init_idx;   // position in init_rom
    logic [14:0] px_cnt;     // pixel counter (0..23039)
    logic        pixel_hi_sent; // tracks which byte of pixel we're on
    state_t      delay_ret;  // return state after delay

    initial begin
        state     = S_RESET_LO;
        lcd_rst   = 1'b0;
        lcd_cs    = 1'b1;
        lcd_dc    = 1'b0;
        lcd_bl    = 1'b0;
        pixel_x   = 8'd0;
        pixel_y   = 8'd0;
        pixel_req = 1'b0;
        busy      = 1'b1;
        init_idx  = 5'd0;
        px_cnt    = 15'd0;
        delay_ctr = 22'd0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= S_RESET_LO;
            lcd_rst   <= 1'b0;
            lcd_cs    <= 1'b1;
            lcd_dc    <= 1'b0;
            lcd_bl    <= 1'b0;
            pixel_x   <= 8'd0;
            pixel_y   <= 8'd0;
            pixel_req <= 1'b0;
            busy      <= 1'b1;
            init_idx  <= 5'd0;
            px_cnt    <= 15'd0;
            delay_ctr <= 22'd0;
            spi_start <= 1'b0;
        end else begin
            spi_start <= 1'b0;
            pixel_req <= 1'b0;

            unique case (state)
                // ---- Hardware reset ----
                S_RESET_LO: begin
                    lcd_rst <= 1'b0;
                    lcd_cs  <= 1'b1;
                    if (delay_ctr == T_10MS[21:0]) begin
                        lcd_rst   <= 1'b1;
                        delay_ctr <= 22'd0;
                        state     <= S_RESET_HI;
                    end else begin
                        delay_ctr <= delay_ctr + 22'd1;
                    end
                end

                S_RESET_HI: begin
                    if (delay_ctr == T_120MS[21:0]) begin
                        delay_ctr <= 22'd0;
                        init_idx  <= 5'd0;
                        state     <= S_INIT;
                    end else begin
                        delay_ctr <= delay_ctr + 22'd1;
                    end
                end

                // ---- Init sequence ----
                S_INIT: begin
                    if (!spi_busy) begin
                        unique case (init_rom[init_idx][9:8])
                            2'b00: begin // command byte
                                lcd_cs    <= 1'b0;
                                lcd_dc    <= 1'b0;
                                shift_reg <= init_rom[init_idx][7:0];
                                spi_start <= 1'b1;
                                init_idx  <= init_idx + 5'd1;
                                state     <= S_INIT_WAIT;
                            end
                            2'b01: begin // data byte
                                lcd_cs    <= 1'b0;
                                lcd_dc    <= 1'b1;
                                shift_reg <= init_rom[init_idx][7:0];
                                spi_start <= 1'b1;
                                init_idx  <= init_idx + 5'd1;
                                state     <= S_INIT_WAIT;
                            end
                            2'b10: begin // delay
                                lcd_cs    <= 1'b1;
                                delay_ctr <= 22'd0;
                                delay_ret <= S_INIT;
                                init_idx  <= init_idx + 5'd1;
                                state     <= S_DELAY;
                            end
                            2'b11: begin // end — start streaming
                                lcd_bl    <= 1'b1;
                                busy      <= 1'b0;
                                pixel_x   <= 8'd0;
                                pixel_y   <= 8'd0;
                                px_cnt    <= 15'd0;
                                state     <= S_STREAM_HI;
                                // pixel_req on next cycle
                                pixel_req <= 1'b1;
                            end
                        endcase
                    end
                end

                S_INIT_WAIT: begin
                    if (spi_done) begin
                        // Check if next entry is a command — if so, deassert CS briefly
                        if (init_rom[init_idx][9:8] == 2'b00 ||
                            init_rom[init_idx][9:8] == 2'b10 ||
                            init_rom[init_idx][9:8] == 2'b11) begin
                            lcd_cs <= 1'b1;
                        end
                        state <= S_INIT;
                    end
                end

                // ---- Timed delay ----
                S_DELAY: begin
                    if (delay_ctr == T_120MS[21:0]) begin
                        delay_ctr <= 22'd0;
                        state     <= delay_ret;
                    end else begin
                        delay_ctr <= delay_ctr + 22'd1;
                    end
                end

                // ---- Pixel streaming ----
                S_STREAM_HI: begin
                    if (!spi_busy) begin
                        lcd_cs    <= 1'b0;
                        lcd_dc    <= 1'b1;
                        shift_reg <= pixel_data[15:8];
                        spi_start <= 1'b1;
                        state     <= S_STREAM_LO;
                    end
                end

                S_STREAM_LO: begin
                    if (spi_done) begin
                        shift_reg <= pixel_data[7:0];
                        spi_start <= 1'b1;
                        state     <= S_STREAM_WAIT;
                    end
                end

                S_STREAM_WAIT: begin
                    if (spi_done) begin
                        // Advance coordinates
                        if (pixel_x == FB_W[7:0] - 8'd1) begin
                            pixel_x <= 8'd0;
                            if (pixel_y == FB_H[7:0] - 8'd1) begin
                                pixel_y <= 8'd0;
                                px_cnt  <= 15'd0;
                                // New frame — re-send RAMWR
                                lcd_cs  <= 1'b1;
                                state   <= S_INIT;
                                // Point init_idx at the RAMWR entry (index 19)
                                init_idx <= 5'd19;
                            end else begin
                                pixel_y   <= pixel_y + 8'd1;
                                px_cnt    <= px_cnt + 15'd1;
                                pixel_req <= 1'b1;
                                state     <= S_STREAM_HI;
                            end
                        end else begin
                            pixel_x   <= pixel_x + 8'd1;
                            px_cnt    <= px_cnt + 15'd1;
                            pixel_req <= 1'b1;
                            state     <= S_STREAM_HI;
                        end
                    end
                end

                default: state <= S_RESET_LO;
            endcase
        end
    end

endmodule
