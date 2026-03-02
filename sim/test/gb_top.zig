const std = @import("std");
const gb_top = @import("gb_top");
const print = std.debug.print;

test "power-on reset — LED output" {
    // Simulate exact FPGA power-on: btn_s1=0 (not pressed, floats low).
    // The POR counter asserts reset for 16 clocks, then releases.
    var dut = try gb_top.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 0); // not pressed (floats low on hardware)
    dut.set(.btn_s2, 1);

    // Run enough cycles for POR (16 clocks) + program execution (~14 M-cycles)
    for (0..100) |_| dut.tick();

    // Check LED output.
    // LEDs are active low: led = ~led_reg[5:0].
    // Expected led_reg = 0x1F (binary 011111).
    const led_out: u8 = @truncate(dut.get(.led) & 0x3F);
    const led_reg = (~led_out) & 0x3F;
    print("    led_out=0b{b:0>6} -> led_reg=0b{b:0>6} (expect 0b011111)\n", .{ @as(u6, @truncate(led_out)), @as(u6, @truncate(led_reg)) });
    try std.testing.expectEqual(@as(u8, 0x1F), led_reg);
}

test "button reset — LED output" {
    var dut = try gb_top.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 0); // not pressed
    dut.set(.btn_s2, 1);

    // Let CPU run and complete program
    for (0..100) |_| dut.tick();

    // Verify LEDs are set
    var led_out: u8 = @truncate(dut.get(.led) & 0x3F);
    var led_reg = (~led_out) & 0x3F;
    try std.testing.expectEqual(@as(u8, 0x1F), led_reg);

    // Press reset button (btn_s1=1 = pressed on this board)
    dut.set(.btn_s1, 1);
    for (0..5) |_| dut.tick();

    // Release button
    dut.set(.btn_s1, 0);

    // Run enough cycles for POR counter + program re-execution
    for (0..100) |_| dut.tick();

    led_out = @truncate(dut.get(.led) & 0x3F);
    led_reg = (~led_out) & 0x3F;
    print("    led_out=0b{b:0>6} -> led_reg=0b{b:0>6} (expect 0b011111)\n", .{ @as(u6, @truncate(led_out)), @as(u6, @truncate(led_reg)) });
    try std.testing.expectEqual(@as(u8, 0x1F), led_reg);
}
