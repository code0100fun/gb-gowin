// Debug console — single-character command processor over UART.
//
// Receives commands via UART RX, responds with formatted ASCII text
// via UART TX. Captures all debug inputs into shadow registers when
// a command arrives so the response reflects a consistent snapshot.
//
// Commands:
//   '?' -> "cmds: ? p r\r\n"
//   'p' -> "PC=XXXX\r\n"
//   'r' -> "A=XX F=XX BC=XXXX DE=XXXX HL=XXXX SP=XXXX PC=XXXX IF=XX IE=XX\r\n"
module debug_console #(
    parameter int CYCLES_PER_BIT = 234
) (
    input  logic        clk,
    input  logic        reset,

    // UART pins
    input  logic        uart_rx_pin,
    output logic        uart_tx_pin,

    // CPU debug
    input  logic [15:0] dbg_pc,
    input  logic [15:0] dbg_sp,
    input  logic [7:0]  dbg_a, dbg_f,
    input  logic [7:0]  dbg_b, dbg_c,
    input  logic [7:0]  dbg_d, dbg_e,
    input  logic [7:0]  dbg_h, dbg_l,
    input  logic        dbg_halted,

    // Interrupt debug
    input  logic [7:0]  dbg_if,
    input  logic [7:0]  dbg_ie
);

    // -----------------------------------------------------------------
    // Hex nibble -> ASCII conversion
    // -----------------------------------------------------------------
    function automatic [7:0] hex(input [3:0] v);
        if (v < 4'd10)
            hex = 8'd48 + {4'd0, v};  // '0'..'9'
        else
            hex = 8'd55 + {4'd0, v};  // 'A'..'F'
    endfunction

    // ASCII constants
    localparam [7:0] CH_SP = 8'h20;  // ' '
    localparam [7:0] CH_EQ = 8'h3D;  // '='
    localparam [7:0] CH_QM = 8'h3F;  // '?'
    localparam [7:0] CH_CR = 8'h0D;  // '\r'
    localparam [7:0] CH_LF = 8'h0A;  // '\n'
    localparam [7:0] CH_A  = 8'h41;
    localparam [7:0] CH_B  = 8'h42;
    localparam [7:0] CH_C  = 8'h43;
    localparam [7:0] CH_D  = 8'h44;
    localparam [7:0] CH_E  = 8'h45;
    localparam [7:0] CH_F  = 8'h46;
    localparam [7:0] CH_H  = 8'h48;
    localparam [7:0] CH_I  = 8'h49;
    localparam [7:0] CH_L  = 8'h4C;
    localparam [7:0] CH_P  = 8'h50;
    localparam [7:0] CH_S  = 8'h53;
    localparam [7:0] CH_c  = 8'h63;
    localparam [7:0] CH_d  = 8'h64;
    localparam [7:0] CH_m  = 8'h6D;
    localparam [7:0] CH_p  = 8'h70;
    localparam [7:0] CH_r  = 8'h72;
    localparam [7:0] CH_s  = 8'h73;
    localparam [7:0] CH_CO = 8'h3A;  // ':'

    // -----------------------------------------------------------------
    // UART TX/RX instances
    // -----------------------------------------------------------------
    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_ready;

    uart_tx #(.CYCLES_PER_BIT(CYCLES_PER_BIT)) u_tx (
        .clk  (clk),
        .reset(reset),
        .data (tx_data),
        .valid(tx_valid),
        .ready(tx_ready),
        .tx   (uart_tx_pin)
    );

    logic [7:0] rx_data;
    logic       rx_valid;

    uart_rx #(.CYCLES_PER_BIT(CYCLES_PER_BIT)) u_rx (
        .clk  (clk),
        .reset(reset),
        .rx   (uart_rx_pin),
        .data (rx_data),
        .valid(rx_valid)
    );

    // -----------------------------------------------------------------
    // Shadow registers — captured on command arrival
    // -----------------------------------------------------------------
    logic [15:0] sh_pc, sh_sp;
    logic [7:0]  sh_a, sh_f, sh_b, sh_c, sh_d, sh_e, sh_h, sh_l;
    logic [7:0]  sh_if, sh_ie;

    // -----------------------------------------------------------------
    // Response FSM
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_SEND  = 2'd1,
        S_LATCH = 2'd2,  // wait one cycle for TX to latch data
        S_WAIT  = 2'd3
    } state_t;

    state_t state;
    logic [1:0] cmd;        // 0=?, 1=p, 2=r
    logic [5:0] byte_idx;   // index into response
    logic [5:0] resp_len;   // total bytes in current response

    // Response lengths
    localparam logic [5:0] LEN_HELP = 6'd13;  // "cmds: ? p r\r\n"
    localparam logic [5:0] LEN_PC   = 6'd9;   // "PC=XXXX\r\n"
    localparam logic [5:0] LEN_REGS = 6'd63;  // full register dump

    // -----------------------------------------------------------------
    // Response byte mux (combinational)
    // -----------------------------------------------------------------
    logic [7:0] resp_byte;

    always_comb begin
        resp_byte = 8'h00;
        case (cmd)
            2'd0: begin // '?' help: "cmds: ? p r\r\n"
                case (byte_idx)
                    6'd0:  resp_byte = CH_c;
                    6'd1:  resp_byte = CH_m;
                    6'd2:  resp_byte = CH_d;
                    6'd3:  resp_byte = CH_s;
                    6'd4:  resp_byte = CH_CO;
                    6'd5:  resp_byte = CH_SP;
                    6'd6:  resp_byte = CH_QM;
                    6'd7:  resp_byte = CH_SP;
                    6'd8:  resp_byte = CH_p;
                    6'd9:  resp_byte = CH_SP;
                    6'd10: resp_byte = CH_r;
                    6'd11: resp_byte = CH_CR;
                    6'd12: resp_byte = CH_LF;
                    default: resp_byte = 8'h00;
                endcase
            end
            2'd1: begin // 'p' PC only: "PC=XXXX\r\n"
                case (byte_idx)
                    6'd0: resp_byte = CH_P;
                    6'd1: resp_byte = CH_C;
                    6'd2: resp_byte = CH_EQ;
                    6'd3: resp_byte = hex(sh_pc[15:12]);
                    6'd4: resp_byte = hex(sh_pc[11:8]);
                    6'd5: resp_byte = hex(sh_pc[7:4]);
                    6'd6: resp_byte = hex(sh_pc[3:0]);
                    6'd7: resp_byte = CH_CR;
                    6'd8: resp_byte = CH_LF;
                    default: resp_byte = 8'h00;
                endcase
            end
            2'd2: begin // 'r' full register dump
                case (byte_idx)
                    6'd0:  resp_byte = CH_A;
                    6'd1:  resp_byte = CH_EQ;
                    6'd2:  resp_byte = hex(sh_a[7:4]);
                    6'd3:  resp_byte = hex(sh_a[3:0]);
                    6'd4:  resp_byte = CH_SP;
                    6'd5:  resp_byte = CH_F;
                    6'd6:  resp_byte = CH_EQ;
                    6'd7:  resp_byte = hex(sh_f[7:4]);
                    6'd8:  resp_byte = hex(sh_f[3:0]);
                    6'd9:  resp_byte = CH_SP;
                    6'd10: resp_byte = CH_B;
                    6'd11: resp_byte = CH_C;
                    6'd12: resp_byte = CH_EQ;
                    6'd13: resp_byte = hex(sh_b[7:4]);
                    6'd14: resp_byte = hex(sh_b[3:0]);
                    6'd15: resp_byte = hex(sh_c[7:4]);
                    6'd16: resp_byte = hex(sh_c[3:0]);
                    6'd17: resp_byte = CH_SP;
                    6'd18: resp_byte = CH_D;
                    6'd19: resp_byte = CH_E;
                    6'd20: resp_byte = CH_EQ;
                    6'd21: resp_byte = hex(sh_d[7:4]);
                    6'd22: resp_byte = hex(sh_d[3:0]);
                    6'd23: resp_byte = hex(sh_e[7:4]);
                    6'd24: resp_byte = hex(sh_e[3:0]);
                    6'd25: resp_byte = CH_SP;
                    6'd26: resp_byte = CH_H;
                    6'd27: resp_byte = CH_L;
                    6'd28: resp_byte = CH_EQ;
                    6'd29: resp_byte = hex(sh_h[7:4]);
                    6'd30: resp_byte = hex(sh_h[3:0]);
                    6'd31: resp_byte = hex(sh_l[7:4]);
                    6'd32: resp_byte = hex(sh_l[3:0]);
                    6'd33: resp_byte = CH_SP;
                    6'd34: resp_byte = CH_S;
                    6'd35: resp_byte = CH_P;
                    6'd36: resp_byte = CH_EQ;
                    6'd37: resp_byte = hex(sh_sp[15:12]);
                    6'd38: resp_byte = hex(sh_sp[11:8]);
                    6'd39: resp_byte = hex(sh_sp[7:4]);
                    6'd40: resp_byte = hex(sh_sp[3:0]);
                    6'd41: resp_byte = CH_SP;
                    6'd42: resp_byte = CH_P;
                    6'd43: resp_byte = CH_C;
                    6'd44: resp_byte = CH_EQ;
                    6'd45: resp_byte = hex(sh_pc[15:12]);
                    6'd46: resp_byte = hex(sh_pc[11:8]);
                    6'd47: resp_byte = hex(sh_pc[7:4]);
                    6'd48: resp_byte = hex(sh_pc[3:0]);
                    6'd49: resp_byte = CH_SP;
                    6'd50: resp_byte = CH_I;
                    6'd51: resp_byte = CH_F;
                    6'd52: resp_byte = CH_EQ;
                    6'd53: resp_byte = hex(sh_if[7:4]);
                    6'd54: resp_byte = hex(sh_if[3:0]);
                    6'd55: resp_byte = CH_SP;
                    6'd56: resp_byte = CH_I;
                    6'd57: resp_byte = CH_E;
                    6'd58: resp_byte = CH_EQ;
                    6'd59: resp_byte = hex(sh_ie[7:4]);
                    6'd60: resp_byte = hex(sh_ie[3:0]);
                    6'd61: resp_byte = CH_CR;
                    6'd62: resp_byte = CH_LF;
                    default: resp_byte = 8'h00;
                endcase
            end
            default: resp_byte = 8'h00;
        endcase
    end

    // -----------------------------------------------------------------
    // Main FSM
    // -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state    <= S_IDLE;
            tx_valid <= 1'b0;
            tx_data  <= 8'd0;
            byte_idx <= 6'd0;
            resp_len <= 6'd0;
            cmd      <= 2'd0;
            sh_pc <= 16'd0; sh_sp <= 16'd0;
            sh_a  <= 8'd0;  sh_f  <= 8'd0;
            sh_b  <= 8'd0;  sh_c  <= 8'd0;
            sh_d  <= 8'd0;  sh_e  <= 8'd0;
            sh_h  <= 8'd0;  sh_l  <= 8'd0;
            sh_if <= 8'd0;  sh_ie <= 8'd0;
        end else begin
            tx_valid <= 1'b0;  // default: pulse off

            case (state)
                S_IDLE: begin
                    if (rx_valid) begin
                        // Capture snapshot of all debug signals
                        sh_pc <= dbg_pc; sh_sp <= dbg_sp;
                        sh_a  <= dbg_a;  sh_f  <= dbg_f;
                        sh_b  <= dbg_b;  sh_c  <= dbg_c;
                        sh_d  <= dbg_d;  sh_e  <= dbg_e;
                        sh_h  <= dbg_h;  sh_l  <= dbg_l;
                        sh_if <= dbg_if; sh_ie <= dbg_ie;

                        case (rx_data)
                            8'h3F: begin // '?'
                                cmd      <= 2'd0;
                                resp_len <= LEN_HELP;
                                byte_idx <= 6'd0;
                                state    <= S_SEND;
                            end
                            8'h70: begin // 'p'
                                cmd      <= 2'd1;
                                resp_len <= LEN_PC;
                                byte_idx <= 6'd0;
                                state    <= S_SEND;
                            end
                            8'h72: begin // 'r'
                                cmd      <= 2'd2;
                                resp_len <= LEN_REGS;
                                byte_idx <= 6'd0;
                                state    <= S_SEND;
                            end
                            default: begin
                                // Ignore unknown commands (including \r, \n)
                            end
                        endcase
                    end
                end

                S_SEND: begin
                    if (tx_ready) begin
                        tx_data  <= resp_byte;
                        tx_valid <= 1'b1;
                        state    <= S_LATCH;
                    end
                end

                S_LATCH: begin
                    // One-cycle delay: TX latches data on this edge and
                    // transitions out of IDLE, so tx_ready drops next cycle.
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    // Wait for TX to finish sending the byte.
                    if (tx_ready) begin
                        if (byte_idx + 6'd1 == resp_len) begin
                            state <= S_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 6'd1;
                            state    <= S_SEND;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
