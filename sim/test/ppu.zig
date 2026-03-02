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
const OBP0: u7 = 0x48;
const OBP1: u7 = 0x49;
const WY: u7 = 0x4A;
const WX: u7 = 0x4B;

fn resetDut(dut: *ppu_top.Model) void {
    dut.set(.reset, 1);
    dut.set(.pixel_fetch, 0);
    dut.tick();
    dut.set(.reset, 0);
    // Clear control signals after reset
    dut.set(.vram_wr, 0);
    dut.set(.oam_wr, 0);
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
    // Wait for pipeline (BG=4, BG+Win=7, sprite scan=40+30 on new scanline)
    for (0..80) |_| {
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

/// Write a 4-byte OAM entry: Y position, X position, tile index, attributes.
fn writeOam(dut: *ppu_top.Model, entry: u6, y: u8, x: u8, tile: u8, attr: u8) void {
    const base: u8 = @as(u8, entry) * 4;
    const bytes = [4]u8{ y, x, tile, attr };
    for (bytes, 0..) |byte, i| {
        dut.set(.oam_addr, base + @as(u8, @intCast(i)));
        dut.set(.oam_wdata, byte);
        dut.set(.oam_wr, 1);
        dut.tick();
        dut.set(.oam_wr, 0);
    }
}

/// Common sprite test setup: enable LCD + BG + OBJ, unsigned tile data,
/// identity BGP, and a standard OBP0 palette.
fn setupSprites(dut: *ppu_top.Model) void {
    // LCDC: LCD on (7), tile data unsigned (4), OBJ enable (1), BG enable (0)
    // = 0b1001_0011 = 0x93
    writeReg(dut, LCDC, 0x93);
    writeReg(dut, BGP, 0xE4); // identity: color0=white, 1=lgray, 2=dgray, 3=black
    writeReg(dut, OBP0, 0xE4); // same identity
    writeReg(dut, OBP1, 0xE4);
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

// =====================================================================
// Sprite tests
// =====================================================================

test "sprite — basic rendering" {
    // Place a sprite at screen position (0,0) with all-black tile.
    // BG is white (tile 0 = all zeros). Sprite should appear as black.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // BG tile 0: all zeros (color 0 = white)
    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile 1: all color 3 (black)
    writeTile(&dut, 1, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    setupSprites(&dut);

    // OAM entry 0: Y=16 (screen Y=0), X=8 (screen X=0), tile=1, attr=0
    writeOam(&dut, 0, 16, 8, 1, 0x00);

    // Pixel at (0,0) should be sprite (black)
    const px = getPixel(&dut, 0, 0);
    print("  Sprite basic: pixel(0,0) = 0x{x:0>4} (expect black 0x0000)\n", .{px});
    try std.testing.expectEqual(@as(u16, 0x0000), px);

    // Pixel at (8,0) should be BG (white, no sprite there)
    const px_bg = getPixel(&dut, 8, 0);
    print("  Sprite basic: pixel(8,0) = 0x{x:0>4} (expect white 0xFFFF)\n", .{px_bg});
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_bg);
}

test "sprite — transparency (color 0)" {
    // Sprite tile has color 0 pixels — those should be transparent (BG shows through).
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // BG: all color 1 (light gray with identity palette)
    writeTile(&dut, 0, .{ 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile 1: row 0 has lo=0xF0, hi=0xF0 -> left 4 pixels = color 3, right 4 = color 0
    var spr_tile: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    spr_tile[0] = 0xF0; // row 0 lo: pixels 0-3 = 1, pixels 4-7 = 0
    spr_tile[1] = 0xF0; // row 0 hi: pixels 0-3 = 1, pixels 4-7 = 0
    writeTile(&dut, 1, spr_tile);

    setupSprites(&dut);
    writeOam(&dut, 0, 16, 8, 1, 0x00);

    // Pixel (0,0): sprite color 3 -> black
    const px0 = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px0);

    // Pixel (4,0): sprite color 0 (transparent) -> BG color 1 -> light gray
    const px4 = getPixel(&dut, 4, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px4);
}

test "sprite — OBP0 and OBP1 palettes" {
    // Two sprites with the same tile data but different palettes.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // BG: all white
    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile 1: all color 1 (lo=FF, hi=00)
    writeTile(&dut, 1, .{ 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 });

    setupSprites(&dut);
    // OBP0: color 1 -> shade 1 (light gray)
    writeReg(&dut, OBP0, 0xE4);
    // OBP1: color 1 -> shade 3 (black) — palette: 11_10_11_00 = 0xEC
    writeReg(&dut, OBP1, 0xEC);

    // Sprite 0: uses OBP0 (attr bit4=0)
    writeOam(&dut, 0, 16, 8, 1, 0x00);
    // Sprite 1: uses OBP1 (attr bit4=1), positioned at X=16 (screen X=8)
    writeOam(&dut, 1, 16, 16, 1, 0x10);

    // Pixel (0,0): sprite 0 + OBP0 -> color 1 -> shade 1 -> light gray
    const px0 = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px0);

    // Pixel (8,0): sprite 1 + OBP1 -> color 1 -> shade 3 -> black
    const px8 = getPixel(&dut, 8, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px8);
}

test "sprite — X flip" {
    // Tile row 0: lo=0x80, hi=0x00 -> pixel 0 = color 1, pixels 1-7 = color 0.
    // Without flip: pixel(0,0) = color 1. With X-flip: pixel(7,0) = color 1.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile: only leftmost pixel set (bit 7)
    var spr_tile: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    spr_tile[0] = 0x80; // row 0 lo: bit 7 set
    writeTile(&dut, 1, spr_tile);

    setupSprites(&dut);

    // Sprite without flip (attr=0x00): color 1 at pixel 0
    writeOam(&dut, 0, 16, 8, 1, 0x00);
    const px_normal = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px_normal);
    // pixel 7 should be transparent -> BG (white)
    const px_normal7 = getPixel(&dut, 7, 0);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_normal7);

    // Now flip: attr bit5=1 (X-flip = 0x20)
    writeOam(&dut, 0, 16, 8, 1, 0x20);
    // Force re-scan by changing to a new scanline, then back
    const px_flip0 = getPixel(&dut, 0, 1);
    _ = px_flip0; // different scanline, just to trigger re-scan

    // On scanline 0 with the flip, need to re-trigger scan
    // Actually, changing OAM invalidates the scan. Use a different Y.
    // Sprite covers Y=0..7 (OAM Y=16). Test on Y=0 with fresh DUT.
    var dut2 = try ppu_top.Model.init(.{});
    defer dut2.deinit();
    resetDut(&dut2);
    writeTile(&dut2, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut2, 0, 0, 0, 0);
    spr_tile[0] = 0x80;
    writeTile(&dut2, 1, spr_tile);
    setupSprites(&dut2);
    writeOam(&dut2, 0, 16, 8, 1, 0x20); // X-flip

    // With X-flip: bit 7 moves to pixel 7
    const px_flip7 = getPixel(&dut2, 7, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px_flip7);
    // pixel 0 should now be transparent
    const px_flip_0 = getPixel(&dut2, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_flip_0);
}

test "sprite — Y flip" {
    // Tile has color 3 on row 0 only, rest are color 0.
    // Without Y-flip: sprite row 0 (screen Y=0) is black.
    // With Y-flip: sprite row 7 (screen Y=7) is black.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile: only row 0 has data (color 3)
    var spr_tile: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    spr_tile[0] = 0xFF; // row 0 lo
    spr_tile[1] = 0xFF; // row 0 hi -> color 3
    writeTile(&dut, 1, spr_tile);

    setupSprites(&dut);

    // No flip: row 0 (screen Y=0) is black, row 7 (Y=7) is transparent/BG
    writeOam(&dut, 0, 16, 8, 1, 0x00);
    const px_y0 = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px_y0);
    const px_y7 = getPixel(&dut, 0, 7);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_y7);

    // Y-flip (attr bit6=1 = 0x40): row 0 data moves to screen row 7
    var dut2 = try ppu_top.Model.init(.{});
    defer dut2.deinit();
    resetDut(&dut2);
    writeTile(&dut2, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut2, 0, 0, 0, 0);
    writeTile(&dut2, 1, spr_tile);
    setupSprites(&dut2);
    writeOam(&dut2, 0, 16, 8, 1, 0x40);

    // With Y-flip: screen Y=0 should be transparent, Y=7 should be black
    const px_flip_y0 = getPixel(&dut2, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_flip_y0);
    const px_flip_y7 = getPixel(&dut2, 0, 7);
    try std.testing.expectEqual(@as(u16, 0x0000), px_flip_y7);
}

test "sprite — BG priority flag" {
    // Sprite with attr bit7=1: sprite is behind BG colors 1-3,
    // only visible over BG color 0.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // BG tile 0: row 0 = lo=0xF0, hi=0x00
    //   pixels 0-3: color 1 (light gray), pixels 4-7: color 0 (white)
    var bg_tile: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    bg_tile[0] = 0xF0; // row 0 lo
    writeTile(&dut, 0, bg_tile);
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile 1: all color 3 (black)
    writeTile(&dut, 1, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    setupSprites(&dut);

    // Sprite with BG priority (attr bit7=1 = 0x80)
    writeOam(&dut, 0, 16, 8, 1, 0x80);

    // Pixel (0,0): BG color 1 (non-zero) + sprite behind -> BG wins -> light gray
    const px0 = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px0);

    // Pixel (4,0): BG color 0 + sprite behind -> sprite wins -> black
    const px4 = getPixel(&dut, 4, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px4);
}

test "sprite — OAM priority (lower index wins)" {
    // Two sprites at the same position. Lower OAM index should win.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Tile 1: all color 1 (light gray)
    writeTile(&dut, 1, .{ 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 });
    // Tile 2: all color 3 (black)
    writeTile(&dut, 2, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    setupSprites(&dut);

    // Sprite 0 (higher priority): tile 1 (light gray), at (8,16)
    writeOam(&dut, 0, 16, 8, 1, 0x00);
    // Sprite 1 (lower priority): tile 2 (black), same position
    writeOam(&dut, 1, 16, 8, 2, 0x00);

    // Sprite 0 should win -> light gray
    const px = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px);
}

test "sprite — 10-per-line limit" {
    // Place 11 sprites on the same scanline. Only the first 10 should render.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Sprite tile 1: all color 3 (black)
    writeTile(&dut, 1, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    setupSprites(&dut);

    // Place 11 sprites on scanline 0, spaced 8 pixels apart
    for (0..11) |i| {
        const idx: u6 = @intCast(i);
        const x: u8 = @as(u8, @intCast(i)) * 8 + 8; // screen X = i*8
        writeOam(&dut, idx, 16, x, 1, 0x00);
    }

    // Sprite 9 (10th, at X=72..79) should render -> black
    const px9 = getPixel(&dut, 72, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px9);

    // Sprite 10 (11th, at X=80..87) should NOT render -> BG (white)
    const px10 = getPixel(&dut, 80, 0);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px10);
}

test "sprite — 8x16 tall mode" {
    // LCDC bit 2 enables 8×16 sprites. Top tile = idx & 0xFE, bottom = idx | 0x01.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);

    // Tile 2 (top half): all color 1 (light gray)
    writeTile(&dut, 2, .{ 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 });
    // Tile 3 (bottom half): all color 3 (black)
    writeTile(&dut, 3, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // LCDC: LCD on (7), tile data unsigned (4), OBJ tall (2), OBJ enable (1), BG enable (0)
    // = 0b1001_0111 = 0x97
    writeReg(&dut, LCDC, 0x97);
    writeReg(&dut, BGP, 0xE4);
    writeReg(&dut, OBP0, 0xE4);

    // OAM entry with tile index 3 — in 8×16 mode, bit 0 is ignored:
    // top = 3 & 0xFE = 2, bottom = 3 | 0x01 = 3
    writeOam(&dut, 0, 16, 8, 3, 0x00);

    // Screen Y=0 (sprite row 0) -> top tile (2) -> color 1 -> light gray
    const px_top = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0xAD55), px_top);

    // Screen Y=8 (sprite row 8) -> bottom tile (3) -> color 3 -> black
    const px_bot = getPixel(&dut, 0, 8);
    try std.testing.expectEqual(@as(u16, 0x0000), px_bot);

    // Screen Y=16 (outside 16-pixel sprite) -> BG -> white
    const px_out = getPixel(&dut, 0, 16);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_out);
}

test "sprite — OBJ enable toggle" {
    // LCDC bit 1 = 0 should disable all sprites.
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    writeTile(&dut, 0, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    writeMapEntry(&dut, 0, 0, 0, 0);
    writeTile(&dut, 1, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });

    // Start with sprites enabled
    setupSprites(&dut);
    writeOam(&dut, 0, 16, 8, 1, 0x00);

    // Pixel should be sprite (black)
    const px_on = getPixel(&dut, 0, 0);
    try std.testing.expectEqual(@as(u16, 0x0000), px_on);

    // Disable sprites: LCDC = 0x91 (bit1=0)
    writeReg(&dut, LCDC, 0x91);

    // Need a fresh scanline to see the effect (sprite scan uses LCDC bit 1)
    // Use Y=1 to force new scan
    const px_off = getPixel(&dut, 0, 1);
    try std.testing.expectEqual(@as(u16, 0xFFFF), px_off);
}

// =====================================================================
// Timing / STAT tests (Tutorial 16)
// =====================================================================

/// Read a PPU register via the I/O bus (combinational — no clock advance).
fn readReg(dut: *ppu_top.Model, addr: u7) u8 {
    dut.set(.io_addr, addr);
    dut.set(.io_wr, 0);
    dut.eval();
    return @truncate(dut.get(.io_rdata));
}

/// Advance the clock by N M-cycles.
fn tickN(dut: *ppu_top.Model, n: u32) void {
    for (0..n) |_| dut.tick();
}

/// Enable LCD (LCDC bit 7 + unsigned tile data + BG enable).
/// After this returns, mcycle_ctr = 0 and lcd_on is true.
fn enableLcd(dut: *ppu_top.Model) void {
    writeReg(dut, LCDC, 0x91); // LCD on, unsigned tile data, BG on
}

test "timing — mode 2 after LCD enable" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Before LCD is enabled, mode should be 0
    var stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 0), @as(u2, @truncate(stat)));

    // Enable LCD — counters start at mcycle=0, ly=0 → mode 2
    enableLcd(&dut);

    stat = readReg(&dut, STAT);
    const mode: u2 = @truncate(stat);
    print("  After LCD enable: STAT=0x{x:0>2} mode={d}\n", .{ stat, mode });
    try std.testing.expectEqual(@as(u2, 2), mode);
}

test "timing — mode transitions 2 -> 3 -> 0 -> 2" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    enableLcd(&dut);

    // Mode 2 (OAM scan): mcycles 0-19
    dut.tick(); // mcycle 1
    var stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 2), @as(u2, @truncate(stat)));

    // Advance to mcycle 19 (still mode 2)
    tickN(&dut, 18); // now at mcycle 19
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 2), @as(u2, @truncate(stat)));

    // Advance to mcycle 20 -> mode 3 (pixel transfer)
    dut.tick();
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 3), @as(u2, @truncate(stat)));

    // Advance to mcycle 62 (still mode 3)
    tickN(&dut, 42);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 3), @as(u2, @truncate(stat)));

    // Advance to mcycle 63 -> mode 0 (HBlank)
    dut.tick();
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 0), @as(u2, @truncate(stat)));

    // Advance to mcycle 113 (still mode 0)
    tickN(&dut, 50);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 0), @as(u2, @truncate(stat)));

    // Advance one more -> mcycle 0 of next scanline -> mode 2
    dut.tick();
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 2), @as(u2, @truncate(stat)));
}

test "timing — LY increments every 114 mcycles" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    enableLcd(&dut);

    // LY starts at 0
    var ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 0), ly);

    // After 114 ticks, LY should be 1
    tickN(&dut, 114);
    ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 1), ly);

    // After another 114, LY should be 2
    tickN(&dut, 114);
    ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 2), ly);
}

test "timing — VBlank mode at LY 144-153" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    enableLcd(&dut);

    // Advance to LY=144: 144 * 114 = 16416 ticks
    tickN(&dut, 144 * 114);
    var ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 144), ly);

    // Mode should be 1 (VBlank)
    var stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 1), @as(u2, @truncate(stat)));

    // Advance to LY=153
    tickN(&dut, 9 * 114);
    ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 153), ly);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 1), @as(u2, @truncate(stat)));

    // After 114 more ticks: LY wraps to 0, mode -> 2
    tickN(&dut, 114);
    ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 0), ly);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 2), @as(u2, @truncate(stat)));
}

test "timing — VBlank IRQ at LY 144" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    enableLcd(&dut);

    // Advance to just before LY=144
    tickN(&dut, 144 * 114 - 1);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_irq_vblank));

    // One more tick -> LY becomes 144, VBlank IRQ should pulse
    dut.tick();
    try std.testing.expectEqual(@as(u64, 1), dut.get(.dbg_irq_vblank));

    // Next tick: IRQ cleared (edge-triggered)
    dut.tick();
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_irq_vblank));
}

test "timing — LYC coincidence flag" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    writeReg(&dut, LYC, 5);
    enableLcd(&dut);

    // Before LY=5: coincidence bit (STAT bit 2) should be 0
    tickN(&dut, 4 * 114);
    var stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(stat >> 2)));

    // At LY=5: coincidence bit should be 1
    tickN(&dut, 114);
    const ly = readReg(&dut, LY);
    try std.testing.expectEqual(@as(u8, 5), ly);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u1, 1), @as(u1, @truncate(stat >> 2)));

    // At LY=6: coincidence bit should be 0 again
    tickN(&dut, 114);
    stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u1, 0), @as(u1, @truncate(stat >> 2)));
}

test "timing — STAT IRQ on HBlank entry" {
    var dut = try ppu_top.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);
    writeReg(&dut, STAT, 0x08); // Enable mode-0 (HBlank) STAT interrupt
    enableLcd(&dut);

    // mcycle is now 0. Advance 62 ticks -> mcycle=62, mode=3
    tickN(&dut, 62);
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_irq_stat));

    // Tick to mcycle=63 -> mode=0 (HBlank) -> STAT IRQ fires
    dut.tick();
    try std.testing.expectEqual(@as(u64, 1), dut.get(.dbg_irq_stat));

    // Verify mode is 0
    const stat = readReg(&dut, STAT);
    try std.testing.expectEqual(@as(u2, 0), @as(u2, @truncate(stat)));

    // Next tick: IRQ cleared (one-shot edge)
    dut.tick();
    try std.testing.expectEqual(@as(u64, 0), dut.get(.dbg_irq_stat));
}
