#include "Vdual_port_ram.h"

#include <verilated.h>
#include <verilated_vcd_c.h>

#include <cstdint>
#include <cstdio>

// Custom testbench for dual-port RAM — two independent clocks.
// We don't use the testbench.h helper because it expects a single `clk` port.

static int pass_count = 0;
static int fail_count = 0;
static uint64_t sim_time = 0;

static void check(bool cond, const char* msg) {
    if (cond) {
        pass_count++;
    } else {
        fail_count++;
        printf("  FAIL: %s (at time %lu)\n", msg, sim_time);
    }
}

// Drive one clock cycle on both ports simultaneously.
static void tick(Vdual_port_ram* dut, VerilatedVcdC* trace) {
    dut->clk_a = 1;
    dut->clk_b = 1;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 5);

    dut->clk_a = 0;
    dut->clk_b = 0;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 10);

    sim_time++;
}

// Drive one clock cycle on port A only.
static void tick_a(Vdual_port_ram* dut, VerilatedVcdC* trace) {
    dut->clk_a = 1;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 5);

    dut->clk_a = 0;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 10);

    sim_time++;
}

// Drive one clock cycle on port B only.
static void tick_b(Vdual_port_ram* dut, VerilatedVcdC* trace) {
    dut->clk_b = 1;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 5);

    dut->clk_b = 0;
    dut->eval();
    if (trace) trace->dump(sim_time * 10 + 10);

    sim_time++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto* dut = new Vdual_port_ram;
    auto* trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("build/sim/dual_port_ram.vcd");

    // Initialize
    dut->we_a = 0; dut->we_b = 0;
    dut->addr_a = 0; dut->addr_b = 0;
    dut->wdata_a = 0; dut->wdata_b = 0;
    tick(dut, trace);

    // -------------------------------------------------------------------
    // Test 1: Write on port A, read on port B
    // -------------------------------------------------------------------
    printf("Test 1: Write port A, read port B\n");

    dut->we_a    = 1;
    dut->addr_a  = 0x10;
    dut->wdata_a = 0xCA;
    tick(dut, trace);

    dut->we_a   = 0;
    dut->addr_b = 0x10;
    tick(dut, trace);

    check(dut->rdata_b == 0xCA,
          "Port B reads 0xCA written by port A");

    // -------------------------------------------------------------------
    // Test 2: Write on port B, read on port A
    // -------------------------------------------------------------------
    printf("Test 2: Write port B, read port A\n");

    dut->we_b    = 1;
    dut->addr_b  = 0x20;
    dut->wdata_b = 0xFE;
    tick(dut, trace);

    dut->we_b   = 0;
    dut->addr_a = 0x20;
    tick(dut, trace);

    check(dut->rdata_a == 0xFE,
          "Port A reads 0xFE written by port B");

    // -------------------------------------------------------------------
    // Test 3: Independent addresses — both ports read different locations
    // -------------------------------------------------------------------
    printf("Test 3: Independent simultaneous reads\n");

    // Write two different values via port A
    dut->we_a = 1;
    dut->addr_a = 0x30; dut->wdata_a = 0x11;
    tick(dut, trace);
    dut->addr_a = 0x31; dut->wdata_a = 0x22;
    tick(dut, trace);
    dut->we_a = 0;

    // Read both simultaneously from different ports
    dut->addr_a = 0x30;
    dut->addr_b = 0x31;
    tick(dut, trace);

    check(dut->rdata_a == 0x11, "Port A reads 0x11 from address 0x30");
    check(dut->rdata_b == 0x22, "Port B reads 0x22 from address 0x31");

    // -------------------------------------------------------------------
    // Test 4: Independent clocks — port A and B can tick separately
    // -------------------------------------------------------------------
    printf("Test 4: Independent clocks\n");

    // Write 0xBB at address 0x40 using port A
    dut->we_a = 1;
    dut->addr_a = 0x40; dut->wdata_a = 0xBB;
    tick_a(dut, trace);
    dut->we_a = 0;

    // Read from port B without port A ticking
    dut->addr_b = 0x40;
    tick_b(dut, trace);

    check(dut->rdata_b == 0xBB,
          "Port B reads data written by port A using independent clocks");

    // -------------------------------------------------------------------
    // Test 5: Bulk write+read — fill and verify larger region
    // -------------------------------------------------------------------
    printf("Test 5: Bulk write and verify (64 addresses)\n");

    // Fill addresses 0x00–0x3F via port A with pattern ~addr
    for (int i = 0; i < 64; i++) {
        dut->we_a = 1;
        dut->addr_a = i;
        dut->wdata_a = (~i) & 0xFF;
        tick(dut, trace);
    }
    dut->we_a = 0;

    // Read them all back via port B
    bool all_ok = true;
    for (int i = 0; i < 64; i++) {
        dut->addr_b = i;
        tick(dut, trace);
        uint8_t expected = (~i) & 0xFF;
        if (dut->rdata_b != expected) {
            printf("    addr=0x%02X: got 0x%02X, expected 0x%02X\n",
                   i, dut->rdata_b, expected);
            all_ok = false;
        }
    }
    check(all_ok, "All 64 addresses verified via cross-port read");

    // -------------------------------------------------------------------
    // Results
    // -------------------------------------------------------------------
    printf("\n--- Results: %d passed, %d failed ---\n", pass_count, fail_count);
    trace->close();
    delete trace;
    delete dut;
    return fail_count > 0 ? 1 : 0;
}
