const std = @import("std");
const ram = @import("single_port_ram");

test "write then read" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    dut.set(.we, 1);
    dut.set(.addr, 0x00);
    dut.set(.wdata, 0xAB);
    dut.tick();

    dut.set(.we, 0);
    dut.set(.addr, 0x00);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0xAB), dut.get(.rdata));
}

test "multiple addresses" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    // Write pattern
    for (0..16) |i| {
        dut.set(.we, 1);
        dut.set(.addr, @as(u8, @truncate(i)));
        dut.set(.wdata, @as(u8, @truncate(i * 7 + 3)));
        dut.tick();
    }

    // Read back
    dut.set(.we, 0);
    for (0..16) |i| {
        dut.set(.addr, @as(u8, @truncate(i)));
        dut.tick();
        const expected: u64 = (i * 7 + 3) & 0xFF;
        try std.testing.expectEqual(expected, dut.get(.rdata));
    }
}

test "overwrite" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    // Write initial value
    dut.set(.we, 1);
    dut.set(.addr, 0x05);
    dut.set(.wdata, 0x42);
    dut.tick();

    // Overwrite
    dut.set(.we, 1);
    dut.set(.addr, 0x05);
    dut.set(.wdata, 0xFF);
    dut.tick();

    // Read back
    dut.set(.we, 0);
    dut.set(.addr, 0x05);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0xFF), dut.get(.rdata));
}

test "write-enable gating" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    // Write 0xFF
    dut.set(.we, 1);
    dut.set(.addr, 0x05);
    dut.set(.wdata, 0xFF);
    dut.tick();

    // Attempt write with we=0
    dut.set(.we, 0);
    dut.set(.addr, 0x05);
    dut.set(.wdata, 0x00);
    dut.tick();

    // Read back — should still be 0xFF
    dut.set(.addr, 0x05);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0xFF), dut.get(.rdata));
}

test "read-first behavior" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    // Write 0x42
    dut.set(.we, 1);
    dut.set(.addr, 0x0A);
    dut.set(.wdata, 0x42);
    dut.tick();

    // Simultaneous read+write: output should be OLD value
    dut.set(.we, 1);
    dut.set(.addr, 0x0A);
    dut.set(.wdata, 0x99);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0x42), dut.get(.rdata));

    // Next cycle should show new value
    dut.set(.we, 0);
    dut.set(.addr, 0x0A);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0x99), dut.get(.rdata));
}
