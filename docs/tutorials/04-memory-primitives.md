# Tutorial 04 — Memory Primitives

The Game Boy needs several types of memory: video RAM for tile data, work RAM
for general use, a small high-speed RAM for the CPU stack, and a ROM for the
boot sequence. In this tutorial we'll build the three memory primitives that
all of these are based on, and test each one thoroughly.

## The Game Boy's Memory Budget

Before we build anything, let's understand what we need and what we have.

The Game Boy uses these memories:

| Memory | Size | Purpose |
|--------|------|---------|
| VRAM | 8 KB | Tile patterns, tile maps, sprite data |
| WRAM | 8 KB | General-purpose working RAM |
| OAM | 160 B | Sprite attribute table (40 sprites × 4 bytes) |
| HRAM | 127 B | High-speed RAM, accessible during DMA |
| Boot ROM | 256 B | Startup sequence (read-only) |
| **Total** | **~16.5 KB** | **~134 Kbits** |

Our GW2AR-18 FPGA has **828 Kbits of Block SRAM** (BSRAM), organized as 46
blocks of 18 Kbits each. We need about 134 Kbits — roughly 16% of the
available BSRAM. Plenty of headroom.

### How BSRAM Works

Block SRAM on the GW2AR-18 consists of dedicated memory blocks embedded in the
FPGA fabric. Each 18 Kbit block can be configured as different widths:

- 2048 × 8 (most common for our use)
- 1024 × 16
- 512 × 32
- 4096 × 4
- etc.

The key property: BSRAM is **synchronous** — reads and writes happen on clock
edges, not instantly. This is different from what you might expect if you're
used to software arrays. When you present an address, the data appears on the
**next** clock edge, not immediately.

### Inference vs Instantiation

There are two ways to use BSRAM:

1. **Inference** — write your RAM in standard SystemVerilog, and let Yosys
   recognize the pattern and map it to BSRAM automatically.
2. **Instantiation** — directly use Gowin's `SDPB`, `DPB`, or `pROM` primitives.

We'll use inference. It's portable (the same code works on any FPGA vendor),
readable, and Yosys handles it well for Gowin targets. The key is writing the
RAM in a style that Yosys recognizes.

## Module 1: Single-Port RAM

A single-port RAM has one address port shared for reading and writing. This is
the simplest memory and what we'll use for WRAM, HRAM, and OAM.

Create `rtl/memory/single_port_ram.sv`:

```systemverilog
module single_port_ram #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8
) (
    input  logic                   clk,
    input  logic                   we,
    input  logic [ADDR_WIDTH-1:0]  addr,
    input  logic [DATA_WIDTH-1:0]  wdata,
    output logic [DATA_WIDTH-1:0]  rdata
);

    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

    always_ff @(posedge clk) begin
        if (we)
            mem[addr] <= wdata;
        rdata <= mem[addr];
    end

endmodule
```

Let's break down the design:

### Parameters

```systemverilog
parameter int ADDR_WIDTH = 10,
parameter int DATA_WIDTH = 8
```

Using parameters makes the module reusable. We'll instantiate it with different
sizes for different Game Boy memories:

- WRAM: `ADDR_WIDTH=13` (8 KB = 2^13 bytes)
- HRAM: `ADDR_WIDTH=7` (128 bytes, only 127 used)
- OAM: `ADDR_WIDTH=8` (256 bytes, only 160 used)

### The Memory Array

```systemverilog
logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];
```

This declares an array of `2^ADDR_WIDTH` elements, each `DATA_WIDTH` bits wide.
Yosys recognizes this pattern and maps it to BSRAM blocks. The `[0:N-1]` syntax
is an **unpacked array** — the standard way to declare memory in SystemVerilog.

### Read-First Behavior

```systemverilog
always_ff @(posedge clk) begin
    if (we)
        mem[addr] <= wdata;
    rdata <= mem[addr];
end
```

Both the write and the read happen in the same `always_ff` block, on the same
clock edge. Because we use non-blocking assignments (`<=`), both statements are
evaluated using the **current** values of `mem`, then both are updated:

1. If `we` is high: `mem[addr]` is scheduled to become `wdata`
2. `rdata` is scheduled to become `mem[addr]` (the **old** value)

This is called **read-first** behavior: on a simultaneous read+write to the same
address, you get the old value. The new value is available on the next cycle.

This behavior is important because it's what Gowin BSRAM implements natively.
If you write the code differently (e.g., put the read after the write with
blocking assignments), Yosys might not infer BSRAM, or worse, might silently
use LUT-based RAM that's much less efficient.

### Synchronous Read Latency

Because `rdata` is registered (`<=` inside `always_ff`), there's a one-cycle
latency: you present an address on cycle N, and the data appears at `rdata` on
cycle N+1. This is different from an asynchronous read where data would appear
immediately.

```
Cycle:     1         2         3
           ┌─────────┐         ┌─────────┐
clk  ──────┘         └─────────┘         └──
addr:  ═══ 0x05 ════════════════ 0x0A ══════
rdata: ═══ (old) ════ data@05 ══ (old) ═════
                      ↑ data appears here
```

The CPU will need to account for this latency in its bus timing.

## Module 2: Dual-Port RAM

A dual-port RAM has two independent ports — each with its own clock, address,
data, and write-enable. Both ports access the same underlying memory.

We need this for:
- **VRAM**: the CPU writes tile data while the PPU reads it for rendering
- **Framebuffer**: the PPU writes pixels (Game Boy clock) while the LCD
  controller reads them (SPI clock)

Create `rtl/memory/dual_port_ram.sv`:

```systemverilog
module dual_port_ram #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8
) (
    // Port A
    input  logic                   clk_a,
    input  logic                   we_a,
    input  logic [ADDR_WIDTH-1:0]  addr_a,
    input  logic [DATA_WIDTH-1:0]  wdata_a,
    output logic [DATA_WIDTH-1:0]  rdata_a,

    // Port B
    input  logic                   clk_b,
    input  logic                   we_b,
    input  logic [ADDR_WIDTH-1:0]  addr_b,
    input  logic [DATA_WIDTH-1:0]  wdata_b,
    output logic [DATA_WIDTH-1:0]  rdata_b
);

    // verilator lint_off MULTIDRIVEN
    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];
    // verilator lint_on MULTIDRIVEN

    always_ff @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end

    always_ff @(posedge clk_b) begin
        if (we_b)
            mem[addr_b] <= wdata_b;
        rdata_b <= mem[addr_b];
    end

endmodule
```

### Two Independent always_ff Blocks

Each port gets its own `always_ff` block with its own clock. This is what makes
it "true" dual-port — the two ports can run on different clocks. Yosys
recognizes this pattern and maps it to the dual-port BSRAM primitives in the
GW2AR-18.

### The MULTIDRIVEN Lint Suppression

```systemverilog
// verilator lint_off MULTIDRIVEN
logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];
// verilator lint_on MULTIDRIVEN
```

Verilator warns when two `always_ff` blocks write to the same variable (the
`mem` array). For dual-port RAM, this is intentional and correct — both ports
can write to the shared memory. The `lint_off` tells Verilator to suppress the
warning for this specific variable.

### Simultaneous Access Hazard

What happens if both ports write to the **same address** on the same clock
edge? The result is undefined — the memory could contain either value, or
something corrupted. Our design must prevent this.

Fortunately, the Game Boy hardware naturally prevents it:
- The PPU has exclusive access to VRAM during Mode 3 (pixel transfer). The CPU
  can't access VRAM during this time.
- For the framebuffer, the PPU only writes and the LCD controller only reads —
  they never write to the same address.

### Clock Domain Crossing

When port A and port B use different clocks, the dual-port RAM acts as a safe
clock domain crossing mechanism. Each port's read data is registered on its own
clock, so there's no metastability risk — the BSRAM hardware handles it
internally.

This is exactly what we'll need for the framebuffer: the PPU writes pixels on
the Game Boy's ~4.19 MHz core clock, and the SPI LCD controller reads them on
a clock derived from the 27 MHz system clock.

## Module 3: ROM

A ROM (read-only memory) is loaded at synthesis time from a hex file and cannot
be written to at runtime. We'll use this for the Game Boy's 256-byte boot ROM
and for embedding small test ROMs directly into the bitstream.

Create `rtl/memory/rom.sv`:

```systemverilog
module rom #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 8,
    parameter     INIT_FILE  = ""
) (
    input  logic                   clk,
    input  logic [ADDR_WIDTH-1:0]  addr,
    output logic [DATA_WIDTH-1:0]  rdata
);

    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        rdata <= mem[addr];
    end

endmodule
```

### $readmemh

```systemverilog
initial begin
    if (INIT_FILE != "")
        $readmemh(INIT_FILE, mem);
end
```

`$readmemh` reads a text file containing hex values (one per line) and loads
them into the memory array. This happens at **elaboration time** — both in
simulation (Verilator reads the file when the testbench starts) and in synthesis
(Yosys reads the file and bakes the data into the BSRAM initialization).

The hex file format is simple — one byte per line:

```
DE
AD
BE
EF
CA
FE
```

### No Write Port

The ROM has no `we` or `wdata` — it's read-only. Yosys will infer a BSRAM
block configured as ROM. On the actual hardware, the BSRAM is initialized when
the bitstream is loaded, and cannot be modified at runtime.

### The INIT_FILE Parameter

The `INIT_FILE` is passed as a string parameter. In simulation, Verilator
accepts it via the `-G` flag:

```bash
verilator ... -GADDR_WIDTH=8 -GDATA_WIDTH=8 '-GINIT_FILE="sim/data/test_rom.hex"'
```

In synthesis, you'll set it in the instantiation:

```systemverilog
rom #(.ADDR_WIDTH(8), .INIT_FILE("path/to/boot.hex")) boot_rom_inst (...);
```

## Testing

Each module gets its own testbench. Let's look at the key tests.

### Single-Port RAM Tests (`sim/test/single_port_ram.zig`)

| Test | What it verifies |
|------|-----------------|
| Write then read | Data persists after write |
| Multiple addresses | 16 different addresses with a pattern |
| Overwrite | New write replaces old data |
| Write-enable gating | `we=0` does not modify memory |
| Read-first | Simultaneous read+write returns the OLD value |

The read-first test is especially important:

```zig
test "read-first behavior" {
    var dut = try ram.Model.init(.{});
    defer dut.deinit();

    // Write 0x42 to address 0x0A
    dut.set(.we, 1);
    dut.set(.addr, 0x0A);
    dut.set(.wdata, 0x42);
    dut.tick();

    // Simultaneous read+write: output should be OLD value
    dut.set(.we, 1);
    dut.set(.addr, 0x0A);
    dut.set(.wdata, 0x99);
    dut.tick();

    try std.testing.expectEqual(@as(u64, 0x42), dut.get(.rdata));
}
```

### Dual-Port RAM Tests (`sim/test/dual_port_ram.zig`)

| Test | What it verifies |
|------|-----------------|
| Write A, read B | Cross-port data sharing |
| Write B, read A | Cross-port in the other direction |
| Independent reads | Both ports read different addresses simultaneously |
| Independent clocks | Ports work with separate clock signals |
| Bulk verify | 64-address fill via port A, read back via port B |

The dual-port RAM has two independent clocks (`clk_a`, `clk_b`), so it's
defined with `.clock = null` in `build.zig` — we toggle clocks manually:

```zig
fn tick(dut: *dpr.Model) void {
    dut.set(.clk_a, 1);
    dut.set(.clk_b, 1);
    dut.eval();
    dut.set(.clk_a, 0);
    dut.set(.clk_b, 0);
    dut.eval();
}

fn tickA(dut: *dpr.Model) void {
    dut.set(.clk_a, 1);
    dut.eval();
    dut.set(.clk_a, 0);
    dut.eval();
}
```

### ROM Tests (`sim/test/rom.zig`)

| Test | What it verifies |
|------|-----------------|
| Read initialized data | All 16 loaded bytes match expected values |
| Re-read consistency | Reverse-order re-read produces same data |
| Uninitialized addresses | Beyond the loaded data, reads return 0x00 |
| Synchronous latency | Output updates on clock edge, not immediately |

The synchronous latency test confirms that ROM reads are registered:

```zig
test "synchronous read latency" {
    var dut = try rom.Model.init(.{});
    defer dut.deinit();

    // Set address to 0 and tick — output updates
    dut.set(.addr, 0);
    dut.tick();
    const val_at_0 = dut.get(.rdata);

    // Change address — output should NOT change until next tick
    dut.set(.addr, 5);
    dut.eval(); // combinational only, no clock edge
    try std.testing.expectEqual(val_at_0, dut.get(.rdata));

    // Now tick — output updates
    dut.tick();
    try std.testing.expectEqual(@as(u64, EXPECTED[5]), dut.get(.rdata));
}
```

## Running the Tests

```bash
# Run all testbenches
mise run test

# Run just one
mise run test:single_port_ram
mise run test:dual_port_ram
mise run test:rom
```

## How Yosys Infers BSRAM

For Yosys to recognize your memory as BSRAM (rather than building it from
flip-flops), follow these rules:

1. **Use an `always_ff` block** with a single clock edge for both read and
   write.
2. **Use non-blocking assignments** (`<=`) for all writes and reads.
3. **Keep reads synchronous** — `rdata <= mem[addr]` inside `always_ff`, not
   `assign rdata = mem[addr]` (which would be asynchronous).
4. **Size matters** — very small memories (< 64 bits) may be implemented in
   LUTs. Larger memories are automatically mapped to BSRAM.
5. **Avoid complex read logic** — don't put conditional expressions or
   arithmetic in the read path inside the `always_ff`.

If Yosys can't infer BSRAM, you'll see your LUT and FF counts increase
dramatically (an 8 KB RAM built from flip-flops would use ~65,000 FFs — more
than our FPGA has). The synthesis report will show BSRAM usage — check it to
confirm inference is working.

## What's Next

In [Tutorial 05](05-cpu-registers-and-alu.md) we'll start building the Game
Boy CPU. We'll design the register file (which uses flip-flops, not BSRAM —
it's small and needs multi-port access) and the ALU that performs all arithmetic
and logic operations. These are the CPU's data path — the foundation that every
instruction depends on.
