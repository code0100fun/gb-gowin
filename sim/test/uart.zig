const std = @import("std");
const uart_top = @import("uart_top");
const print = std.debug.print;

const CYCLES_PER_BIT = 4;
// Total frame: 1 start + 8 data + 1 stop = 10 bits × CYCLES_PER_BIT
const FRAME_CYCLES = 10 * CYCLES_PER_BIT;

fn resetDut(dut: *uart_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.tx_data, 0);
    dut.set(.tx_valid, 0);
    dut.set(.rx_pin, 1); // idle high
    dut.tick();
    dut.set(.reset, 0);
}

/// Bit-bang a byte into the RX pin at CYCLES_PER_BIT=4 timing.
fn bitBangByte(dut: *uart_top.Model, byte: u8) void {
    // Start bit (LOW)
    dut.set(.rx_pin, 0);
    for (0..CYCLES_PER_BIT) |_| dut.tick();

    // 8 data bits, LSB first
    var val = byte;
    for (0..8) |_| {
        dut.set(.rx_pin, val & 1);
        val >>= 1;
        for (0..CYCLES_PER_BIT) |_| dut.tick();
    }

    // Stop bit (HIGH)
    dut.set(.rx_pin, 1);
    for (0..CYCLES_PER_BIT) |_| dut.tick();
}

test "TX idle state" {
    // When no data is sent, TX line should be HIGH and ready should be 1.
    var dut = try uart_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Tick a few cycles in idle
    for (0..10) |_| dut.tick();

    const tx_pin: u1 = @truncate(dut.get(.tx_pin));
    const tx_ready: u1 = @truncate(dut.get(.tx_ready));
    print("  TX idle: pin={d} ready={d}\n", .{ tx_pin, tx_ready });
    try std.testing.expectEqual(@as(u1, 1), tx_pin);
    try std.testing.expectEqual(@as(u1, 1), tx_ready);
}

test "TX sends 0x55" {
    // 0x55 = 01010101 — nice alternating pattern for verification.
    // Frame: start(0) 1 0 1 0 1 0 1 0 stop(1)
    var dut = try uart_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Start transmission
    dut.set(.tx_data, 0x55);
    dut.set(.tx_valid, 1);
    dut.tick();
    dut.set(.tx_valid, 0);

    // Ready should drop
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(dut.get(.tx_ready))));

    // Capture TX pin at the start of each bit period.
    // We already consumed 1 tick (the valid tick), so we're at the start of
    // the start bit period. Sample at tick 0 of each bit.
    var bits: [10]u1 = undefined;
    for (0..10) |bit_num| {
        bits[bit_num] = @truncate(dut.get(.tx_pin));
        for (0..CYCLES_PER_BIT) |_| dut.tick();
    }

    // Expected: start=0, then LSB-first of 0x55: 1,0,1,0,1,0,1,0, stop=1
    const expected = [10]u1{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 };
    print("  TX 0x55 bits: ", .{});
    for (bits) |b| print("{d}", .{b});
    print("\n", .{});
    try std.testing.expectEqual(expected, bits);

    // Should be back to idle
    const tx_ready: u1 = @truncate(dut.get(.tx_ready));
    try std.testing.expectEqual(@as(u1, 1), tx_ready);
}

test "TX back-to-back" {
    // Send two bytes sequentially without gap.
    var dut = try uart_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Send first byte: 0xAA
    dut.set(.tx_data, 0xAA);
    dut.set(.tx_valid, 1);
    dut.tick();
    dut.set(.tx_valid, 0);

    // Wait for first frame to complete
    for (0..FRAME_CYCLES) |_| dut.tick();

    // Ready should be back
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(dut.get(.tx_ready))));

    // Send second byte: 0x55
    dut.set(.tx_data, 0x55);
    dut.set(.tx_valid, 1);
    dut.tick();
    dut.set(.tx_valid, 0);

    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(dut.get(.tx_ready))));

    // Wait for second frame
    for (0..FRAME_CYCLES) |_| dut.tick();

    // Back to idle
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(dut.get(.tx_ready))));
    print("  Back-to-back TX: both frames sent OK\n", .{});
}

test "RX receives 0xA3" {
    // Bit-bang 0xA3 = 10100011 into RX and verify decoded output.
    var dut = try uart_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Let RX synchronizer settle in idle
    for (0..4) |_| dut.tick();

    // Bit-bang inline so we can capture the valid pulse.
    // The 2-FF synchronizer delays the RX signal by 2 cycles, so valid
    // pulses a few ticks after the stop bit finishes.
    const byte: u8 = 0xA3;

    // Start bit
    dut.set(.rx_pin, 0);
    for (0..CYCLES_PER_BIT) |_| dut.tick();

    // 8 data bits, LSB first
    var val = byte;
    for (0..8) |_| {
        dut.set(.rx_pin, val & 1);
        val >>= 1;
        for (0..CYCLES_PER_BIT) |_| dut.tick();
    }

    // Stop bit + extra cycles for synchronizer delay
    dut.set(.rx_pin, 1);
    var rx_got_valid = false;
    var rx_byte: u8 = 0;
    for (0..CYCLES_PER_BIT + 10) |_| {
        dut.tick();
        if (dut.get(.rx_valid) != 0) {
            rx_got_valid = true;
            rx_byte = @truncate(dut.get(.rx_data));
        }
    }

    print("  RX 0xA3: got_valid={} data=0x{x:0>2}\n", .{ rx_got_valid, rx_byte });
    try std.testing.expect(rx_got_valid);
    try std.testing.expectEqual(@as(u8, 0xA3), rx_byte);
}

test "TX to RX loopback" {
    // Connect TX pin to RX pin in the testbench for a round-trip test.
    var dut = try uart_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const test_byte: u8 = 0x42;

    // Start TX
    dut.set(.tx_data, test_byte);
    dut.set(.tx_valid, 1);
    dut.tick();
    dut.set(.tx_valid, 0);

    // Run the loopback: on each tick, feed tx_pin back to rx_pin.
    // Give extra cycles for the RX synchronizer delay (2 FFs).
    var rx_got_valid = false;
    var rx_byte: u8 = 0;
    for (0..FRAME_CYCLES + 20) |_| {
        // Wire loopback
        dut.set(.rx_pin, dut.get(.tx_pin));
        dut.tick();

        if (dut.get(.rx_valid) != 0) {
            rx_got_valid = true;
            rx_byte = @truncate(dut.get(.rx_data));
        }
    }

    print("  Loopback: got_valid={} byte=0x{x:0>2}\n", .{ rx_got_valid, rx_byte });
    try std.testing.expect(rx_got_valid);
    try std.testing.expectEqual(test_byte, rx_byte);
}
