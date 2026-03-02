// ST7789 SPI LCD controller — 240×240 display with 160×144 Game Boy window.
//
// Drives a 4-wire SPI interface (Mode 0: CPOL=0, CPHA=0) to initialize
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
    output logic        lcd_sclk,   // SPI clock (idles low, Mode 0)
    output logic        lcd_mosi,   // SPI data out
    output logic        lcd_bl,     // backlight enable

    // Pixel interface
    input  logic [15:0] pixel_data, // RGB565 pixel to send
    input  logic        pixel_ready,// high when pixel_data is valid (from PPU pipeline)
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
    wire spi_phase_a = (spi_div == 2'b01); // clock rises  (display samples)
    wire spi_phase_b = (spi_div == 2'b11); // clock falls  (shift to next bit)

    always_ff @(posedge clk) begin
        if (reset)
            spi_div <= 2'b00;
        else if (spi_start && !spi_busy)
            spi_div <= 2'b00;  // align phase so first event is spi_phase_a
        else
            spi_div <= spi_div + 2'd1;
    end

    // -----------------------------------------------------------------
    // SPI byte shifter
    // -----------------------------------------------------------------
    // shift_data is loaded by the FSM; shift_reg is owned solely by
    // this always_ff block (eliminates the multi-driver issue).
    logic [7:0]  shift_reg;
    logic [7:0]  shift_data;   // byte to send (set by FSM)
    logic [3:0]  bit_cnt;      // 0 = idle, 1–8 = shifting
    logic        spi_busy;
    logic        spi_start;    // pulse to begin sending shift_data
    logic        spi_done;     // pulse when byte is complete

    assign spi_busy = (bit_cnt != 4'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            bit_cnt   <= 4'd0;
            shift_reg <= 8'd0;
            lcd_sclk  <= 1'b0; // idle low (CPOL=0)
            lcd_mosi  <= 1'b0;
            spi_done  <= 1'b0;
        end else begin
            spi_done <= 1'b0;

            if (spi_start && !spi_busy) begin
                shift_reg <= shift_data;
                bit_cnt   <= 4'd1;
                lcd_mosi  <= shift_data[7]; // set up MSB before first rising edge
                lcd_sclk  <= 1'b0;
            end else if (spi_busy) begin
                if (spi_phase_a) begin
                    // Rising edge — display samples MOSI
                    lcd_sclk <= 1'b1;
                end else if (spi_phase_b) begin
                    // Falling edge — shift to next bit
                    lcd_sclk <= 1'b0;
                    shift_reg <= {shift_reg[6:0], 1'b0};
                    if (bit_cnt == 4'd8) begin
                        bit_cnt  <= 4'd0;
                        spi_done <= 1'b1;
                    end else begin
                        bit_cnt  <= bit_cnt + 4'd1;
                        lcd_mosi <= shift_reg[6]; // next bit after shift
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // Init command table (combinational ROM — no initial block needed)
    // -----------------------------------------------------------------
    // Format: {type[1:0], data[7:0]}
    //   type 00 = command byte (DC=0)
    //   type 01 = data byte    (DC=1)
    //   type 10 = delay (data = index: 0=10ms, 1=120ms)
    //   type 11 = end marker
    localparam int RAMWR_IDX = 44;  // index of RAMWR entry for frame restart
    logic [5:0]  init_idx;
    logic [9:0]  init_entry;

    always_comb begin
        unique case (init_idx)
            // ---- Software reset + delay ----
            6'd0:    init_entry = {2'b00, 8'h01};  // SWRESET
            6'd1:    init_entry = {2'b10, 8'h01};  // delay 120ms
            // ---- Sleep out + delay ----
            6'd2:    init_entry = {2'b00, 8'h11};  // SLPOUT
            6'd3:    init_entry = {2'b10, 8'h01};  // delay 120ms
            // ---- Pixel format ----
            6'd4:    init_entry = {2'b00, 8'h3A};  // COLMOD
            6'd5:    init_entry = {2'b01, 8'h55};  //   RGB565
            // ---- Memory access control ----
            6'd6:    init_entry = {2'b00, 8'h36};  // MADCTL
            6'd7:    init_entry = {2'b01, 8'h00};  //   no rotation
            // ---- Porch control ----
            6'd8:    init_entry = {2'b00, 8'hB2};  // PORCTRL
            6'd9:    init_entry = {2'b01, 8'h0C};
            6'd10:   init_entry = {2'b01, 8'h0C};
            6'd11:   init_entry = {2'b01, 8'h00};
            6'd12:   init_entry = {2'b01, 8'h33};
            6'd13:   init_entry = {2'b01, 8'h33};
            // ---- Gate control ----
            6'd14:   init_entry = {2'b00, 8'hB7};  // GCTRL
            6'd15:   init_entry = {2'b01, 8'h35};  //   VGH=13.26V, VGL=-10.43V
            // ---- VCOM setting ----
            6'd16:   init_entry = {2'b00, 8'hBB};  // VCOMS
            6'd17:   init_entry = {2'b01, 8'h19};  //   0.725V
            // ---- LCM control ----
            6'd18:   init_entry = {2'b00, 8'hC0};  // LCMCTRL
            6'd19:   init_entry = {2'b01, 8'h2C};
            // ---- VDV and VRH enable ----
            6'd20:   init_entry = {2'b00, 8'hC2};  // VDVVRHEN
            6'd21:   init_entry = {2'b01, 8'h01};
            // ---- VRH set ----
            6'd22:   init_entry = {2'b00, 8'hC3};  // VRHS
            6'd23:   init_entry = {2'b01, 8'h12};  //   4.45V
            // ---- VDV set ----
            6'd24:   init_entry = {2'b00, 8'hC4};  // VDVS
            6'd25:   init_entry = {2'b01, 8'h20};  //   0V
            // ---- Frame rate control ----
            6'd26:   init_entry = {2'b00, 8'hC6};  // FRCTRL2
            6'd27:   init_entry = {2'b01, 8'h0F};  //   60 Hz
            // ---- Power control 1 ----
            6'd28:   init_entry = {2'b00, 8'hD0};  // PWCTRL1
            6'd29:   init_entry = {2'b01, 8'hA4};
            6'd30:   init_entry = {2'b01, 8'hA1};
            // ---- Display inversion ----
            6'd31:   init_entry = {2'b00, 8'h21};  // INVON
            // ---- Column address set ----
            6'd32:   init_entry = {2'b00, 8'h2A};  // CASET
            6'd33:   init_entry = {2'b01, 8'h00};  //   x_start high
            6'd34:   init_entry = {2'b01, 8'h28};  //   x_start low  (40)
            6'd35:   init_entry = {2'b01, 8'h00};  //   x_end high
            6'd36:   init_entry = {2'b01, 8'hC7};  //   x_end low    (199)
            // ---- Row address set ----
            6'd37:   init_entry = {2'b00, 8'h2B};  // RASET
            6'd38:   init_entry = {2'b01, 8'h00};  //   y_start high
            6'd39:   init_entry = {2'b01, 8'h30};  //   y_start low  (48)
            6'd40:   init_entry = {2'b01, 8'h00};  //   y_end high
            6'd41:   init_entry = {2'b01, 8'hBF};  //   y_end low    (191)
            // ---- Display on + delay ----
            6'd42:   init_entry = {2'b00, 8'h29};  // DISPON
            6'd43:   init_entry = {2'b10, 8'h01};  // delay 120ms
            // ---- Start pixel stream ----
            6'd44:   init_entry = {2'b00, 8'h2C};  // RAMWR
            default: init_entry = {2'b11, 8'h00};  // end marker
        endcase
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
    logic [14:0] px_cnt;     // pixel counter (0..23039)
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
        init_idx  = 6'd0;
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
            init_idx  <= 6'd0;
            px_cnt    <= 15'd0;
            delay_ctr <= 22'd0;
            spi_start <= 1'b0;
            shift_data <= 8'd0;
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
                        init_idx  <= 6'd0;
                        state     <= S_INIT;
                    end else begin
                        delay_ctr <= delay_ctr + 22'd1;
                    end
                end

                // ---- Init sequence ----
                S_INIT: begin
                    if (!spi_busy) begin
                        unique case (init_entry[9:8])
                            2'b00: begin // command byte
                                lcd_cs     <= 1'b0;
                                lcd_dc     <= 1'b0;
                                shift_data <= init_entry[7:0];
                                spi_start  <= 1'b1;
                                init_idx   <= init_idx + 6'd1;
                                state      <= S_INIT_WAIT;
                            end
                            2'b01: begin // data byte
                                lcd_cs     <= 1'b0;
                                lcd_dc     <= 1'b1;
                                shift_data <= init_entry[7:0];
                                spi_start  <= 1'b1;
                                init_idx   <= init_idx + 6'd1;
                                state      <= S_INIT_WAIT;
                            end
                            2'b10: begin // delay
                                lcd_cs    <= 1'b1;
                                delay_ctr <= 22'd0;
                                delay_ret <= S_INIT;
                                init_idx  <= init_idx + 6'd1;
                                state     <= S_DELAY;
                            end
                            2'b11: begin // end — start streaming
                                lcd_bl    <= 1'b1;
                                busy      <= 1'b0;
                                pixel_x   <= 8'd0;
                                pixel_y   <= 8'd0;
                                px_cnt    <= 15'd0;
                                state     <= S_STREAM_HI;
                                pixel_req <= 1'b1;
                            end
                        endcase
                    end
                end

                S_INIT_WAIT: begin
                    if (spi_done) begin
                        // Check if next entry is a command — if so, deassert CS briefly
                        if (init_entry[9:8] == 2'b00 ||
                            init_entry[9:8] == 2'b10 ||
                            init_entry[9:8] == 2'b11) begin
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
                    if (!spi_busy && pixel_ready) begin
                        lcd_cs     <= 1'b0;
                        lcd_dc     <= 1'b1;
                        shift_data <= pixel_data[15:8];
                        spi_start  <= 1'b1;
                        state      <= S_STREAM_LO;
                    end
                end

                S_STREAM_LO: begin
                    if (spi_done) begin
                        shift_data <= pixel_data[7:0];
                        spi_start  <= 1'b1;
                        state      <= S_STREAM_WAIT;
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
                                init_idx <= RAMWR_IDX[5:0];
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
