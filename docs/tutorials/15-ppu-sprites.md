# Tutorial 15 — PPU: Sprites

The Game Boy's PPU renders three layers: background, window, and sprites
(called OBJ in the Pan Docs). Tutorials 13–14 covered the first two layers.
This tutorial adds the sprite layer: OAM storage, per-scanline sprite
scanning, tile data pre-fetching, and priority-based pixel mixing.

## Game Boy Sprite Basics

Each sprite is a 4-byte entry in OAM (Object Attribute Memory) at
FE00–FE9F — 40 sprites total:

| Byte | Field | Description |
|------|-------|-------------|
| 0 | Y position | Screen Y + 16 (Y=16 means top of screen) |
| 1 | X position | Screen X + 8 (X=8 means left edge) |
| 2 | Tile index | Tile number in VRAM 8000–8FFF |
| 3 | Attributes | Priority, flip, palette (see below) |

**Attribute byte:**

| Bit | Name | Effect |
|-----|------|--------|
| 7 | BG priority | 0 = sprite on top; 1 = behind BG colors 1-3 |
| 6 | Y flip | Vertically mirror the sprite |
| 5 | X flip | Horizontally mirror the sprite |
| 4 | Palette | 0 = OBP0; 1 = OBP1 |
| 3-0 | (CGB only) | Unused on DMG |

**LCDC control bits:**
- Bit 1: OBJ enable (0 = all sprites hidden)
- Bit 2: OBJ size (0 = 8×8, 1 = 8×16)

**Key rules:**
- Max 10 sprites per scanline (the rest are ignored)
- Sprite color 0 is transparent (background shows through)
- On DMG, lower OAM index = higher priority when sprites overlap
- Sprites always use the unsigned tile data area (8000–8FFF)

## OAM Storage

OAM is only 160 bytes — small enough for distributed RAM. Unlike VRAM (which
uses BSRAM), OAM uses a plain array with combinational reads. This lets the
PPU scan all 40 entries in 40 clock cycles without any wait states.

```systemverilog
    logic [7:0] oam [0:159];

    assign cpu_oam_rdata = oam[cpu_oam_addr];

    always_ff @(posedge clk) begin
        if (cpu_oam_cs && cpu_oam_we)
            oam[cpu_oam_addr] <= cpu_oam_wdata;
    end
```

The CPU accesses OAM through new bus ports, following the same pattern as
VRAM. The bus decoder routes FE00–FE9F to the PPU's OAM interface.

## New Registers

Two new palette registers for sprites:

```systemverilog
    logic [7:0] reg_obp0;   // FF48 — sprite palette 0
    logic [7:0] reg_obp1;   // FF49 — sprite palette 1
```

These work identically to BGP — each 2-bit field maps a color ID (1–3) to a
shade. Color 0 is always transparent for sprites regardless of the palette.

Two new LCDC bit aliases:

```systemverilog
    wire obj_tall   = reg_lcdc[2]; // 0 = 8×8, 1 = 8×16
    wire obj_enable = reg_lcdc[1];
```

## Pipeline Design

Adding sprites to the pixel pipeline requires three phases:

### Phase 1: Scanline Sprite Scan (40 cycles)

On the first `pixel_fetch` of a new scanline, the PPU scans all 40 OAM
entries to find which sprites overlap the current Y coordinate. Up to 10
matches are stored in a sprite buffer.

```systemverilog
    // Per-entry Y check (combinational from OAM):
    wire [8:0] scan_spr_row_raw = {1'b0, pixel_y} + 9'd16 - {1'b0, scan_oam_y};
    wire [3:0] scan_spr_height  = obj_tall ? 4'd15 : 4'd7;
    wire       scan_spr_hit     = (scan_spr_row_raw[8:4] == 5'd0)
                                && (scan_spr_row_raw[3:0] <= scan_spr_height);
```

The scan checks one OAM entry per clock cycle. For each hit, it stores the
sprite's X position, tile index, attributes, and the pre-computed row (with
Y-flip already applied):

```systemverilog
    wire [3:0] scan_spr_row_flip = scan_oam_attr[6]
        ? (scan_spr_height - scan_spr_row_raw[3:0])
        : scan_spr_row_raw[3:0];
```

### Phase 2: Tile Data Pre-fetch (3 cycles per sprite)

After the scan, the PPU fetches tile data for each found sprite from VRAM
port B. Each sprite needs two reads (tile row low byte + high byte), taking
3 cycles per sprite (set address → read low → read high):

```
SPR_FETCH_LO:   addr_b = tile_lo_addr     → SPR_FETCH_HI
SPR_FETCH_HI:   latch tile_lo from rdata  → SPR_FETCH_DONE
SPR_FETCH_DONE: latch tile_hi from rdata  → next sprite or BG pipeline
```

Sprites always use the unsigned tile data area (VRAM 0x0000 = GB 0x8000).
In 8×16 mode, the tile index's bit 0 selects top/bottom:

```systemverilog
    wire [7:0] fetch_spr_tile_adj = obj_tall
        ? (fetch_spr_row[3] ? (fetch_spr_tile | 8'h01)
                            : (fetch_spr_tile & 8'hFE))
        : fetch_spr_tile;
```

### Phase 3: Pixel Mixing (combinational)

After both sprite phases complete, the normal BG/window pipeline runs
unchanged. At the final pixel output stage (PX_BG_HI or PX_WIN_HI), the
sprite buffer is checked combinationally.

A generate block pre-computes per-slot hit and color:

```systemverilog
    for (genvar gi = 0; gi < 10; gi++) begin : gen_spr
        assign spr_col[gi]   = {1'b0, px_x} + 9'd8 - {1'b0, spr_buf_x[gi]};
        assign spr_hit[gi]   = (spr_col[gi][8:3] == 6'd0);
        assign spr_bpos[gi]  = spr_buf_attr[gi][5]
                              ? spr_col[gi][2:0]
                              : (3'd7 - spr_col[gi][2:0]);
        assign spr_color[gi] = {spr_buf_row_hi[gi][spr_bpos[gi]],
                                spr_buf_row_lo[gi][spr_bpos[gi]]};
    end
```

A priority encoder finds the first (lowest OAM index) opaque sprite, then
a `mix_sprite` function applies BG priority rules:

```systemverilog
    function logic [15:0] mix_sprite(logic [1:0] under_color_id,
                                     logic [15:0] under_rgb565);
        if (obj_enable && spr_pixel_found) begin
            if (spr_pixel_behind_bg && under_color_id != 2'd0)
                mix_sprite = under_rgb565;  // BG wins
            else
                mix_sprite = spr_rgb565;    // sprite wins
        end else begin
            mix_sprite = under_rgb565;
        end
    endfunction
```

## FSM State Machine

The pipeline FSM expands from 8 states (3-bit enum) to 12 states (4-bit):

```systemverilog
    typedef enum logic [3:0] {
        PX_IDLE, PX_BG_MAP, PX_BG_LO, PX_BG_HI,
        PX_WIN_MAP, PX_WIN_LO, PX_WIN_HI, PX_DONE,
        SPR_SCAN, SPR_FETCH_LO, SPR_FETCH_HI, SPR_FETCH_DONE
    } px_state_t;
```

**First pixel of a new scanline:**
```
PX_IDLE → SPR_SCAN (40 cyc) → SPR_FETCH (3×N cyc) → PX_BG_MAP → ... → PX_DONE
```

**Subsequent pixels (sprites already scanned):**
```
PX_DONE → PX_BG_MAP → ... → PX_BG_HI (with sprite mix) → PX_DONE
```

The sprite scan adds ~70 cycles to the first pixel of each scanline (40 scan
+ up to 30 fetch). With the SPI LCD running at ~32 system clocks per pixel
and 160 pixels per scanline (~5120 clocks), this is about 1.4% overhead.

## Bus Changes

The bus decoder (`bus.sv`) gets new OAM ports following the same pattern as
VRAM. The OAM address space (FE00–FE9F) maps to an 8-bit local address:

```systemverilog
    end else if (cpu_addr <= 16'hFE9F) begin
        oam_cs    = 1'b1;
        oam_addr  = cpu_addr[7:0];
        oam_we    = cpu_wr;
        cpu_rdata = oam_rdata;
    end
```

## Simulation

The testbench adds a `writeOam` helper to write 4-byte OAM entries and a
`setupSprites` helper for common sprite configuration. The `getPixel` timeout
is increased from 16 to 80 cycles to accommodate the scanline sprite scan.

Ten new tests verify:

| Test | What it checks |
|------|---------------|
| Basic rendering | Sprite pixels appear over BG |
| Transparency | Color 0 is see-through |
| OBP0/OBP1 palettes | Attribute bit 4 selects palette |
| X flip | Attribute bit 5 mirrors horizontally |
| Y flip | Attribute bit 6 mirrors vertically |
| BG priority | Attribute bit 7: sprite behind BG colors 1-3 |
| OAM priority | Lower OAM index wins |
| 10-per-line limit | 11th sprite not rendered |
| 8×16 tall mode | LCDC bit 2, top/bottom tile selection |
| OBJ enable toggle | LCDC bit 1 hides all sprites |

## What's Next

Tutorial 16 adds accurate PPU timing — mode transitions (OAM scan → pixel
transfer → HBlank → VBlank), the STAT register, and LY/LYC comparison
interrupts. This gives games correct timing signals so they can synchronize
their rendering with the PPU.
