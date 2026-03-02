const std = @import("std");
const bus = @import("bus");
const print = std.debug.print;

/// Helper: set address and device read data, then eval.
fn probe(dut: *bus.Model, addr: u16) void {
    dut.set(.cpu_addr, addr);
    dut.set(.cpu_rd, 1);
    dut.set(.cpu_wr, 0);
    dut.set(.cpu_wdata, 0);
    dut.set(.rom_rdata, 0xAA);
    dut.set(.vram_rdata, 0x77);
    dut.set(.wram_rdata, 0xBB);
    dut.set(.hram_rdata, 0xCC);
    dut.set(.io_rdata, 0xDD);
    dut.set(.ie_rdata, 0xEE);
    dut.eval();
}

test "ROM at 0x0000" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0x0000);
    try std.testing.expect(dut.get(.rom_cs) != 0);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expect(dut.get(.hram_cs) == 0);
    try std.testing.expect(dut.get(.io_cs) == 0);
    try std.testing.expect(dut.get(.ie_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0x0000), dut.get(.rom_addr));
    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.cpu_rdata));
}

test "ROM at 0x7FFF" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0x7FFF);
    try std.testing.expect(dut.get(.rom_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x7FFF), dut.get(.rom_addr));
    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.cpu_rdata));
}

test "ROM at 0x4000" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0x4000);
    try std.testing.expect(dut.get(.rom_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x4000), dut.get(.rom_addr));
}

test "VRAM at 0x8000" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0x8000);
    try std.testing.expect(dut.get(.vram_cs) != 0);
    try std.testing.expect(dut.get(.rom_cs) == 0);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expect(dut.get(.hram_cs) == 0);
    try std.testing.expect(dut.get(.io_cs) == 0);
    try std.testing.expect(dut.get(.ie_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0x0000), dut.get(.vram_addr));
    try std.testing.expectEqual(@as(u64, 0x77), dut.get(.cpu_rdata));
}

test "VRAM at 0x9FFF" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0x9FFF);
    try std.testing.expect(dut.get(.vram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x1FFF), dut.get(.vram_addr));
    try std.testing.expectEqual(@as(u64, 0x77), dut.get(.cpu_rdata));
}

test "ExtRAM stub" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xA000);
    try std.testing.expect(dut.get(.rom_cs) == 0);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0xFF), dut.get(.cpu_rdata));
}

test "WRAM at 0xC000" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xC000);
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expect(dut.get(.rom_cs) == 0);
    try std.testing.expect(dut.get(.hram_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0x0000), dut.get(.wram_addr));
    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.cpu_rdata));
}

test "WRAM at 0xC100" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xC100);
    print("    0xC100 -> wram_addr=0x{x:0>4}\n", .{@as(u16, @truncate(dut.get(.wram_addr)))});
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x0100), dut.get(.wram_addr));
}

test "WRAM at 0xDFFF" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xDFFF);
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x1FFF), dut.get(.wram_addr));
}

test "Echo RAM at 0xE000" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xE000);
    print("    Echo 0xE000 -> wram_addr=0x{x:0>4} (mirrors WRAM)\n", .{@as(u16, @truncate(dut.get(.wram_addr)))});
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x0000), dut.get(.wram_addr));
    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.cpu_rdata));
}

test "Echo RAM at 0xFDFF" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFDFF);
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x1DFF), dut.get(.wram_addr));
    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.cpu_rdata));
}

test "OAM select" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    // OAM at FE00: should assert oam_cs, not wram_cs
    probe(&dut, 0xFE00);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expect(dut.get(.oam_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.oam_addr));

    // OAM at FE9F: last OAM byte
    probe(&dut, 0xFE9F);
    try std.testing.expect(dut.get(.oam_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x9F), dut.get(.oam_addr));
}

test "unusable region" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFEA0);
    try std.testing.expectEqual(@as(u64, 0xFF), dut.get(.cpu_rdata));
}

test "I/O at 0xFF00" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFF00);
    try std.testing.expect(dut.get(.io_cs) != 0);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expect(dut.get(.hram_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.io_addr));
    try std.testing.expectEqual(@as(u64, 0xDD), dut.get(.cpu_rdata));
    try std.testing.expect(dut.get(.io_rd) != 0);
}

test "I/O at 0xFF7F" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFF7F);
    try std.testing.expect(dut.get(.io_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x7F), dut.get(.io_addr));
    try std.testing.expectEqual(@as(u64, 0xDD), dut.get(.cpu_rdata));
}

test "HRAM at 0xFF80" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFF80);
    try std.testing.expect(dut.get(.hram_cs) != 0);
    try std.testing.expect(dut.get(.io_cs) == 0);
    try std.testing.expect(dut.get(.wram_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.hram_addr));
    try std.testing.expectEqual(@as(u64, 0xCC), dut.get(.cpu_rdata));
}

test "HRAM at 0xFFFE" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFFFE);
    try std.testing.expect(dut.get(.hram_cs) != 0);
    try std.testing.expectEqual(@as(u64, 0x7E), dut.get(.hram_addr));
    try std.testing.expectEqual(@as(u64, 0xCC), dut.get(.cpu_rdata));
}

test "IE at 0xFFFF" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    probe(&dut, 0xFFFF);
    try std.testing.expect(dut.get(.ie_cs) != 0);
    try std.testing.expect(dut.get(.hram_cs) == 0);
    try std.testing.expect(dut.get(.io_cs) == 0);
    try std.testing.expectEqual(@as(u64, 0xEE), dut.get(.cpu_rdata));
}

test "WRAM write" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    dut.set(.cpu_addr, 0xC042);
    dut.set(.cpu_rd, 0);
    dut.set(.cpu_wr, 1);
    dut.set(.cpu_wdata, 0x55);
    dut.set(.wram_rdata, 0);
    dut.eval();

    print("    write 0x55 -> 0xC042: wram_addr=0x{x:0>4}, wram_we={d}\n", .{
        @as(u16, @truncate(dut.get(.wram_addr))),
        @as(u1, @truncate(dut.get(.wram_we))),
    });
    try std.testing.expect(dut.get(.wram_cs) != 0);
    try std.testing.expect(dut.get(.wram_we) != 0);
    try std.testing.expectEqual(@as(u64, 0x55), dut.get(.wram_wdata));
    try std.testing.expectEqual(@as(u64, 0x0042), dut.get(.wram_addr));
}

test "I/O write" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    dut.set(.cpu_addr, 0xFF46);
    dut.set(.cpu_rd, 0);
    dut.set(.cpu_wr, 1);
    dut.set(.cpu_wdata, 0x99);
    dut.set(.io_rdata, 0);
    dut.eval();

    try std.testing.expect(dut.get(.io_cs) != 0);
    try std.testing.expect(dut.get(.io_wr) != 0);
    try std.testing.expect(dut.get(.io_rd) == 0);
    try std.testing.expectEqual(@as(u64, 0x99), dut.get(.io_wdata));
    try std.testing.expectEqual(@as(u64, 0x46), dut.get(.io_addr));
}

test "IE write" {
    var dut = try bus.Model.init(.{});
    defer dut.deinit();

    dut.set(.cpu_addr, 0xFFFF);
    dut.set(.cpu_rd, 0);
    dut.set(.cpu_wr, 1);
    dut.set(.cpu_wdata, 0x1F);
    dut.set(.ie_rdata, 0);
    dut.eval();

    try std.testing.expect(dut.get(.ie_cs) != 0);
    try std.testing.expect(dut.get(.ie_we) != 0);
    try std.testing.expectEqual(@as(u64, 0x1F), dut.get(.ie_wdata));
}
