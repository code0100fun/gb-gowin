# Tutorial 13 — PPU: Background and Window

With the ST7789 LCD streaming pixels from Tutorial 12, we now need actual
Game Boy graphics. This tutorial builds the PPU's background and window
renderers — tile data fetching, 2bpp pixel decoding, palette mapping, and
scrolling. The PPU outputs RGB565 pixels directly to the ST7789 controller
with no framebuffer.

**Source:** [Pan Docs — Pixel Processing Unit](https://gbdev.io/pandocs/Rendering.html)

## Architecture Overview

The st7789 module already provides `pixel_x` and `pixel_y` coordinates and
expects an RGB565 `pixel_data` value for each pixel. The PPU's job is purely
combinational: given (x, y), look up the correct tile in VRAM, decode the
2bpp pixel, apply the palette, and convert to RGB565.

This "scanline renderer" approach works because VRAM is a plain array with
combinational reads — the entire tile lookup chain resolves in one cycle.
Accurate PPU timing (mode transitions, STAT interrupts) comes in Tutorial 15.

```
pixel_x, pixel_y  ──→  tile map lookup  ──→  tile data lookup
        │                                          │
        │                                    2bpp decode
        │                                          │
        └──────────────→  window check  ──→  BGP palette  ──→  RGB565 out
```

## VRAM Layout

VRAM is 8 KB mapped at 0x8000–0x9FFF in the CPU address space. Internally
the PPU indexes it as 0x0000–0x1FFF:

| Range         | CPU Address   | Contents                      |
|---------------|---------------|-------------------------------|
| 0x0000–0x17FF | 0x8000–0x97FF | Tile data (384 tiles × 16 B)  |
| 0x1800–0x1BFF | 0x9800–0x9BFF | Tile map 0 (32×32 entries)    |
| 0x1C00–0x1FFF | 0x9C00–0x9FFF | Tile map 1 (32×32 entries)    |

Each tile is 8×8 pixels stored as 16 bytes (2 bytes per row, 2 bits per
pixel). The two bytes per row are the low and high bitplanes:

```
Row N: [low_byte, high_byte]
Pixel 0 (leftmost): color_id = {high_byte[7], low_byte[7]}
Pixel 7 (rightmost): color_id = {high_byte[0], low_byte[0]}
```

## Tile Data Addressing

LCDC bit 4 selects between two addressing modes:

- **Unsigned (LCDC.4=1):** Base 0x8000 (VRAM 0x0000). Tile index 0–255
  maps to `tile_idx * 16 + row * 2`.

- **Signed (LCDC.4=0):** Base 0x9000 (VRAM 0x1000). Tile index is treated
  as signed: index 0 → 0x1000, index 127 → 0x17F0, index 128 (−128) →
  0x0800.

```systemverilog
function logic [12:0] tile_data_addr(logic [7:0] tile_idx, logic [2:0] row);
    if (tile_data_sel)
        tile_data_addr = {1'b0, tile_idx, row, 1'b0};           // unsigned
    else
        tile_data_addr = 13'h1000 + {tile_idx[7], tile_idx, row, 1'b0}; // signed
endfunction
```

## Background Rendering

For each pixel (px, py), the background tile is found by:

1. Apply scroll: `bg_x = (px + SCX) & 0xFF`, `bg_y = (py + SCY) & 0xFF`
2. Tile map entry: address = `map_base + {bg_y[7:3], bg_x[7:3]}`
3. Read tile index from VRAM
4. Compute tile data address from tile index and `bg_y[2:0]` (row within tile)
5. Read low and high bytes, extract bit at position `7 - bg_x[2:0]`
6. Combine into 2-bit color ID: `{hi_bit, lo_bit}`
7. Apply BGP palette to get shade

The map base is selected by LCDC bit 3: 0x1800 (9800h) or 0x1C00 (9C00h).

## Window Layer

The window overlays the background when LCDC bit 5 is set. It activates
for pixels where `pixel_y >= WY` and `pixel_x >= (WX - 7)`. The window
uses LCDC bit 6 to select its tile map.

The window has an internal line counter that only increments on scanlines
where the window was actually visible — it doesn't use SCY. This counter
resets at frame start.

## PPU Registers

| Address | Name | Description |
|---------|------|-------------|
| FF40    | LCDC | LCD control (see below) |
| FF41    | STAT | LCD status (simplified: mode always 3) |
| FF42    | SCY  | Background scroll Y |
| FF43    | SCX  | Background scroll X |
| FF44    | LY   | Current scanline (read-only) |
| FF45    | LYC  | LY compare value |
| FF47    | BGP  | Background palette |
| FF4A    | WY   | Window Y position |
| FF4B    | WX   | Window X position + 7 |

**LCDC bits:**
- Bit 7: LCD enable (0 = off, white screen)
- Bit 6: Window tile map (0 = 9800, 1 = 9C00)
- Bit 5: Window enable
- Bit 4: Tile data addressing (0 = signed/9000, 1 = unsigned/8000)
- Bit 3: BG tile map (0 = 9800, 1 = 9C00)
- Bit 0: BG enable (0 = white)

**BGP palette encoding:** Each 2-bit field maps a color ID to a shade:
`BGP[1:0]` = color 0, `BGP[3:2]` = color 1, `BGP[5:4]` = color 2,
`BGP[7:6]` = color 3.

## DMG Shade to RGB565

| Shade | Color      | RGB565 |
|-------|------------|--------|
| 0     | White      | 0xFFFF |
| 1     | Light gray | 0xAD55 |
| 2     | Dark gray  | 0x52AA |
| 3     | Black      | 0x0000 |

## Bus Changes

The VRAM stub in `bus.sv` is replaced with real ports:

```systemverilog
output logic [12:0] vram_addr,
output logic        vram_cs,
output logic        vram_we,
output logic [7:0]  vram_wdata,
input  logic [7:0]  vram_rdata
```

The CPU can now read and write VRAM at 0x8000–0x9FFF. The VRAM array itself
lives inside the PPU module — one port for CPU access (via the bus), and
internal combinational reads for tile rendering.

## Module Interface

```systemverilog
module ppu (
    input  logic        clk,
    input  logic        reset,
    // CPU VRAM access
    input  logic [12:0] cpu_vram_addr,
    input  logic        cpu_vram_cs,
    input  logic        cpu_vram_we,
    input  logic [7:0]  cpu_vram_wdata,
    output logic [7:0]  cpu_vram_rdata,
    // I/O registers
    input  logic        io_cs,
    input  logic [6:0]  io_addr,
    input  logic        io_wr, io_rd,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    output logic        io_rdata_valid,
    // Pixel interface (from st7789)
    input  logic [7:0]  pixel_x,
    input  logic [7:0]  pixel_y,
    output logic [15:0] pixel_data,
    // Interrupts
    output logic        irq_vblank
);
```

## Top-Level Integration

In `gb_top.sv`, the PPU replaces the color-bar test pattern:

```systemverilog
ppu u_ppu (
    .clk(clk), .reset(reset),
    .cpu_vram_addr(vram_addr), .cpu_vram_cs(vram_cs),
    .cpu_vram_we(vram_we),     .cpu_vram_wdata(vram_wdata),
    .cpu_vram_rdata(vram_rdata),
    .io_cs(io_cs), .io_addr(io_addr), .io_wr(io_wr), .io_rd(io_rd),
    .io_wdata(io_wdata), .io_rdata(ppu_rdata),
    .io_rdata_valid(ppu_rdata_valid),
    .pixel_x(lcd_pixel_x), .pixel_y(lcd_pixel_y),
    .pixel_data(lcd_pixel_data),
    .irq_vblank(ppu_irq_vblank)
);
```

The PPU's `io_rdata_valid` is checked first in the I/O read mux, before
the timer and manual registers. VBlank IRQ is wired to `if_reg[0]`.

## Testing

The simulation testbench (`sim/test/ppu.zig`) uses a standalone wrapper
(`ppu_top.sv`) with direct VRAM and register access — no CPU needed.

Seven tests verify the PPU:

1. **LCD off outputs white** — LCDC.7=0, all pixels return 0xFFFF
2. **Solid color tile** — tile filled with color 3, verify black output
3. **2bpp tile decode** — known bit pattern, verify per-pixel color IDs
4. **BGP palette mapping** — remap color 1 to different shades
5. **SCX/SCY scrolling** — adjacent tiles with different colors, scroll and verify
6. **Tile data addressing modes** — unsigned (0x8000) vs signed (0x9000) base
7. **Window layer** — window overrides background, toggled via LCDC.5

## Building and Running

Run just the PPU tests:

```
mise run test:ppu
```

Run the full test suite (111 tests across 15 modules):

```
mise run test
```

Synthesize (note: VRAM uses distributed RAM for now — ~1040 RAM16SDP4 cells):

```
mise run synth -- gb_top
```

## Resource Notes

The 8 KB VRAM is currently implemented as a plain array, which synthesizes
to distributed RAM (RAM16SDP4 primitives). This works for simulation but
overflows the Tang Nano 20K's LUT budget (127% LUT4, 160% RAM16SDP4).
Tutorial 14 migrates VRAM and WRAM to BSRAM to fix this.

## What's Next

Tutorial 14 migrates VRAM and WRAM from distributed RAM to BSRAM, adding
CPU wait states, a PPU tile-fetch pipeline, and an ST7789 handshake to
handle the 1-cycle synchronous read latency.
