#include "Vsingle_port_ram.h"
#include "testbench.h"

int main(int argc, char** argv) {
    Testbench<Vsingle_port_ram> tb("build/sim/single_port_ram.vcd", argc, argv);

    // -------------------------------------------------------------------
    // Test 1: Write then read — data should persist
    // -------------------------------------------------------------------
    printf("Test 1: Write then read\n");

    // Write 0xAB to address 0x00
    tb.dut->we    = 1;
    tb.dut->addr  = 0x00;
    tb.dut->wdata = 0xAB;
    tb.tick();

    // Disable write, read back address 0x00
    tb.dut->we   = 0;
    tb.dut->addr = 0x00;
    tb.tick();

    // Data appears one cycle after the address is presented
    tb.check(tb.dut->rdata == 0xAB,
             "Read back 0xAB from address 0x00");

    // -------------------------------------------------------------------
    // Test 2: Write to multiple addresses, read them all back
    // -------------------------------------------------------------------
    printf("Test 2: Multiple addresses\n");

    // Write pattern: addr[i] = i * 7 + 3
    for (int i = 0; i < 16; i++) {
        tb.dut->we    = 1;
        tb.dut->addr  = i;
        tb.dut->wdata = (i * 7 + 3) & 0xFF;
        tb.tick();
    }

    // Read them all back
    tb.dut->we = 0;
    bool all_correct = true;
    for (int i = 0; i < 16; i++) {
        tb.dut->addr = i;
        tb.tick();
        uint8_t expected = (i * 7 + 3) & 0xFF;
        if (tb.dut->rdata != expected) {
            printf("    addr=%d: got 0x%02X, expected 0x%02X\n",
                   i, tb.dut->rdata, expected);
            all_correct = false;
        }
    }
    tb.check(all_correct, "All 16 addresses read back correctly");

    // -------------------------------------------------------------------
    // Test 3: Overwrite — new data replaces old
    // -------------------------------------------------------------------
    printf("Test 3: Overwrite\n");

    // Write 0xFF to address 0x05
    tb.dut->we    = 1;
    tb.dut->addr  = 0x05;
    tb.dut->wdata = 0xFF;
    tb.tick();

    // Read it back
    tb.dut->we   = 0;
    tb.dut->addr = 0x05;
    tb.tick();

    tb.check(tb.dut->rdata == 0xFF,
             "Overwritten value reads back as 0xFF");

    // -------------------------------------------------------------------
    // Test 4: Write-enable gating — data unchanged when we=0
    // -------------------------------------------------------------------
    printf("Test 4: Write-enable gating\n");

    // Attempt to write 0x00 to address 0x05 with we=0
    tb.dut->we    = 0;
    tb.dut->addr  = 0x05;
    tb.dut->wdata = 0x00;
    tb.tick();

    // Read back — should still be 0xFF
    tb.dut->addr = 0x05;
    tb.tick();

    tb.check(tb.dut->rdata == 0xFF,
             "Write with we=0 does not modify memory");

    // -------------------------------------------------------------------
    // Test 5: Read-first behavior — simultaneous read+write returns OLD value
    // -------------------------------------------------------------------
    printf("Test 5: Read-first behavior\n");

    // Write 0x42 to address 0x0A
    tb.dut->we    = 1;
    tb.dut->addr  = 0x0A;
    tb.dut->wdata = 0x42;
    tb.tick();

    // Now write 0x99 to the same address and read simultaneously
    tb.dut->we    = 1;
    tb.dut->addr  = 0x0A;
    tb.dut->wdata = 0x99;
    tb.tick();

    // The read output should be the OLD value (0x42), not the new one (0x99)
    tb.check(tb.dut->rdata == 0x42,
             "Read-first: simultaneous read+write returns old value (0x42)");

    // Next cycle read should return the new value
    tb.dut->we   = 0;
    tb.dut->addr = 0x0A;
    tb.tick();

    tb.check(tb.dut->rdata == 0x99,
             "Next-cycle read returns new value (0x99)");

    return tb.done();
}
