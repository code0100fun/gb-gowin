const std = @import("std");
const dpr = @import("dual_port_ram");

// Dual-port RAM has two independent clocks (clk_a, clk_b).
// clock=null in build.zig, so we manually toggle clocks and call eval().

fn tick(dut: *dpr.Model) void {
    dut.set(.clk_a, 1);
    dut.set(.clk_b, 1);
    dut.eval();
    dut.set(.clk_a, 0);
    dut.set(.clk_b, 0);
    dut.eval();
}

fn tickA(dut: *dpr.Model) void {
    dut.set(.clk_a, 1);
    dut.eval();
    dut.set(.clk_a, 0);
    dut.eval();
}

fn tickB(dut: *dpr.Model) void {
    dut.set(.clk_b, 1);
    dut.eval();
    dut.set(.clk_b, 0);
    dut.eval();
}

test "write port A, read port B" {
    var dut = try dpr.Model.init(.{});
    defer dut.deinit();

    dut.set(.we_a, 0);
    dut.set(.we_b, 0);
    dut.set(.addr_a, 0);
    dut.set(.addr_b, 0);
    dut.set(.wdata_a, 0);
    dut.set(.wdata_b, 0);
    tick(&dut);

    dut.set(.we_a, 1);
    dut.set(.addr_a, 0x10);
    dut.set(.wdata_a, 0xCA);
    tick(&dut);

    dut.set(.we_a, 0);
    dut.set(.addr_b, 0x10);
    tick(&dut);

    try std.testing.expectEqual(@as(u64, 0xCA), dut.get(.rdata_b));
}

test "write port B, read port A" {
    var dut = try dpr.Model.init(.{});
    defer dut.deinit();

    dut.set(.we_a, 0);
    dut.set(.we_b, 0);
    tick(&dut);

    dut.set(.we_b, 1);
    dut.set(.addr_b, 0x20);
    dut.set(.wdata_b, 0xFE);
    tick(&dut);

    dut.set(.we_b, 0);
    dut.set(.addr_a, 0x20);
    tick(&dut);

    try std.testing.expectEqual(@as(u64, 0xFE), dut.get(.rdata_a));
}

test "independent simultaneous reads" {
    var dut = try dpr.Model.init(.{});
    defer dut.deinit();

    dut.set(.we_a, 0);
    dut.set(.we_b, 0);
    tick(&dut);

    // Write two different values via port A
    dut.set(.we_a, 1);
    dut.set(.addr_a, 0x30);
    dut.set(.wdata_a, 0x11);
    tick(&dut);
    dut.set(.addr_a, 0x31);
    dut.set(.wdata_a, 0x22);
    tick(&dut);
    dut.set(.we_a, 0);

    // Read both simultaneously from different ports
    dut.set(.addr_a, 0x30);
    dut.set(.addr_b, 0x31);
    tick(&dut);

    try std.testing.expectEqual(@as(u64, 0x11), dut.get(.rdata_a));
    try std.testing.expectEqual(@as(u64, 0x22), dut.get(.rdata_b));
}

test "independent clocks" {
    var dut = try dpr.Model.init(.{});
    defer dut.deinit();

    dut.set(.we_a, 0);
    dut.set(.we_b, 0);
    tick(&dut);

    // Write 0xBB at address 0x40 using port A only
    dut.set(.we_a, 1);
    dut.set(.addr_a, 0x40);
    dut.set(.wdata_a, 0xBB);
    tickA(&dut);
    dut.set(.we_a, 0);

    // Read from port B without port A ticking
    dut.set(.addr_b, 0x40);
    tickB(&dut);

    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.rdata_b));
}

test "bulk write and verify (64 addresses)" {
    var dut = try dpr.Model.init(.{});
    defer dut.deinit();

    dut.set(.we_a, 0);
    dut.set(.we_b, 0);
    tick(&dut);

    // Fill addresses 0x00-0x3F via port A with pattern ~addr
    for (0..64) |i| {
        dut.set(.we_a, 1);
        dut.set(.addr_a, @as(u8, @truncate(i)));
        dut.set(.wdata_a, @as(u8, @truncate(~i)));
        tick(&dut);
    }
    dut.set(.we_a, 0);

    // Read them all back via port B
    for (0..64) |i| {
        dut.set(.addr_b, @as(u8, @truncate(i)));
        tick(&dut);
        const expected: u64 = (~i) & 0xFF;
        try std.testing.expectEqual(expected, dut.get(.rdata_b));
    }
}
