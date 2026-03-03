const std = @import("std");
const mbc1_top = @import("mbc1_top");
const print = std.debug.print;

fn resetDut(dut: *mbc1_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.cpu_addr, 0);
    dut.set(.cpu_rd, 0);
    dut.set(.cpu_wr, 0);
    dut.set(.cpu_wdata, 0);
    dut.tick();
    dut.set(.reset, 0);
}

/// Write to an MBC1 register (writes to ROM space 0000-7FFF).
fn mbcWrite(dut: *mbc1_top.Model, addr: u16, val: u8) void {
    dut.set(.cpu_addr, addr);
    dut.set(.cpu_wr, 1);
    dut.set(.cpu_wdata, val);
    dut.tick();
    dut.set(.cpu_wr, 0);
}

/// Read from an address (combinational — set addr, eval, read result).
fn readAddr(dut: *mbc1_top.Model, addr: u16) u8 {
    dut.set(.cpu_addr, addr);
    dut.set(.cpu_rd, 1);
    dut.set(.cpu_wr, 0);
    dut.eval();
    return @truncate(dut.get(.cpu_rdata));
}

/// Get the current translated ROM address after setting cpu_addr.
fn getRomAddr(dut: *mbc1_top.Model, addr: u16) u21 {
    dut.set(.cpu_addr, addr);
    dut.eval();
    return @truncate(dut.get(.dbg_rom_addr));
}

/// Get the current translated ExtRAM address after setting cpu_addr.
fn getExtramAddr(dut: *mbc1_top.Model, addr: u16) u15 {
    dut.set(.cpu_addr, addr);
    dut.eval();
    return @truncate(dut.get(.dbg_extram_addr));
}

test "power-on defaults" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_rom_bank));
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_bank));
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_bank_mode));
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_en));
    print("  defaults: rom_bank=0 ram_bank=0 mode=0 ram_en=0\n", .{});
}

test "bank 0 window reads bank 0" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // 0000-3FFF should map to ROM bank 0.
    // rom_addr = {2'b00, 5'b00000, cpu_addr[13:0]}
    const addr = getRomAddr(&dut, 0x0000);
    print("  rom_addr for 0x0000: 0x{x:0>6}\n", .{addr});
    try std.testing.expectEqual(@as(u21, 0x000000), addr);

    const addr2 = getRomAddr(&dut, 0x3FFF);
    print("  rom_addr for 0x3FFF: 0x{x:0>6}\n", .{addr2});
    try std.testing.expectEqual(@as(u21, 0x003FFF), addr2);

    // Verify ROM data: rom_mem[i] = i[7:0], so byte at 0x0042 = 0x42
    const val = readAddr(&dut, 0x0042);
    print("  ROM[0x0042] = 0x{x:0>2} (expect 0x42)\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x42), val);
}

test "bank 0 to 1 fixup" {
    // Writing 0 to ROM bank register: 4000-7FFF should use bank 1, not 0.
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // rom_bank defaults to 0, which maps to bank 1
    // rom_addr for 0x4000 = {2'b00, 5'b00001, 14'h0000} = 0x004000
    const addr = getRomAddr(&dut, 0x4000);
    print("  rom_addr for 0x4000 (bank 0→1): 0x{x:0>6}\n", .{addr});
    try std.testing.expectEqual(@as(u21, 0x004000), addr);

    // Explicitly write 0 — same result
    mbcWrite(&dut, 0x2000, 0x00);
    const addr2 = getRomAddr(&dut, 0x4000);
    print("  rom_addr after write 0: 0x{x:0>6}\n", .{addr2});
    try std.testing.expectEqual(@as(u21, 0x004000), addr2);
}

test "ROM bank switch" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Select ROM bank 5
    mbcWrite(&dut, 0x2000, 0x05);
    try std.testing.expectEqual(@as(u64, 5), dut.get(.dbg_rom_bank));

    // rom_addr for 0x4000 = {2'b00, 5'b00101, 14'h0000} = 0x014000
    const addr = getRomAddr(&dut, 0x4000);
    print("  rom_addr for 0x4000 (bank 5): 0x{x:0>6}\n", .{addr});
    try std.testing.expectEqual(@as(u21, 0x014000), addr);

    // Verify data: rom_mem is only 32KB, so rom_addr 0x014000 wraps.
    // The test wrapper indexes rom_mem[mbc_rom_addr[$clog2(32768)-1:0]]
    // = rom_mem[0x014000 & 0x7FFF] = rom_mem[0x4000]
    // rom_mem[0x4000] = 0x4000[7:0] = 0x00
    const val = readAddr(&dut, 0x4000);
    print("  ROM data at bank 5, offset 0: 0x{x:0>2}\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x00), val);
}

test "only 5 bits for rom_bank" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Write 0xFF — only lower 5 bits should be stored
    mbcWrite(&dut, 0x2000, 0xFF);
    const bank: u8 = @truncate(dut.get(.dbg_rom_bank));
    print("  rom_bank after write 0xFF: 0x{x:0>2} (expect 0x1F)\n", .{bank});
    try std.testing.expectEqual(@as(u8, 0x1F), bank);
}

test "upper ROM bits via ram_bank" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Set rom_bank=3, ram_bank=2
    mbcWrite(&dut, 0x2000, 0x03);
    mbcWrite(&dut, 0x4000, 0x02);

    // rom_addr for 0x4000 = {2'b10, 5'b00011, 14'h0000}
    // = (2 << 19) | (3 << 14) = 0x10C000
    const addr = getRomAddr(&dut, 0x4000);
    print("  rom_addr for ram_bank=2, rom_bank=3: 0x{x:0>6}\n", .{addr});
    try std.testing.expectEqual(@as(u21, 0x10C000), addr);
}

test "mode 1 bank 0 window uses upper bits" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Set ram_bank=2, bank_mode=1
    mbcWrite(&dut, 0x4000, 0x02);
    mbcWrite(&dut, 0x6000, 0x01);

    // 0000-3FFF in mode 1: rom_addr = {ram_bank, 5'b0, addr[13:0]}
    // = {2'b10, 5'b00000, 14'h0000} = (2 << 19) = 0x100000
    const addr = getRomAddr(&dut, 0x0000);
    print("  rom_addr for 0x0000 mode 1, ram_bank=2: 0x{x:0>6}\n", .{addr});
    try std.testing.expectEqual(@as(u21, 0x100000), addr);

    // 0x3FFF should be 0x103FFF
    const addr2 = getRomAddr(&dut, 0x3FFF);
    print("  rom_addr for 0x3FFF: 0x{x:0>6}\n", .{addr2});
    try std.testing.expectEqual(@as(u21, 0x103FFF), addr2);
}

test "RAM enable and disable" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // RAM disabled by default
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_en));

    // Write 0x0A to 0000-1FFF → enable
    mbcWrite(&dut, 0x0000, 0x0A);
    try std.testing.expectEqual(@as(u64, 1), dut.get(.dbg_ram_en));
    print("  ram_en after 0x0A: 1\n", .{});

    // Write 0x0B → disable (lower nibble != 0xA)
    mbcWrite(&dut, 0x1FFF, 0x0B);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_en));
    print("  ram_en after 0x0B: 0\n", .{});

    // Write 0x3A → enable (lower nibble == 0xA)
    mbcWrite(&dut, 0x0000, 0x3A);
    try std.testing.expectEqual(@as(u64, 1), dut.get(.dbg_ram_en));
    print("  ram_en after 0x3A: 1\n", .{});

    // Write 0x00 → disable
    mbcWrite(&dut, 0x0000, 0x00);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_en));
    print("  ram_en after 0x00: 0\n", .{});
}

test "ExtRAM write and read" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Enable RAM
    mbcWrite(&dut, 0x0000, 0x0A);

    // Write 0x42 to A000
    dut.set(.cpu_addr, 0xA000);
    dut.set(.cpu_wr, 1);
    dut.set(.cpu_wdata, 0x42);
    dut.tick();
    dut.set(.cpu_wr, 0);

    // Read back
    const val = readAddr(&dut, 0xA000);
    print("  ExtRAM[0xA000] = 0x{x:0>2} (expect 0x42)\n", .{val});
    try std.testing.expectEqual(@as(u8, 0x42), val);

    // Different address should still be 0x00
    const val2 = readAddr(&dut, 0xA001);
    print("  ExtRAM[0xA001] = 0x{x:0>2} (expect 0x00)\n", .{val2});
    try std.testing.expectEqual(@as(u8, 0x00), val2);
}

test "ExtRAM disabled returns 0xFF" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // RAM disabled (default) — reads should return 0xFF
    const val = readAddr(&dut, 0xA000);
    print("  ExtRAM disabled read: 0x{x:0>2} (expect 0xFF)\n", .{val});
    try std.testing.expectEqual(@as(u8, 0xFF), val);
}

test "RAM banking in mode 1" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Enable RAM, set ram_bank=1, mode=1
    mbcWrite(&dut, 0x0000, 0x0A);
    mbcWrite(&dut, 0x4000, 0x01);
    mbcWrite(&dut, 0x6000, 0x01);

    // Mode 1: extram_addr = {ram_bank, cpu_addr[12:0]}
    // For A000: {2'b01, 13'h0000} = 0x2000
    const addr = getExtramAddr(&dut, 0xA000);
    print("  extram_addr for A000, bank 1: 0x{x:0>4}\n", .{addr});
    try std.testing.expectEqual(@as(u15, 0x2000), addr);

    // Mode 0: extram_addr = {2'b00, cpu_addr[12:0]} = 0x0000
    mbcWrite(&dut, 0x6000, 0x00);
    const addr2 = getExtramAddr(&dut, 0xA000);
    print("  extram_addr for A000, mode 0: 0x{x:0>4}\n", .{addr2});
    try std.testing.expectEqual(@as(u15, 0x0000), addr2);
}

test "writes above 0x7FFF do not affect MBC registers" {
    var dut = try mbc1_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Write to 0x8000 should NOT change any MBC register
    mbcWrite(&dut, 0x8000, 0x0A);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_ram_en));

    mbcWrite(&dut, 0xA000, 0x05);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_rom_bank));
    print("  writes to 8000+: no effect on MBC regs\n", .{});
}
