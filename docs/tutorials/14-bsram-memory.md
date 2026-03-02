# Tutorial 14 — BSRAM Memory

Tutorial 13 implemented VRAM as a plain 8 KB array, which synthesizes to
distributed RAM (RAM16SDP4 primitives on the Gowin GW2AR-18). This blows
the Tang Nano 20K's resource budget: Yosys reports 1040 RAM16SDP4 cells
against a maximum of 648 — 160% utilization. The design can't be placed.

The Gowin GW2AR-18 has 46 BSRAM (Block Static RAM) blocks, each 18 Kbit.
VRAM (8 KB) fits in 8 blocks, and WRAM (8 KB) in another 4 — just 12 of
46 available. The trade-off is that BSRAM reads are **synchronous**: you
set an address on one clock edge and data appears on the next. This 1-cycle
latency ripples through three subsystems:

1. **CPU wait states** — the CPU must pause for 1 cycle during VRAM/WRAM reads
2. **PPU tile-fetch pipeline** — 6 combinational VRAM reads become a multi-cycle FSM
3. **ST7789 handshake** — the LCD controller must wait for the PPU pipeline to complete

## BSRAM Inference

Yosys infers BSRAM from the same `single_port_ram` and `dual_port_ram` modules
created in Tutorial 4. The key pattern is a registered read:

```systemverilog
always_ff @(posedge clk) begin
    if (we)
        mem[addr] <= wdata;
    rdata <= mem[addr];  // synchronous read — infers BSRAM
end
```

Contrast with distributed RAM, which uses a combinational read (`assign rdata = mem[addr]`).
The registered read is what tells the synthesizer to use BSRAM blocks instead of LUTs.

## CPU `mem_wait`

When the CPU reads from VRAM or WRAM, the BSRAM data won't be valid until
the next clock edge. During that cycle the CPU must freeze — no state
changes, no writes. A new `mem_wait` input handles this:

```systemverilog
input logic mem_wait,  // pause CPU for BSRAM read latency
```

### Freezing the state machine

The CPU's `always_ff` block wraps its entire non-reset body with a
`mem_wait` check. When asserted, the CPU holds all state:

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        ...
    end else if (mem_wait) begin
        // BSRAM read in progress — freeze all state
    end else if (halt_mode) begin
        ...  // existing halt handling
    end else begin
        ...  // existing instruction execution
    end
end
```

### Suppressing write enables

The combinational `always_comb` block adds a final override to zero all
external write enables while the CPU is frozen:

```systemverilog
if (mem_wait) begin
    rf_r8_we     = 1'b0;
    rf_r16_we    = 1'b0;
    rf_r16stk_we = 1'b0;
    rf_flags_we  = 1'b0;
    rf_sp_we     = 1'b0;
    rf_pc_we     = 1'b0;
    mem_wr       = 1'b0;
    int_ack      = 5'b0;
end
```

`mem_rd` and `mem_addr` are **not** suppressed — the BSRAM needs to see the
read request to output data on the next cycle.

## Wait-State Generation

The top-level module (`gb_top.sv`) generates `mem_wait` with a simple
one-cycle tracker:

```systemverilog
logic bsram_read_done;
always_ff @(posedge clk) begin
    if (reset)
        bsram_read_done <= 1'b0;
    else
        bsram_read_done <= (vram_cs || wram_cs) && cpu_rd && !bsram_read_done;
end
wire mem_wait = (vram_cs || wram_cs) && cpu_rd && !bsram_read_done;
```

- **Cycle 0:** CPU addresses VRAM/WRAM with `cpu_rd=1` → `mem_wait=1`, CPU freezes,
  BSRAM latches the address.
- **Cycle 1:** `bsram_read_done=1` → `mem_wait=0`, BSRAM data is valid, CPU resumes.

ROM and HRAM use combinational reads (distributed RAM), so `mem_wait`
is only asserted for VRAM and WRAM.

## WRAM — Single-Port BSRAM

The previous WRAM stub (`assign wram_rdata = 8'hFF`) is replaced with a
real 8 KB BSRAM instance:

```systemverilog
single_port_ram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_wram (
    .clk  (clk),
    .we   (wram_cs && wram_we),
    .addr (wram_addr),
    .wdata(wram_wdata),
    .rdata(wram_rdata)
);
```

## VRAM — Dual-Port BSRAM

VRAM needs two independent access paths: the CPU reads and writes through
the bus, and the PPU reads tiles for rendering. A dual-port BSRAM provides
both without arbitration:

```systemverilog
dual_port_ram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_vram (
    .clk_a  (clk),
    .we_a   (cpu_vram_cs && cpu_vram_we),
    .addr_a (cpu_vram_addr),
    .wdata_a(cpu_vram_wdata),
    .rdata_a(cpu_vram_rdata),
    .clk_b  (clk),
    .we_b   (1'b0),
    .addr_b (ppu_vram_addr),
    .wdata_b(8'd0),
    .rdata_b(ppu_vram_rdata)
);
```

Port A is wired to the CPU bus. Port B is read-only, driven by the PPU's
tile-fetch pipeline.

## PPU Tile-Fetch Pipeline

In Tutorial 13 the PPU's tile lookup was fully combinational — given
(pixel_x, pixel_y), six array reads resolved in a single cycle. With
BSRAM's 1-cycle latency, each read now takes two cycles (set address,
read data). The PPU uses a small FSM to walk through the reads:

```
PX_IDLE   →  pixel_fetch pulse → set bg map addr  →  PX_BG_MAP
PX_BG_MAP →  latch bg tile idx, set tile data lo  →  PX_BG_LO
PX_BG_LO  →  latch tile lo byte, set tile data hi →  PX_BG_HI
PX_BG_HI  →  if window active: set win map addr   →  PX_WIN_MAP
              else: compute BG pixel               →  PX_DONE
PX_WIN_MAP → latch win tile idx, set tile data lo  →  PX_WIN_LO
PX_WIN_LO  → latch tile lo byte, set tile data hi  →  PX_WIN_HI
PX_WIN_HI  → compute window pixel                  →  PX_DONE
PX_DONE    → hold pixel_data until next fetch
```

Background rendering takes 4 cycles, window adds 3 more for 7 total. At
27 MHz SPI with a ÷4 clock divider, each pixel takes ~64 system clocks to
shift out — plenty of time.

### Combinational address mux

The BSRAM address for Port B is driven combinationally from the FSM state.
This creates a valid path: BSRAM registered output → combinational logic →
BSRAM address input. There's no loop because `rdata_b` is registered
inside the BSRAM.

```systemverilog
always_comb begin
    case (px_state)
        PX_IDLE:    ppu_vram_addr = fetch_bg_map_addr;
        PX_BG_MAP:  ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_bg_y[2:0]);
        PX_BG_LO:   ppu_vram_addr = px_bg_data_base + 13'd1;
        PX_BG_HI:   ppu_vram_addr = pipe_win_map_addr;
        PX_WIN_MAP: ppu_vram_addr = tile_data_addr(ppu_vram_rdata, pipe_win_y[2:0]);
        PX_WIN_LO:  ppu_vram_addr = px_win_data_base + 13'd1;
        PX_DONE:    ppu_vram_addr = fetch_bg_map_addr;
        default:     ppu_vram_addr = 13'd0;
    endcase
end
```

In PX_BG_MAP and PX_WIN_MAP, the tile data address is computed directly
from the just-read BSRAM output (`ppu_vram_rdata`), which is the tile
index. This works because the BSRAM output is a registered value — stable
for the entire cycle.

### Pre-loading in IDLE and DONE

A subtle optimization: in both PX_IDLE and PX_DONE, the address mux
outputs `fetch_bg_map_addr` computed from the **raw** `pixel_x`/`pixel_y`
inputs (not the latched `px_x`/`px_y`). This means the BSRAM starts
reading the background tile map entry on the same cycle as the
`pixel_fetch` pulse. By the time we reach PX_BG_MAP on the next cycle,
the tile index is already available — no wasted cycle.

### Pixel computation

The 2bpp decode, palette lookup, and RGB565 conversion are purely
combinational wires:

```systemverilog
wire [2:0] bg_bit_pos    = 3'd7 - pipe_bg_x[2:0];
wire [1:0] bg_color_id   = {ppu_vram_rdata[bg_bit_pos], px_bg_tile_lo[bg_bit_pos]};
wire [1:0] bg_shade      = reg_bgp[bg_color_id * 2 +: 2];
wire [15:0] bg_rgb565    = shade_to_rgb565(bg_shade);
```

When the FSM reaches PX_BG_HI or PX_WIN_HI, all tile bytes are available.
The combinational result is registered into `pixel_data` on the same clock
edge, and `pixel_data_valid` is asserted.

## ST7789 Handshake

The ST7789 controller needs to wait for the PPU pipeline to complete
before shifting out pixel data. A new `pixel_ready` input gates the
streaming state:

```systemverilog
// In st7789.sv
input logic pixel_ready,  // high when pixel_data is valid

// S_STREAM_HI — was: if (!spi_busy)
S_STREAM_HI: begin
    if (!spi_busy && pixel_ready) begin
        lcd_cs    <= 1'b0;
        lcd_dc    <= 1'b1;
        shift_data <= pixel_data[15:8];
        spi_start <= 1'b1;
        state     <= S_STREAM_LO;
    end
end
```

The PPU's `pixel_data_valid` output connects directly to the ST7789's
`pixel_ready` input in `gb_top.sv`:

```systemverilog
ppu u_ppu (
    ...
    .pixel_fetch      (lcd_pixel_req),
    .pixel_data_valid (lcd_pixel_ready),
    ...
);

st7789 u_lcd (
    ...
    .pixel_ready (lcd_pixel_ready),
    ...
);
```

## Top-Level Wiring

In `gb_top.sv`, the new signals connect the three subsystems:

```systemverilog
// CPU pauses during BSRAM reads
cpu u_cpu (
    ...
    .mem_wait (mem_wait),
    ...
);

// WRAM: real 8 KB BSRAM
single_port_ram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_wram (
    .clk  (clk),
    .we   (wram_cs && wram_we),
    .addr (wram_addr),
    .wdata(wram_wdata),
    .rdata(wram_rdata)
);

// PPU with BSRAM VRAM and tile-fetch pipeline
ppu u_ppu (
    ...
    .pixel_fetch      (lcd_pixel_req),
    .pixel_data_valid (lcd_pixel_ready),
    ...
);

// ST7789 waits for PPU pipeline
st7789 u_lcd (
    ...
    .pixel_ready (lcd_pixel_ready),
    ...
);
```

## Simulation Wrappers

The existing simulation wrappers (`cpu_bus_top.sv`, `timer_top.sv`) use
combinational VRAM/WRAM arrays. Since there's no BSRAM latency in these
simple test memories, `mem_wait` is tied to 0:

```systemverilog
cpu u_cpu (
    ...
    .mem_wait (1'b0),
    ...
);
```

The PPU wrapper (`ppu_top.sv`) adds `pixel_fetch` and `pixel_data_valid`
ports so the testbench can drive the pipeline and observe completion.

## Testing

The PPU testbench (`sim/test/ppu.zig`) changes from a single-cycle
`getPixel()` to a pipeline-based version:

```zig
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
```

All 7 existing PPU tests pass unchanged — only the helper function needed
updating.

Run just the PPU tests:

```
mise run test:ppu
```

Run the full test suite (111 tests across 15 modules):

```
mise run test
```

## Resource Usage

Before (Tutorial 13 — distributed RAM):

| Resource   | Used  | Available | Utilization |
|------------|-------|-----------|-------------|
| LUT4       | 26459 | 20736     | **127%**    |
| RAM16SDP4  | 1040  | 648       | **160%**    |
| SP (BSRAM) | 0     | 46        | 0%          |

After (Tutorial 14 — BSRAM):

| Resource   | Used  | Available | Utilization |
|------------|-------|-----------|-------------|
| RAM16SDP4  | 16    | 648       | 2%          |
| SP (BSRAM) | 8     | 46        | 17%         |

RAM16SDP4 usage dropped from 1040 to 16 (98.5% reduction), and 8 BSRAM
blocks are used for VRAM and WRAM. The design now places and routes
successfully on the Tang Nano 20K with a max frequency of ~34 MHz
(target: 27 MHz).

Synthesize and verify:

```
mise run synth -- gb_top
mise run pnr
mise run pack
```

## What's Next

Tutorial 15 adds sprites: OAM (FE00–FE9F) with 40 sprite entries, sprite
priority, 10-per-line limit, and sprite pixel mixing with the background.
