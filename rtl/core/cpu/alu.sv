// LR35902 ALU (Arithmetic Logic Unit).
//
// Purely combinational — takes inputs and produces result + flags in the
// same cycle. The CPU's control logic selects the operation and routes
// data to/from registers and the memory bus.
//
// Operations are grouped into three categories:
//
//   1. alu8_op: 8-bit arithmetic/logic (ADD, ADC, SUB, SBC, AND, XOR, OR, CP)
//      Encoding matches opcode bits [5:3] in Block 2 (0x80–0xBF).
//
//   2. shift_op: Rotates, shifts, SWAP (CB-prefix category 00)
//      Encoding matches CB opcode bits [5:3].
//
//   3. bit_op: BIT, RES, SET (CB-prefix categories 01, 10, 11)
//
//   4. Miscellaneous: INC, DEC, DAA, CPL, SCF, CCF, accumulator rotates
//      (RLCA/RRCA/RLA/RRA), 16-bit ADD HL
//
// Flag register bits: {Z, N, H, C} — see regfile.sv for layout.
module alu (
    // 8-bit ALU operation
    input  logic [7:0]  a,          // first operand (usually accumulator)
    input  logic [7:0]  b,          // second operand (register or immediate)
    input  logic [3:0]  flags_in,   // current flags {Z, N, H, C}
    input  logic [4:0]  op,         // operation select (see alu_op_t)
    input  logic [2:0]  bit_sel,    // bit index for BIT/SET/RES

    output logic [7:0]  result,     // operation result
    output logic [3:0]  flags_out   // updated flags {Z, N, H, C}
);

    // Operation encoding
    // Bits [4:3] select category, bits [2:0] select operation within category
    //
    // 00_xxx: 8-bit arithmetic/logic (matches opcode bits [5:3])
    //   000=ADD  001=ADC  010=SUB  011=SBC  100=AND  101=XOR  110=OR  111=CP
    //
    // 01_xxx: Rotate/shift (matches CB opcode bits [5:3])
    //   000=RLC  001=RRC  010=RL  011=RR  100=SLA  101=SRA  110=SWAP  111=SRL
    //
    // 10_xxx: Bit operations
    //   000=BIT  001=RES  010=SET
    //
    // 11_xxx: Miscellaneous
    //   000=INC  001=DEC  010=DAA  011=CPL  100=SCF  101=CCF
    //   110=RLCA/RLA  111=RRCA/RRA  (accumulator rotates — flag Z always 0)

    // Category decode
    localparam logic [1:0] CAT_ALU8  = 2'b00;
    localparam logic [1:0] CAT_SHIFT = 2'b01;
    localparam logic [1:0] CAT_BIT   = 2'b10;
    localparam logic [1:0] CAT_MISC  = 2'b11;

    logic [1:0] cat;
    logic [2:0] sub_op;
    assign cat    = op[4:3];
    assign sub_op = op[2:0];

    // Intermediate signals
    logic [8:0] sum9;       // 9-bit for carry detection
    logic [4:0] hsum5;      // 5-bit for half-carry detection
    logic       cin;        // carry input (for ADC/SBC)
    logic       c_in;       // current carry flag
    logic [7:0] daa_result;
    logic [3:0] daa_flags;

    assign c_in = flags_in[0];

    // DAA computation
    always_comb begin
        logic [7:0] adjust;
        logic new_c;

        adjust = 8'h00;
        new_c  = flags_in[0];  // C

        if (!flags_in[2]) begin  // N=0 (after addition)
            if (flags_in[1] || (a[3:0] > 4'h9))
                adjust = 8'h06;
            if (flags_in[0] || (a > 8'h99)) begin
                adjust = adjust + 8'h60;
                new_c  = 1'b1;
            end
        end else begin  // N=1 (after subtraction)
            if (flags_in[1])
                adjust = 8'h06;
            if (flags_in[0])
                adjust = adjust + 8'h60;
        end

        if (!flags_in[2])
            daa_result = a + adjust;
        else
            daa_result = a - adjust;

        daa_flags = {(daa_result == 8'h00), flags_in[2], 1'b0, new_c};
    end

    // Main ALU logic
    always_comb begin
        result    = 8'h00;
        flags_out = flags_in;  // default: preserve all flags
        sum9      = 9'd0;
        hsum5     = 5'd0;
        cin       = 1'b0;

        unique case (cat)
            // =============================================================
            // 8-bit arithmetic/logic
            // =============================================================
            CAT_ALU8: begin
                unique case (sub_op)
                    3'd0, 3'd1: begin  // ADD, ADC
                        cin   = (sub_op == 3'd1) ? c_in : 1'b0;
                        hsum5 = {1'b0, a[3:0]} + {1'b0, b[3:0]} + {4'd0, cin};
                        sum9  = {1'b0, a}      + {1'b0, b}      + {8'd0, cin};
                        result    = sum9[7:0];
                        flags_out = {(result == 8'h0), 1'b0, hsum5[4], sum9[8]};
                    end

                    3'd2, 3'd3, 3'd7: begin  // SUB, SBC, CP
                        cin   = (sub_op == 3'd3) ? c_in : 1'b0;
                        hsum5 = {1'b0, a[3:0]} - {1'b0, b[3:0]} - {4'd0, cin};
                        sum9  = {1'b0, a}      - {1'b0, b}      - {8'd0, cin};
                        result    = (sub_op == 3'd7) ? a : sum9[7:0];  // CP doesn't store
                        flags_out = {(sum9[7:0] == 8'h0), 1'b1, hsum5[4], sum9[8]};
                    end

                    3'd4: begin  // AND
                        result    = a & b;
                        flags_out = {(result == 8'h0), 1'b0, 1'b1, 1'b0};
                    end

                    3'd5: begin  // XOR
                        result    = a ^ b;
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, 1'b0};
                    end

                    3'd6: begin  // OR
                        result    = a | b;
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, 1'b0};
                    end

                    default: ;
                endcase
            end

            // =============================================================
            // Rotate/shift (CB prefix, category 00)
            // =============================================================
            CAT_SHIFT: begin
                unique case (sub_op)
                    3'd0: begin  // RLC — rotate left, old bit7 → carry & bit0
                        result    = {a[6:0], a[7]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[7]};
                    end

                    3'd1: begin  // RRC — rotate right, old bit0 → carry & bit7
                        result    = {a[0], a[7:1]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[0]};
                    end

                    3'd2: begin  // RL — rotate left through carry
                        result    = {a[6:0], c_in};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[7]};
                    end

                    3'd3: begin  // RR — rotate right through carry
                        result    = {c_in, a[7:1]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[0]};
                    end

                    3'd4: begin  // SLA — shift left arithmetic, bit0=0
                        result    = {a[6:0], 1'b0};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[7]};
                    end

                    3'd5: begin  // SRA — shift right arithmetic, bit7 preserved
                        result    = {a[7], a[7:1]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[0]};
                    end

                    3'd6: begin  // SWAP — swap nibbles
                        result    = {a[3:0], a[7:4]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, 1'b0};
                    end

                    3'd7: begin  // SRL — shift right logical, bit7=0
                        result    = {1'b0, a[7:1]};
                        flags_out = {(result == 8'h0), 1'b0, 1'b0, a[0]};
                    end
                endcase
            end

            // =============================================================
            // Bit operations (CB prefix, categories 01/10/11)
            // =============================================================
            CAT_BIT: begin
                unique case (sub_op[1:0])
                    2'd0: begin  // BIT — test bit
                        result    = a;  // BIT doesn't modify the value
                        flags_out = {~a[bit_sel], 1'b0, 1'b1, flags_in[0]};
                    end

                    2'd1: begin  // RES — reset (clear) bit
                        result    = a & ~(8'd1 << bit_sel);
                        flags_out = flags_in;  // no flag changes
                    end

                    2'd2: begin  // SET — set bit
                        result    = a | (8'd1 << bit_sel);
                        flags_out = flags_in;  // no flag changes
                    end

                    default: begin
                        result    = a;
                        flags_out = flags_in;
                    end
                endcase
            end

            // =============================================================
            // Miscellaneous operations
            // =============================================================
            CAT_MISC: begin
                unique case (sub_op)
                    3'd0: begin  // INC — increment (C unaffected)
                        hsum5     = {1'b0, a[3:0]} + 5'd1;
                        result    = a + 8'd1;
                        flags_out = {(result == 8'h0), 1'b0, hsum5[4], flags_in[0]};
                    end

                    3'd1: begin  // DEC — decrement (C unaffected)
                        hsum5     = {1'b0, a[3:0]} - 5'd1;
                        result    = a - 8'd1;
                        flags_out = {(result == 8'h0), 1'b1, hsum5[4], flags_in[0]};
                    end

                    3'd2: begin  // DAA
                        result    = daa_result;
                        flags_out = daa_flags;
                    end

                    3'd3: begin  // CPL — complement A
                        result    = ~a;
                        flags_out = {flags_in[3], 1'b1, 1'b1, flags_in[0]};
                    end

                    3'd4: begin  // SCF — set carry flag
                        result    = a;
                        flags_out = {flags_in[3], 1'b0, 1'b0, 1'b1};
                    end

                    3'd5: begin  // CCF — complement carry flag
                        result    = a;
                        flags_out = {flags_in[3], 1'b0, 1'b0, ~flags_in[0]};
                    end

                    3'd6: begin  // RLCA or RLA (accumulator rotate left, Z=0)
                        // bit_sel[0] distinguishes: 0=RLCA, 1=RLA
                        if (!bit_sel[0]) begin
                            result = {a[6:0], a[7]};       // RLCA
                        end else begin
                            result = {a[6:0], c_in};        // RLA
                        end
                        flags_out = {1'b0, 1'b0, 1'b0, a[7]};  // Z always 0
                    end

                    3'd7: begin  // RRCA or RRA (accumulator rotate right, Z=0)
                        // bit_sel[0] distinguishes: 0=RRCA, 1=RRA
                        if (!bit_sel[0]) begin
                            result = {a[0], a[7:1]};       // RRCA
                        end else begin
                            result = {c_in, a[7:1]};       // RRA
                        end
                        flags_out = {1'b0, 1'b0, 1'b0, a[0]};  // Z always 0
                    end
                endcase
            end
        endcase
    end

endmodule
