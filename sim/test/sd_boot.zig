const std = @import("std");
const sd_boot_top = @import("sd_boot_top");
const print = std.debug.print;

fn resetDut(dut: *sd_boot_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.rom_rd_addr, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Wait for boot to complete (done=1 or boot_error=1).
fn waitBoot(dut: *sd_boot_top.Model) bool {
    var cycles: u32 = 0;
    while (dut.get(.done) == 0 and dut.get(.boot_error) == 0) {
        dut.tick();
        cycles += 1;
        if (cycles > 1_000_000) {
            print("  boot TIMEOUT after {} cycles\n", .{cycles});
            return false;
        }
    }
    const done_val: u1 = @truncate(dut.get(.done));
    const err_val: u1 = @truncate(dut.get(.boot_error));
    const err_code: u3 = @truncate(dut.get(.error_code));
    print("  boot completed in {} cycles (done={} error={} code={})\n", .{ cycles, done_val, err_val, err_code });
    return dut.get(.done) == 1;
}

/// Read a byte from ROM BSRAM.
fn readRom(dut: *sd_boot_top.Model, addr: u15) u8 {
    dut.set(.rom_rd_addr, addr);
    dut.tick(); // address registered
    dut.tick(); // data available
    return @truncate(dut.get(.rom_rd_data));
}

test "boot loads ROM successfully" {
    var dut = try sd_boot_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const ok = waitBoot(&dut);
    try std.testing.expect(ok);

    const done_val: u1 = @truncate(dut.get(.done));
    const err_val: u1 = @truncate(dut.get(.boot_error));
    try std.testing.expectEqual(@as(u1, 1), done_val);
    try std.testing.expectEqual(@as(u1, 0), err_val);
}

test "ROM data matches expected pattern" {
    var dut = try sd_boot_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const ok = waitBoot(&dut);
    try std.testing.expect(ok);

    // Verify ROM pattern: rom[i] = i[7:0]
    const b0 = readRom(&dut, 0);
    const b1 = readRom(&dut, 1);
    const b42 = readRom(&dut, 0x42);
    const b255 = readRom(&dut, 255);
    const b256 = readRom(&dut, 256);
    const b4095 = readRom(&dut, 4095);
    const b8191 = readRom(&dut, 8191);
    print("  rom[0]=0x{x:0>2} [1]=0x{x:0>2} [0x42]=0x{x:0>2} [255]=0x{x:0>2}\n", .{ b0, b1, b42, b255 });
    print("  rom[256]=0x{x:0>2} [4095]=0x{x:0>2} [8191]=0x{x:0>2}\n", .{ b256, b4095, b8191 });

    try std.testing.expectEqual(@as(u8, 0x00), b0);
    try std.testing.expectEqual(@as(u8, 0x01), b1);
    try std.testing.expectEqual(@as(u8, 0x42), b42);
    try std.testing.expectEqual(@as(u8, 0xFF), b255);
    try std.testing.expectEqual(@as(u8, 0x00), b256);   // 256 & 0xFF = 0x00
    try std.testing.expectEqual(@as(u8, 0xFF), b4095);   // 4095 & 0xFF = 0xFF
    try std.testing.expectEqual(@as(u8, 0xFF), b8191);   // 8191 & 0xFF = 0xFF
}

test "ROM beyond file size is zero" {
    var dut = try sd_boot_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const ok = waitBoot(&dut);
    try std.testing.expect(ok);

    // ROM file is 8192 bytes. Bytes beyond that should be 0 (unwritten BSRAM)
    const b8192 = readRom(&dut, 8192);
    const b16000 = readRom(&dut, 16000);
    const b32767 = readRom(&dut, 32767);
    print("  rom[8192]=0x{x:0>2} [16000]=0x{x:0>2} [32767]=0x{x:0>2}\n", .{ b8192, b16000, b32767 });

    try std.testing.expectEqual(@as(u8, 0x00), b8192);
    try std.testing.expectEqual(@as(u8, 0x00), b16000);
    try std.testing.expectEqual(@as(u8, 0x00), b32767);
}
