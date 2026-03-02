module blinky (
    input  logic       clk,
    input  logic       btn_s1,
    input  logic       btn_s2,
    output logic [5:0] led
);

    // 27 MHz clock. To blink at ~1 Hz we need a ~25-bit counter.
    // Bit 24 toggles every 2^24 / 27_000_000 ≈ 0.62 seconds.
    // Bit 23 toggles every 2^23 / 27_000_000 ≈ 0.31 seconds.
    localparam int COUNTER_WIDTH = 25;

    logic [COUNTER_WIDTH-1:0] counter;

    always_ff @(posedge clk) begin
        counter <= counter + 1;
    end

    // Drive LEDs from the upper bits of the counter.
    // LEDs are active low, so invert the counter bits.
    // When btn_s1 is pressed (high), shift to a faster blink rate.
    always_comb begin
        if (btn_s1)
            // Fast mode: use bits [21:16] — blinks ~8x faster
            led = ~counter[21:16];
        else
            // Normal mode: use bits [24:19] — leisurely blink
            led = ~counter[24:19];
    end

endmodule
