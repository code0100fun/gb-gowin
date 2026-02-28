#include "Valu.h"

#include <verilated.h>
#include <cstdint>
#include <cstdio>

// ALU operation encoding: {cat[1:0], sub_op[2:0]}
enum AluOp : uint8_t {
    // 8-bit arithmetic/logic (cat=00)
    OP_ADD  = 0b00'000,
    OP_ADC  = 0b00'001,
    OP_SUB  = 0b00'010,
    OP_SBC  = 0b00'011,
    OP_AND  = 0b00'100,
    OP_XOR  = 0b00'101,
    OP_OR   = 0b00'110,
    OP_CP   = 0b00'111,

    // Rotate/shift (cat=01, CB prefix)
    OP_RLC  = 0b01'000,
    OP_RRC  = 0b01'001,
    OP_RL   = 0b01'010,
    OP_RR   = 0b01'011,
    OP_SLA  = 0b01'100,
    OP_SRA  = 0b01'101,
    OP_SWAP = 0b01'110,
    OP_SRL  = 0b01'111,

    // Bit operations (cat=10)
    OP_BIT  = 0b10'000,
    OP_RES  = 0b10'001,
    OP_SET  = 0b10'010,

    // Miscellaneous (cat=11)
    OP_INC  = 0b11'000,
    OP_DEC  = 0b11'001,
    OP_DAA  = 0b11'010,
    OP_CPL  = 0b11'011,
    OP_SCF  = 0b11'100,
    OP_CCF  = 0b11'101,
    OP_RLCA = 0b11'110,  // bit_sel[0]=0 for RLCA, 1 for RLA
    OP_RRCA = 0b11'111,  // bit_sel[0]=0 for RRCA, 1 for RRA
};

// Flag bit positions in the 4-bit flags word
enum FlagBit : uint8_t {
    FLAG_C = 0,
    FLAG_H = 1,
    FLAG_N = 2,
    FLAG_Z = 3,
};

#define F_Z (1 << FLAG_Z)
#define F_N (1 << FLAG_N)
#define F_H (1 << FLAG_H)
#define F_C (1 << FLAG_C)

struct TestVec {
    const char* name;
    uint8_t  op;
    uint8_t  a;
    uint8_t  b;
    uint8_t  bit_sel;
    uint8_t  flags_in;
    uint8_t  exp_result;
    uint8_t  exp_flags;
};

static int run_tests(Valu* dut, const TestVec* tests, int count,
                     const char* group) {
    int pass = 0, fail = 0;
    for (int i = 0; i < count; i++) {
        const auto& t = tests[i];
        dut->op       = t.op;
        dut->a        = t.a;
        dut->b        = t.b;
        dut->bit_sel  = t.bit_sel;
        dut->flags_in = t.flags_in;
        dut->eval();

        bool result_ok = (dut->result == t.exp_result);
        bool flags_ok  = (dut->flags_out == t.exp_flags);

        if (result_ok && flags_ok) {
            pass++;
        } else {
            fail++;
            printf("  FAIL [%s] %s: a=0x%02X b=0x%02X flags_in=0x%X\n",
                   group, t.name, t.a, t.b, t.flags_in);
            if (!result_ok)
                printf("    result: got 0x%02X, expected 0x%02X\n",
                       dut->result, t.exp_result);
            if (!flags_ok)
                printf("    flags:  got 0x%X, expected 0x%X\n",
                       dut->flags_out, t.exp_flags);
        }
    }
    return fail;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Valu* dut = new Valu;

    int total_pass = 0, total_fail = 0;

    // =================================================================
    // Test group 1: ADD
    // =================================================================
    printf("Test group 1: ADD\n");
    {
        TestVec tests[] = {
            {"0+0",        OP_ADD, 0x00, 0x00, 0, 0,   0x00, F_Z},
            {"1+1",        OP_ADD, 0x01, 0x01, 0, 0,   0x02, 0},
            {"0xFF+1",     OP_ADD, 0xFF, 0x01, 0, 0,   0x00, F_Z|F_H|F_C},
            {"0x0F+0x01",  OP_ADD, 0x0F, 0x01, 0, 0,   0x10, F_H},
            {"0xF0+0x10",  OP_ADD, 0xF0, 0x10, 0, 0,   0x00, F_Z|F_C},
            {"0x80+0x80",  OP_ADD, 0x80, 0x80, 0, 0,   0x00, F_Z|F_C},
            {"0x3A+0xC6",  OP_ADD, 0x3A, 0xC6, 0, 0,   0x00, F_Z|F_H|F_C},
            {"0x0E+0x01",  OP_ADD, 0x0E, 0x01, 0, 0,   0x0F, 0},
            {"0x08+0x08",  OP_ADD, 0x08, 0x08, 0, 0,   0x10, F_H},
            {"0x50+0x50",  OP_ADD, 0x50, 0x50, 0, 0,   0xA0, 0},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "ADD");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 2: ADC
    // =================================================================
    printf("Test group 2: ADC\n");
    {
        TestVec tests[] = {
            {"0+0+0",       OP_ADC, 0x00, 0x00, 0, 0,     0x00, F_Z},
            {"0+0+C",       OP_ADC, 0x00, 0x00, 0, F_C,   0x01, 0},
            {"0xFF+0+C",    OP_ADC, 0xFF, 0x00, 0, F_C,   0x00, F_Z|F_H|F_C},
            {"0x0F+0+C",    OP_ADC, 0x0F, 0x00, 0, F_C,   0x10, F_H},
            {"0x0E+0x01+C", OP_ADC, 0x0E, 0x01, 0, F_C,   0x10, F_H},
            {"0xFF+0xFF+C", OP_ADC, 0xFF, 0xFF, 0, F_C,   0xFF, F_H|F_C},
            {"0x01+0x01+0", OP_ADC, 0x01, 0x01, 0, 0,     0x02, 0},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "ADC");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 3: SUB
    // =================================================================
    printf("Test group 3: SUB\n");
    {
        TestVec tests[] = {
            {"0-0",        OP_SUB, 0x00, 0x00, 0, 0,   0x00, F_Z|F_N},
            {"1-1",        OP_SUB, 0x01, 0x01, 0, 0,   0x00, F_Z|F_N},
            {"0-1",        OP_SUB, 0x00, 0x01, 0, 0,   0xFF, F_N|F_H|F_C},
            {"0x10-0x01",  OP_SUB, 0x10, 0x01, 0, 0,   0x0F, F_N|F_H},
            {"0x80-0x01",  OP_SUB, 0x80, 0x01, 0, 0,   0x7F, F_N|F_H},
            {"0x3E-0x3E",  OP_SUB, 0x3E, 0x3E, 0, 0,   0x00, F_Z|F_N},
            {"0x3E-0x0F",  OP_SUB, 0x3E, 0x0F, 0, 0,   0x2F, F_N|F_H},
            {"0x3E-0x40",  OP_SUB, 0x3E, 0x40, 0, 0,   0xFE, F_N|F_C},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "SUB");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 4: SBC
    // =================================================================
    printf("Test group 4: SBC\n");
    {
        TestVec tests[] = {
            {"0-0-0",       OP_SBC, 0x00, 0x00, 0, 0,     0x00, F_Z|F_N},
            {"0-0-C",       OP_SBC, 0x00, 0x00, 0, F_C,   0xFF, F_N|F_H|F_C},
            {"1-0-C",       OP_SBC, 0x01, 0x00, 0, F_C,   0x00, F_Z|F_N},
            {"0x10-0x01-C", OP_SBC, 0x10, 0x01, 0, F_C,   0x0E, F_N|F_H},
            {"0x3B-0x4F-C", OP_SBC, 0x3B, 0x4F, 0, F_C,   0xEB, F_N|F_H|F_C},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "SBC");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 5: AND / XOR / OR
    // =================================================================
    printf("Test group 5: AND, XOR, OR\n");
    {
        TestVec tests[] = {
            // AND: Z,0,1,0
            {"AND 0xFF,0xFF",  OP_AND, 0xFF, 0xFF, 0, 0,   0xFF, F_H},
            {"AND 0xFF,0x00",  OP_AND, 0xFF, 0x00, 0, 0,   0x00, F_Z|F_H},
            {"AND 0xF0,0x0F",  OP_AND, 0xF0, 0x0F, 0, 0,   0x00, F_Z|F_H},
            {"AND 0xA5,0x5A",  OP_AND, 0xA5, 0x5A, 0, 0,   0x00, F_Z|F_H},
            {"AND 0xAA,0xFF",  OP_AND, 0xAA, 0xFF, 0, 0,   0xAA, F_H},

            // XOR: Z,0,0,0
            {"XOR 0xFF,0xFF",  OP_XOR, 0xFF, 0xFF, 0, 0,   0x00, F_Z},
            {"XOR 0xFF,0x00",  OP_XOR, 0xFF, 0x00, 0, 0,   0xFF, 0},
            {"XOR 0xA5,0x5A",  OP_XOR, 0xA5, 0x5A, 0, 0,   0xFF, 0},
            {"XOR 0x00,0x00",  OP_XOR, 0x00, 0x00, 0, 0,   0x00, F_Z},

            // OR: Z,0,0,0
            {"OR 0x00,0x00",   OP_OR,  0x00, 0x00, 0, 0,   0x00, F_Z},
            {"OR 0xF0,0x0F",   OP_OR,  0xF0, 0x0F, 0, 0,   0xFF, 0},
            {"OR 0x00,0xFF",   OP_OR,  0x00, 0xFF, 0, 0,   0xFF, 0},
            {"OR 0xA0,0x05",   OP_OR,  0xA0, 0x05, 0, 0,   0xA5, 0},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "AND/XOR/OR");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 6: CP (compare — SUB without storing result)
    // =================================================================
    printf("Test group 6: CP\n");
    {
        TestVec tests[] = {
            {"CP 0x3C,0x3C",  OP_CP, 0x3C, 0x3C, 0, 0,   0x3C, F_Z|F_N},
            {"CP 0x3C,0x2F",  OP_CP, 0x3C, 0x2F, 0, 0,   0x3C, F_N|F_H},
            {"CP 0x3C,0x40",  OP_CP, 0x3C, 0x40, 0, 0,   0x3C, F_N|F_C},
            {"CP 0x00,0x01",  OP_CP, 0x00, 0x01, 0, 0,   0x00, F_N|F_H|F_C},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "CP");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 7: INC / DEC
    // =================================================================
    printf("Test group 7: INC, DEC\n");
    {
        TestVec tests[] = {
            // INC: Z,0,H,- (C preserved)
            {"INC 0",         OP_INC, 0x00, 0, 0, 0,      0x01, 0},
            {"INC 0x0F",      OP_INC, 0x0F, 0, 0, 0,      0x10, F_H},
            {"INC 0xFF",      OP_INC, 0xFF, 0, 0, 0,      0x00, F_Z|F_H},
            {"INC 0 +C",      OP_INC, 0x00, 0, 0, F_C,    0x01, F_C},  // C preserved!
            {"INC 0xFF +C",   OP_INC, 0xFF, 0, 0, F_C,    0x00, F_Z|F_H|F_C},

            // DEC: Z,1,H,- (C preserved)
            {"DEC 1",         OP_DEC, 0x01, 0, 0, 0,      0x00, F_Z|F_N},
            {"DEC 0x10",      OP_DEC, 0x10, 0, 0, 0,      0x0F, F_N|F_H},
            {"DEC 0",         OP_DEC, 0x00, 0, 0, 0,      0xFF, F_N|F_H},
            {"DEC 0 +C",      OP_DEC, 0x00, 0, 0, F_C,    0xFF, F_N|F_H|F_C},  // C preserved!
            {"DEC 0x20",      OP_DEC, 0x20, 0, 0, 0,      0x1F, F_N|F_H},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "INC/DEC");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 8: Rotates and shifts (CB prefix)
    // =================================================================
    printf("Test group 8: CB rotates/shifts\n");
    {
        TestVec tests[] = {
            // RLC: rotate left, old bit7 → C and bit0
            {"RLC 0x80",     OP_RLC, 0x80, 0, 0, 0,     0x01, F_C},
            {"RLC 0x01",     OP_RLC, 0x01, 0, 0, 0,     0x02, 0},
            {"RLC 0x00",     OP_RLC, 0x00, 0, 0, 0,     0x00, F_Z},
            {"RLC 0xFF",     OP_RLC, 0xFF, 0, 0, 0,     0xFF, F_C},
            {"RLC 0x85",     OP_RLC, 0x85, 0, 0, 0,     0x0B, F_C},

            // RRC: rotate right, old bit0 → C and bit7
            {"RRC 0x01",     OP_RRC, 0x01, 0, 0, 0,     0x80, F_C},
            {"RRC 0x80",     OP_RRC, 0x80, 0, 0, 0,     0x40, 0},
            {"RRC 0x00",     OP_RRC, 0x00, 0, 0, 0,     0x00, F_Z},
            {"RRC 0xFF",     OP_RRC, 0xFF, 0, 0, 0,     0xFF, F_C},

            // RL: rotate left through carry
            {"RL 0x80 C=0",  OP_RL, 0x80, 0, 0, 0,      0x00, F_Z|F_C},
            {"RL 0x80 C=1",  OP_RL, 0x80, 0, 0, F_C,    0x01, F_C},
            {"RL 0x01 C=0",  OP_RL, 0x01, 0, 0, 0,      0x02, 0},
            {"RL 0x00 C=1",  OP_RL, 0x00, 0, 0, F_C,    0x01, 0},

            // RR: rotate right through carry
            {"RR 0x01 C=0",  OP_RR, 0x01, 0, 0, 0,      0x00, F_Z|F_C},
            {"RR 0x01 C=1",  OP_RR, 0x01, 0, 0, F_C,    0x80, F_C},
            {"RR 0x80 C=0",  OP_RR, 0x80, 0, 0, 0,      0x40, 0},
            {"RR 0x00 C=1",  OP_RR, 0x00, 0, 0, F_C,    0x80, 0},

            // SLA: shift left, bit0=0
            {"SLA 0x80",     OP_SLA, 0x80, 0, 0, 0,     0x00, F_Z|F_C},
            {"SLA 0x01",     OP_SLA, 0x01, 0, 0, 0,     0x02, 0},
            {"SLA 0xFF",     OP_SLA, 0xFF, 0, 0, 0,     0xFE, F_C},

            // SRA: shift right, bit7 preserved (arithmetic)
            {"SRA 0x80",     OP_SRA, 0x80, 0, 0, 0,     0xC0, 0},
            {"SRA 0x01",     OP_SRA, 0x01, 0, 0, 0,     0x00, F_Z|F_C},
            {"SRA 0x81",     OP_SRA, 0x81, 0, 0, 0,     0xC0, F_C},
            {"SRA 0x7E",     OP_SRA, 0x7E, 0, 0, 0,     0x3F, 0},

            // SWAP: swap nibbles
            {"SWAP 0xF0",    OP_SWAP, 0xF0, 0, 0, 0,    0x0F, 0},
            {"SWAP 0x12",    OP_SWAP, 0x12, 0, 0, 0,    0x21, 0},
            {"SWAP 0x00",    OP_SWAP, 0x00, 0, 0, 0,    0x00, F_Z},
            {"SWAP 0xAB",    OP_SWAP, 0xAB, 0, 0, 0,    0xBA, 0},

            // SRL: shift right, bit7=0 (logical)
            {"SRL 0x80",     OP_SRL, 0x80, 0, 0, 0,     0x40, 0},
            {"SRL 0x01",     OP_SRL, 0x01, 0, 0, 0,     0x00, F_Z|F_C},
            {"SRL 0xFF",     OP_SRL, 0xFF, 0, 0, 0,     0x7F, F_C},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "CB rotate/shift");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 9: BIT / RES / SET
    // =================================================================
    printf("Test group 9: BIT, RES, SET\n");
    {
        TestVec tests[] = {
            // BIT: Z=~bit, N=0, H=1, C=unchanged
            {"BIT 0,0x01",   OP_BIT, 0x01, 0, 0, 0,      0x01, F_H},         // bit 0 set → Z=0
            {"BIT 0,0xFE",   OP_BIT, 0xFE, 0, 0, 0,      0xFE, F_Z|F_H},     // bit 0 clear → Z=1
            {"BIT 7,0x80",   OP_BIT, 0x80, 0, 7, 0,      0x80, F_H},         // bit 7 set
            {"BIT 7,0x7F",   OP_BIT, 0x7F, 0, 7, 0,      0x7F, F_Z|F_H},     // bit 7 clear
            {"BIT 3,0x08",   OP_BIT, 0x08, 0, 3, 0,      0x08, F_H},
            {"BIT 3,0xF7",   OP_BIT, 0xF7, 0, 3, 0,      0xF7, F_Z|F_H},
            {"BIT 0,0x01+C", OP_BIT, 0x01, 0, 0, F_C,    0x01, F_H|F_C},     // C preserved

            // RES: clear bit, no flag changes
            {"RES 0,0xFF",   OP_RES, 0xFF, 0, 0, 0,      0xFE, 0},
            {"RES 7,0xFF",   OP_RES, 0xFF, 0, 7, 0,      0x7F, 0},
            {"RES 3,0xFF",   OP_RES, 0xFF, 0, 3, 0,      0xF7, 0},
            {"RES 0,0x00",   OP_RES, 0x00, 0, 0, 0,      0x00, 0},
            {"RES 4,0xFF+C", OP_RES, 0xFF, 0, 4, F_C,    0xEF, F_C},  // flags preserved

            // SET: set bit, no flag changes
            {"SET 0,0x00",   OP_SET, 0x00, 0, 0, 0,      0x01, 0},
            {"SET 7,0x00",   OP_SET, 0x00, 0, 7, 0,      0x80, 0},
            {"SET 3,0x00",   OP_SET, 0x00, 0, 3, 0,      0x08, 0},
            {"SET 7,0xFF",   OP_SET, 0xFF, 0, 7, 0,      0xFF, 0},
            {"SET 4,0x00+C", OP_SET, 0x00, 0, 4, F_C,    0x10, F_C},  // flags preserved
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "BIT/RES/SET");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 10: Accumulator rotates (RLCA, RRCA, RLA, RRA)
    // These always clear Z (unlike CB versions)
    // =================================================================
    printf("Test group 10: Accumulator rotates (RLCA/RRCA/RLA/RRA)\n");
    {
        TestVec tests[] = {
            // RLCA: op=OP_RLCA, bit_sel[0]=0
            {"RLCA 0x80",     OP_RLCA, 0x80, 0, 0, 0,     0x01, F_C},      // Z=0 always!
            {"RLCA 0x01",     OP_RLCA, 0x01, 0, 0, 0,     0x02, 0},
            {"RLCA 0x00",     OP_RLCA, 0x00, 0, 0, 0,     0x00, 0},        // Z=0 even for 0!
            {"RLCA 0x85",     OP_RLCA, 0x85, 0, 0, 0,     0x0B, F_C},

            // RLA: op=OP_RLCA, bit_sel[0]=1
            {"RLA 0x80 C=0",  OP_RLCA, 0x80, 0, 1, 0,     0x00, F_C},      // Z=0 always!
            {"RLA 0x80 C=1",  OP_RLCA, 0x80, 0, 1, F_C,   0x01, F_C},
            {"RLA 0x00 C=1",  OP_RLCA, 0x00, 0, 1, F_C,   0x01, 0},

            // RRCA: op=OP_RRCA, bit_sel[0]=0
            {"RRCA 0x01",     OP_RRCA, 0x01, 0, 0, 0,     0x80, F_C},
            {"RRCA 0x80",     OP_RRCA, 0x80, 0, 0, 0,     0x40, 0},
            {"RRCA 0x00",     OP_RRCA, 0x00, 0, 0, 0,     0x00, 0},        // Z=0 even for 0!

            // RRA: op=OP_RRCA, bit_sel[0]=1
            {"RRA 0x01 C=0",  OP_RRCA, 0x01, 0, 1, 0,     0x00, F_C},      // Z=0 always!
            {"RRA 0x01 C=1",  OP_RRCA, 0x01, 0, 1, F_C,   0x80, F_C},
            {"RRA 0x00 C=1",  OP_RRCA, 0x00, 0, 1, F_C,   0x80, 0},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "Acc rotate");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 11: DAA
    // =================================================================
    printf("Test group 11: DAA\n");
    {
        TestVec tests[] = {
            // After ADD: N=0
            // 0x09 + 0x01 = 0x0A → DAA → 0x10 (BCD 10)
            {"DAA 0x0A N=0",       OP_DAA, 0x0A, 0, 0, 0,         0x10, 0},
            // 0x09 + 0x09 = 0x12 → already valid BCD? No, 12 is valid BCD
            {"DAA 0x12 N=0",       OP_DAA, 0x12, 0, 0, 0,         0x12, 0},
            // 0x99 + 0x01 = 0x9A → DAA → 0x00 with C
            {"DAA 0x9A N=0",       OP_DAA, 0x9A, 0, 0, 0,         0x00, F_Z|F_C},
            // After ADD with H: 0x0F (with H set) → 0x15
            {"DAA 0x0F N=0 H=1",   OP_DAA, 0x0F, 0, 0, F_H,      0x15, 0},
            // After ADD with C: 0x00 → 0x60 (C already set means > 0x99)
            {"DAA 0x00 N=0 C=1",   OP_DAA, 0x00, 0, 0, F_C,      0x60, F_C},
            // 0xA0 N=0 → adjust upper nibble
            {"DAA 0xA0 N=0",       OP_DAA, 0xA0, 0, 0, 0,         0x00, F_Z|F_C},
            // 0x99 N=0 → valid BCD
            {"DAA 0x99 N=0",       OP_DAA, 0x99, 0, 0, 0,         0x99, 0},

            // After SUB: N=1
            // 0x10 - 0x01 = 0x0F → DAA → 0x09 (BCD 09)
            {"DAA 0x0F N=1 H=1",   OP_DAA, 0x0F, 0, 0, F_N|F_H,  0x09, F_N},
            // Already valid BCD with N=1
            {"DAA 0x45 N=1",       OP_DAA, 0x45, 0, 0, F_N,       0x45, F_N},
            // 0x00 after sub with C=1 → 0xA0
            {"DAA 0x00 N=1 C=1",   OP_DAA, 0x00, 0, 0, F_N|F_C,  0xA0, F_N|F_C},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "DAA");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Test group 12: CPL, SCF, CCF
    // =================================================================
    printf("Test group 12: CPL, SCF, CCF\n");
    {
        TestVec tests[] = {
            // CPL: Z=-, N=1, H=1, C=-
            {"CPL 0xFF",      OP_CPL, 0xFF, 0, 0, 0,       0x00, F_N|F_H},
            {"CPL 0x00",      OP_CPL, 0x00, 0, 0, 0,       0xFF, F_N|F_H},
            {"CPL 0xA5",      OP_CPL, 0xA5, 0, 0, 0,       0x5A, F_N|F_H},
            {"CPL 0 +Z+C",   OP_CPL, 0x00, 0, 0, F_Z|F_C, 0xFF, F_Z|F_N|F_H|F_C},

            // SCF: Z=-, N=0, H=0, C=1
            {"SCF",           OP_SCF, 0x42, 0, 0, 0,       0x42, F_C},
            {"SCF +Z",        OP_SCF, 0x42, 0, 0, F_Z,     0x42, F_Z|F_C},
            {"SCF +NH",       OP_SCF, 0x42, 0, 0, F_N|F_H, 0x42, F_C},  // clears N,H

            // CCF: Z=-, N=0, H=0, C=~C
            {"CCF C=0",       OP_CCF, 0x42, 0, 0, 0,       0x42, F_C},
            {"CCF C=1",       OP_CCF, 0x42, 0, 0, F_C,     0x42, 0},
            {"CCF +Z,C=0",    OP_CCF, 0x42, 0, 0, F_Z,     0x42, F_Z|F_C},
            {"CCF +ZNH,C=1",  OP_CCF, 0x42, 0, 0, F_Z|F_N|F_H|F_C, 0x42, F_Z},
        };
        int f = run_tests(dut, tests, sizeof(tests)/sizeof(tests[0]), "CPL/SCF/CCF");
        total_pass += (int)(sizeof(tests)/sizeof(tests[0])) - f;
        total_fail += f;
    }

    // =================================================================
    // Summary
    // =================================================================
    printf("\n--- Results: %d passed, %d failed ---\n",
           total_pass, total_fail);
    delete dut;
    return total_fail > 0 ? 1 : 0;
}
