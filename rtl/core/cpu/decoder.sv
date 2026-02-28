// LR35902 instruction decoder.
//
// Purely combinational — decodes an opcode into control signals and cycle
// counts. The CPU feeds in the current opcode and M-cycle counter; the
// decoder tells it what to do this cycle and how many cycles remain.
//
// For CB-prefixed instructions, the CPU sets cb_prefix=1 and feeds the
// second byte as opcode. The mcycles output then covers only the CB
// instruction (excluding the prefix fetch).
//
// Opcode structure:
//   Block 0 (00-3F): misc, 16-bit loads, inc/dec, rotates, JR
//   Block 1 (40-7F): 8-bit LD r8,r8 (HALT at 0x76)
//   Block 2 (80-BF): 8-bit ALU A,r8
//   Block 3 (C0-FF): jumps, calls, returns, stack, I/O, CB prefix
module decoder (
    input  logic [7:0]  opcode,
    input  logic        cb_prefix,   // 1 = CB-prefixed instruction
    input  logic        cond_met,    // 1 = branch condition satisfied

    // Cycle count
    output logic [2:0]  mcycles,     // Total M-cycles for this decode

    // Decoded opcode fields (directly extracted from opcode bits)
    output logic [2:0]  r8_src,      // opcode[2:0] — source r8 index
    output logic [2:0]  r8_dst,      // opcode[5:3] — dest r8 / ALU op
    output logic [1:0]  r16_idx,     // opcode[5:4] — r16 pair index
    output logic [1:0]  cond_code,   // opcode[4:3] — condition code
    output logic [2:0]  rst_vec,     // opcode[5:3] — RST vector (×8)
    output logic [2:0]  cb_bit_idx,  // opcode[5:3] — bit index for BIT/SET/RES

    // ALU operation (5-bit, matches alu.sv encoding)
    output logic [4:0]  alu_op,

    // Instruction type flags
    output logic        is_cb_prefix,     // This is the 0xCB prefix byte
    output logic        uses_hl_indirect, // Instruction accesses [HL]
    output logic        is_halt,
    output logic        is_ei,
    output logic        is_di
);

    // ---------------------------------------------------------------
    // Direct bit field extraction
    // ---------------------------------------------------------------
    assign r8_src    = opcode[2:0];
    assign r8_dst    = opcode[5:3];
    assign r16_idx   = opcode[5:4];
    assign cond_code = opcode[4:3];
    assign rst_vec   = opcode[5:3];
    assign cb_bit_idx = opcode[5:3];

    // ---------------------------------------------------------------
    // Simple instruction flags
    // ---------------------------------------------------------------
    assign is_cb_prefix = !cb_prefix && (opcode == 8'hCB);
    assign is_halt      = !cb_prefix && (opcode == 8'h76);
    assign is_ei        = !cb_prefix && (opcode == 8'hFB);
    assign is_di        = !cb_prefix && (opcode == 8'hF3);

    // ---------------------------------------------------------------
    // [HL] indirect detection
    // ---------------------------------------------------------------
    always_comb begin
        if (cb_prefix) begin
            uses_hl_indirect = (opcode[2:0] == 3'd6);
        end else begin
            unique case (opcode[7:6])
                2'b01:   uses_hl_indirect = (opcode[2:0] == 3'd6) ||
                                            (opcode[5:3] == 3'd6);
                2'b10:   uses_hl_indirect = (opcode[2:0] == 3'd6);
                default: uses_hl_indirect = 1'b0;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // ALU operation decode
    // ---------------------------------------------------------------
    // ALU op encoding: {category[1:0], sub_op[2:0]}
    //   00_xxx = 8-bit arith/logic (ADD/ADC/SUB/SBC/AND/XOR/OR/CP)
    //   01_xxx = rotate/shift (RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL)
    //   10_xxx = bit ops (BIT=000/RES=001/SET=010)
    //   11_xxx = misc (INC=000/DEC=001/DAA=010/CPL=011/SCF=100/CCF=101
    //                   RLCA_RLA=110/RRCA_RRA=111)
    always_comb begin
        alu_op = 5'd0;

        if (cb_prefix) begin
            // CB-prefixed: category from opcode[7:6], sub_op from [5:3]
            unique case (opcode[7:6])
                2'b00: alu_op = {2'b01, opcode[5:3]};  // Rotate/shift
                2'b01: alu_op = {2'b10, 3'b000};       // BIT
                2'b10: alu_op = {2'b10, 3'b001};       // RES
                2'b11: alu_op = {2'b10, 3'b010};       // SET
            endcase
        end else begin
            unique case (opcode[7:6])
                2'b10: begin
                    // Block 2: ALU A,r8 — opcode[5:3] IS the ALU op
                    alu_op = {2'b00, opcode[5:3]};
                end

                2'b11: begin
                    // Block 3: ALU A,u8 at 11_xxx_110
                    if (opcode[2:0] == 3'b110)
                        alu_op = {2'b00, opcode[5:3]};
                end

                2'b00: begin
                    // Block 0 miscellaneous
                    casez (opcode)
                        8'b00_???_100: alu_op = 5'b11_000; // INC r8
                        8'b00_???_101: alu_op = 5'b11_001; // DEC r8
                        8'h07:         alu_op = 5'b11_110; // RLCA
                        8'h17:         alu_op = 5'b11_110; // RLA
                        8'h0F:         alu_op = 5'b11_111; // RRCA
                        8'h1F:         alu_op = 5'b11_111; // RRA
                        8'h27:         alu_op = 5'b11_010; // DAA
                        8'h2F:         alu_op = 5'b11_011; // CPL
                        8'h37:         alu_op = 5'b11_100; // SCF
                        8'h3F:         alu_op = 5'b11_101; // CCF
                        default:       alu_op = 5'd0;
                    endcase
                end

                default: alu_op = 5'd0;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // M-cycle count
    // ---------------------------------------------------------------
    // verilator lint_off CASEOVERLAP
    always_comb begin
        mcycles = 3'd1; // default

        if (cb_prefix) begin
            // CB-prefixed opcodes
            if (opcode[2:0] != 3'd6)
                mcycles = 3'd1;              // Register target
            else if (opcode[7:6] == 2'b01)
                mcycles = 3'd2;              // BIT n,(HL) — read only
            else
                mcycles = 3'd3;              // Shift/rot/RES/SET (HL)
        end else begin
            casez (opcode)
                // =========================================================
                // Block 0 (0x00–0x3F)
                // =========================================================
                8'h00: mcycles = 3'd1; // NOP
                8'h10: mcycles = 3'd1; // STOP
                8'h08: mcycles = 3'd5; // LD (u16),SP
                8'h18: mcycles = 3'd3; // JR i8 (unconditional)

                8'h20, 8'h28,
                8'h30, 8'h38: mcycles = cond_met ? 3'd3 : 3'd2; // JR cond

                8'b00_??_0001: mcycles = 3'd3; // LD r16,u16
                8'b00_??_0010: mcycles = 3'd2; // LD (r16mem),A
                8'b00_??_0011: mcycles = 3'd2; // INC r16
                8'b00_??_1001: mcycles = 3'd2; // ADD HL,r16
                8'b00_??_1010: mcycles = 3'd2; // LD A,(r16mem)
                8'b00_??_1011: mcycles = 3'd2; // DEC r16

                8'h34:         mcycles = 3'd3; // INC (HL)
                8'h35:         mcycles = 3'd3; // DEC (HL)
                8'h36:         mcycles = 3'd3; // LD (HL),u8

                8'b00_???_100: mcycles = 3'd1; // INC r8 (not (HL))
                8'b00_???_101: mcycles = 3'd1; // DEC r8 (not (HL))
                8'b00_???_110: mcycles = 3'd2; // LD r8,u8 (not (HL))
                8'b00_???_111: mcycles = 3'd1; // RLCA/RLA/DAA/SCF/RRCA/RRA/CPL/CCF

                // =========================================================
                // Block 1 (0x40–0x7F): LD r8,r8
                // =========================================================
                8'h76:         mcycles = 3'd1; // HALT
                8'b01_110_???: mcycles = 3'd2; // LD (HL),r8
                8'b01_???_110: mcycles = 3'd2; // LD r8,(HL)
                8'b01_???_???: mcycles = 3'd1; // LD r8,r8

                // =========================================================
                // Block 2 (0x80–0xBF): ALU A,r8
                // =========================================================
                8'b10_???_110: mcycles = 3'd2; // ALU A,(HL)
                8'b10_???_???: mcycles = 3'd1; // ALU A,r8

                // =========================================================
                // Block 3 (0xC0–0xFF)
                // =========================================================

                // Conditional branches
                8'hC0, 8'hC8,
                8'hD0, 8'hD8: mcycles = cond_met ? 3'd5 : 3'd2; // RET cond

                8'hC2, 8'hCA,
                8'hD2, 8'hDA: mcycles = cond_met ? 3'd4 : 3'd3; // JP cond,u16

                8'hC4, 8'hCC,
                8'hD4, 8'hDC: mcycles = cond_met ? 3'd6 : 3'd3; // CALL cond

                // Unconditional control flow
                8'hC3: mcycles = 3'd4; // JP u16
                8'hC9: mcycles = 3'd4; // RET
                8'hCD: mcycles = 3'd6; // CALL u16
                8'hD9: mcycles = 3'd4; // RETI
                8'hE9: mcycles = 3'd1; // JP HL

                // Stack ops
                8'hC1, 8'hD1,
                8'hE1, 8'hF1: mcycles = 3'd3; // POP r16stk

                8'hC5, 8'hD5,
                8'hE5, 8'hF5: mcycles = 3'd4; // PUSH r16stk

                // ALU with immediate
                8'b11_???_110: mcycles = 3'd2; // ALU A,u8

                // RST
                8'b11_???_111: mcycles = 3'd4; // RST n

                // High-page I/O
                8'hE0: mcycles = 3'd3; // LDH (FF00+u8),A
                8'hF0: mcycles = 3'd3; // LDH A,(FF00+u8)
                8'hE2: mcycles = 3'd2; // LDH (FF00+C),A
                8'hF2: mcycles = 3'd2; // LDH A,(FF00+C)

                // 16-bit address loads
                8'hEA: mcycles = 3'd4; // LD (u16),A
                8'hFA: mcycles = 3'd4; // LD A,(u16)

                // SP/HL ops
                8'hE8: mcycles = 3'd4; // ADD SP,i8
                8'hF8: mcycles = 3'd3; // LD HL,SP+i8
                8'hF9: mcycles = 3'd2; // LD SP,HL

                // CB prefix and control
                8'hCB: mcycles = 3'd1; // CB prefix byte
                8'hF3: mcycles = 3'd1; // DI
                8'hFB: mcycles = 3'd1; // EI

                // Invalid opcodes (D3,DB,DD,E3,E4,EB,EC,ED,F4,FC,FD)
                default: mcycles = 3'd1;
            endcase
        end
    end
    // verilator lint_on CASEOVERLAP

endmodule
