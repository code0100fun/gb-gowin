// Dead-simple ST7789 SPI test — hardcoded bit-banging.
// SPI clock ~52 kHz (very slow, breadboard-safe).
// CS toggled between every command. SWRESET included. Backlight on immediately.
module lcd_test_top (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,
    input  logic       btn_s2,
    output logic [5:0] led,

    output logic       lcd_rst,
    output logic       lcd_cs,
    output logic       lcd_dc,
    output logic       lcd_sclk,
    output logic       lcd_mosi,
    output logic       lcd_bl
);

    // ---- Slow clock: 27 MHz / 256 ≈ 105 kHz tick rate ----
    logic [7:0] clk_div;
    always_ff @(posedge clk) clk_div <= clk_div + 8'd1;
    wire slow_tick = (clk_div == 8'd0);

    // ---- Power-on reset ----
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];

    // ---- SPI byte sender (single always_ff, no multi-driver) ----
    logic [7:0]  spi_tx_data;   // latched copy of byte being sent
    logic [3:0]  bit_idx;       // 0=idle, 1-8=sending
    logic        tx_start;      // pulse from FSM
    logic        tx_done;       // pulse when byte complete
    logic        sclk_phase;    // 0=rising edge next, 1=falling edge next

    always_ff @(posedge clk) begin
        if (reset) begin
            spi_tx_data <= 8'd0;
            bit_idx     <= 4'd0;
            lcd_sclk    <= 1'b0;
            lcd_mosi    <= 1'b0;
            tx_done     <= 1'b0;
            sclk_phase  <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            if (tx_start && bit_idx == 4'd0) begin
                // Latch the byte and set up MSB on MOSI
                spi_tx_data <= tx_byte;
                bit_idx     <= 4'd1;
                lcd_mosi    <= tx_byte[7];
                lcd_sclk    <= 1'b0;
                sclk_phase  <= 1'b0;
            end else if (bit_idx != 4'd0 && slow_tick) begin
                if (!sclk_phase) begin
                    // Rising edge — display samples MOSI
                    lcd_sclk   <= 1'b1;
                    sclk_phase <= 1'b1;
                end else begin
                    // Falling edge — shift to next bit
                    lcd_sclk   <= 1'b0;
                    sclk_phase <= 1'b0;
                    if (bit_idx == 4'd8) begin
                        bit_idx <= 4'd0;
                        tx_done <= 1'b1;
                    end else begin
                        bit_idx  <= bit_idx + 4'd1;
                        lcd_mosi <= spi_tx_data[4'd7 - bit_idx[2:0]];
                    end
                end
            end
        end
    end

    // ---- Delay counter (in slow_ticks) ----
    logic [16:0] delay_cnt;

    // Delay constants in slow_ticks (~105 kHz)
    localparam int D_10MS  = 1050;
    localparam int D_150MS = 15750;
    localparam int D_500MS = 52500;

    // ---- Main FSM ----
    // tx_byte is ONLY written by this always_ff block (no multi-driver)
    logic [7:0] tx_byte;

    typedef enum logic [4:0] {
        S_BL_ON,
        S_RST_LO,
        S_RST_HI,
        // SWRESET
        S_CS_LO_SWRST,
        S_CMD_SWRST,
        S_WAIT_SWRST,
        S_CS_HI_SWRST,
        S_DELAY_SWRST,
        // SLPOUT
        S_CS_LO_SLPOUT,
        S_CMD_SLPOUT,
        S_WAIT_SLPOUT,
        S_CS_HI_SLPOUT,
        S_DELAY_SLPOUT,
        // COLMOD
        S_CS_LO_COLMOD,
        S_CMD_COLMOD,
        S_WAIT_COLMOD,
        S_DAT_COLMOD,
        S_WAIT_COLMOD2,
        S_CS_HI_COLMOD,
        // INVON
        S_CS_LO_INVON,
        S_CMD_INVON,
        S_WAIT_INVON,
        S_CS_HI_INVON,
        // DISPON
        S_CS_LO_DISPON,
        S_CMD_DISPON,
        S_WAIT_DISPON,
        S_CS_HI_DISPON,
        S_DELAY_DISPON,
        // RAMWR + pixels
        S_CS_LO_RAMWR,
        S_CMD_RAMWR,
        S_WAIT_RAMWR
    } state_t;

    // S_PIXEL must be outside the enum since we need more states
    logic        in_pixel_stream;
    logic        pixel_phase; // 0=high byte, 1=low byte

    state_t state;

    always_ff @(posedge clk) begin
        if (reset) begin
            state           <= S_BL_ON;
            lcd_rst         <= 1'b0;
            lcd_cs          <= 1'b1;
            lcd_dc          <= 1'b0;
            lcd_bl          <= 1'b0;
            tx_start        <= 1'b0;
            tx_byte         <= 8'd0;
            delay_cnt       <= 17'd0;
            led             <= 6'b111111;
            in_pixel_stream <= 1'b0;
            pixel_phase     <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (in_pixel_stream) begin
                // Continuous pixel streaming (white = 0xFF, 0xFF)
                if (tx_done) begin
                    tx_byte  <= 8'hFF;
                    tx_start <= 1'b1;
                end else if (bit_idx == 4'd0 && !tx_start) begin
                    // Start next byte if idle
                    tx_byte  <= 8'hFF;
                    tx_start <= 1'b1;
                end
            end else begin
                unique case (state)
                    // ---- Backlight on immediately ----
                    S_BL_ON: begin
                        lcd_bl <= 1'b1;
                        state  <= S_RST_LO;
                    end

                    // ---- Hardware reset ----
                    S_RST_LO: begin
                        lcd_rst <= 1'b0;
                        lcd_cs  <= 1'b1;
                        if (slow_tick) begin
                            if (delay_cnt == D_10MS[16:0]) begin
                                lcd_rst   <= 1'b1;
                                delay_cnt <= 17'd0;
                                state     <= S_RST_HI;
                            end else
                                delay_cnt <= delay_cnt + 17'd1;
                        end
                    end

                    S_RST_HI: begin
                        if (slow_tick) begin
                            if (delay_cnt == D_150MS[16:0]) begin
                                delay_cnt <= 17'd0;
                                state     <= S_CS_LO_SWRST;
                            end else
                                delay_cnt <= delay_cnt + 17'd1;
                        end
                    end

                    // ---- SWRESET (0x01) ----
                    S_CS_LO_SWRST: begin
                        lcd_cs  <= 1'b0;
                        lcd_dc  <= 1'b0;
                        state   <= S_CMD_SWRST;
                    end
                    S_CMD_SWRST: begin
                        tx_byte  <= 8'h01;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_SWRST;
                        led      <= 6'b111110;
                    end
                    S_WAIT_SWRST: if (tx_done) begin
                        lcd_cs <= 1'b1;
                        state  <= S_CS_HI_SWRST;
                    end
                    S_CS_HI_SWRST: begin
                        delay_cnt <= 17'd0;
                        state     <= S_DELAY_SWRST;
                    end
                    S_DELAY_SWRST: begin
                        if (slow_tick) begin
                            if (delay_cnt == D_150MS[16:0]) begin
                                delay_cnt <= 17'd0;
                                state     <= S_CS_LO_SLPOUT;
                            end else
                                delay_cnt <= delay_cnt + 17'd1;
                        end
                    end

                    // ---- SLPOUT (0x11) ----
                    S_CS_LO_SLPOUT: begin
                        lcd_cs <= 1'b0;
                        lcd_dc <= 1'b0;
                        state  <= S_CMD_SLPOUT;
                    end
                    S_CMD_SLPOUT: begin
                        tx_byte  <= 8'h11;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_SLPOUT;
                        led      <= 6'b111100;
                    end
                    S_WAIT_SLPOUT: if (tx_done) begin
                        lcd_cs <= 1'b1;
                        state  <= S_CS_HI_SLPOUT;
                    end
                    S_CS_HI_SLPOUT: begin
                        delay_cnt <= 17'd0;
                        state     <= S_DELAY_SLPOUT;
                    end
                    S_DELAY_SLPOUT: begin
                        if (slow_tick) begin
                            if (delay_cnt == D_500MS[16:0]) begin
                                delay_cnt <= 17'd0;
                                state     <= S_CS_LO_COLMOD;
                            end else
                                delay_cnt <= delay_cnt + 17'd1;
                        end
                    end

                    // ---- COLMOD (0x3A, 0x55) ----
                    S_CS_LO_COLMOD: begin
                        lcd_cs <= 1'b0;
                        lcd_dc <= 1'b0;
                        state  <= S_CMD_COLMOD;
                    end
                    S_CMD_COLMOD: begin
                        tx_byte  <= 8'h3A;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_COLMOD;
                    end
                    S_WAIT_COLMOD: if (tx_done) begin
                        state <= S_DAT_COLMOD;
                    end
                    S_DAT_COLMOD: begin
                        lcd_dc   <= 1'b1;
                        tx_byte  <= 8'h55;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_COLMOD2;
                        led      <= 6'b111000;
                    end
                    S_WAIT_COLMOD2: if (tx_done) begin
                        lcd_cs <= 1'b1;
                        state  <= S_CS_HI_COLMOD;
                    end
                    S_CS_HI_COLMOD: begin
                        state <= S_CS_LO_INVON;
                    end

                    // ---- INVON (0x21) ----
                    S_CS_LO_INVON: begin
                        lcd_cs <= 1'b0;
                        lcd_dc <= 1'b0;
                        state  <= S_CMD_INVON;
                    end
                    S_CMD_INVON: begin
                        tx_byte  <= 8'h21;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_INVON;
                    end
                    S_WAIT_INVON: if (tx_done) begin
                        lcd_cs <= 1'b1;
                        state  <= S_CS_HI_INVON;
                    end
                    S_CS_HI_INVON: begin
                        state <= S_CS_LO_DISPON;
                    end

                    // ---- DISPON (0x29) ----
                    S_CS_LO_DISPON: begin
                        lcd_cs <= 1'b0;
                        lcd_dc <= 1'b0;
                        state  <= S_CMD_DISPON;
                    end
                    S_CMD_DISPON: begin
                        tx_byte  <= 8'h29;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_DISPON;
                        led      <= 6'b110000;
                    end
                    S_WAIT_DISPON: if (tx_done) begin
                        lcd_cs <= 1'b1;
                        state  <= S_CS_HI_DISPON;
                    end
                    S_CS_HI_DISPON: begin
                        delay_cnt <= 17'd0;
                        state     <= S_DELAY_DISPON;
                    end
                    S_DELAY_DISPON: begin
                        if (slow_tick) begin
                            if (delay_cnt == D_150MS[16:0]) begin
                                delay_cnt <= 17'd0;
                                state     <= S_CS_LO_RAMWR;
                            end else
                                delay_cnt <= delay_cnt + 17'd1;
                        end
                    end

                    // ---- RAMWR (0x2C) + stream white ----
                    S_CS_LO_RAMWR: begin
                        lcd_cs <= 1'b0;
                        lcd_dc <= 1'b0;
                        state  <= S_CMD_RAMWR;
                    end
                    S_CMD_RAMWR: begin
                        tx_byte  <= 8'h2C;
                        tx_start <= 1'b1;
                        state    <= S_WAIT_RAMWR;
                    end
                    S_WAIT_RAMWR: if (tx_done) begin
                        // Switch to data mode and start pixel stream
                        lcd_dc          <= 1'b1;
                        in_pixel_stream <= 1'b1;
                        led             <= 6'b000000;
                    end

                    default: state <= S_BL_ON;
                endcase
            end
        end
    end

endmodule
