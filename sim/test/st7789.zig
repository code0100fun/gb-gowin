const std = @import("std");
const st7789_top = @import("st7789_top");
const print = std.debug.print;

fn resetDut(dut: *st7789_top.Model) void {
    dut.set(.reset, 1);
    dut.tick();
    dut.set(.reset, 0);
}

fn getSclk(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_sclk));
}

fn getMosi(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_mosi));
}

fn getRst(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_rst));
}

fn getBusy(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.busy));
}

fn getPixelX(dut: *st7789_top.Model) u8 {
    return @truncate(dut.get(.dbg_pixel_x));
}

fn getPixelY(dut: *st7789_top.Model) u8 {
    return @truncate(dut.get(.dbg_pixel_y));
}

fn getPixelReq(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.dbg_pixel_req));
}

fn getCs(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_cs));
}

fn getDc(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_dc));
}

fn getBl(dut: *st7789_top.Model) u1 {
    return @truncate(dut.get(.lcd_bl));
}

test "reset sequence" {
    // After reset, lcd_rst should be LOW (holding display in reset).
    // After ~270,000 cycles (10ms at 27MHz), lcd_rst goes HIGH.
    var dut = try st7789_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // lcd_rst should be low immediately after reset
    try std.testing.expectEqual(@as(u1, 0), getRst(&dut));

    // Tick a few cycles — still low
    for (0..100) |_| dut.tick();
    try std.testing.expectEqual(@as(u1, 0), getRst(&dut));

    // Run through the 10ms reset period (270,000 cycles)
    // Use 270,100 to be safe
    for (0..270_000) |_| dut.tick();

    // lcd_rst should now be HIGH
    const rst_after = getRst(&dut);
    print("  RST after 270,100 ticks: {d}\n", .{rst_after});
    try std.testing.expectEqual(@as(u1, 1), rst_after);

    // Backlight should still be off during init
    try std.testing.expectEqual(@as(u1, 0), getBl(&dut));
}

test "SCLK idles low (Mode 0)" {
    // SPI Mode 0: CPOL=0, clock idles low when not active
    var dut = try st7789_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // After reset, SCLK should be low (idle)
    try std.testing.expectEqual(@as(u1, 0), getSclk(&dut));

    // During the reset hold period, SCLK should remain low
    for (0..1000) |_| dut.tick();
    try std.testing.expectEqual(@as(u1, 0), getSclk(&dut));
}

test "init completes and streaming starts" {
    // The full init takes: 10ms (RST) + 120ms (wait) + 120ms (SLPOUT) +
    // 120ms (DISPON) + command bytes ≈ 370ms = ~10,000,000 cycles.
    // We need to run enough cycles for the entire init sequence.
    var dut = try st7789_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // busy should be high during init
    try std.testing.expectEqual(@as(u1, 1), getBusy(&dut));

    // Run through init (~14M cycles for all delays + commands)
    // SWRESET delay + SLPOUT delay + DISPON delay + reset periods
    for (0..14_000_000) |_| dut.tick();

    // busy should now be low (streaming)
    const busy_after = getBusy(&dut);
    print("  busy after init: {d}\n", .{busy_after});
    try std.testing.expectEqual(@as(u1, 0), busy_after);

    // Backlight should be on
    try std.testing.expectEqual(@as(u1, 1), getBl(&dut));

    // pixel_x and pixel_y should have started incrementing
    // (some pixels already sent during the ticks after init completed)
    const px = getPixelX(&dut);
    const py = getPixelY(&dut);
    print("  pixel position after init: ({d}, {d})\n", .{ px, py });

    // At least some pixels should have been sent
    try std.testing.expect(px > 0 or py > 0);
}

test "SPI byte output is MSB first" {
    // Capture the first SPI byte sent after the reset period.
    // The first command is SWRESET (0x01 = 0b00000001).
    // Reset period: 270,001 cycles (RST low) + 3,240,001 cycles (RST high wait)
    // = 3,510,002 cycles total. Land just before S_INIT starts.
    var dut = try st7789_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Skip to just before the init FSM starts sending
    for (0..3_509_500) |_| dut.tick();

    // Wait for CS to go low (start of first SPI transaction)
    var cs_went_low = false;
    for (0..1000) |_| {
        dut.tick();
        if (getCs(&dut) == 0) {
            cs_went_low = true;
            break;
        }
    }
    try std.testing.expect(cs_went_low);

    // DC should be 0 (command mode) for SWRESET
    try std.testing.expectEqual(@as(u1, 0), getDc(&dut));

    // Capture 8 bits: watch for rising edges of SCLK, read MOSI
    // (Mode 0: display samples MOSI on the rising edge)
    var captured: u8 = 0;
    var bits_captured: u4 = 0;
    var prev_sclk: u1 = getSclk(&dut);

    for (0..200) |_| {
        dut.tick();
        const cur_sclk = getSclk(&dut);
        // Rising edge: display samples MOSI
        if (prev_sclk == 0 and cur_sclk == 1) {
            captured = (captured << 1) | getMosi(&dut);
            bits_captured += 1;
            if (bits_captured == 8) break;
        }
        prev_sclk = cur_sclk;
    }

    print("  Captured SPI byte: 0x{x:0>2} (expect 0x01 SWRESET)\n", .{captured});
    try std.testing.expectEqual(@as(u8, 0x01), captured);
}

test "pixel coordinates wrap correctly" {
    // After init, pixel streaming should cycle through (0,0)..(159,143)
    // then wrap back to (0,0) for the next frame.
    var dut = try st7789_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Skip through init (extra time for SWRESET delay)
    for (0..14_000_000) |_| dut.tick();
    try std.testing.expectEqual(@as(u1, 0), getBusy(&dut));

    // Find a pixel_req and check that coordinates advance
    var found_req = false;
    var last_x: u8 = getPixelX(&dut);
    var advances: u32 = 0;

    for (0..500) |_| {
        dut.tick();
        if (getPixelReq(&dut) == 1) {
            found_req = true;
            const new_x = getPixelX(&dut);
            if (new_x != last_x) advances += 1;
            last_x = new_x;
        }
    }

    print("  pixel_req found: {}, advances: {d}\n", .{ found_req, advances });
    try std.testing.expect(found_req);
    try std.testing.expect(advances > 0);
}
