const std = @import("std");
const joypad_top = @import("joypad_top");
const print = std.debug.print;

fn resetDut(dut: *joypad_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.btn, 0);
    dut.set(.io_wr, 0);
    dut.set(.io_addr, 0);
    dut.set(.io_wdata, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Wait for button debounce to settle.
/// With DEBOUNCE_CYCLES=4: 2 sync cycles + 3 sample periods (4 ticks each) = 14 ticks.
fn waitDebounce(dut: *joypad_top.Model) void {
    for (0..14) |_| dut.tick();
}

/// Write to JOYP register (FF00) — sets column select bits [5:4].
fn writeJoyp(dut: *joypad_top.Model, val: u8) void {
    dut.set(.io_addr, 0x00);
    dut.set(.io_wr, 1);
    dut.set(.io_wdata, val);
    dut.tick();
    dut.set(.io_wr, 0);
}

/// Read current JOYP register value (combinational, no tick needed).
fn readJoyp(dut: *joypad_top.Model) u8 {
    dut.set(.io_addr, 0x00);
    return @truncate(dut.get(.io_rdata));
}

test "default JOYP read" {
    // After reset: both columns deselected (P14=P15=1), no buttons pressed.
    // JOYP = {11, 11, 1111} = 0xFF.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const val = readJoyp(&dut);
    print("  Default JOYP: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0xFF), val);
}

test "direction select" {
    // Select directions (P14=0), press Right → bit 0 should read 0.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Press Right (btn[0]) and wait for debounce
    dut.set(.btn, 0x01);
    waitDebounce(&dut);

    // Select direction column: P14=0, P15=1 → bits [5:4]=10 → 0x20
    writeJoyp(&dut, 0x20);

    const val = readJoyp(&dut);
    print("  Direction select, Right pressed: JOYP=0x{x:0>2}\n", .{val});
    // P10 (Right) should be 0 (pressed, active low)
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(val)));
    // P11-P13 should be 1 (not pressed)
    try std.testing.expectEqual(@as(u3, 0b111), @as(u3, @truncate(val >> 1)));
}

test "action select" {
    // Select actions (P15=0), press A → bit 0 should read 0.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Press A (btn[4]) and wait for debounce
    dut.set(.btn, 0x10);
    waitDebounce(&dut);

    // Select action column: P14=1, P15=0 → bits [5:4]=01 → 0x10
    writeJoyp(&dut, 0x10);

    const val = readJoyp(&dut);
    print("  Action select, A pressed: JOYP=0x{x:0>2}\n", .{val});
    // P10 (A) should be 0 (pressed, active low)
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(val)));
}

test "column isolation" {
    // Select direction only (P14=0), press A (action button) →
    // A should NOT appear on the direction column.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Press A (btn[4], action) and wait for debounce
    dut.set(.btn, 0x10);
    waitDebounce(&dut);

    // Select direction column only: P14=0, P15=1 → 0x20
    writeJoyp(&dut, 0x20);

    const val = readJoyp(&dut);
    print("  Column isolation, A on direction column: JOYP=0x{x:0>2}\n", .{val});
    // Lower nibble should be 0xF (no direction buttons pressed)
    try std.testing.expectEqual(@as(u4, 0xF), @as(u4, @truncate(val)));
}

test "both columns selected" {
    // Both P14=P15=0, press Right (direction) and Start (action).
    // Both should appear in the read.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Press Right (btn[0]) and Start (btn[7])
    dut.set(.btn, 0x81);
    waitDebounce(&dut);

    // Select both: P14=0, P15=0 → bits [5:4]=00 → 0x00
    writeJoyp(&dut, 0x00);

    const val = readJoyp(&dut);
    print("  Both columns, Right+Start: JOYP=0x{x:0>2}\n", .{val});
    // P10=0 (Right from dpad), P13=0 (Start from action), P11=P12=1
    const lower: u4 = @truncate(val);
    try std.testing.expectEqual(@as(u4, 0b0110), lower);
}

test "debounce rejects glitch" {
    // A brief 1-tick glitch should not register as a button press.
    // A sustained press should debounce and register.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Select direction column
    writeJoyp(&dut, 0x20);

    // Brief glitch on Right — press for only 1 tick, then release
    dut.set(.btn, 0x01);
    dut.tick();
    dut.set(.btn, 0x00);

    // Tick through what would be the full debounce period
    for (0..20) |_| dut.tick();

    // Right should NOT be debounced as pressed (glitch too brief)
    var val = readJoyp(&dut);
    print("  After glitch: JOYP=0x{x:0>2} (expect not pressed)\n", .{val});
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(val)));

    // Now properly press and hold — should debounce as pressed
    dut.set(.btn, 0x01);
    waitDebounce(&dut);

    val = readJoyp(&dut);
    print("  After sustained press: JOYP=0x{x:0>2} (expect pressed)\n", .{val});
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(val)));
}

test "joypad interrupt" {
    // Pressing a button while column is selected should fire IRQ exactly once.
    var dut = try joypad_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Select direction column
    writeJoyp(&dut, 0x20);
    // Let prev_p10_p13 settle
    dut.tick();
    dut.tick();

    // No IRQ should be active
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(dut.get(.dbg_irq))));

    // Press Right and count IRQ pulses through debounce
    dut.set(.btn, 0x01);
    var irq_count: u32 = 0;
    for (0..20) |_| {
        dut.tick();
        if (dut.get(.dbg_irq) != 0) irq_count += 1;
    }

    print("  IRQ pulse count: {d}\n", .{irq_count});
    try std.testing.expectEqual(@as(u32, 1), irq_count);
}
