const std = @import("std");
const ppu_top = @import("ppu_top");
const print = std.debug.print;

// PPU register I/O addresses (relative to FF00)
const LCDC: u7 = 0x40;
const STAT: u7 = 0x41;
const SCY: u7 = 0x42;
const SCX: u7 = 0x43;
const LY: u7 = 0x44;
const LYC: u7 = 0x45;
const BGP: u7 = 0x47;
const WY: u7 = 0x4A;
const WX: u7 = 0x4B;

fn resetDut(dut: *ppu_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.pixel_fetch, 0);
    dut.tick();
    dut.set(.reset, 0);
    // Clear control signals after reset
    dut.set(.vram_wr, 0);
    dut.set(.io_wr, 0);
    dut.tick();
}

/// Write a byte to VRAM at the given 13-bit offset.
fn writeVram(dut: *ppu_top.Model, addr: u13, data: u8) void {
    dut.set(.vram_addr, addr);
    dut.set(.vram_wdata, data);
    dut.set(.vram_wr, 1);
    dut.tick();
    dut.set(.vram_wr, 0);
}

/// Write a PPU register.
fn writeReg(dut: *ppu_top.Model, addr: u7, data: u8) void {
    dut.set(.io_addr, addr);
    dut.set(.io_wdata, data);
    dut.set(.io_wr, 1);
    dut.tick();
    dut.set(.io_wr, 0);
}

/// Fetch the pixel output at (x, y) using the BSRAM pipeline.
/// Pulses pixel_fetch, then ticks until pixel_data_valid is asserted.
fn getPixel(dut: *ppu_top.Model, x: u8, y: u8) u16 {
    dut.set(.pixel_x, x);
    dut.set(.pixel_y, y);
    dut.set(.pixel_fetch, 1);
    dut.tick();
    dut.set(.pixel_fetch, 0);
    // Wait for pipeline to complete (BG=4 cycles, BG+Win=7 cycles)
    for (0..16) |_| {
        if (dut.get(.pixel_data_valid) != 0) break;
        dut.tick();
    }
    return @truncate(dut.get(.pixel_data));
}

/// Write a complete 8x8 tile (16 bytes) to VRAM at the given tile index
/// using unsigned addressing (base 0x0000, i.e. 0x8000 in CPU space).
fn writeTile(dut: *ppu_top.Model, tile_idx: u8, data: [16]u8) void {
    const base: u13 = @as(u13, tile_idx) * 16;
    for (data, 0..) |byte, i| {
        writeVram(dut, base + @as(u13, @intCast(i)), byte);
    }
}

/// Write a tile map entry. map_select: 0 = map at 0x1800, 1 = map at 0x1C00.
fn writeMapEntry(dut: *ppu_top.Model, map_select: u1, col: u5, row: u5, tile_idx: u8) void {
    const base: u13 = if (map_select == 0) 0x1800 else 0x1C00;
    const offset: u13 = @as(u13, row) * 32 + @as(u13, col);
    writeVram(dut, base + offset, tile_idx);
}

test "LCD off outputs white" {
    // When LCDC.7 = 0 (LCD off), pixel output should be white (0xFFFF)
    // regardless of VRAM contents.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // LCDC = 0x00 (LCD off) — default after reset
    const px = getPixel(&dut, 0, 0);
    print("  LCD off: pixel(0,0) = 0x{x:0>4}\n", .{px});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px);

    // Check a few more positions
    try std.testing.expectEqual(@as(u16, 0xFFFF), getPixel(&dut, 80, 72));
    try std.testing.expectEqual(@as(u16, 0xFFFF), getPixel(&dut, 159, 143));
}

test "solid color tile" {
    // Fill tile 0 with all-1s in both bitplanes (color ID 3 = black with
    // default BGP 0xFC). Set tile map entry (0,0) -> tile 0. Verify pixels
    // in the first 8x8 block are all black (0x0000).
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Write tile 0: all rows = 0xFF for both low and high planes
    const tile_data = [16]u8{
        0xFF, 0xFF, // row 0
        0xFF, 0xFF, // row 1
        0xFF, 0xFF, // row 2
        0xFF, 0xFF, // row 3
        0xFF, 0xFF, // row 4
        0xFF, 0xFF, // row 5
        0xFF, 0xFF, // row 6
        0xFF, 0xFF, // row 7
    };
    writeTile(&dut, 0, tile_data);

    // Set tile map 0 entry (0,0) -> tile 0
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Enable LCD + BG, unsigned tile data, BG map 0
    // LCDC = 0x91: bit7=LCD on, bit4=tile data 8000, bit0=BG on
    writeReg(&dut, LCDC, 0x91);

    // Default BGP = 0xFC: color0=00(white), color1=11(black), color2=11(black), color3=11(black)
    // So color 3 -> shade 3 -> black (0x0000).

    const px00 = getPixel(&dut, 0, 0);
    print("  Solid tile: pixel(0,0) = 0x{x:0>4}\n", .{px00});
    try std.testing.expectEqual(@as(u16, 0x0000), px00);

    try std.testing.expectEqual(@as(u16, 0x0000), getPixel(&dut, 7, 7));
    try std.testing.expectEqual(@as(u16, 0x0000), getPixel(&dut, 3, 5));
}

test "2bpp tile decode" {
    // Write a tile with a known pattern and verify individual pixel colors.
    // Row 0: lo=0b10101010, hi=0b11001100
    //   pixel 0 (bit7): hi=1, lo=1 -> color 3
    //   pixel 1 (bit6): hi=1, lo=0 -> color 2
    //   pixel 2 (bit5): hi=0, lo=1 -> color 1
    //   pixel 3 (bit4): hi=0, lo=0 -> color 0
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Tile 1, row 0: lo=0xAA, hi=0xCC, rest zeros
    var tile_data = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    tile_data[0] = 0xAA; // row 0 low plane
    tile_data[1] = 0xCC; // row 0 high plane
    writeTile(&dut, 1, tile_data);

    // Set tile map 0 entry (0,0) -> tile 1
    writeMapEntry(&dut, 0, 0, 0, 1);

    // LCDC = 0x91 (LCD on, unsigned tile data, BG on)
    writeReg(&dut, LCDC, 0x91);

    // Set BGP = 0xE4 -> identity palette: color0=0, color1=1, color2=2, color3=3
    writeReg(&dut, BGP, 0xE4);

    // pixel(0,0) -> tile_pixel(0,0) -> color 3 -> shade 3 -> black
    const px0 = getPixel(&dut, 0, 0);
    print("  2bpp: pixel(0,0)=0x{x:0>4} (expect black 0x0000)\n", .{px0});
    try std.testing.expectEqual(@as(u16, 0x0000), px0);

    // pixel(1,0) -> tile_pixel(1,0) -> color 2 -> shade 2 -> dark gray
    const px1 = getPixel(&dut, 1, 0);
    print("  2bpp: pixel(1,0)=0x{x:0>4} (expect dark gray 0x52AA)\n", .{px1});
    try std.testing.expectEqual(@as(u16, 0x52AA), px1);

    // pixel(2,0) -> tile_pixel(2,0) -> color 1 -> shade 1 -> light gray
    const px2 = getPixel(&dut, 2, 0);
    print("  2bpp: pixel(2,0)=0x{x:0>4} (expect light gray 0xAD55)\n", .{px2});
    try std.testing.expectEqual(@as(u16, 0xAD55), px2);

    // pixel(3,0) -> tile_pixel(3,0) -> color 0 -> shade 0 -> white
    const px3 = getPixel(&dut, 3, 0);
    print("  2bpp: pixel(3,0)=0x{x:0>4} (expect white 0xFFFF)\n", .{px3});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px3);
}

test "BGP palette mapping" {
    // Use a tile with all-color-1 pixels, then change BGP to map color 1
    // to different shades.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Tile 0: all lo=0xFF, hi=0x00 -> color ID 1 for every pixel
    const tile_data = [16]u8{
        0xFF, 0x00, // row 0: lo=FF hi=00 -> color 1
        0xFF, 0x00, // row 1
        0xFF, 0x00, // row 2
        0xFF, 0x00, // row 3
        0xFF, 0x00, // row 4
        0xFF, 0x00, // row 5
        0xFF, 0x00, // row 6
        0xFF, 0x00, // row 7
    };
    writeTile(&dut, 0, tile_data);
    writeMapEntry(&dut, 0, 0, 0, 0);
    writeReg(&dut, LCDC, 0x91);

    // BGP = 0xE4 (identity): color 1 -> shade 1 -> light gray (0xAD55)
    writeReg(&dut, BGP, 0xE4);
    const px_identity = getPixel(&dut, 0, 0);
    print("  BGP identity: color1 -> 0x{x:0>4} (expect 0xAD55)\n", .{px_identity});
    try std.testing.expectEqual(@as(u16, 0xAD55), px_identity);

    // BGP = 0xE0 -> color 1 maps to shade 0 (white, 0xFFFF)
    writeReg(&dut, BGP, 0xE0);
    const px_white = getPixel(&dut, 0, 0);
    print("  BGP remapped: color1 -> 0x{x:0>4} (expect 0xFFFF)\n", .{px_white});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_white);

    // BGP = 0xEC -> color 1 maps to shade 3 (black, 0x0000)
    writeReg(&dut, BGP, 0xEC);
    const px_black = getPixel(&dut, 0, 0);
    print("  BGP remapped: color1 -> 0x{x:0>4} (expect 0x0000)\n", .{px_black});
    try std.testing.expectEqual(@as(u16, 0x0000), px_black);
}

test "SCX/SCY scrolling" {
    // Place two different tiles at adjacent map positions:
    //   tile map (0,0) -> tile 0 (all white, color 0)
    //   tile map (1,0) -> tile 1 (all black, color 3)
    // With SCX=0: pixel(0,0) comes from tile 0 -> white
    // With SCX=8: pixel(0,0) comes from tile 1 -> black
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Tile 0: all zeros -> color 0
    writeTile(&dut, 0, [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    // Tile 1: all 0xFF -> color 3
    writeTile(&dut, 1, [16]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // Map: (0,0)->tile 0, (1,0)->tile 1
    writeMapEntry(&dut, 0, 0, 0, 0);
    writeMapEntry(&dut, 0, 1, 0, 1);

    writeReg(&dut, LCDC, 0x91);
    writeReg(&dut, BGP, 0xE4); // identity palette

    // SCX=0, SCY=0: pixel(0,0) -> tile map (0,0) -> tile 0 -> color 0 -> white
    writeReg(&dut, SCX, 0);
    writeReg(&dut, SCY, 0);
    const px_no_scroll = getPixel(&dut, 0, 0);
    print("  No scroll: pixel(0,0) = 0x{x:0>4} (expect white 0xFFFF)\n", .{px_no_scroll});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_no_scroll);

    // SCX=8: pixel(0,0) -> bg_x = 0+8 = 8 -> tile map col=1 -> tile 1 -> color 3 -> black
    writeReg(&dut, SCX, 8);
    const px_scroll_x = getPixel(&dut, 0, 0);
    print("  SCX=8: pixel(0,0) = 0x{x:0>4} (expect black 0x0000)\n", .{px_scroll_x});
    try std.testing.expectEqual(@as(u16, 0x0000), px_scroll_x);

    // SCY=8: pixel(0,0) -> bg_y = 0+8 = 8 -> tile map row=1 -> default tile (0) -> color 0 -> white
    writeReg(&dut, SCX, 0);
    writeReg(&dut, SCY, 8);
    const px_scroll_y = getPixel(&dut, 0, 0);
    print("  SCY=8: pixel(0,0) = 0x{x:0>4} (expect white 0xFFFF)\n", .{px_scroll_y});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_scroll_y);
}

test "tile data addressing modes" {
    // LCDC.4=1 (unsigned, base 0x0000): tile index 0 -> VRAM 0x0000
    // LCDC.4=0 (signed, base 0x1000): tile index 0 -> VRAM 0x1000
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Write tile at VRAM 0x0000 (tile 0 in unsigned mode): all color 3 (black)
    writeTile(&dut, 0, [16]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // Write tile at VRAM 0x1000 (tile 0 in signed mode): all color 1
    for (0..8) |row| {
        const base: u13 = 0x1000 + @as(u13, @intCast(row)) * 2;
        writeVram(&dut, base, 0xFF); // lo plane
        writeVram(&dut, base + 1, 0x00); // hi plane
    }

    // Map entry (0,0) -> tile 0
    writeMapEntry(&dut, 0, 0, 0, 0);

    writeReg(&dut, BGP, 0xE4); // identity palette

    // Test unsigned mode (LCDC.4=1): tile 0 -> VRAM 0x0000 -> color 3 -> black
    writeReg(&dut, LCDC, 0x91); // bit4=1
    const px_unsigned = getPixel(&dut, 0, 0);
    print("  Unsigned mode: pixel(0,0) = 0x{x:0>4} (expect black 0x0000)\n", .{px_unsigned});
    try std.testing.expectEqual(@as(u16, 0x0000), px_unsigned);

    // Test signed mode (LCDC.4=0): tile 0 -> VRAM 0x1000 -> color 1 -> light gray
    writeReg(&dut, LCDC, 0x81); // bit4=0, bit7=1, bit0=1
    const px_signed = getPixel(&dut, 0, 0);
    print("  Signed mode: pixel(0,0) = 0x{x:0>4} (expect light gray 0xAD55)\n", .{px_signed});
    try std.testing.expectEqual(@as(u16, 0xAD55), px_signed);
}

test "window layer overrides background" {
    // Background: tile 0 (all white, color 0)
    // Window: tile 1 (all black, color 3)
    // Window enabled at WX=7, WY=0 (covers entire screen)
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Tile 0: all zeros -> color 0 (white)
    writeTile(&dut, 0, [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    // Tile 1: all 0xFF -> color 3 (black)
    writeTile(&dut, 1, [16]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // BG map 0: all entries -> tile 0
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Window map 1 (0x1C00): tile 1
    writeMapEntry(&dut, 1, 0, 0, 1);

    // LCDC: LCD on (7), win map=1 (6), win enable (5), tile data unsigned (4), BG map=0 (3=0), BG on (0)
    // = 0b1111_0001 = 0xF1
    writeReg(&dut, LCDC, 0xF1);
    writeReg(&dut, BGP, 0xE4); // identity palette
    writeReg(&dut, WX, 7); // window X = 7 -> starts at pixel 0
    writeReg(&dut, WY, 0); // window Y = 0

    // pixel(0,0): window active -> tile 1 -> color 3 -> black
    const px_win = getPixel(&dut, 0, 0);
    print("  Window: pixel(0,0) = 0x{x:0>4} (expect black 0x0000)\n", .{px_win});
    try std.testing.expectEqual(@as(u16, 0x0000), px_win);

    // Disable window -> should get background (white)
    writeReg(&dut, LCDC, 0x91); // window off (bit5=0)
    const px_bg = getPixel(&dut, 0, 0);
    print("  BG only: pixel(0,0) = 0x{x:0>4} (expect white 0xFFFF)\n", .{px_bg});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_bg);
}
