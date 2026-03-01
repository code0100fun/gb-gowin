# CPU BSRAM Wait States

## Problem

The Gowin GW2AR-18's BSRAM blocks have synchronous reads: you present an
address on clock edge N and the data appears on clock edge N+1. Our CPU
executes one M-cycle per clock, so when an instruction reads VRAM or WRAM,
the data isn't ready until the next cycle.

The real SM83 CPU avoids this entirely because it runs at 4 MHz with 4
T-cycles per M-cycle. The address goes out on T0 and the data is captured
on T2 — two T-cycles of slack absorb any memory latency. Our 1-M-cycle-
per-clock architecture doesn't have that slack.

## Current Solution: `mem_wait` Freeze

Added in Tutorial 14. When the CPU reads from VRAM (0x8000-0x9FFF) or WRAM
(0xC000-0xDFFF), the top-level module asserts `mem_wait` for one cycle:

```
Cycle 0: CPU presents address + rd=1 → mem_wait=1, CPU freezes
Cycle 1: BSRAM data valid → mem_wait=0, CPU resumes
```

The freeze is implemented in two places in `cpu.sv`:

1. **`always_ff`**: A `mem_wait` guard wraps the entire non-reset body.
   When asserted, no internal state changes (IR, M-cycle counter, W/Z
   registers, mode flags).

2. **`always_comb`**: A final override zeroes all write enables
   (`rf_r8_we`, `rf_r16_we`, `rf_r16stk_we`, `rf_flags_we`, `rf_sp_we`,
   `rf_pc_we`, `mem_wr`, `int_ack`). The read signals (`mem_rd`,
   `mem_addr`) are intentionally NOT suppressed so the BSRAM sees the
   request.

Wait-state generation in `gb_top.sv`:

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

ROM and HRAM use combinational reads (distributed RAM), so they never
trigger `mem_wait`.

## Precedent

This approach is common among Game Boy FPGA implementations:

- **Gamebub** (Chisel/Scala, Xilinx) uses a `clocker.enable` signal that
  gates all register writes system-wide. When memory isn't ready, the
  enable is suppressed and the entire emulator freezes. The author reports
  ~0.5% stall overhead for DMG — imperceptible. See
  [eli.lipsitz.net/posts/fpga-gameboy-emulator](https://eli.lipsitz.net/posts/fpga-gameboy-emulator/).

- **MiSTer Gameboy** (SystemVerilog, Cyclone V) avoids the problem by
  running the system clock at 33-64 MHz and generating 4 MHz clock enable
  pulses. BSRAM responds within one fast clock cycle, so WAIT_n is tied
  to 1. Requires a PLL.

- **VerilogBoy** (Verilog) models the real 4 MHz T-cycle pipeline: address
  on T0, data captured on T2. No stalls needed because the architecture
  inherently accounts for the latency. Requires a much more complex CPU.

## Timing Accuracy

The freeze approach is not cycle-accurate with real hardware. An
instruction that reads VRAM/WRAM takes 1 extra system clock compared to
one that reads ROM or HRAM. No Game Boy software can observe this
difference (the CPU bus interface is identical from the software
perspective), but our internal cycle count diverges from a real SM83.

This is acceptable for DMG. The only scenario where it matters is
cycle-exact PPU/CPU synchronization for mid-scanline register tricks, and
those are rare enough that the 1-cycle jitter is invisible on an SPI LCD
that doesn't have per-pixel timing anyway.

## GBC Double-Speed Mode

Game Boy Color adds a double-speed CPU mode (KEY1 register, FF4D) that
doubles the M-cycle rate from ~1 MHz to ~2 MHz. Memory access patterns
become more demanding:

- At normal speed, ~0.5% of cycles stall (Gamebub's measurement).
- At double speed, the CPU issues memory requests twice as fast but BSRAM
  latency stays the same. Gamebub measured stall rates above **10%** in
  double-speed mode, concentrated on cartridge ROM reads.

For our architecture, VRAM and WRAM stalls will similarly increase. The
exact overhead depends on the game's memory access pattern, but 5-15%
is a reasonable estimate.

### Mitigation: Read Cache

Gamebub solved the GBC double-speed problem with a **512-entry
direct-mapped cache** for cartridge ROM reads. The same strategy applies
here:

1. **Identify the hot path.** Profile which memory regions cause the most
   stalls. Cartridge ROM (0x0000-0x7FFF) is the biggest offender because
   instruction fetches hit it every M-cycle. WRAM and VRAM are less
   frequent.

2. **Add a small direct-mapped cache.** A 256- or 512-entry cache with
   8-bit data lines and 15-bit tags (for the 32 KB ROM address space)
   uses minimal LUTs. On a cache hit, `mem_wait` is not asserted and the
   CPU proceeds without stalling. On a miss, the CPU stalls for 1 cycle
   while the BSRAM is read and the cache line is filled.

3. **Cache invalidation.** ROM is read-only so no invalidation is needed.
   For WRAM, a write-through policy keeps the cache coherent: writes go
   to both the cache and BSRAM, reads check the cache first.

4. **VRAM complications.** VRAM is written by both the CPU and DMA. If
   VRAM access is a bottleneck, a cache would need to be invalidated on
   DMA transfers. In practice, VRAM reads from the CPU are rare enough
   that caching may not be worthwhile — the PPU has its own dedicated
   BSRAM port.

### Alternative: 2x System Clock

Another option is to double the system clock (54 MHz on the Tang Nano 20K
using the PLL) and generate M-cycle enable pulses at the original rate.
BSRAM responds within one fast clock cycle, so reads never stall. This
is essentially the MiSTer approach.

Pros:
- Eliminates stalls entirely, no cache needed.
- Simpler correctness argument (no cache coherence).

Cons:
- Requires PLL configuration and clock domain management.
- All timing constraints tighten (less slack at 54 MHz).
- Power consumption increases.
- The Tang Nano 20K's GW2AR-18 comfortably runs at 54 MHz (the current
  design achieves 34 MHz with margin), so this is feasible.

### Recommendation

For DMG-only operation, the current `mem_wait` freeze is sufficient and
correct. When GBC support is added:

1. First measure the actual stall rate in double-speed mode.
2. If stalls cause visible slowdown, try the 2x system clock approach
   first — it's architecturally simpler than a cache.
3. If the 2x clock causes timing issues or the design needs to run at an
   even higher frequency for other reasons (SDRAM controller, HDMI), fall
   back to a direct-mapped ROM read cache.

## Related Files

| File | Role |
|------|------|
| `rtl/core/cpu/cpu.sv` | `mem_wait` input, freeze logic |
| `rtl/platform/gb_top.sv` | `bsram_read_done` register, `mem_wait` generation |
| `rtl/ppu/ppu.sv` | Dual-port BSRAM VRAM, tile-fetch pipeline |
| `rtl/memory/single_port_ram.sv` | WRAM BSRAM instance |
| `rtl/memory/dual_port_ram.sv` | VRAM BSRAM instance |
| `sim/top/cpu_bus_top.sv` | Sim wrapper, `mem_wait` tied to 0 |
| `sim/top/timer_top.sv` | Sim wrapper, `mem_wait` tied to 0 |
