const std = @import("std");
const debug_console_top = @import("debug_console_top");
const print = std.debug.print;

const CYCLES_PER_BIT = 4;
const FRAME_TICKS = 10 * CYCLES_PER_BIT; // 1 start + 8 data + 1 stop

fn resetDut(dut: *debug_console_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.uart_rx_pin, 1); // idle high
    dut.set(.dbg_pc, 0);
    dut.set(.dbg_sp, 0);
    dut.set(.dbg_a, 0);
    dut.set(.dbg_f, 0);
    dut.set(.dbg_b, 0);
    dut.set(.dbg_c, 0);
    dut.set(.dbg_d, 0);
    dut.set(.dbg_e, 0);
    dut.set(.dbg_h, 0);
    dut.set(.dbg_l, 0);
    dut.set(.dbg_halted, 0);
    dut.set(.dbg_if, 0);
    dut.set(.dbg_ie, 0);
    dut.tick();
    dut.set(.reset, 0);
    // Let synchronizer settle
    for (0..4) |_| dut.tick();
}

/// Bit-bang a byte into the UART RX pin at CYCLES_PER_BIT=4 timing.
fn sendByte(dut: *debug_console_top.Model, byte: u8) void {
    // Start bit
    dut.set(.uart_rx_pin, 0);
    for (0..CYCLES_PER_BIT) |_| dut.tick();

    // 8 data bits, LSB first
    var val = byte;
    for (0..8) |_| {
        dut.set(.uart_rx_pin, val & 1);
        val >>= 1;
        for (0..CYCLES_PER_BIT) |_| dut.tick();
    }

    // Stop bit — only half to avoid missing the response start bit.
    // The internal RX samples at mid-bit, so half a bit period is enough
    // for the stop bit to be recognized.
    dut.set(.uart_rx_pin, 1);
    for (0..CYCLES_PER_BIT / 2) |_| dut.tick();
}

/// Receive a byte from the UART TX pin by sampling at mid-bit.
/// Returns null if no start bit detected within `timeout` ticks.
fn receiveByte(dut: *debug_console_top.Model, timeout: u32) ?u8 {
    // Wait for falling edge (start bit)
    var prev: u1 = 1;
    for (0..timeout) |_| {
        dut.tick();
        const cur: u1 = @truncate(dut.get(.uart_tx_pin));
        if (prev == 1 and cur == 0) {
            // Found start bit — wait to mid-bit
            for (0..CYCLES_PER_BIT / 2 - 1) |_| dut.tick();

            // Sample 8 data bits at mid-bit
            var byte: u8 = 0;
            for (0..8) |bit_num| {
                for (0..CYCLES_PER_BIT) |_| dut.tick();
                const b: u1 = @truncate(dut.get(.uart_tx_pin));
                byte |= @as(u8, b) << @intCast(bit_num);
            }

            // Wait through stop bit
            for (0..CYCLES_PER_BIT) |_| dut.tick();

            return byte;
        }
        prev = cur;
    }
    return null;
}

/// Receive a complete string response up to `max_len` bytes.
fn receiveString(dut: *debug_console_top.Model, buf: []u8) []u8 {
    var len: usize = 0;
    while (len < buf.len) {
        // First byte needs longer timeout to account for console processing
        const timeout: u32 = if (len == 0) FRAME_TICKS * 10 else FRAME_TICKS * 3;
        const byte = receiveByte(dut, timeout) orelse break;
        buf[len] = byte;
        len += 1;
    }
    return buf[0..len];
}

test "'?' command returns help" {
    var dut = try debug_console_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    sendByte(&dut, '?');

    var buf: [64]u8 = undefined;
    const resp = receiveString(&dut, &buf);

    print("  '?' response ({d} bytes): \"{s}\"\n", .{ resp.len, resp });
    try std.testing.expectEqualStrings("cmds: ? p r\r\n", resp);
}

test "'p' command returns PC" {
    var dut = try debug_console_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Set PC to 0x1234
    dut.set(.dbg_pc, 0x1234);
    dut.tick();

    sendByte(&dut, 'p');

    var buf: [64]u8 = undefined;
    const resp = receiveString(&dut, &buf);

    print("  'p' response ({d} bytes): \"{s}\"\n", .{ resp.len, resp });
    try std.testing.expectEqualStrings("PC=1234\r\n", resp);
}

test "'r' command returns full register dump" {
    var dut = try debug_console_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Set known register values
    dut.set(.dbg_a, 0xAB);
    dut.set(.dbg_f, 0xCD);
    dut.set(.dbg_b, 0x01);
    dut.set(.dbg_c, 0x23);
    dut.set(.dbg_d, 0x45);
    dut.set(.dbg_e, 0x67);
    dut.set(.dbg_h, 0x89);
    dut.set(.dbg_l, 0xEF);
    dut.set(.dbg_sp, 0xFFFE);
    dut.set(.dbg_pc, 0x0150);
    dut.set(.dbg_if, 0xE1);
    dut.set(.dbg_ie, 0x0F);
    dut.tick();

    sendByte(&dut, 'r');

    var buf: [128]u8 = undefined;
    const resp = receiveString(&dut, &buf);

    const expected = "A=AB F=CD BC=0123 DE=4567 HL=89EF SP=FFFE PC=0150 IF=E1 IE=0F\r\n";
    print("  'r' response ({d} bytes): \"{s}\"\n", .{ resp.len, resp });
    try std.testing.expectEqualStrings(expected, resp);
}

test "unknown command produces no response" {
    var dut = try debug_console_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    sendByte(&dut, 'x');

    // TX should stay idle (HIGH) — no response.
    // Try to receive a byte with a short timeout.
    const byte = receiveByte(&dut, FRAME_TICKS * 3);
    print("  'x' response: {?}\n", .{byte});
    try std.testing.expectEqual(@as(?u8, null), byte);
}
