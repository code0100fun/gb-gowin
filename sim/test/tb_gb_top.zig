const std = @import("std");
const gb_top = @import("gb_top");
const print = std.debug.print;

test "boot test — LED output" {
    var dut = try gb_top.Model.init(.{});
    defer dut.deinit();

    // Reset: btn_s1 active low (pressed = 0)
    dut.set(.btn_s1, 0);
    dut.set(.btn_s2, 1);
    for (0..5) |_| dut.tick();

    // Release reset
    dut.set(.btn_s1, 1);
    for (0..3) |_| dut.tick(); // 2-FF synchronizer propagation

    // Run enough cycles for the program to complete (~14 M-cycles)
    for (0..50) |_| dut.tick();

    // Check LED output.
    // LEDs are active low: led = ~led_reg[5:0].
    // Expected led_reg = 0x1F (binary 011111).
    // So led output = ~0x1F & 0x3F = 0x20 (binary 100000).
    const led_out: u8 = @truncate(dut.get(.led) & 0x3F);
    const led_reg = (~led_out) & 0x3F;
    print("    led_out=0b{b:0>6} -> led_reg=0b{b:0>6} (expect 0b011111)\n", .{ @as(u6, @truncate(led_out)), @as(u6, @truncate(led_reg)) });
    try std.testing.expectEqual(@as(u8, 0x1F), led_reg);
}
