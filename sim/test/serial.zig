const std = @import("std");
const serial_top = @import("serial_top");
const print = std.debug.print;

const CLOCKS_PER_BIT = 4;

fn resetDut(dut: *serial_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.io_addr, 0);
    dut.set(.io_wr, 0);
    dut.set(.io_wdata, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Write to an I/O register.
fn writeReg(dut: *serial_top.Model, addr: u7, val: u8) void {
    dut.set(.io_addr, addr);
    dut.set(.io_wr, 1);
    dut.set(.io_wdata, val);
    dut.tick();
    dut.set(.io_wr, 0);
}

/// Read from an I/O register (combinational — needs eval to propagate).
fn readReg(dut: *serial_top.Model, addr: u7) u8 {
    dut.set(.io_addr, addr);
    dut.eval();
    return @truncate(dut.get(.io_rdata));
}

test "SB read/write" {
    var dut = try serial_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // SB defaults to 0x00 after reset
    var val = readReg(&dut, 0x01);
    print("  SB after reset: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x00), val);

    // Write 0x42 to SB, read it back
    writeReg(&dut, 0x01, 0x42);
    val = readReg(&dut, 0x01);
    print("  SB after write 0x42: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x42), val);
}

test "SC read format" {
    // Unused bits 6-1 should always read as 1.
    var dut = try serial_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // After reset: SC = 0b0_111111_0 = 0x7E
    var val = readReg(&dut, 0x02);
    print("  SC after reset: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x7E), val);

    // Write SC with bit 0 = 1 (internal clock), bit 7 = 0 (no transfer)
    writeReg(&dut, 0x02, 0x01);
    val = readReg(&dut, 0x02);
    print("  SC after write 0x01: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x7F), val);
}

test "internal transfer completes" {
    // Start an internal-clock transfer and verify:
    // - SC bit 7 clears after 8 * CLOCKS_PER_BIT cycles
    // - SB ends up as 0xFF
    var dut = try serial_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Load SB with a known pattern
    writeReg(&dut, 0x01, 0xA5);

    // Start transfer: SC bit 7=1, bit 0=1
    writeReg(&dut, 0x02, 0x81);

    // SC should show transfer in progress
    var sc = readReg(&dut, 0x02);
    print("  SC during transfer: 0x{x:0>2}\n", .{sc});
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(sc >> 7)));

    // Run for 8 * CLOCKS_PER_BIT cycles (full transfer)
    for (0..8 * CLOCKS_PER_BIT) |_| dut.tick();

    // Transfer should be complete
    sc = readReg(&dut, 0x02);
    const sb = readReg(&dut, 0x01);
    print("  SC after transfer: 0x{x:0>2} (expect bit 7 clear)\n", .{sc});
    print("  SB after transfer: 0x{x:0>2} (expect 0xFF)\n", .{sb});
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(sc >> 7)));
    try std.testing.expectEqual(@as(u8, 0xFF), sb);
}

test "serial IRQ fires exactly once" {
    var dut = try serial_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Load SB and start transfer
    writeReg(&dut, 0x01, 0x55);
    writeReg(&dut, 0x02, 0x81);

    // Count IRQ pulses through the transfer
    var irq_count: u32 = 0;
    for (0..8 * CLOCKS_PER_BIT + 10) |_| {
        dut.tick();
        if (dut.get(.dbg_irq) != 0) irq_count += 1;
    }

    print("  IRQ pulse count: {d}\n", .{irq_count});
    try std.testing.expectEqual(@as(u32, 1), irq_count);
}

test "external clock does not transfer" {
    // Setting SC bit 7=1 with bit 0=0 (external clock) should NOT
    // start a transfer since there's no external clock source.
    var dut = try serial_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Load SB with a known value
    writeReg(&dut, 0x01, 0x42);

    // Set SC bit 7=1, bit 0=0 (external clock)
    writeReg(&dut, 0x02, 0x80);

    // Run many cycles
    for (0..8 * CLOCKS_PER_BIT + 10) |_| dut.tick();

    // SB should be unchanged (no transfer happened)
    const sb = readReg(&dut, 0x01);
    const sc = readReg(&dut, 0x02);
    print("  SB after external mode: 0x{x:0>2} (expect 0x42)\n", .{sb});
    print("  SC after external mode: 0x{x:0>2}\n", .{sc});
    try std.testing.expectEqual(@as(u8, 0x42), sb);

    // SC bit 7 should still be set (waiting for external clock that never comes)
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(sc >> 7)));
}
