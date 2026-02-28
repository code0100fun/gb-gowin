#include "Vrom.h"
#include "testbench.h"

// Expected contents of sim/data/test_rom.hex (16 bytes)
static const uint8_t EXPECTED[] = {
    0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
};

int main(int argc, char** argv) {
    Testbench<Vrom> tb("build/sim/rom.vcd", argc, argv);

    // -------------------------------------------------------------------
    // Test 1: Read all initialized addresses
    // -------------------------------------------------------------------
    printf("Test 1: Read initialized data\n");

    bool all_ok = true;
    for (int i = 0; i < 16; i++) {
        tb.dut->addr = i;
        tb.tick();
        if (tb.dut->rdata != EXPECTED[i]) {
            printf("    addr=%d: got 0x%02X, expected 0x%02X\n",
                   i, tb.dut->rdata, EXPECTED[i]);
            all_ok = false;
        }
    }
    tb.check(all_ok, "All 16 ROM bytes match expected values");

    // -------------------------------------------------------------------
    // Test 2: Re-read — data should not change
    // -------------------------------------------------------------------
    printf("Test 2: Re-read consistency\n");

    all_ok = true;
    for (int i = 15; i >= 0; i--) {
        tb.dut->addr = i;
        tb.tick();
        if (tb.dut->rdata != EXPECTED[i]) {
            all_ok = false;
        }
    }
    tb.check(all_ok, "Reverse-order re-read matches");

    // -------------------------------------------------------------------
    // Test 3: Uninitialized addresses read as 0
    // -------------------------------------------------------------------
    printf("Test 3: Uninitialized addresses\n");

    // Addresses beyond the 16 initialized bytes should be 0
    all_ok = true;
    for (int i = 16; i < 32; i++) {
        tb.dut->addr = i;
        tb.tick();
        if (tb.dut->rdata != 0x00) {
            printf("    addr=%d: got 0x%02X, expected 0x00\n",
                   i, tb.dut->rdata);
            all_ok = false;
        }
    }
    tb.check(all_ok, "Uninitialized ROM addresses read as 0x00");

    // -------------------------------------------------------------------
    // Test 4: Synchronous read — output updates one cycle after address
    // -------------------------------------------------------------------
    printf("Test 4: Synchronous read latency\n");

    // Set address to 0 and tick
    tb.dut->addr = 0;
    tb.tick();
    uint8_t val_at_0 = tb.dut->rdata;

    // Change address to 5 — output should NOT change until the next tick
    tb.dut->addr = 5;
    tb.dut->eval();  // propagate combinational logic only (no clock edge)
    tb.check(tb.dut->rdata == val_at_0,
             "Output unchanged before clock edge");

    // Now tick — output should update
    tb.tick();
    tb.check(tb.dut->rdata == EXPECTED[5],
             "Output updates to address 5 data after clock edge");

    return tb.done();
}
