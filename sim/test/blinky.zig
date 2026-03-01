const std = @import("std");
const blinky = @import("blinky");

test "counter increments - LEDs change over time" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 1); // not pressed (active low)
    dut.set(.btn_s2, 1);

    const initial_led: u8 = @truncate(dut.get(.led));

    // Run 2^20 cycles — bit 19 will have toggled
    var i: u32 = 0;
    while (i < (1 << 20)) : (i += 1) dut.tick();

    const later_led: u8 = @truncate(dut.get(.led));
    try std.testing.expect(initial_led != later_led);
}

test "normal mode - LED[0] toggles after 2^19 cycles" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 1);
    dut.set(.btn_s2, 1);

    // Run past initial state
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    var i: u32 = 0;
    while (i < (1 << 19)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    try std.testing.expect((led_before ^ led_after) & 0x01 != 0);
}

test "fast mode - LED[0] toggles after 2^16 cycles when S1 pressed" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 0); // pressed (active low)
    dut.set(.btn_s2, 1);
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    var i: u32 = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    try std.testing.expect((led_before ^ led_after) & 0x01 != 0);
}

test "releasing S1 returns to normal mode" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    // Start in fast mode
    dut.set(.btn_s1, 0);
    dut.set(.btn_s2, 1);
    var i: u32 = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();

    // Release button
    dut.set(.btn_s1, 1);
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    i = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    // In normal mode, 2^16 cycles should NOT toggle LED[0]
    try std.testing.expectEqual(@as(u8, 0), (led_before ^ led_after) & 0x01);
}
