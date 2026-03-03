const std = @import("std");
const sd_spi_top = @import("sd_spi_top");
const print = std.debug.print;

fn resetDut(dut: *sd_spi_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.start, 0);
    dut.set(.cs_en, 0);
    dut.set(.slow_clk, 0);
    dut.set(.tx_data, 0);
    dut.set(.miso_in, 1);
    dut.tick();
    dut.set(.reset, 0);
}

/// Send a byte and return the received byte (fast clock, ÷4).
fn sendByte(dut: *sd_spi_top.Model, tx: u8, miso_val: u1) u8 {
    dut.set(.tx_data, tx);
    dut.set(.miso_in, miso_val);
    dut.set(.start, 1);
    dut.tick();
    dut.set(.start, 0);

    // Wait for done (each bit takes 4 system clocks, 8 bits = 32 clocks)
    var cycles: u32 = 0;
    while (dut.get(.done) == 0) {
        dut.tick();
        cycles += 1;
        if (cycles > 100) break;
    }
    return @truncate(dut.get(.rx_data));
}

/// Send a byte at slow clock (÷64).
fn sendByteSlow(dut: *sd_spi_top.Model, tx: u8, miso_val: u1) u8 {
    dut.set(.tx_data, tx);
    dut.set(.miso_in, miso_val);
    dut.set(.slow_clk, 1);
    dut.set(.start, 1);
    dut.tick();
    dut.set(.start, 0);

    var cycles: u32 = 0;
    while (dut.get(.done) == 0) {
        dut.tick();
        cycles += 1;
        if (cycles > 1000) break;
    }
    dut.set(.slow_clk, 0);
    return @truncate(dut.get(.rx_data));
}

test "fast clock byte transfer" {
    var dut = try sd_spi_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    dut.set(.cs_en, 1);
    dut.tick();

    // Send 0xA5 with MISO tied high — should receive 0xFF
    const rx = sendByte(&dut, 0xA5, 1);
    print("  TX=0xA5, RX=0x{x:0>2} (expect 0xFF with MISO=1)\n", .{rx});
    try std.testing.expectEqual(@as(u8, 0xFF), rx);
}

test "fast clock MISO sampling" {
    var dut = try sd_spi_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    dut.set(.cs_en, 1);
    dut.tick();

    // Send 0xFF with MISO tied low — should receive 0x00
    const rx = sendByte(&dut, 0xFF, 0);
    print("  TX=0xFF, RX=0x{x:0>2} (expect 0x00 with MISO=0)\n", .{rx});
    try std.testing.expectEqual(@as(u8, 0x00), rx);
}

test "slow clock byte transfer" {
    var dut = try sd_spi_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    dut.set(.cs_en, 1);
    dut.tick();

    // Slow clock: send 0x55 with MISO high
    const rx = sendByteSlow(&dut, 0x55, 1);
    print("  slow TX=0x55, RX=0x{x:0>2} (expect 0xFF)\n", .{rx});
    try std.testing.expectEqual(@as(u8, 0xFF), rx);
}

test "CS control" {
    var dut = try sd_spi_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // CS should be deasserted (high) initially
    dut.eval();
    const cs_init: u1 = @truncate(dut.get(.cs_n_out));
    print("  CS after reset: {} (expect 1)\n", .{cs_init});
    try std.testing.expectEqual(@as(u1, 1), cs_init);

    // Assert CS
    dut.set(.cs_en, 1);
    dut.eval();
    const cs_assert: u1 = @truncate(dut.get(.cs_n_out));
    print("  CS after cs_en=1: {} (expect 0)\n", .{cs_assert});
    try std.testing.expectEqual(@as(u1, 0), cs_assert);

    // Deassert CS
    dut.set(.cs_en, 0);
    dut.eval();
    const cs_deassert: u1 = @truncate(dut.get(.cs_n_out));
    print("  CS after cs_en=0: {} (expect 1)\n", .{cs_deassert});
    try std.testing.expectEqual(@as(u1, 1), cs_deassert);
}

test "idle state" {
    var dut = try sd_spi_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // After reset: SCLK=0, MOSI=1, not busy
    dut.eval();
    const sclk: u1 = @truncate(dut.get(.sclk_out));
    const mosi: u1 = @truncate(dut.get(.mosi_out));
    const busy: u1 = @truncate(dut.get(.busy));
    print("  idle: SCLK={} MOSI={} busy={} (expect 0, 1, 0)\n", .{ sclk, mosi, busy });
    try std.testing.expectEqual(@as(u1, 0), sclk);
    try std.testing.expectEqual(@as(u1, 1), mosi);
    try std.testing.expectEqual(@as(u1, 0), busy);
}
