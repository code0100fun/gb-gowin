# Tutorial 19 — Serial Port (SB/SC Registers)

Single-player Game Boy games often probe the serial hardware during
initialization — Tetris, for example, checks the SB and SC registers before
proceeding. Without these registers, reads return 0x00 and writes are silently
dropped, which can cause games to hang or behave incorrectly. This tutorial
adds a minimal serial port — just enough for internal-clock transfers so games
that probe serial are satisfied.

## Game Boy Serial Protocol

The Game Boy serial port is a simple shift register with a selectable clock:

- **SB (FF01)** — Serial transfer data. An 8-bit shift register. During an
  internal-clock transfer, SB shifts out MSB-first and shifts in 1s (no link
  partner connected), ending up as 0xFF after transfer completes.

- **SC (FF02)** — Serial control.
  - Bit 7: Transfer start / in-progress (1 = active, auto-clears on complete)
  - Bits 6–1: Unused, always read as 1
  - Bit 0: Clock select (0 = external, 1 = internal 8192 Hz)

Writing SC with bits 7 and 0 both set starts an internal-clock transfer. The
serial controller shifts SB left once per bit period (128 M-cycles at 8192 Hz),
shifting in 1s from the right. After 8 bits, SC bit 7 auto-clears and the
serial interrupt (IF bit 3) fires.

Since we have no link cable hardware, external clock mode (bit 0 = 0) simply
waits forever — the transfer never completes.

## LED Register Relocation

There's one complication: FF01 (`io_addr = 0x01`) was previously used for the
LED debug register. Serial needs this address for SB. The fix is to relocate
the LED register to FF50 (`io_addr = 0x50`), which is the boot ROM lock
register on a real Game Boy. Since we don't have a boot ROM that uses this
address, it's a safe place to park the LED register.

This change requires updating `boot_test.hex` to write to the new address.

## Implementation

### serial.sv

The serial module follows the same I/O peripheral pattern as timer and joypad:

```systemverilog
module serial #(
    parameter int CLOCKS_PER_BIT = 128  // 8192 Hz at 1 M-cycle/clk
) (
    input  logic       clk, reset,
    input  logic       io_cs,
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,
    output logic       io_rdata_valid,
    output logic       irq,
    output logic [7:0] dbg_sb, dbg_sc
);
```

Internal state:
- `sb_reg` — 8-bit shift register (SB)
- `sc_transfer` — SC bit 7 (transfer active)
- `sc_clock` — SC bit 0 (clock select)
- `bit_cnt` — 3-bit counter (0–7 bits shifted)
- `clk_cnt` — countdown timer per bit period
- `transferring` — internal flag, separate from `sc_transfer`

The read mux is purely combinational — addr 0x01 returns `sb_reg`, addr 0x02
returns `{sc_transfer, 6'b111111, sc_clock}`. The `io_rdata_valid` signal
tells the top-level I/O mux when the serial module is responding.

### Transfer State Machine

When the CPU writes SC with both bit 7 and bit 0 set:

1. `transferring` and `sc_transfer` are set
2. `clk_cnt` loads with `CLOCKS_PER_BIT - 1`
3. Each tick decrements `clk_cnt`
4. When `clk_cnt` reaches 0: shift SB left, OR in 1, increment `bit_cnt`
5. After 8 shifts (`bit_cnt == 7`): clear `transferring` and `sc_transfer`,
   pulse `irq`

The shift logic and register write logic are in a single `always_ff` block
to avoid multi-driver issues (a lesson from Tutorial 12).

### Integration in gb_top.sv

Four changes to the top level:

1. **LED register**: Move from `io_addr == 7'h01` to `io_addr == 7'h50`
   (both the write check and the read mux case)

2. **Serial instantiation**: Same pattern as timer and joypad — wire `io_cs`,
   `io_addr`, `io_wr`, `io_wdata`, and connect `io_rdata`/`io_rdata_valid`

3. **IF register**: Add `serial_irq` to IF bit 3:
   ```systemverilog
   if (serial_irq) next_if = next_if | 5'b01000;
   ```

4. **I/O read mux**: Add `serial_rdata_valid` to the priority chain

## Tests

Five tests verify the serial port (`sim/test/serial.zig`):

| # | Test | Verifies |
|---|------|----------|
| 1 | SB read/write | Write 0x42 to SB, read it back |
| 2 | SC read format | Unused bits 6–1 read as 1 (0x7E after reset) |
| 3 | Internal transfer | SC bit 7 clears after 8×CLOCKS_PER_BIT cycles, SB = 0xFF |
| 4 | Serial IRQ | Exactly 1 IRQ pulse on transfer complete |
| 5 | External clock no-op | SC bit 0 = 0, no transfer happens |

The test wrapper (`sim/top/serial_top.sv`) uses `CLOCKS_PER_BIT = 4` for fast
simulation and hardwires `io_cs = 1`.

Note: the `readReg` helper must call `dut.eval()` after setting `io_addr` to
propagate the combinational read mux before reading `io_rdata`. Without this,
stale values from the previous evaluation are returned.

```
$ mise run test:serial
5/5 tests passed

$ mise run test
150/150 tests passed
```

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `rtl/io/serial.sv` | Created | SB/SC registers + shift logic |
| `sim/top/serial_top.sv` | Created | Standalone test wrapper |
| `sim/test/serial.zig` | Created | 5 serial port tests |
| `build.zig` | Modified | Added serial_mod + test entry, gb_top sources |
| `rtl/platform/gb_top.sv` | Modified | LED → 0x50, serial instance, IRQ, read mux |
| `sim/data/boot_test.hex` | Modified | LED address 0x01 → 0x50 |
| `mise.toml` | Modified | serial.sv in synth, test:serial task |

## What's Next

Tutorial 20 adds the MBC1 mapper — bank switching for ROM (up to 2 MB) and
optional external RAM (up to 32 KB). This is the last piece needed before
loading real game ROMs from an SD card.
