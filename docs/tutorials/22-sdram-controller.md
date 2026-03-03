# Tutorial 22 — SDRAM Controller

The Tang Nano 20K includes a 64 Mbit SDRAM chip (HY57V641620F) embedded right
in the GW2AR-18 package. Until now, ROM loading has been limited to 32 KB of
BSRAM — enough for Tetris but not for multi-bank games. This tutorial adds an
SDRAM controller, a behavioral model for simulation, a hardware test, and then
integrates SDRAM into gb_top so that ROM (up to 2 MB) and external RAM (32 KB)
are backed by SDRAM. VRAM and WRAM stay in fast 1-cycle BSRAM.

## The HY57V641620F SDRAM

The embedded SDRAM is a standard 64 Mbit (8 MB) synchronous DRAM with a 32-bit
data bus. Here are the key specs:

| Parameter | Value |
|-----------|-------|
| Capacity | 64 Mbit (8 MB) |
| Organization | 4 banks × 2048 rows × 256 columns × 32 bits |
| Data bus width | 32 bits |
| CAS latency | 2 cycles (at 27 MHz) |
| Refresh interval | 64 ms / 8192 rows |

At our 27 MHz system clock, one cycle is 37 ns — very relaxed compared to the
SDRAM's typical 20 ns timing specs. Every timing constraint (tRCD, tRP, tRC)
fits in 1–2 cycles with room to spare. No PLL is needed — we simply output the
inverted clock (`sdram_clk = ~clk`) to give the SDRAM a 180° phase shift for
clean setup/hold margins.

## Address Decomposition

The controller exposes a 23-bit byte address (8 MB range). Internally, each
address is split into bank, row, column, and byte offset to address the 32-bit
wide SDRAM:

```
addr[22:21] = bank     (2 bits  → 4 banks)
addr[20:10] = row      (11 bits → 2048 rows)
addr[9:2]   = column   (8 bits  → 256 words)
addr[1:0]   = byte_off (2 bits  → byte within 32-bit word)
```

Since the SDRAM is 32 bits wide but we operate on bytes, the controller uses
DQM (data mask) pins to select which byte lane to read or write.

## The SDRAM Controller (`rtl/memory/sdram_ctrl.sv`)

The controller provides a simple pulse-driven interface: assert `rd`, `wr`, or
`refresh` for one cycle with an address, then wait for `data_ready` (reads) or
`!busy` (writes/refresh).

```systemverilog
module sdram_ctrl #(
    parameter int FREQ  = 27_000_000,
    parameter int CAS   = 2,
    parameter int T_WR  = 2,   // Write recovery
    parameter int T_RP  = 1,   // Precharge to activate
    parameter int T_RCD = 1,   // Activate to read/write
    parameter int T_RC  = 2    // Refresh/activate cycle time
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        rd, wr, refresh,
    input  logic [22:0] addr,
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        data_ready,
    output logic        busy,
    // SDRAM physical interface (active-low control)
    output logic        sdram_clk, sdram_cke, sdram_cs_n,
    output logic        sdram_ras_n, sdram_cas_n, sdram_we_n,
    output logic [10:0] sdram_addr,
    output logic [1:0]  sdram_ba,
    output logic [3:0]  sdram_dqm,
    // Split DQ bus (Verilator-compatible)
    output logic [31:0] sdram_dq_out,
    output logic        sdram_dq_oe,
    input  logic [31:0] sdram_dq_in
);
```

### Split DQ Bus

Real SDRAM uses a bidirectional `inout` data bus. Verilator doesn't support
`inout`, so the controller uses three signals instead: `sdram_dq_out` (data to
write), `sdram_dq_oe` (output enable), and `sdram_dq_in` (data from SDRAM).
The synthesis top-level collapses these back into a tristate:

```systemverilog
assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 32'bZ;
assign sdram_dq_in = IO_sdram_dq;
```

### SDRAM Commands

Commands are encoded as `{RAS#, CAS#, WE#}` — three active-low signals:

| Command | {RAS#, CAS#, WE#} |
|---------|--------------------|
| NOP | 111 |
| ACTIVATE | 011 |
| READ | 101 |
| WRITE | 100 |
| PRECHARGE | 010 |
| AUTO-REFRESH | 001 |
| MODE REG SET | 000 |

### FSM Overview

The controller has six states:

```
S_INIT → S_CONFIG → S_IDLE → S_READ / S_WRITE / S_REFRESH
```

**S_INIT**: Wait 200 µs after power-on (5400 cycles at 27 MHz). The SDRAM
needs time to stabilize before accepting commands.

**S_CONFIG**: Run the one-time setup sequence — Precharge All, two
Auto-Refresh cycles, then Mode Register Set (CAS=2, burst length=1).

**S_IDLE**: Accept `rd`, `wr`, or `refresh` pulses. Latch address and data.

**S_READ**: Activate row → Read command (with auto-precharge via A10) → wait
CAS latency → capture data. Total: 5 cycles.

**S_WRITE**: Activate row → Write command (with auto-precharge) → drive data
for one cycle → wait for write recovery. Total: 6 cycles.

**S_REFRESH**: Issue Auto-Refresh command → wait T_RC. Total: 3 cycles.

### Byte Masking with DQM

On writes, the byte value is replicated across all four lanes of the 32-bit
bus, then DQM selects which lane to actually write (0 = write, 1 = mask):

```systemverilog
sdram_dq_out <= {din_buf, din_buf, din_buf, din_buf};
case (addr_buf[1:0])
    2'd0: sdram_dqm <= 4'b1110;  // write byte 0 only
    2'd1: sdram_dqm <= 4'b1101;
    2'd2: sdram_dqm <= 4'b1011;
    2'd3: sdram_dqm <= 4'b0111;
endcase
```

On reads, all four bytes are returned. The `byte_off` (latched from
`addr[1:0]`) selects the correct byte from the 32-bit result:

```systemverilog
case (byte_off)
    2'd0: dout <= sdram_dq_in[7:0];
    2'd1: dout <= sdram_dq_in[15:8];
    2'd2: dout <= sdram_dq_in[23:16];
    2'd3: dout <= sdram_dq_in[31:24];
endcase
```

## Behavioral SDRAM Model (`sim/model/sdram_model.sv`)

For simulation, a behavioral model stands in for the real SDRAM chip. It
samples commands on `negedge clk` (which corresponds to `posedge sdram_clk`
since `sdram_clk = ~clk`) — matching the real SDRAM's sampling edge.

Key features:
- **Flat byte array**: 8 MB `mem[0:8388607]` — preloadable from test wrappers
- **Per-bank row tracking**: `active_row[0:3]` and `row_active[0:3]`
- **CAS latency pipeline**: A 2-stage shift register delays read data by the
  configured CAS latency, accurately modeling real SDRAM behavior
- **DQM write masking**: Each DQM bit controls whether its corresponding byte
  is written, matching the spec (`0 = write, 1 = mask`)
- **Auto-precharge**: When A10 is set on READ/WRITE commands, the row is
  automatically closed

The model uses the split DQ interface (no `inout`) for Verilator
compatibility, matching the controller's interface.

## Simulation Tests

The test wrapper (`sim/top/sdram_ctrl_top.sv`) wires `sdram_ctrl` directly to
`sdram_model` over the split DQ bus, exposing only the user-side interface to
the Zig testbench.

```
$ mise run test:sdram_ctrl
9/9 tests passed
```

| Test | Description |
|------|-------------|
| initialization completes | Busy for ~5400 cycles (200 µs at 27 MHz), then idle |
| write then read single byte | Round-trip 0xAB at address 0 |
| all four byte offsets | 0x11–0x44 at consecutive addresses in same word — validates DQM |
| different banks | Write/read 4 bank-0/1/2/3 addresses (0x000000–0x600000) |
| different rows | Write/read across row boundaries (stride = 1024 bytes) |
| sequential write/read block | 256-byte pattern write + readback, zero errors |
| refresh does not corrupt data | Write pattern, 10 refreshes, verify data intact |
| large address range | Write/read near top of 8 MB space (0x7FFFFC–0x7FFFFF) |
| interleaved read/write/refresh | Realistic mixed access pattern |

## Hardware Test (`rtl/platform/sdram_test_top.sv`)

Before integrating into gb_top, a standalone hardware test verifies the SDRAM
controller works on real silicon. Flash it, connect a UART terminal, and press
S1 to run:

```
$ mise run flash -- sdram_test_top
$ picocom -b 115200 /dev/ttyUSB1
>123OK
```

The output characters mean:

| Char | Meaning |
|------|---------|
| `>` | Boot started, waiting for SDRAM init |
| `1` | Test 1 pass: single byte write/read at address 0 |
| `2` | Test 2 pass: four byte offsets (DQM masking) |
| `3` | Test 3 pass: 1 MB block write and verify |
| `OK` | All tests passed |
| `!N` | Test N failed |

### SDRAM Pin Assignments

The GW2AR-18's embedded SDRAM uses special "magic" pin names (`IOL`/`IOR`)
that the open-source toolchain (Apicula/nextpnr) understands:

```
IO_LOC "O_sdram_clk"  IOR11B;
IO_LOC "O_sdram_cke"  IOL13A;
IO_LOC "O_sdram_cs_n" IOL14B;
...
IO_LOC "IO_sdram_dq[0]" IOL3A;
IO_LOC "IO_sdram_dq[1]" IOL3B;
...
```

These pin names were already added to `constraints.cst` in this tutorial, taken
from the open-source sdram-tang-nano-20k reference project.

### Refresh Timer

SDRAM requires periodic refresh to retain data — all 2048 rows must be
refreshed within 64 ms. The test uses a 9-bit counter that wraps at 400 cycles:

```
400 cycles × 37 ns = 14.8 µs per refresh
```

That's well within the 31 µs maximum interval. When the timer fires, it sets a
`ref_needed` flag. The test FSM services refresh between other operations. This
same pattern is reused in gb_top.

### The `skip_busy` Pattern

After issuing a command, `busy` goes high on the *same* clock edge. If you
check `!busy` on the next cycle, it might still appear low (combinational
hazard). The hardware test uses a `skip_busy` flag: set it when issuing a
command, skip the first `!busy` check, then wait for busy to genuinely fall.

## Integrating SDRAM into gb_top

With the controller proven in simulation and hardware, the final step is
replacing the BSRAM-backed ROM and ExtRAM with SDRAM in gb_top. This removes
the 32 KB ROM cap and enables multi-bank MBC1 games up to 2 MB.

### SDRAM Address Map

```
0x000000 – 0x1FFFFF  ROM      (2 MB, from MBC1 rom_addr[20:0])
0x200000 – 0x207FFF  ExtRAM   (32 KB, from MBC1 extram_addr[14:0])
```

### What Stays in BSRAM

VRAM (8 KB) and WRAM (8 KB) remain in BSRAM — they need 1-cycle reads for PPU
timing. SDRAM reads take ~5 cycles, which is fine for ROM (the CPU already has
a wait-state mechanism) but too slow for VRAM tile fetches.

### SDRAM Controller Instance

Inside a `USE_SD != 0` generate block, gb_top instantiates `sdram_ctrl` with
the same split-DQ tristate pattern as the hardware test:

```systemverilog
sdram_ctrl u_sdram (
    .clk(clk), .reset(hw_reset),
    .rd(sdram_rd), .wr(sdram_wr), .refresh(sdram_refresh),
    .addr(sdram_a), .din(sdram_din),
    .dout(sdram_dout), .data_ready(sdram_data_ready), .busy(sdram_busy),
    ...
);

assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 32'bZ;
assign sdram_dq_in = IO_sdram_dq;
```

The SDRAM controller receives `hw_reset` (not `reset`) so it begins
initialization during the SD boot phase, before the CPU comes out of reset.

### sd_boot Changes

The SD boot loader now writes ROM data directly to SDRAM instead of BSRAM:

- **Wider address**: `rom_addr` is now 23 bits (was 15) to address 8 MB
- **No 32 KB cap**: The loader continues until `rom_bytes_loaded >= file_size`
- **Backpressure via `sdram_busy`**: Since SDRAM writes take ~6 cycles,
  sd_boot buffers each incoming SPI byte in a `pending_byte` register.
  The byte is written to SDRAM only when `!sdram_busy`. This is safe because
  SPI bytes arrive every ~80+ clocks at the fast ÷4 clock speed.

```systemverilog
// Drain pending byte to SDRAM when not busy
if (pending_wr && !sdram_busy) begin
    rom_addr   <= rom_bytes_loaded[22:0];
    rom_data   <= pending_byte;
    rom_wr     <= 1'b1;
    pending_wr <= 1'b0;
    rom_bytes_loaded <= rom_bytes_loaded + 32'd1;
end
```

### SDRAM Command Arbiter

The SDRAM has a single port shared between boot writes, CPU reads/writes, and
refresh. A combinational arbiter selects based on `boot_done`:

**Boot mode** (`!boot_done`): sd_boot writes ROM data. Refresh runs when idle.

**Run mode** (`boot_done`): CPU reads (ROM and ExtRAM) and writes (ExtRAM
only) go through the SDRAM controller. Refresh fires when the CPU isn't
accessing memory.

```systemverilog
if (!boot_done) begin
    if (sd_rom_wr && !sdram_busy) begin
        sdram_wr = 1'b1; sdram_a = sd_rom_addr; sdram_din = sd_rom_data;
    end else if (ref_needed && !sdram_busy)
        sdram_refresh = 1'b1;
end else begin
    if (cpu_rd_pulse)
        begin sdram_rd = 1'b1; sdram_a = cpu_sdram_addr; end
    else if (cpu_wr_pulse)
        begin sdram_wr = 1'b1; sdram_a = cpu_sdram_addr; sdram_din = extram_wdata; end
    else if (ref_needed && !sdram_busy)
        sdram_refresh = 1'b1;
end
```

### CPU Wait-State FSM

A small FSM tracks the lifecycle of each CPU SDRAM access:

```
SCPU_IDLE → SCPU_WAIT → SCPU_DONE → (back to IDLE when CPU drops rd/wr)
```

**IDLE**: Detect `cpu_sdram_rd` or `cpu_sdram_wr` when `!sdram_busy`.
Issue the rd/wr pulse and transition to WAIT.

**WAIT**: For reads, wait for `data_ready` and latch `sdram_dout`. For writes,
wait for `!sdram_busy` (write recovery complete). Transition to DONE.

**DONE**: Release `mem_wait` so the CPU proceeds. Return to IDLE when the CPU
drops its rd/wr signals.

The rd/wr pulse fires only on the IDLE→WAIT transition — this prevents
re-pulsing while the CPU is frozen with stable address and control signals.

### Wait-State Generation

```systemverilog
// BSRAM reads: VRAM and WRAM only (1-cycle latency)
wire bsram_rd = (vram_cs || wram_cs) && cpu_rd;

// SDRAM: ~5 cycles for reads, ~6 for writes
wire sdram_mem_wait = boot_done && cpu_sdram_access &&
                      scpu_state != SCPU_DONE;

wire mem_wait = (bsram_rd && !bsram_read_done) || sdram_mem_wait;
```

### USE_SD=0 Simulation Path

When `USE_SD=0` (simulation), nothing changes from before:
- ROM is distributed RAM loaded via `$readmemh`
- ExtRAM is a BSRAM `single_port_ram`
- All SDRAM outputs are tied low, DQ is undriven
- `sdram_mem_wait` is hardwired to 0
- All existing gb_top tests pass unchanged

## Building and Testing

Full regression passes with no regressions:

```
$ mise run test
Build Summary: 78/78 steps succeeded; 183/183 tests passed
```

Synthesis for hardware:

```
$ mise run build -- gb_top
```

The design meets timing at 29.89 MHz (target: 27 MHz) with SDRAM included.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `rtl/memory/sdram_ctrl.sv` | Created | SDRAM controller — init, read, write, refresh |
| `sim/model/sdram_model.sv` | Created | Behavioral SDRAM model for simulation |
| `sim/top/sdram_ctrl_top.sv` | Created | Sim wrapper wiring controller to model |
| `sim/test/sdram_ctrl.zig` | Created | 9 simulation tests |
| `rtl/platform/sdram_test_top.sv` | Created | Standalone hardware test (UART output) |
| `rtl/platform/constraints.cst` | Modified | SDRAM pin assignments (IOL/IOR names) |
| `rtl/cart/sd_boot.sv` | Modified | 23-bit addr, sdram_busy backpressure, no 32KB cap |
| `sim/top/sd_boot_top.sv` | Modified | Updated for wider rom_addr and sdram_busy port |
| `rtl/platform/gb_top.sv` | Modified | SDRAM controller, arbiter, wait states, address map |
| `build.zig` | Modified | sdram_ctrl Verilator model + test target |
| `mise.toml` | Modified | sdram_ctrl in gb_top synth, new test tasks |

## What's Next

Tutorial 23 adds audio — all four Game Boy sound channels (two square waves,
one custom waveform, one noise) mixed into a single output, driven through a
PWM DAC on a GPIO pin.
