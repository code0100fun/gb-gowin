# Tutorial 16 — PPU: Timing and STAT

The PPU has been rendering pixels on demand — the ST7789 LCD requests a pixel,
the PPU fetches tiles and responds. This works for display output, but games
need more: they read the STAT register to know what mode the PPU is in, they
use LY to track which scanline is being drawn, and they rely on STAT interrupts
for raster effects like mid-frame palette changes.

This tutorial adds an autonomous timing layer that runs in parallel with the
existing rendering pipeline: mode transitions, an accurate LY counter, LYC
comparison, and STAT interrupt generation.

## Game Boy PPU Timing

The PPU divides each frame into 154 scanlines. Each scanline takes exactly
456 dots (114 M-cycles). Visible scanlines 0–143 cycle through three modes;
scanlines 144–153 are VBlank:

| Mode | Name | Duration | M-cycles |
|------|------|----------|----------|
| 2 | OAM scan | 80 dots | 0–19 |
| 3 | Pixel transfer | 172 dots | 20–62 |
| 0 | HBlank | 204 dots | 63–113 |
| 1 | VBlank | 4560 dots | LY 144–153 (full scanlines) |

A complete frame is 154 × 114 = 17,556 M-cycles, giving ~59.7 Hz at the
Game Boy's native clock. Our system runs at 27 MHz (one M-cycle per clock),
so everything is proportionally faster — but the CPU-to-PPU ratio is correct,
which is what games depend on.

## Design Approach

The key insight is that **timing and rendering can be separated**:

- **Timing layer** (new): M-cycle counter, scanline counter, mode derivation,
  STAT interrupt line. Runs every clock cycle, fully autonomous.
- **Rendering pipeline** (unchanged): still driven by the ST7789 LCD controller's
  `pixel_fetch` requests. Uses `pixel_x`/`pixel_y` from the LCD, not from the
  timing counters.

This separation means all existing rendering tests pass without modification.
The timing layer provides correct register values (LY, STAT mode bits) and
generates interrupts at the right times relative to CPU M-cycles.

## Timing Counters

Two counters track position within the frame:

```systemverilog
    logic [6:0] mcycle_ctr;  // 0–113: position within scanline
    logic [7:0] ly_ctr;      // 0–153: current scanline

    always_ff @(posedge clk) begin
        if (reset || !lcd_on) begin
            mcycle_ctr <= 7'd0;
            ly_ctr     <= 8'd0;
        end else begin
            if (mcycle_ctr == 7'd113) begin
                mcycle_ctr <= 7'd0;
                ly_ctr <= (ly_ctr == 8'd153) ? 8'd0 : ly_ctr + 8'd1;
            end else begin
                mcycle_ctr <= mcycle_ctr + 7'd1;
            end
        end
    end
```

When the LCD is disabled (LCDC bit 7 = 0), both counters reset to zero.
This matches real hardware behavior — disabling the LCD resets LY and the
mode state.

## Mode Derivation

The PPU mode is derived combinationally from the counters:

```systemverilog
    always_comb begin
        if (!lcd_on)
            ppu_mode = 2'd0;
        else if (ly_ctr >= 8'd144)
            ppu_mode = 2'd1;  // VBlank
        else if (mcycle_ctr < 7'd20)
            ppu_mode = 2'd2;  // OAM scan
        else if (mcycle_ctr < 7'd63)
            ppu_mode = 2'd3;  // Pixel transfer
        else
            ppu_mode = 2'd0;  // HBlank
    end
```

The mode boundaries use fixed cycle counts. On real hardware, mode 3 duration
varies with sprite count and window usage (172–289 dots). The fixed 172-dot
duration works for most games; variable timing can be refined later.

## STAT Register

The STAT register (FF41) now reflects the real mode:

```systemverilog
    wire [7:0] stat_read = {1'b1, reg_stat[6:3],
                            (ly == reg_lyc) ? 1'b1 : 1'b0, ppu_mode};
```

| Bit | Name | Access | Description |
|-----|------|--------|-------------|
| 7 | — | R | Always 1 |
| 6 | LYC interrupt | R/W | Fire STAT IRQ when LY == LYC |
| 5 | Mode 2 interrupt | R/W | Fire STAT IRQ on OAM scan entry |
| 4 | Mode 1 interrupt | R/W | Fire STAT IRQ on VBlank entry |
| 3 | Mode 0 interrupt | R/W | Fire STAT IRQ on HBlank entry |
| 2 | LYC == LY flag | R | 1 when LY matches LYC |
| 1–0 | Mode | R | Current PPU mode (0–3) |

## LY and LYC

LY (FF44) now reads from `ly_ctr` instead of `pixel_y`:

```systemverilog
    wire [7:0] ly = ly_ctr;
```

This gives the full 0–153 range. Games read LY to know which scanline the
PPU is on, and use LYC (FF45) for per-scanline effects.

## STAT Interrupt

The STAT interrupt uses a composite "STAT line" — the OR of all enabled
conditions. The interrupt fires on the **rising edge** of this line:

```systemverilog
    wire stat_line = lcd_on && (
        (reg_stat[3] && ppu_mode == 2'd0) ||  // Mode 0 HBlank
        (reg_stat[4] && ppu_mode == 2'd1) ||  // Mode 1 VBlank
        (reg_stat[5] && ppu_mode == 2'd2) ||  // Mode 2 OAM scan
        (reg_stat[6] && ly == reg_lyc));       // LYC=LY coincidence

    logic prev_stat_line;
    always_ff @(posedge clk) begin
        if (reset) prev_stat_line <= 1'b0;
        else       prev_stat_line <= stat_line;
    end

    assign irq_stat = stat_line && !prev_stat_line;
```

The `lcd_on` gate is critical — without it, `ppu_mode = 0` when the LCD is
off would match the HBlank condition and fire spurious interrupts.

The composite-line approach implements "STAT blocking": when the STAT line
stays high across overlapping conditions (e.g., mode 2 entry while LYC is
still matching), no duplicate interrupt fires. Only the 0→1 transition
triggers.

## VBlank Interrupt

The VBlank interrupt is now derived from the timing counter instead of
detecting `pixel_y` wrap:

```systemverilog
    logic prev_vblank_line;
    always_ff @(posedge clk) begin
        if (reset) prev_vblank_line <= 1'b0;
        else       prev_vblank_line <= (ly_ctr == 8'd144);
    end
    assign irq_vblank = (ly_ctr == 8'd144) && !prev_vblank_line;
```

## IF Register Fix

The IF register in `gb_top.sv` previously used an `else if` chain that could
only set one interrupt bit per cycle. With STAT and VBlank potentially firing
on the same cycle (e.g., VBlank entry with STAT mode-1 interrupt enabled),
this is replaced with a parallel OR:

```systemverilog
    logic [4:0] next_if;
    always_comb begin
        next_if = if_reg;
        if (ppu_irq_vblank) next_if = next_if | 5'b00001;
        if (ppu_irq_stat)   next_if = next_if | 5'b00010;
        if (timer_irq)      next_if = next_if | 5'b00100;
        if (io_cs && io_wr && io_addr == 7'h0F)
            next_if = io_wdata[4:0];
        if (int_ack != 5'b0)
            next_if = next_if & ~int_ack;
    end
```

## Simulation

Seven new tests verify the timing layer:

| Test | What it checks |
|------|---------------|
| Mode 2 after LCD enable | Counters start at mcycle=0/ly=0 → mode 2 |
| Mode transitions 2→3→0→2 | Correct mode at boundary mcycles |
| LY increments every 114 mcycles | LY=0→1→2 at correct intervals |
| VBlank mode at LY 144–153 | Mode 1 during VBlank, wraps to mode 2 |
| VBlank IRQ at LY 144 | Single-cycle pulse on LY transition to 144 |
| LYC coincidence flag | STAT bit 2 set when LY==LYC |
| STAT IRQ on HBlank entry | Mode-0 interrupt fires at mcycle 63 |

A `readReg` helper reads PPU registers combinationally (via `eval()` without
advancing the clock), enabling precise cycle-by-cycle verification of mode
transitions.

## What's Next

Tutorial 17 adds joypad input — 8 pushbuttons mapped to the JOYP register
(FF00) with the Game Boy's column/row multiplexing scheme.
