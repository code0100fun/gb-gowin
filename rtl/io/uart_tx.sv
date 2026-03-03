// UART transmitter — shift-register with ready/valid handshake.
//
// Sends 8N1 frames (1 start bit, 8 data bits LSB-first, 1 stop bit).
// Line idles HIGH. Pulse `valid` when `ready` is asserted to begin
// transmission of `data`.
module uart_tx #(
    parameter int CYCLES_PER_BIT = 234  // 27 MHz / 115200
) (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] data,
    input  logic       valid,   // pulse to start transmission
    output logic       ready,   // high when idle
    output logic       tx       // serial output (idles high)
);

    typedef enum logic [1:0] {
        IDLE  = 2'd0,
        START = 2'd1,
        DATA  = 2'd2,
        STOP  = 2'd3
    } state_t;

    state_t state;
    logic [7:0]  shift_reg;
    logic [2:0]  bit_idx;
    logic [$clog2(CYCLES_PER_BIT)-1:0] cycle_cnt;

    assign ready = (state == IDLE);

    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= IDLE;
            tx        <= 1'b1;
            shift_reg <= 8'd0;
            bit_idx   <= 3'd0;
            cycle_cnt <= '0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (valid) begin
                        shift_reg <= data;
                        state     <= START;
                        cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                        tx        <= 1'b0;  // start bit
                    end
                end

                START: begin
                    if (cycle_cnt == 0) begin
                        state     <= DATA;
                        cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                        bit_idx   <= 3'd0;
                        tx        <= shift_reg[0];
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end

                DATA: begin
                    if (cycle_cnt == 0) begin
                        if (bit_idx == 3'd7) begin
                            state     <= STOP;
                            cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                            tx        <= 1'b1;  // stop bit
                        end else begin
                            bit_idx   <= bit_idx + 3'd1;
                            cycle_cnt <= CYCLES_PER_BIT[$clog2(CYCLES_PER_BIT)-1:0] - 1;
                            tx        <= shift_reg[bit_idx + 1];
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end

                STOP: begin
                    if (cycle_cnt == 0) begin
                        state <= IDLE;
                    end else begin
                        cycle_cnt <= cycle_cnt - 1;
                    end
                end
            endcase
        end
    end

endmodule
