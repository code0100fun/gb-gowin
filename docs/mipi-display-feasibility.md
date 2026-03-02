# MIPI Display Feasibility Analysis

Can we drive a 480×800 MIPI display from the Tang Nano 20K in SystemVerilog
using our open-source toolchain?

**Short answer: pure MIPI DSI is not practical on this board and toolchain,
but there are viable alternatives.**

---

## 1. Bandwidth Requirements

A 480×800 display at 60 fps in RGB565 (16-bit color):

```
480 × 800 × 16 bits × 60 fps = 368.6 Mbps (raw pixel data)
```

With MIPI DSI protocol overhead (~20%), you need roughly **440–460 Mbps**,
which fits comfortably in a single MIPI DSI lane at 500 Mbps or two lanes at
250 Mbps each.

For comparison, the Game Boy PPU outputs 160×144 pixels — so we'd be
rendering into a subset of the display, but the display controller still
expects full-resolution timing.

---

## 2. MIPI DSI on the GW2AR-18 — Why It Won't Work Here

### The silicon has MIPI D-PHY hard IP...

The GW2AR-18 (Arora family) includes MIPI D-PHY hard IP at the die level.
Gowin provides official IP cores for this:

- **IPUG948** — MIPI D-PHY RX/TX Advance IP
- **IPUG1037** — MIPI DSI/CSI-2 Transmitter IP

### ...but three things block us:

#### a) QN88 package doesn't expose D-PHY pins

The Tang Nano 20K uses the **QN88** package (88-pin QFP). This is the
smallest package option for the GW2AR-18. The MIPI D-PHY differential pairs
require specific I/O bank pins that are not routed to external pins in this
package. The larger QFP144 and BGA packages do expose them.

#### b) Open-source toolchain has no D-PHY support

Our toolchain (Yosys + nextpnr-himbaechel + Apicula) does not support
configuring the MIPI D-PHY hard macro. The Apicula project has been
progressively reverse-engineering Gowin primitives, but hard IP blocks like
D-PHY are not yet documented or supported. Using D-PHY would require
switching to Gowin's proprietary IDE.

#### c) Soft-core MIPI D-PHY is not feasible

MIPI D-PHY requires differential signaling at 80 Mbps to 1.5 Gbps per lane
with precise timing. Bit-banging this through general-purpose LVCMOS33 I/O
pins is not possible — you'd need proper LVDS drivers and sub-nanosecond
edge control that GPIO pins cannot provide.

### Verdict: Pure MIPI DSI is ruled out on this board + toolchain.

---

## 3. Viable Alternatives

### Option A: SPI display with a larger panel (Recommended near-term)

**Displays:** ILI9488 or ST7796 (480×320, SPI interface)

These are the same class of SPI display we already use (ST7789), just larger.
Our existing `st7789.sv` driver architecture transfers directly.

| Metric | Value |
|---|---|
| Resolution | 480×320 (1.5× Game Boy in each axis) |
| Interface | 4-wire SPI (same as current) |
| SPI clock | Up to 62.5 MHz |
| Throughput | ~62.5 Mbps → **~12 fps** full-screen at RGB565 |
| Game Boy window refresh | **~40 fps** (only updating 160×144 region) |
| Pin count | 6 pins (same as current) |
| Toolchain impact | None — fully compatible |

**Pros:** Drop-in replacement for our current driver. No new IP needed.
Partial-screen updates keep frame rate acceptable for Game Boy.

**Cons:** Still SPI-limited. 480×320 is the practical max at usable frame
rates.

### Option B: SPI-configured display with RGB parallel pixel interface

**Displays:** ST7701S or ILI9806E (480×800, SPI + DPI/RGB interface)

These controllers support a hybrid mode: SPI sends init/config commands
(slow, just at startup), then pixel data flows over a parallel RGB bus.

| Metric | Value |
|---|---|
| Resolution | 480×800 |
| Config interface | 3-wire SPI (3 pins, used only during init) |
| Pixel interface | RGB565 parallel (16 data + HSYNC + VSYNC + DE + PCLK = 20 pins) |
| Pixel clock | ~25–33 MHz |
| Throughput | 25 MHz × 16 bits = **400 Mbps** → full 60 fps |
| Total pin count | ~23 pins |
| Toolchain impact | None — all standard GPIO |

**Pros:** Full 60 fps at 480×800. Pure SystemVerilog implementation. No
hard IP needed. Works with our open-source toolchain.

**Cons:** Consumes ~23 GPIO pins. Need to verify the Tang Nano 20K has
enough free pins on its headers (the board exposes ~40 GPIO on its edge
connectors, so this should be feasible but tight). Requires writing a new
DPI timing generator module.

### Option C: Upgrade the board

**Board:** Sipeed Tang Primer 25K (GW5A-25, QFN88)

This board has native MIPI D-PHY at 2.5 Gbps per lane, DDR3, and is
designed for camera/display work. It uses the Gowin Arora V family.

**Pros:** Real MIPI DSI support. More logic, more memory.

**Cons:** Requires Gowin's proprietary IDE for D-PHY configuration.
Different pin assignments — all constraints and possibly some platform
code would need porting. Higher cost.

---

## 4. Recommendation

**For the 480×800 goal, Option B (SPI + RGB parallel) is the best path.**

It gives us full 60 fps at 480×800, stays entirely in SystemVerilog with our
open-source toolchain, and doesn't require any hard IP. The implementation
is a straightforward parallel video timing generator — significantly simpler
than MIPI DSI.

The development path would be:

1. Write an RGB/DPI timing generator in SystemVerilog (HSYNC, VSYNC, DE,
   pixel clock, blanking intervals)
2. Write a lightweight SPI init sequence module for the ST7701S (similar
   to our existing ST7789 init ROM, but only runs once at startup)
3. Connect the Game Boy PPU output to a scaler/mapper that places the
   160×144 image within the 480×800 frame
4. Wire up ~23 GPIO pins to the display via the Tang Nano 20K headers

The RGB timing generator is a well-understood pattern and much simpler than
MIPI DSI protocol handling. The hardest part is the physical wiring and
verifying that the Tang Nano 20K headers have enough accessible pins in
compatible I/O banks.

---

## 5. Summary Table

| Approach | Resolution | FPS | Pins | Toolchain | Complexity |
|---|---|---|---|---|---|
| Current ST7789 SPI | 240×240 | ~30 | 6 | Open-source | Done |
| **A.** Larger SPI (ILI9488) | 480×320 | ~12-40 | 6 | Open-source | Low |
| **B.** SPI + RGB parallel | 480×800 | 60 | ~23 | Open-source | Medium |
| **C.** Board upgrade + MIPI | 480×800+ | 60 | ~6 | Proprietary | High |
| Pure soft MIPI DSI | — | — | — | — | Not feasible |
