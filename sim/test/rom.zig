const std = @import("std");
const rom = @import("rom");
const print = std.debug.print;

// Expected contents of sim/data/test_rom.hex (16 bytes)
const EXPECTED = [16]u8{
    0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
};

test "read initialized data" {
    var dut = try rom.Model.init(.{});
    defer dut.deinit();

    for (0..16) |i| {
        dut.set(.addr, @as(u8, @truncate(i)));
        dut.tick();
        const got: u8 = @truncate(dut.get(.rdata));
        print("    addr[{d:>2}] = 0x{x:0>2} (expect 0x{x:0>2})\n", .{ i, got, EXPECTED[i] });
        try std.testing.expectEqual(@as(u64, EXPECTED[i]), dut.get(.rdata));
    }
    print("  16/16 ROM bytes match\n", .{});
}

test "re-read consistency" {
    var dut = try rom.Model.init(.{});
    defer dut.deinit();

    // Read in reverse order
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        dut.set(.addr, @as(u8, @truncate(i)));
        dut.tick();
        try std.testing.expectEqual(@as(u64, EXPECTED[i]), dut.get(.rdata));
    }
}

test "uninitialized addresses read as zero" {
    var dut = try rom.Model.init(.{});
    defer dut.deinit();

    for (16..32) |i| {
        dut.set(.addr, @as(u8, @truncate(i)));
        dut.tick();
        try std.testing.expectEqual(@as(u64, 0x00), dut.get(.rdata));
    }
}

test "synchronous read latency" {
    var dut = try rom.Model.init(.{});
    defer dut.deinit();

    // Set address to 0 and tick
    dut.set(.addr, 0);
    dut.tick();
    const val_at_0 = dut.get(.rdata);
    print("    addr=0 after tick: 0x{x:0>2}\n", .{@as(u8, @truncate(val_at_0))});

    // Change address to 5 — output should NOT change until the next tick
    dut.set(.addr, 5);
    dut.eval();
    print("    addr=5 before tick (should still be old): 0x{x:0>2}\n", .{@as(u8, @truncate(dut.get(.rdata)))});
    try std.testing.expectEqual(val_at_0, dut.get(.rdata));

    // Now tick — output should update
    dut.tick();
    print("    addr=5 after tick: 0x{x:0>2} (expect 0x{x:0>2})\n", .{ @as(u8, @truncate(dut.get(.rdata))), EXPECTED[5] });
    try std.testing.expectEqual(@as(u64, EXPECTED[5]), dut.get(.rdata));
}
