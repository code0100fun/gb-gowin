const std = @import("std");
const sd_reader_top = @import("sd_reader_top");
const print = std.debug.print;

fn resetDut(dut: *sd_reader_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.read_start, 0);
    dut.set(.sector, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Wait for card initialization to complete (ready=1 or error=1).
fn waitInit(dut: *sd_reader_top.Model) bool {
    var cycles: u32 = 0;
    while (dut.get(.ready) == 0 and dut.get(.err) == 0) {
        dut.tick();
        cycles += 1;
        if (cycles > 500_000) return false; // timeout
    }
    const ready: u1 = @truncate(dut.get(.ready));
    const err: u1 = @truncate(dut.get(.err));
    print("  init completed in {} cycles (ready={} err={})\n", .{ cycles, ready, err });
    return dut.get(.ready) == 1;
}

/// Read a sector and collect all 512 bytes into a buffer.
fn readSector(dut: *sd_reader_top.Model, sector_num: u32, buf: *[512]u8) bool {
    dut.set(.sector, sector_num);
    dut.set(.read_start, 1);
    dut.tick();
    dut.set(.read_start, 0);

    var byte_count: u32 = 0;
    var cycles: u32 = 0;
    while (dut.get(.read_done) == 0) {
        dut.tick();
        if (dut.get(.read_valid) == 1) {
            if (byte_count < 512) {
                buf[byte_count] = @truncate(dut.get(.read_data));
            }
            byte_count += 1;
        }
        cycles += 1;
        if (cycles > 100_000) return false; // timeout
    }
    print("  sector {} read: {} bytes in {} cycles\n", .{ sector_num, byte_count, cycles });
    return byte_count == 512;
}

test "card initialization" {
    var dut = try sd_reader_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const ok = waitInit(&dut);
    try std.testing.expect(ok);

    const ready: u1 = @truncate(dut.get(.ready));
    const err: u1 = @truncate(dut.get(.err));
    print("  ready={} error={}\n", .{ ready, err });
    try std.testing.expectEqual(@as(u1, 1), ready);
    try std.testing.expectEqual(@as(u1, 0), err);
}

test "read sector 0" {
    var dut = try sd_reader_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const init_ok = waitInit(&dut);
    try std.testing.expect(init_ok);

    var buf: [512]u8 = undefined;
    const read_ok = readSector(&dut, 0, &buf);
    try std.testing.expect(read_ok);

    // Verify pattern: byte[i] = i[7:0]
    print("  sector 0: [0]=0x{x:0>2} [1]=0x{x:0>2} [255]=0x{x:0>2} [511]=0x{x:0>2}\n", .{ buf[0], buf[1], buf[255], buf[511] });
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[255]);
    // buf[511] = 511 & 0xFF = 0xFF
    try std.testing.expectEqual(@as(u8, 0xFF), buf[511]);
}

test "read sector 1" {
    var dut = try sd_reader_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const init_ok = waitInit(&dut);
    try std.testing.expect(init_ok);

    var buf: [512]u8 = undefined;
    const read_ok = readSector(&dut, 1, &buf);
    try std.testing.expect(read_ok);

    // Sector 1 is all 0xAA
    print("  sector 1: [0]=0x{x:0>2} [256]=0x{x:0>2} [511]=0x{x:0>2}\n", .{ buf[0], buf[256], buf[511] });
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[256]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[511]);
}

test "consecutive sector reads" {
    var dut = try sd_reader_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    const init_ok = waitInit(&dut);
    try std.testing.expect(init_ok);

    var buf0: [512]u8 = undefined;
    var buf1: [512]u8 = undefined;
    const ok0 = readSector(&dut, 0, &buf0);
    const ok1 = readSector(&dut, 1, &buf1);
    try std.testing.expect(ok0);
    try std.testing.expect(ok1);

    // Verify both sectors have correct data
    try std.testing.expectEqual(@as(u8, 0x42), buf0[0x42]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf1[0]);
    print("  consecutive reads OK\n", .{});
}
