// SPI byte-level transport for SD card communication.
//
// Full-duplex: transmits tx_data on MOSI while simultaneously receiving
// on MISO into rx_data. SPI Mode 0 (CPOL=0, CPHA=0): clock idles low,
// data sampled on rising edge, shifted on falling edge.
//
// Two clock speeds: slow (~421 KHz at 27 MHz) for card initialization,
// fast (~6.75 MHz) for data transfer.
module sd_spi (
    input  logic       clk,
    input  logic       reset,

    // SPI pins
    output logic       sclk,
    output logic       mosi,
    input  logic       miso,
    output logic       cs_n,

    // Byte interface
    input  logic [7:0] tx_data,
    input  logic       start,      // pulse to begin transfer
    output logic [7:0] rx_data,    // valid when done pulses
    output logic       busy,
    output logic       done,       // 1-cycle pulse when byte complete

    // Control
    input  logic       cs_en,      // 1=assert CS low, 0=deassert
    input  logic       slow_clk    // 1=÷64 (~421 KHz), 0=÷4 (~6.75 MHz)
);

    // Clock divider
    logic [5:0] clk_div;
    wire [5:0]  clk_max = slow_clk ? 6'd63 : 6'd3;
    wire [5:0]  clk_half = slow_clk ? 6'd31 : 6'd1;
    // Rising edge at clk_half, falling edge at clk_max
    wire        phase_rise = (clk_div == clk_half);
    wire        phase_fall = (clk_div == clk_max);

    // Shift registers
    logic [7:0] tx_shift;
    logic [7:0] rx_shift;
    logic [3:0] bit_cnt;  // 0=idle, 1-8=transferring

    assign busy = (bit_cnt != 4'd0);
    assign cs_n = !cs_en;

    always_ff @(posedge clk) begin
        if (reset) begin
            sclk    <= 1'b0;
            mosi    <= 1'b1;
            rx_data <= 8'h00;
            clk_div <= 6'd0;
            bit_cnt <= 4'd0;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;

            if (bit_cnt == 4'd0) begin
                // Idle — wait for start
                sclk    <= 1'b0;
                clk_div <= 6'd0;
                if (start) begin
                    tx_shift <= tx_data;
                    mosi     <= tx_data[7]; // MSB ready before first clock
                    bit_cnt  <= 4'd1;
                    clk_div  <= 6'd0;
                end
            end else begin
                // Transferring
                if (phase_rise) begin
                    // Rising edge — sample MISO
                    sclk     <= 1'b1;
                    rx_shift <= {rx_shift[6:0], miso};
                end

                if (phase_fall) begin
                    // Falling edge — shift MOSI
                    sclk     <= 1'b0;
                    tx_shift <= {tx_shift[6:0], 1'b1};
                    mosi     <= tx_shift[6]; // next bit (after shift)

                    if (bit_cnt == 4'd8) begin
                        // Transfer complete
                        bit_cnt <= 4'd0;
                        rx_data <= rx_shift;
                        done    <= 1'b1;
                        mosi    <= 1'b1; // idle high
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end

                // Advance divider
                if (clk_div == clk_max)
                    clk_div <= 6'd0;
                else
                    clk_div <= clk_div + 6'd1;
            end
        end
    end

endmodule
