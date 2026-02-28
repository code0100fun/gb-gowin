#include "Vgb_top.h"
#include "testbench.h"

int main(int argc, char** argv) {
    Testbench<Vgb_top> tb("build/sim/gb_top.vcd", argc, argv);

    // Reset: btn_s1 active low (pressed = 0)
    tb.dut->btn_s1 = 0;
    tb.dut->btn_s2 = 1;
    tb.tick(5);

    // Release reset
    tb.dut->btn_s1 = 1;
    tb.tick(3);  // 2-FF synchronizer propagation

    // Run enough cycles for the program to complete (~14 M-cycles)
    tb.tick(50);

    // Check LED output.
    // LEDs are active low: led = ~led_reg[5:0].
    // Expected led_reg = 0x1F (binary 011111).
    // So led output = ~0x1F & 0x3F = 0x20 (binary 100000).
    uint8_t led_out = tb.dut->led & 0x3F;
    uint8_t led_reg = (~led_out) & 0x3F;
    printf("LED output: 0x%02X → register: 0x%02X (binary: %c%c%c%c%c%c)\n",
           led_out, led_reg,
           (led_reg & 0x20) ? '1' : '0', (led_reg & 0x10) ? '1' : '0',
           (led_reg & 0x08) ? '1' : '0', (led_reg & 0x04) ? '1' : '0',
           (led_reg & 0x02) ? '1' : '0', (led_reg & 0x01) ? '1' : '0');

    tb.check(led_reg == 0x1F, "LED register = 0x1F (ROM→ALU→HRAM→IO)");

    return tb.done();
}
