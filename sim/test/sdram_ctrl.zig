const std = @import("std");
const sdram_ctrl_top = @import("sdram_ctrl_top");
const print = std.debug.print;

fn resetDut(dut: *sdram_ctrl_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.rd, 0);
    dut.set(.wr, 0);
    dut.set(.refresh, 0);
    dut.set(.addr, 0);
    dut.set(.din, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Wait for busy to deassert (initialization or command completion).
fn waitNotBusy(dut: *sdram_ctrl_top.Model, timeout: u32) bool {
    var cycles: u32 = 0;
    while (dut.get(.busy) == 1) {
        dut.tick();
        cycles += 1;
        if (cycles > timeout) return false;
    }
    return true;
}

/// Write a single byte to the SDRAM.
fn writeByte(dut: *sdram_ctrl_top.Model, address: u32, value: u8) bool {
    dut.set(.addr, address);
    dut.set(.din, value);
    dut.set(.wr, 1);
    dut.tick();
    dut.set(.wr, 0);
    return waitNotBusy(dut, 100);
}

/// Read a single byte from the SDRAM. Returns the byte value.
fn readByte(dut: *sdram_ctrl_top.Model, address: u32) ?u8 {
    dut.set(.addr, address);
    dut.set(.rd, 1);
    dut.tick();
    dut.set(.rd, 0);

    var cycles: u32 = 0;
    while (dut.get(.data_ready) == 0) {
        dut.tick();
        cycles += 1;
        if (cycles > 100) return null;
    }
    const val: u8 = @truncate(dut.get(.dout));
    // Wait for busy to clear
    _ = waitNotBusy(dut, 100);
    return val;
}

/// Issue a refresh command.
fn doRefresh(dut: *sdram_ctrl_top.Model) bool {
    dut.set(.refresh, 1);
    dut.tick();
    dut.set(.refresh, 0);
    return waitNotBusy(dut, 100);
}

test "initialization completes" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Should be busy during init
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(dut.get(.busy))));

    var cycles: u32 = 0;
    while (dut.get(.busy) == 1) {
        dut.tick();
        cycles += 1;
        if (cycles > 10_000) break;
    }
    print("  init completed in {} cycles\n", .{cycles});
    try std.testing.expect(cycles > 5000); // Should take ~5400+ cycles
    try std.testing.expect(cycles < 6000);
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(dut.get(.busy))));
}

test "write then read single byte" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    try std.testing.expect(writeByte(&dut, 0x000000, 0xAB));
    const val = readByte(&dut, 0x000000);
    print("  wrote 0xAB, read 0x{x:0>2}\n", .{val.?});
    try std.testing.expectEqual(@as(u8, 0xAB), val.?);
}

test "all four byte offsets" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Write to 4 consecutive byte addresses (same 32-bit word)
    try std.testing.expect(writeByte(&dut, 0x100, 0x11));
    try std.testing.expect(writeByte(&dut, 0x101, 0x22));
    try std.testing.expect(writeByte(&dut, 0x102, 0x33));
    try std.testing.expect(writeByte(&dut, 0x103, 0x44));

    // Read back all four
    const v0 = readByte(&dut, 0x100);
    const v1 = readByte(&dut, 0x101);
    const v2 = readByte(&dut, 0x102);
    const v3 = readByte(&dut, 0x103);
    print("  offsets: 0x{x:0>2} 0x{x:0>2} 0x{x:0>2} 0x{x:0>2}\n", .{ v0.?, v1.?, v2.?, v3.? });
    try std.testing.expectEqual(@as(u8, 0x11), v0.?);
    try std.testing.expectEqual(@as(u8, 0x22), v1.?);
    try std.testing.expectEqual(@as(u8, 0x33), v2.?);
    try std.testing.expectEqual(@as(u8, 0x44), v3.?);
}

test "different banks" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Bank 0: addr[22:21] = 00 → 0x000000
    // Bank 1: addr[22:21] = 01 → 0x200000
    // Bank 2: addr[22:21] = 10 → 0x400000
    // Bank 3: addr[22:21] = 11 → 0x600000
    try std.testing.expect(writeByte(&dut, 0x000000, 0xAA));
    try std.testing.expect(writeByte(&dut, 0x200000, 0xBB));
    try std.testing.expect(writeByte(&dut, 0x400000, 0xCC));
    try std.testing.expect(writeByte(&dut, 0x600000, 0xDD));

    try std.testing.expectEqual(@as(u8, 0xAA), readByte(&dut, 0x000000).?);
    try std.testing.expectEqual(@as(u8, 0xBB), readByte(&dut, 0x200000).?);
    try std.testing.expectEqual(@as(u8, 0xCC), readByte(&dut, 0x400000).?);
    try std.testing.expectEqual(@as(u8, 0xDD), readByte(&dut, 0x600000).?);
    print("  all 4 banks OK\n", .{});
}

test "different rows" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Row is addr[20:10]. Each row is 256 words × 4 bytes = 1024 bytes.
    // Row 0: addr 0x000, Row 1: addr 0x400, Row 2: addr 0x800
    try std.testing.expect(writeByte(&dut, 0x000, 0x10));
    try std.testing.expect(writeByte(&dut, 0x400, 0x20));
    try std.testing.expect(writeByte(&dut, 0x800, 0x30));

    try std.testing.expectEqual(@as(u8, 0x10), readByte(&dut, 0x000).?);
    try std.testing.expectEqual(@as(u8, 0x20), readByte(&dut, 0x400).?);
    try std.testing.expectEqual(@as(u8, 0x30), readByte(&dut, 0x800).?);
    print("  different rows OK\n", .{});
}

test "sequential write/read block" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Write 256 bytes with pattern addr[7:0]
    for (0..256) |i| {
        const a: u32 = @intCast(i);
        try std.testing.expect(writeByte(&dut, a, @truncate(a)));
    }

    // Read back and verify
    var errors: u32 = 0;
    for (0..256) |i| {
        const a: u32 = @intCast(i);
        const val = readByte(&dut, a);
        if (val == null or val.? != @as(u8, @truncate(a))) {
            errors += 1;
        }
    }
    print("  256-byte block: {} errors\n", .{errors});
    try std.testing.expectEqual(@as(u32, 0), errors);
}

test "refresh does not corrupt data" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Write a pattern
    try std.testing.expect(writeByte(&dut, 0x1000, 0xDE));
    try std.testing.expect(writeByte(&dut, 0x2000, 0xAD));
    try std.testing.expect(writeByte(&dut, 0x3000, 0xBE));
    try std.testing.expect(writeByte(&dut, 0x4000, 0xEF));

    // Issue several refreshes
    for (0..10) |_| {
        try std.testing.expect(doRefresh(&dut));
    }

    // Verify data intact
    try std.testing.expectEqual(@as(u8, 0xDE), readByte(&dut, 0x1000).?);
    try std.testing.expectEqual(@as(u8, 0xAD), readByte(&dut, 0x2000).?);
    try std.testing.expectEqual(@as(u8, 0xBE), readByte(&dut, 0x3000).?);
    try std.testing.expectEqual(@as(u8, 0xEF), readByte(&dut, 0x4000).?);
    print("  refresh preserves data OK\n", .{});
}

test "large address range" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Write near top of address space (8 MB = 0x7FFFFF)
    try std.testing.expect(writeByte(&dut, 0x7FFFFC, 0xA1));
    try std.testing.expect(writeByte(&dut, 0x7FFFFD, 0xB2));
    try std.testing.expect(writeByte(&dut, 0x7FFFFE, 0xC3));
    try std.testing.expect(writeByte(&dut, 0x7FFFFF, 0xD4));

    try std.testing.expectEqual(@as(u8, 0xA1), readByte(&dut, 0x7FFFFC).?);
    try std.testing.expectEqual(@as(u8, 0xB2), readByte(&dut, 0x7FFFFD).?);
    try std.testing.expectEqual(@as(u8, 0xC3), readByte(&dut, 0x7FFFFE).?);
    try std.testing.expectEqual(@as(u8, 0xD4), readByte(&dut, 0x7FFFFF).?);
    print("  large addresses OK\n", .{});
}

test "interleaved read/write/refresh" {
    var dut = try sdram_ctrl_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    try std.testing.expect(waitNotBusy(&dut, 10_000));

    // Simulate a realistic access pattern: write, refresh, read, write, refresh, read
    try std.testing.expect(writeByte(&dut, 0x100, 0x42));
    try std.testing.expect(doRefresh(&dut));
    try std.testing.expectEqual(@as(u8, 0x42), readByte(&dut, 0x100).?);

    try std.testing.expect(writeByte(&dut, 0x200, 0x55));
    try std.testing.expect(writeByte(&dut, 0x300, 0xAA));
    try std.testing.expect(doRefresh(&dut));

    try std.testing.expectEqual(@as(u8, 0x55), readByte(&dut, 0x200).?);
    try std.testing.expectEqual(@as(u8, 0xAA), readByte(&dut, 0x300).?);
    // Original value should still be there
    try std.testing.expectEqual(@as(u8, 0x42), readByte(&dut, 0x100).?);
    print("  interleaved operations OK\n", .{});
}
