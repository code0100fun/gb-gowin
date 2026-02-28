#include "Vdecoder.h"

#include <verilated.h>
#include <cstdint>
#include <cstdio>

// Expected M-cycle counts for all 256 base opcodes (branch taken).
// Rows = high nibble (0x?0), columns = low nibble (0x0?).
static const uint8_t BASE_MCYCLES_TAKEN[256] = {
    //      0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    /* 0 */ 1, 3, 2, 2, 1, 1, 2, 1, 5, 2, 2, 2, 1, 1, 2, 1,
    /* 1 */ 1, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    /* 2 */ 3, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    /* 3 */ 3, 3, 2, 2, 3, 3, 3, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    /* 4 */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* 5 */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* 6 */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* 7 */ 2, 2, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 2, 1,
    /* 8 */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* 9 */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* A */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* B */ 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    /* C */ 5, 3, 4, 4, 6, 4, 2, 4, 5, 4, 4, 1, 6, 6, 2, 4,
    /* D */ 5, 3, 4, 1, 6, 4, 2, 4, 5, 4, 4, 1, 6, 1, 2, 4,
    /* E */ 3, 3, 2, 1, 1, 4, 2, 4, 4, 1, 4, 1, 1, 1, 2, 4,
    /* F */ 3, 3, 2, 1, 1, 4, 2, 4, 3, 2, 4, 1, 1, 1, 2, 4,
};

// Expected M-cycle counts for conditional opcodes when NOT taken.
struct CondEntry { uint8_t opcode; uint8_t mcycles_not_taken; };
static const CondEntry COND_NOT_TAKEN[] = {
    // JR cond
    {0x20, 2}, {0x28, 2}, {0x30, 2}, {0x38, 2},
    // RET cond
    {0xC0, 2}, {0xC8, 2}, {0xD0, 2}, {0xD8, 2},
    // JP cond,u16
    {0xC2, 3}, {0xCA, 3}, {0xD2, 3}, {0xDA, 3},
    // CALL cond,u16
    {0xC4, 3}, {0xCC, 3}, {0xD4, 3}, {0xDC, 3},
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vdecoder* dut = new Vdecoder;

    int total_pass = 0, total_fail = 0;

    // =================================================================
    // Test 1: Base opcode M-cycle counts (branch taken)
    // =================================================================
    printf("Test 1: Base opcode M-cycles (branch taken)\n");
    {
        int pass = 0, fail = 0;
        for (int op = 0; op < 256; op++) {
            dut->opcode    = op;
            dut->cb_prefix = 0;
            dut->cond_met  = 1;
            dut->eval();

            uint8_t expected = BASE_MCYCLES_TAKEN[op];
            if (dut->mcycles != expected) {
                printf("  FAIL: opcode 0x%02X: got %d, expected %d\n",
                       op, dut->mcycles, expected);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/256 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 2: Conditional opcodes (branch NOT taken)
    // =================================================================
    printf("Test 2: Conditional opcodes M-cycles (not taken)\n");
    {
        int pass = 0, fail = 0;
        int count = sizeof(COND_NOT_TAKEN) / sizeof(COND_NOT_TAKEN[0]);
        for (int i = 0; i < count; i++) {
            uint8_t op = COND_NOT_TAKEN[i].opcode;
            dut->opcode    = op;
            dut->cb_prefix = 0;
            dut->cond_met  = 0;
            dut->eval();

            uint8_t expected = COND_NOT_TAKEN[i].mcycles_not_taken;
            if (dut->mcycles != expected) {
                printf("  FAIL: opcode 0x%02X not-taken: got %d, expected %d\n",
                       op, dut->mcycles, expected);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/%d passed\n", pass, count);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 3: CB-prefixed opcode M-cycle counts
    // =================================================================
    printf("Test 3: CB opcode M-cycles\n");
    {
        int pass = 0, fail = 0;
        for (int op = 0; op < 256; op++) {
            dut->opcode    = op;
            dut->cb_prefix = 1;
            dut->cond_met  = 0;
            dut->eval();

            // r8 = op[2:0]: if not 6, mcycles=1
            // r8 == 6 and BIT (op[7:6]==01): mcycles=2
            // r8 == 6 and other: mcycles=3
            uint8_t expected;
            if ((op & 0x07) != 0x06)
                expected = 1;
            else if ((op & 0xC0) == 0x40)
                expected = 2;
            else
                expected = 3;

            if (dut->mcycles != expected) {
                printf("  FAIL: CB 0x%02X: got %d, expected %d\n",
                       op, dut->mcycles, expected);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/256 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 4: ALU operation decode (Block 2)
    // =================================================================
    printf("Test 4: ALU op decode (Block 2)\n");
    {
        // Block 2: opcodes 0x80-0xBF, ALU op = {2'b00, opcode[5:3]}
        int pass = 0, fail = 0;
        for (int op = 0x80; op <= 0xBF; op++) {
            dut->opcode    = op;
            dut->cb_prefix = 0;
            dut->cond_met  = 0;
            dut->eval();

            uint8_t expected_alu = (op >> 3) & 0x07;  // {00, opcode[5:3]}
            if (dut->alu_op != expected_alu) {
                printf("  FAIL: opcode 0x%02X: alu_op got %d, expected %d\n",
                       op, dut->alu_op, expected_alu);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/64 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 5: ALU operation decode (Block 3 immediate)
    // =================================================================
    printf("Test 5: ALU op decode (Block 3 immediate)\n");
    {
        // Block 3 ALU immediate: C6,CE,D6,DE,E6,EE,F6,FE
        // alu_op = {2'b00, opcode[5:3]}
        uint8_t imm_ops[] = {0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE};
        int pass = 0, fail = 0;
        for (int i = 0; i < 8; i++) {
            uint8_t op = imm_ops[i];
            dut->opcode    = op;
            dut->cb_prefix = 0;
            dut->cond_met  = 0;
            dut->eval();

            uint8_t expected_alu = (op >> 3) & 0x07;
            if (dut->alu_op != expected_alu) {
                printf("  FAIL: opcode 0x%02X: alu_op got %d, expected %d\n",
                       op, dut->alu_op, expected_alu);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/8 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 6: CB ALU operation decode
    // =================================================================
    printf("Test 6: CB ALU op decode\n");
    {
        int pass = 0, fail = 0;
        for (int op = 0; op < 256; op++) {
            dut->opcode    = op;
            dut->cb_prefix = 1;
            dut->cond_met  = 0;
            dut->eval();

            uint8_t expected_alu;
            switch ((op >> 6) & 0x03) {
                case 0: expected_alu = 0x08 | ((op >> 3) & 0x07); break; // 01_xxx
                case 1: expected_alu = 0x10; break;  // 10_000 = BIT
                case 2: expected_alu = 0x11; break;  // 10_001 = RES
                case 3: expected_alu = 0x12; break;  // 10_010 = SET
                default: expected_alu = 0; break;
            }

            if (dut->alu_op != expected_alu) {
                printf("  FAIL: CB 0x%02X: alu_op got 0x%02X, expected 0x%02X\n",
                       op, dut->alu_op, expected_alu);
                fail++;
            } else {
                pass++;
            }
        }
        printf("  %d/256 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 7: Instruction flags
    // =================================================================
    printf("Test 7: Instruction flags\n");
    {
        int pass = 0, fail = 0;

        // HALT
        dut->opcode = 0x76; dut->cb_prefix = 0; dut->cond_met = 0; dut->eval();
        if (dut->is_halt) pass++; else { fail++; printf("  FAIL: 0x76 is_halt\n"); }

        // EI
        dut->opcode = 0xFB; dut->cb_prefix = 0; dut->cond_met = 0; dut->eval();
        if (dut->is_ei) pass++; else { fail++; printf("  FAIL: 0xFB is_ei\n"); }

        // DI
        dut->opcode = 0xF3; dut->cb_prefix = 0; dut->cond_met = 0; dut->eval();
        if (dut->is_di) pass++; else { fail++; printf("  FAIL: 0xF3 is_di\n"); }

        // CB prefix
        dut->opcode = 0xCB; dut->cb_prefix = 0; dut->cond_met = 0; dut->eval();
        if (dut->is_cb_prefix) pass++; else { fail++; printf("  FAIL: 0xCB is_cb_prefix\n"); }

        // Non-HALT should not have is_halt
        dut->opcode = 0x00; dut->cb_prefix = 0; dut->cond_met = 0; dut->eval();
        if (!dut->is_halt) pass++; else { fail++; printf("  FAIL: 0x00 !is_halt\n"); }

        printf("  %d/5 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Test 8: [HL] indirect detection
    // =================================================================
    printf("Test 8: [HL] indirect detection\n");
    {
        int pass = 0, fail = 0;

        // Block 1: LD B,(HL) = 0x46, src=110
        dut->opcode = 0x46; dut->cb_prefix = 0; dut->eval();
        if (dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: 0x46\n"); }

        // Block 1: LD (HL),B = 0x70, dst=110
        dut->opcode = 0x70; dut->cb_prefix = 0; dut->eval();
        if (dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: 0x70\n"); }

        // Block 1: LD B,C = 0x41, no (HL)
        dut->opcode = 0x41; dut->cb_prefix = 0; dut->eval();
        if (!dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: 0x41\n"); }

        // Block 2: ADD A,(HL) = 0x86, src=110
        dut->opcode = 0x86; dut->cb_prefix = 0; dut->eval();
        if (dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: 0x86\n"); }

        // Block 2: ADD A,B = 0x80, no (HL)
        dut->opcode = 0x80; dut->cb_prefix = 0; dut->eval();
        if (!dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: 0x80\n"); }

        // CB: RLC (HL) = CB 0x06
        dut->opcode = 0x06; dut->cb_prefix = 1; dut->eval();
        if (dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: CB 0x06\n"); }

        // CB: RLC B = CB 0x00
        dut->opcode = 0x00; dut->cb_prefix = 1; dut->eval();
        if (!dut->uses_hl_indirect) pass++; else { fail++; printf("  FAIL: CB 0x00\n"); }

        printf("  %d/7 passed\n", pass);
        total_pass += pass;
        total_fail += fail;
    }

    // =================================================================
    // Summary
    // =================================================================
    printf("\n--- Results: %d passed, %d failed ---\n",
           total_pass, total_fail);
    delete dut;
    return total_fail > 0 ? 1 : 0;
}
