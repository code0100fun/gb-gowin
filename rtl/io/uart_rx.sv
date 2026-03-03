// UART receiver — mid-bit sampling with 2-FF synchronizer.
//
// Receives 8N1 frames (1 start bit, 8 data bits LSB-first, 1 stop bit).
// Pulses `valid` for one cycle when a byte is successfully received.
module uart_rx #(
    parameter int CYCLES_PER_BIT = 234  // 27 MHz / 115200
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx,       // serial input
    output logic [7:0] data,
    output logic       valid     // one-cycle pulse when byte received
);

    typedef enum logic [1:0] {
        IDLE  = 2'd0,
        START = 2'd1,
        DATA  = 2'd2,
        STOP  = 2'd3
    } state_t;

    // 2-FF synchronizer to prevent metastability
    logic rx_sync1, rx_sync;
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_sync1 <= 1'b1;
            rx_sync  <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync  <= rx_sync1;
        end
    end

    state_t state;
    logic [7:0]  shift_reg;
    logic [2:0]  bit_idx;
    logic [$clog2(CYCLES_PER_BIT)-1:0] cycle_cnt;

    // Half-bit count for centering on start bit
    localparam int HALF_BIT = CYCLES_PER_BIT / 2;

    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= IDLE;
            shift_reg <= 8'd0;
            bit_idx   <= 3'd0;
            cycle_cnt <= '0;
            data      <= 8'd0;
            valid     <= 1'b0;
        end else begin
            valid <= 1'b0;  // default: pulse off

            case (state)
                IDLE: begin
                    if (!rx_sync) begin
                        // Falling edge — potential start bit
                        state     <= START;
                        cycle_cnt <= HALF_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                    end
                end

                START: begin
                    if (cycle_cnt == 0) begin
                        // At mid-bit of start bit — verify still LOW
                        if (!rx_sync) begin
                            state     <= DATA;
                            cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                            bit_idx   <= 3'd0;
                        end else begin
                            // False start — back to idle
                            state <= IDLE;
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end

                DATA: begin
                    if (cycle_cnt == 0) begin
                        shift_reg[bit_idx] <= rx_sync;
                        if (bit_idx == 3'd7) begin
                            state     <= STOP;
                            cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                        end else begin
                            bit_idx   <= bit_idx + 3'd1;
                            cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end

                STOP: begin
                    if (cycle_cnt == 0) begin
                        if (rx_sync) begin
                            // Valid stop bit — output the byte
                            data  <= shift_reg;
                            valid <= 1'b1;
                        end
                        // Either way, return to idle
                        state <= IDLE;
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end
            endcase
        end
    end

endmodule
