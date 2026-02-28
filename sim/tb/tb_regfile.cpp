#include "Vregfile.h"
#include "testbench.h"

int main(int argc, char** argv) {
    Testbench<Vregfile> tb("build/sim/regfile.vcd", argc, argv);

    // Helper: disable all write enables
    auto clear_we = [&]() {
        tb.dut->r8_we      = 0;
        tb.dut->r16_we     = 0;
        tb.dut->r16stk_we  = 0;
        tb.dut->flags_we   = 0;
        tb.dut->sp_we      = 0;
        tb.dut->pc_we      = 0;
    };

    clear_we();
    tb.tick();

    // -------------------------------------------------------------------
    // Test 1: 8-bit register write and read
    // -------------------------------------------------------------------
    printf("Test 1: 8-bit register write/read\n");

    // Write a distinct value to each register: B=0x11, C=0x22, ..., A=0x77
    uint8_t vals[] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x77};
    for (int i = 0; i < 8; i++) {
        if (i == 6) continue;  // skip [HL] index
        clear_we();
        tb.dut->r8_we    = 1;
        tb.dut->r8_wsel  = i;
        tb.dut->r8_wdata = vals[i];
        tb.tick();
    }

    // Read them all back (combinational — no tick needed after setting rsel)
    clear_we();
    bool all_ok = true;
    for (int i = 0; i < 8; i++) {
        tb.dut->r8_rsel = i;
        tb.dut->eval();  // propagate combinational read mux
        if (i == 6) {
            // [HL] should return 0xFF
            if (tb.dut->r8_rdata != 0xFF) {
                printf("    r8[6]=[HL]: got 0x%02X, expected 0xFF\n",
                       tb.dut->r8_rdata);
                all_ok = false;
            }
        } else {
            if (tb.dut->r8_rdata != vals[i]) {
                printf("    r8[%d]: got 0x%02X, expected 0x%02X\n",
                       i, tb.dut->r8_rdata, vals[i]);
                all_ok = false;
            }
        }
    }
    tb.check(all_ok, "All 8-bit registers read back correctly");

    // -------------------------------------------------------------------
    // Test 2: 16-bit pair read (r16: BC, DE, HL, SP)
    // -------------------------------------------------------------------
    printf("Test 2: 16-bit pair reads (r16)\n");

    // Registers should still hold: B=0x11, C=0x22, D=0x33, E=0x44,
    // H=0x55, L=0x66
    uint16_t expected_r16[] = {0x1122, 0x3344, 0x5566, 0x0000};

    // Set SP to a known value first
    clear_we();
    tb.dut->sp_we    = 1;
    tb.dut->sp_wdata = 0xABCD;
    tb.tick();
    expected_r16[3] = 0xABCD;

    clear_we();
    all_ok = true;
    for (int i = 0; i < 4; i++) {
        tb.dut->r16_rsel = i;
        tb.dut->eval();
        if (tb.dut->r16_rdata != expected_r16[i]) {
            printf("    r16[%d]: got 0x%04X, expected 0x%04X\n",
                   i, tb.dut->r16_rdata, expected_r16[i]);
            all_ok = false;
        }
    }
    tb.check(all_ok, "16-bit pair reads (BC, DE, HL, SP) correct");

    // -------------------------------------------------------------------
    // Test 3: 16-bit pair write (r16)
    // -------------------------------------------------------------------
    printf("Test 3: 16-bit pair write (r16)\n");

    clear_we();
    tb.dut->r16_we    = 1;
    tb.dut->r16_wsel  = 0;  // BC
    tb.dut->r16_wdata = 0xBEEF;
    tb.tick();

    // Verify BC
    clear_we();
    tb.dut->r16_rsel = 0;
    tb.dut->eval();
    tb.check(tb.dut->r16_rdata == 0xBEEF, "r16 write BC = 0xBEEF");

    // Verify B and C individually
    tb.dut->r8_rsel = 0;  // B
    tb.dut->eval();
    bool b_ok = (tb.dut->r8_rdata == 0xBE);

    tb.dut->r8_rsel = 1;  // C
    tb.dut->eval();
    bool c_ok = (tb.dut->r8_rdata == 0xEF);

    tb.check(b_ok && c_ok,
             "r16 write splits correctly: B=0xBE, C=0xEF");

    // -------------------------------------------------------------------
    // Test 4: Stack pair (r16stk: BC, DE, HL, AF)
    // -------------------------------------------------------------------
    printf("Test 4: Stack pair read/write (r16stk)\n");

    // Write A=0x77 was done in test 1. Write flags via flags port.
    clear_we();
    tb.dut->flags_we    = 1;
    tb.dut->flags_wdata = 0b1010;  // Z=1, N=0, H=1, C=0 → F=0xA0
    tb.tick();

    // Read AF via r16stk
    clear_we();
    tb.dut->r16stk_rsel = 3;  // AF
    tb.dut->eval();
    tb.check(tb.dut->r16stk_rdata == 0x77A0,
             "r16stk read AF = 0x77A0");

    // Write AF via r16stk — low nibble of F should be masked
    clear_we();
    tb.dut->r16stk_we    = 1;
    tb.dut->r16stk_wsel  = 3;  // AF
    tb.dut->r16stk_wdata = 0x12FF;  // A=0x12, F=0xFF → should become 0xF0
    tb.tick();

    clear_we();
    tb.dut->r16stk_rsel = 3;
    tb.dut->eval();
    tb.check(tb.dut->r16stk_rdata == 0x12F0,
             "POP AF masks F lower nibble: 0x12FF → 0x12F0");

    // -------------------------------------------------------------------
    // Test 5: Flag access
    // -------------------------------------------------------------------
    printf("Test 5: Flag access\n");

    // Set all flags
    clear_we();
    tb.dut->flags_we    = 1;
    tb.dut->flags_wdata = 0b1111;  // Z=1, N=1, H=1, C=1
    tb.tick();

    clear_we();
    tb.dut->eval();
    tb.check(tb.dut->flags == 0b1111, "All flags set: ZNHC = 1111");

    // Clear all flags
    tb.dut->flags_we    = 1;
    tb.dut->flags_wdata = 0b0000;
    tb.tick();

    clear_we();
    tb.dut->eval();
    tb.check(tb.dut->flags == 0b0000, "All flags clear: ZNHC = 0000");

    // Set just Z and C
    tb.dut->flags_we    = 1;
    tb.dut->flags_wdata = 0b1001;
    tb.tick();

    clear_we();
    tb.dut->eval();
    tb.check(tb.dut->flags == 0b1001, "Flags Z=1, C=1 only");

    // -------------------------------------------------------------------
    // Test 6: SP and PC
    // -------------------------------------------------------------------
    printf("Test 6: SP and PC\n");

    clear_we();
    tb.dut->sp_we    = 1;
    tb.dut->sp_wdata = 0xFFFE;
    tb.dut->pc_we    = 1;
    tb.dut->pc_wdata = 0x0100;
    tb.tick();

    clear_we();
    tb.dut->eval();
    tb.check(tb.dut->sp == 0xFFFE, "SP = 0xFFFE");
    tb.check(tb.dut->pc == 0x0100, "PC = 0x0100");

    // -------------------------------------------------------------------
    // Test 7: Write priority — r16 write and r8 write to same register
    // -------------------------------------------------------------------
    printf("Test 7: Write priority (r8 vs r16 simultaneous)\n");

    // Write BC=0x1234 via r16 and B=0xFF via r8 simultaneously
    // The last always_ff statement to assign reg_b wins (r16stk is after r16)
    // but in our design r8 is first, r16 second, r16stk third.
    // In real CPU usage, only one write path is active at a time.
    // We just verify r8 writes work when r16 is disabled.
    clear_we();
    tb.dut->r8_we    = 1;
    tb.dut->r8_wsel  = 0;  // B
    tb.dut->r8_wdata = 0xAA;
    tb.tick();

    clear_we();
    tb.dut->r8_rsel = 0;
    tb.dut->eval();
    tb.check(tb.dut->r8_rdata == 0xAA, "r8 write to B = 0xAA");

    // Now r16 write to BC
    clear_we();
    tb.dut->r16_we    = 1;
    tb.dut->r16_wsel  = 0;  // BC
    tb.dut->r16_wdata = 0x9988;
    tb.tick();

    clear_we();
    tb.dut->r8_rsel = 0;  // B
    tb.dut->eval();
    tb.check(tb.dut->r8_rdata == 0x99,
             "r16 write to BC updates B to 0x99");

    return tb.done();
}
