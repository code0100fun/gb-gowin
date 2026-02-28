#include "Vcpu_bus_top.h"
#include "testbench.h"

static int run_until_halt(Testbench<Vcpu_bus_top>& tb, int max_cycles = 2000) {
    int cycles = 0;
    while (cycles < max_cycles && !tb.dut->halted) {
        tb.tick();
        cycles++;
    }
    return cycles;
}

static void dump_regs(Vcpu_bus_top* d) {
    printf("    PC=%04X SP=%04X\n", d->dbg_pc, d->dbg_sp);
    printf("    A=%02X F=%02X B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X\n",
           d->dbg_a, d->dbg_f, d->dbg_b, d->dbg_c,
           d->dbg_d, d->dbg_e, d->dbg_h, d->dbg_l);
}

int main(int argc, char** argv) {
    Testbench<Vcpu_bus_top> tb("build/sim/cpu_bus.vcd", argc, argv);

    // ROM program (see sim/data/cpu_bus_test.hex):
    //   00: LD A,0x42; LD HL,0xC000; LD (HL),A; LD B,(HL)
    //       → B = 0x42 (WRAM write + read)
    //   07: LD A,0xAB; LDH (0x80),A; LD A,0x00; LDH A,(0x80); LD C,A
    //       → C = 0xAB (HRAM write + read)
    //   10: LD HL,0xC010; LD A,0x33; LD (HL),A
    //       LD HL,0xE010; LD A,(HL); LD D,A
    //       → D = 0x33 (Echo RAM mirrors WRAM)
    //   1B: LD A,0x00; CALL 0x0030; LD E,A; HALT
    //   30: LD A,0x77; RET
    //       → E = 0x77 (CALL/RET stack through HRAM, SP=0xFFFE)

    tb.dut->reset = 1;
    tb.tick();
    tb.dut->reset = 0;

    int cycles = run_until_halt(tb);
    printf("Program completed in %d cycles\n", cycles);
    dump_regs(tb.dut);

    tb.check(tb.dut->halted, "CPU halted");
    tb.check(tb.dut->dbg_b == 0x42, "WRAM write+read: B=0x42");
    tb.check(tb.dut->dbg_c == 0xAB, "HRAM write+read: C=0xAB");
    tb.check(tb.dut->dbg_d == 0x33, "Echo RAM read: D=0x33");
    tb.check(tb.dut->dbg_e == 0x77, "CALL/RET via bus stack: E=0x77");
    tb.check(tb.dut->dbg_a == 0x77, "A=0x77 (from subroutine)");

    return tb.done();
}
