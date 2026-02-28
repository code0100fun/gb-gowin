#include "Vcpu.h"
#include "testbench.h"

#include <cstring>

// 64KB memory model
static uint8_t memory[65536];

// Run the CPU for up to max_cycles or until HALT.
// Returns the number of cycles executed.
static int run_until_halt(Testbench<Vcpu>& tb, int max_cycles = 1000) {
    int cycles = 0;
    while (cycles < max_cycles && !tb.dut->halted) {
        // Combinational memory: provide read data for current address
        tb.dut->mem_rdata = memory[tb.dut->mem_addr];
        tb.dut->eval();

        // Handle memory writes BEFORE clock edge (signals are combinational)
        if (tb.dut->mem_wr) {
            memory[tb.dut->mem_addr] = tb.dut->mem_wdata;
        }

        // Clock edge: state machine advances, regfile writes take effect
        tb.tick();

        // After clock: update read data for the new combinational state
        tb.dut->mem_rdata = memory[tb.dut->mem_addr];
        tb.dut->eval();

        cycles++;
    }
    return cycles;
}

static void reset_cpu(Testbench<Vcpu>& tb) {
    memset(memory, 0, sizeof(memory));
    tb.dut->reset = 1;
    tb.dut->mem_rdata = 0;
    tb.tick();
    tb.dut->reset = 0;
    // After reset: PC=0x0000, SP=0xFFFE
    // Provide initial read data
    tb.dut->mem_rdata = memory[tb.dut->mem_addr];
    tb.dut->eval();
}

static void dump_regs(Vcpu* dut) {
    printf("    PC=%04X SP=%04X\n", dut->dbg_pc, dut->dbg_sp);
    printf("    A=%02X F=%02X B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X\n",
           dut->dbg_a, dut->dbg_f, dut->dbg_b, dut->dbg_c,
           dut->dbg_d, dut->dbg_e, dut->dbg_h, dut->dbg_l);
}

int main(int argc, char** argv) {
    Testbench<Vcpu> tb("build/sim/cpu.vcd", argc, argv);

    // ==================================================================
    // Test 1: Basic loads and ALU
    // ==================================================================
    printf("Test 1: Basic loads and ALU\n");
    {
        reset_cpu(tb);

        // LD A, 0x01    ; 3E 01
        // LD B, 0x02    ; 06 02
        // ADD A, B      ; 80
        // LD C, A       ; 4F
        // SUB A, C      ; 91
        // HALT          ; 76
        uint8_t prog[] = {
            0x3E, 0x01,  // LD A, 0x01
            0x06, 0x02,  // LD B, 0x02
            0x80,        // ADD A, B
            0x4F,        // LD C, A
            0x91,        // SUB A, C
            0x76         // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x00) { printf("    A: got 0x%02X, expected 0x00\n", tb.dut->dbg_a); ok = false; }
        if (tb.dut->dbg_b != 0x02) { printf("    B: got 0x%02X, expected 0x02\n", tb.dut->dbg_b); ok = false; }
        if (tb.dut->dbg_c != 0x03) { printf("    C: got 0x%02X, expected 0x03\n", tb.dut->dbg_c); ok = false; }
        // After SUB A,C (0-3 wraps): Z=1 N=1 H=1 C=1 → F = 0xF0? No.
        // SUB 0x00 - 0x03: result=0xFD, not zero. Wait...
        // ADD A,B: A=0x01+0x02=0x03. LD C,A: C=0x03. SUB A,C: A=0x03-0x03=0x00.
        // Z=1, N=1, H=0, C=0 → F = 0xC0
        if (tb.dut->dbg_a != 0x00) { ok = false; }
        // Check Z flag is set (F bit 7)
        if (!(tb.dut->dbg_f & 0x80)) { printf("    Z flag not set after SUB A,C\n"); ok = false; }
        // Check N flag is set (F bit 6)
        if (!(tb.dut->dbg_f & 0x40)) { printf("    N flag not set after SUB\n"); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "Basic loads and ALU (LD, ADD, SUB)");
    }

    // ==================================================================
    // Test 2: Memory access through HL
    // ==================================================================
    printf("Test 2: Memory access through HL\n");
    {
        reset_cpu(tb);

        // LD H, 0xC0    ; 26 C0
        // LD L, 0x00    ; 2E 00
        // LD A, 0x42    ; 3E 42
        // LD (HL), A    ; 77
        // LD B, (HL)    ; 46
        // INC (HL)      ; 34
        // HALT          ; 76
        uint8_t prog[] = {
            0x26, 0xC0,  // LD H, 0xC0
            0x2E, 0x00,  // LD L, 0x00
            0x3E, 0x42,  // LD A, 0x42
            0x77,        // LD (HL), A
            0x46,        // LD B, (HL)
            0x34,        // INC (HL)
            0x76         // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_b != 0x42) { printf("    B: got 0x%02X, expected 0x42\n", tb.dut->dbg_b); ok = false; }
        if (memory[0xC000] != 0x43) { printf("    [0xC000]: got 0x%02X, expected 0x43\n", memory[0xC000]); ok = false; }
        if (tb.dut->dbg_h != 0xC0) { printf("    H: got 0x%02X, expected 0xC0\n", tb.dut->dbg_h); ok = false; }
        if (tb.dut->dbg_l != 0x00) { printf("    L: got 0x%02X, expected 0x00\n", tb.dut->dbg_l); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "Memory access through HL (LD (HL), LD r,(HL), INC (HL))");
    }

    // ==================================================================
    // Test 3: 16-bit loads, PUSH/POP
    // ==================================================================
    printf("Test 3: 16-bit loads, PUSH/POP\n");
    {
        reset_cpu(tb);

        // LD DE, 0x1234  ; 11 34 12
        // PUSH DE        ; D5
        // POP BC         ; C1
        // HALT           ; 76
        uint8_t prog[] = {
            0x11, 0x34, 0x12,  // LD DE, 0x1234
            0xD5,              // PUSH DE
            0xC1,              // POP BC
            0x76               // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_d != 0x12) { printf("    D: got 0x%02X, expected 0x12\n", tb.dut->dbg_d); ok = false; }
        if (tb.dut->dbg_e != 0x34) { printf("    E: got 0x%02X, expected 0x34\n", tb.dut->dbg_e); ok = false; }
        if (tb.dut->dbg_b != 0x12) { printf("    B: got 0x%02X, expected 0x12\n", tb.dut->dbg_b); ok = false; }
        if (tb.dut->dbg_c != 0x34) { printf("    C: got 0x%02X, expected 0x34\n", tb.dut->dbg_c); ok = false; }
        // SP should be restored after PUSH+POP
        if (tb.dut->dbg_sp != 0xFFFE) { printf("    SP: got 0x%04X, expected 0xFFFE\n", tb.dut->dbg_sp); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "16-bit loads, PUSH/POP (LD DE,u16; PUSH DE; POP BC)");
    }

    // ==================================================================
    // Test 4: Jumps and calls
    // ==================================================================
    printf("Test 4: Jumps and calls\n");
    {
        reset_cpu(tb);

        // 0x0000: LD A, 0x00    ; 3E 00
        // 0x0002: JP 0x0010     ; C3 10 00
        // 0x0005: LD A, 0xFF    ; 3E FF  (should be skipped)
        // ...
        // 0x0010: LD A, 0x01    ; 3E 01
        // 0x0012: CALL 0x0020   ; CD 20 00
        // 0x0015: HALT          ; 76
        // ...
        // 0x0020: LD A, 0x77    ; 3E 77
        // 0x0022: RET           ; C9
        memset(memory, 0, 256);
        memory[0x0000] = 0x3E; memory[0x0001] = 0x00;  // LD A, 0x00
        memory[0x0002] = 0xC3; memory[0x0003] = 0x10; memory[0x0004] = 0x00;  // JP 0x0010
        memory[0x0005] = 0x3E; memory[0x0006] = 0xFF;  // LD A, 0xFF (skipped)

        memory[0x0010] = 0x3E; memory[0x0011] = 0x01;  // LD A, 0x01
        memory[0x0012] = 0xCD; memory[0x0013] = 0x20; memory[0x0014] = 0x00;  // CALL 0x0020
        memory[0x0015] = 0x76;  // HALT

        memory[0x0020] = 0x3E; memory[0x0021] = 0x77;  // LD A, 0x77
        memory[0x0022] = 0xC9;  // RET

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x77) { printf("    A: got 0x%02X, expected 0x77\n", tb.dut->dbg_a); ok = false; }
        // PC should be at HALT+1 = 0x0016
        if (tb.dut->dbg_pc != 0x0016) { printf("    PC: got 0x%04X, expected 0x0016\n", tb.dut->dbg_pc); ok = false; }
        // SP should be restored after CALL+RET
        if (tb.dut->dbg_sp != 0xFFFE) { printf("    SP: got 0x%04X, expected 0xFFFE\n", tb.dut->dbg_sp); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "JP, CALL, and RET");
    }

    // ==================================================================
    // Test 5: CB prefix (SWAP) and conditional JR
    // ==================================================================
    printf("Test 5: CB prefix and conditional JR\n");
    {
        reset_cpu(tb);

        // LD A, 0x42    ; 3E 42
        // SWAP A        ; CB 37
        // LD B, 0x00    ; 06 00
        // INC B         ; 04
        // JR NZ, +2     ; 20 02
        // LD A, 0xFF    ; 3E FF  (should be skipped)
        // HALT          ; 76  ← JR NZ lands here (skip 2 bytes)
        uint8_t prog[] = {
            0x3E, 0x42,  // LD A, 0x42
            0xCB, 0x37,  // SWAP A → A = 0x24
            0x06, 0x00,  // LD B, 0x00
            0x04,        // INC B → B = 0x01, Z=0
            0x20, 0x02,  // JR NZ, +2
            0x3E, 0xFF,  // LD A, 0xFF (skipped)
            0x76         // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x24) { printf("    A: got 0x%02X, expected 0x24\n", tb.dut->dbg_a); ok = false; }
        if (tb.dut->dbg_b != 0x01) { printf("    B: got 0x%02X, expected 0x01\n", tb.dut->dbg_b); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "CB SWAP A and JR NZ (conditional jump)");
    }

    // ==================================================================
    // Test 6: LD A,(HL+) and LD A,(HL-)
    // ==================================================================
    printf("Test 6: HL increment/decrement loads\n");
    {
        reset_cpu(tb);

        // LD HL, 0xC000  ; 21 00 C0
        // LD A, 0xAA     ; 3E AA
        // LD (HL+), A    ; 22      → [C000]=0xAA, HL=C001
        // LD A, 0xBB     ; 3E BB
        // LD (HL-), A    ; 32      → [C001]=0xBB, HL=C000
        // LD A, (HL+)    ; 2A      → A=[C000]=0xAA, HL=C001
        // LD B, A        ; 47
        // LD A, (HL-)    ; 3A      → A=[C001]=0xBB, HL=C000
        // HALT           ; 76
        uint8_t prog[] = {
            0x21, 0x00, 0xC0,  // LD HL, 0xC000
            0x3E, 0xAA,        // LD A, 0xAA
            0x22,              // LD (HL+), A
            0x3E, 0xBB,        // LD A, 0xBB
            0x32,              // LD (HL-), A
            0x2A,              // LD A, (HL+)
            0x47,              // LD B, A
            0x3A,              // LD A, (HL-)
            0x76               // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_b != 0xAA) { printf("    B: got 0x%02X, expected 0xAA\n", tb.dut->dbg_b); ok = false; }
        if (tb.dut->dbg_a != 0xBB) { printf("    A: got 0x%02X, expected 0xBB\n", tb.dut->dbg_a); ok = false; }
        // HL should end at 0xC000 (HL+ then HL-)
        uint16_t hl = ((uint16_t)tb.dut->dbg_h << 8) | tb.dut->dbg_l;
        if (hl != 0xC000) { printf("    HL: got 0x%04X, expected 0xC000\n", hl); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "LD (HL+/HL-) and LD A,(HL+/HL-)");
    }

    // ==================================================================
    // Test 7: INC/DEC r16
    // ==================================================================
    printf("Test 7: 16-bit INC/DEC\n");
    {
        reset_cpu(tb);

        // LD BC, 0x00FF  ; 01 FF 00
        // INC BC         ; 03      → BC = 0x0100
        // LD DE, 0x0100  ; 11 00 01
        // DEC DE         ; 1B      → DE = 0x00FF
        // HALT           ; 76
        uint8_t prog[] = {
            0x01, 0xFF, 0x00,  // LD BC, 0x00FF
            0x03,              // INC BC
            0x11, 0x00, 0x01,  // LD DE, 0x0100
            0x1B,              // DEC DE
            0x76               // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        uint16_t bc = ((uint16_t)tb.dut->dbg_b << 8) | tb.dut->dbg_c;
        uint16_t de = ((uint16_t)tb.dut->dbg_d << 8) | tb.dut->dbg_e;
        if (bc != 0x0100) { printf("    BC: got 0x%04X, expected 0x0100\n", bc); ok = false; }
        if (de != 0x00FF) { printf("    DE: got 0x%04X, expected 0x00FF\n", de); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "INC BC, DEC DE");
    }

    // ==================================================================
    // Test 8: RST instruction
    // ==================================================================
    printf("Test 8: RST instruction\n");
    {
        reset_cpu(tb);

        // 0x0000: LD A, 0x42    ; 3E 42
        // 0x0002: RST 0x08      ; CF
        // 0x0003: HALT          ; 76 ← return here after RST handler
        // ...
        // 0x0008: LD A, 0x99    ; 3E 99
        // 0x000A: RET           ; C9
        memset(memory, 0, 256);
        memory[0x0000] = 0x3E; memory[0x0001] = 0x42;  // LD A, 0x42
        memory[0x0002] = 0xCF;  // RST 0x08
        memory[0x0003] = 0x76;  // HALT

        memory[0x0008] = 0x3E; memory[0x0009] = 0x99;  // LD A, 0x99
        memory[0x000A] = 0xC9;  // RET

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x99) { printf("    A: got 0x%02X, expected 0x99\n", tb.dut->dbg_a); ok = false; }
        if (tb.dut->dbg_pc != 0x0004) { printf("    PC: got 0x%04X, expected 0x0004\n", tb.dut->dbg_pc); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "RST 0x08 and RET");
    }

    // ==================================================================
    // Test 9: LDH instructions
    // ==================================================================
    printf("Test 9: LDH instructions\n");
    {
        reset_cpu(tb);

        // LD A, 0x55    ; 3E 55
        // LDH (0x80),A  ; E0 80    → [FF80] = 0x55
        // LD A, 0x00    ; 3E 00
        // LDH A,(0x80)  ; F0 80    → A = 0x55
        // HALT          ; 76
        uint8_t prog[] = {
            0x3E, 0x55,  // LD A, 0x55
            0xE0, 0x80,  // LDH (0x80), A
            0x3E, 0x00,  // LD A, 0x00
            0xF0, 0x80,  // LDH A, (0x80)
            0x76         // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x55) { printf("    A: got 0x%02X, expected 0x55\n", tb.dut->dbg_a); ok = false; }
        if (memory[0xFF80] != 0x55) { printf("    [FF80]: got 0x%02X, expected 0x55\n", memory[0xFF80]); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "LDH (u8),A and LDH A,(u8)");
    }

    // ==================================================================
    // Test 10: ADD HL, r16
    // ==================================================================
    printf("Test 10: ADD HL, r16\n");
    {
        reset_cpu(tb);

        // LD HL, 0x1000  ; 21 00 10
        // LD BC, 0x0234  ; 01 34 02
        // ADD HL, BC     ; 09       → HL = 0x1234
        // HALT           ; 76
        uint8_t prog[] = {
            0x21, 0x00, 0x10,  // LD HL, 0x1000
            0x01, 0x34, 0x02,  // LD BC, 0x0234
            0x09,              // ADD HL, BC
            0x76               // HALT
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        uint16_t hl = ((uint16_t)tb.dut->dbg_h << 8) | tb.dut->dbg_l;
        if (hl != 0x1234) { printf("    HL: got 0x%04X, expected 0x1234\n", hl); ok = false; }
        // N=0, H=0, C=0 for this addition
        if (tb.dut->dbg_f & 0x40) { printf("    N flag set unexpectedly\n"); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "ADD HL, BC");
    }

    // ==================================================================
    // Test 11: LD (u16), A and LD A, (u16)
    // ==================================================================
    printf("Test 11: LD (u16),A and LD A,(u16)\n");
    {
        reset_cpu(tb);

        // LD A, 0xAB     ; 3E AB
        // LD (0xC100), A ; EA 00 C1
        // LD A, 0x00     ; 3E 00
        // LD A, (0xC100) ; FA 00 C1
        // HALT           ; 76
        uint8_t prog[] = {
            0x3E, 0xAB,
            0xEA, 0x00, 0xC1,
            0x3E, 0x00,
            0xFA, 0x00, 0xC1,
            0x76
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0xAB) { printf("    A: got 0x%02X, expected 0xAB\n", tb.dut->dbg_a); ok = false; }
        if (memory[0xC100] != 0xAB) { printf("    [C100]: got 0x%02X, expected 0xAB\n", memory[0xC100]); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "LD (u16),A and LD A,(u16)");
    }

    // ==================================================================
    // Test 12: Conditional RET
    // ==================================================================
    printf("Test 12: Conditional RET\n");
    {
        reset_cpu(tb);

        // 0x0000: CALL 0x0010   ; CD 10 00
        // 0x0003: HALT          ; 76
        // ...
        // 0x0010: LD A, 0x01    ; 3E 01
        // 0x0012: OR A, A       ; B7       → Z=0 (A=1)
        // 0x0013: RET Z         ; C8       → not taken (Z=0)
        // 0x0014: LD B, 0xAA    ; 06 AA
        // 0x0016: RET           ; C9
        memset(memory, 0, 256);
        memory[0x0000] = 0xCD; memory[0x0001] = 0x10; memory[0x0002] = 0x00;
        memory[0x0003] = 0x76;

        memory[0x0010] = 0x3E; memory[0x0011] = 0x01;
        memory[0x0012] = 0xB7;
        memory[0x0013] = 0xC8;  // RET Z
        memory[0x0014] = 0x06; memory[0x0015] = 0xAA;
        memory[0x0016] = 0xC9;

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_b != 0xAA) { printf("    B: got 0x%02X, expected 0xAA\n", tb.dut->dbg_b); ok = false; }
        if (tb.dut->dbg_a != 0x01) { printf("    A: got 0x%02X, expected 0x01\n", tb.dut->dbg_a); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "Conditional RET Z (not taken)");
    }

    // ==================================================================
    // Test 13: CB BIT/SET/RES on register
    // ==================================================================
    printf("Test 13: CB BIT/SET/RES\n");
    {
        reset_cpu(tb);

        // LD A, 0x00    ; 3E 00
        // SET 3, A      ; CB DF    → A = 0x08
        // BIT 3, A      ; CB 5F    → Z=0 (bit is set)
        // RES 3, A      ; CB 9F    → A = 0x00
        // BIT 3, A      ; CB 5F    → Z=1 (bit is clear)
        // HALT          ; 76
        uint8_t prog[] = {
            0x3E, 0x00,
            0xCB, 0xDF,  // SET 3, A
            0xCB, 0x5F,  // BIT 3, A
            0xCB, 0x9F,  // RES 3, A
            0xCB, 0x5F,  // BIT 3, A
            0x76
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x00) { printf("    A: got 0x%02X, expected 0x00\n", tb.dut->dbg_a); ok = false; }
        // After last BIT 3,A: Z=1 (bit is clear)
        if (!(tb.dut->dbg_f & 0x80)) { printf("    Z flag not set after BIT 3,A (bit clear)\n"); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "CB SET, BIT, RES on A");
    }

    // ==================================================================
    // Test 14: DEC (HL)
    // ==================================================================
    printf("Test 14: DEC (HL)\n");
    {
        reset_cpu(tb);

        // LD HL, 0xC000 ; 21 00 C0
        // LD A, 0x01    ; 3E 01
        // LD (HL), A    ; 77
        // DEC (HL)      ; 35       → [C000] = 0x00, Z=1
        // HALT          ; 76
        uint8_t prog[] = {
            0x21, 0x00, 0xC0,
            0x3E, 0x01,
            0x77,
            0x35,
            0x76
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (memory[0xC000] != 0x00) { printf("    [C000]: got 0x%02X, expected 0x00\n", memory[0xC000]); ok = false; }
        // Z flag should be set
        if (!(tb.dut->dbg_f & 0x80)) { printf("    Z flag not set after DEC (HL)\n"); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "DEC (HL)");
    }

    // ==================================================================
    // Test 15: LD (HL), u8
    // ==================================================================
    printf("Test 15: LD (HL), u8\n");
    {
        reset_cpu(tb);

        // LD HL, 0xC000 ; 21 00 C0
        // LD (HL), 0x5A ; 36 5A
        // LD A, (HL)    ; 7E
        // HALT          ; 76
        uint8_t prog[] = {
            0x21, 0x00, 0xC0,
            0x36, 0x5A,
            0x7E,
            0x76
        };
        memcpy(memory, prog, sizeof(prog));

        run_until_halt(tb);

        bool ok = true;
        if (tb.dut->dbg_a != 0x5A) { printf("    A: got 0x%02X, expected 0x5A\n", tb.dut->dbg_a); ok = false; }
        if (memory[0xC000] != 0x5A) { printf("    [C000]: got 0x%02X, expected 0x5A\n", memory[0xC000]); ok = false; }
        if (!ok) dump_regs(tb.dut);
        tb.check(ok, "LD (HL), u8");
    }

    return tb.done();
}
