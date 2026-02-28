# Tutorial 08 — Memory Bus

Up to now the CPU has talked to a flat 64 KB memory array in the testbench.
Real Game Boy hardware doesn't have a single flat memory — it has ROM, WRAM,
HRAM, I/O registers, and more, all sharing a single 16-bit address bus. An
**address decoder** examines the address and routes read/write traffic to the
correct device. This tutorial builds that address decoder.

**Source:** [Pan Docs — Memory Map](https://gbdev.io/pandocs/Memory_Map.html)

## The Game Boy Memory Map

Every memory access by the CPU goes through a single 16-bit bus. The hardware
uses the upper bits of the address to decide which chip responds:

| Address Range | Size | Device | This Tutorial |
|---------------|------|--------|:-------------:|
| 0000–7FFF | 32 KB | Cartridge ROM | Active |
| 8000–9FFF | 8 KB | VRAM | Stub (FF) |
| A000–BFFF | 8 KB | External (cartridge) RAM | Stub (FF) |
| C000–DFFF | 8 KB | Work RAM (WRAM) | Active |
| E000–FDFF | ~8 KB | Echo RAM (mirrors C000–DDFF) | Active |
| FE00–FE9F | 160 B | OAM (sprite attributes) | Stub (FF) |
| FEA0–FEFF | 96 B | Unusable | Returns FF |
| FF00–FF7F | 128 B | I/O registers | Active (select only) |
| FF80–FFFE | 127 B | High RAM (HRAM) | Active |
| FFFF | 1 B | Interrupt Enable (IE) register | Active |

"Stub" means we generate the chip-select signal but return 0xFF (open bus)
instead of connecting real hardware. Those devices will be added in later
tutorials.

"Active (select only)" means the bus drives a chip-select line and routes
read/write data, but no actual register logic exists yet — I/O reads return
0x00 for now.

## What Is an Address Decoder?

An address decoder is a purely combinational circuit — no clock, no state. It
takes the CPU's address and produces:

1. **Chip-select lines** — one per device, at most one active at a time.
2. **Local addresses** — strips the high bits so each device sees addresses
   starting at zero. For example, address 0xC100 on the CPU bus becomes WRAM
   local address 0x0100.
3. **Read-data mux** — selects which device's data goes back to the CPU. If
   no device is selected, returns 0xFF (open bus).
4. **Write routing** — passes the CPU's write data and write-enable to the
   selected device.

```
                  CPU
                   │
          ┌────────┴────────┐
          │  ADDRESS DECODER │
          │                  │
          │  addr[15:0] ──────► chip selects
          │                  │
          │  rdata ◄─────────── read mux (ROM / WRAM / HRAM / IO / IE)
          │                  │
          │  wdata ──────────► write routing
          └──┬──┬──┬──┬──┬──┘
             │  │  │  │  │
           ROM WRAM HRAM IO IE
```

## The Bus Module

Create `rtl/core/bus.sv`:

```systemverilog
module bus (
    // CPU side
    input  logic [15:0] cpu_addr,
    input  logic        cpu_rd,
    input  logic        cpu_wr,
    input  logic [7:0]  cpu_wdata,
    output logic [7:0]  cpu_rdata,

    // ROM (0000-7FFF)
    output logic [14:0] rom_addr,
    output logic        rom_cs,
    input  logic [7:0]  rom_rdata,

    // WRAM (C000-DFFF, echoed at E000-FDFF)
    output logic [12:0] wram_addr,
    output logic        wram_cs,
    output logic        wram_we,
    output logic [7:0]  wram_wdata,
    input  logic [7:0]  wram_rdata,

    // HRAM (FF80-FFFE)
    output logic [6:0]  hram_addr,
    output logic        hram_cs,
    output logic        hram_we,
    output logic [7:0]  hram_wdata,
    input  logic [7:0]  hram_rdata,

    // I/O registers (FF00-FF7F)
    output logic [6:0]  io_addr,
    output logic        io_cs,
    output logic        io_rd,
    output logic        io_wr,
    output logic [7:0]  io_wdata,
    input  logic [7:0]  io_rdata,

    // IE register (FFFF)
    output logic        ie_cs,
    output logic        ie_we,
    output logic [7:0]  ie_wdata,
    input  logic [7:0]  ie_rdata
);
```

The port list has a clear pattern: each device gets a chip-select, a local
address (sized to match the device), read data flowing in, and write
data/enable flowing out. The CPU side has the full 16-bit address and the
read data mux output.

### Write Data Is Always the Same

Regardless of which device is selected, the write data is just the CPU's
write data passed through:

```systemverilog
    assign wram_wdata = cpu_wdata;
    assign hram_wdata = cpu_wdata;
    assign io_wdata   = cpu_wdata;
    assign ie_wdata   = cpu_wdata;
```

### Address Decode Logic

The actual decode is a single `always_comb` block using `casez` to match
address ranges by their upper bits:

```systemverilog
    always_comb begin
        // Defaults: nothing selected, open bus
        rom_cs  = 0; wram_cs = 0; hram_cs = 0; io_cs = 0; ie_cs = 0;
        wram_we = 0; hram_we = 0; io_rd = 0; io_wr = 0; ie_we = 0;

        rom_addr  = cpu_addr[14:0];
        wram_addr = cpu_addr[12:0];
        hram_addr = cpu_addr[6:0];
        io_addr   = cpu_addr[6:0];

        cpu_rdata = 8'hFF;  // open bus default

        casez (cpu_addr)
            16'b0???_????_????_????: begin  // 0000-7FFF: ROM
                rom_cs    = 1'b1;
                cpu_rdata = rom_rdata;
            end
            16'b100?_????_????_????: begin  // 8000-9FFF: VRAM (stub)
                cpu_rdata = 8'hFF;
            end
            16'b101?_????_????_????: begin  // A000-BFFF: ExtRAM (stub)
                cpu_rdata = 8'hFF;
            end
            16'b110?_????_????_????: begin  // C000-DFFF: WRAM
                wram_cs   = 1'b1;
                wram_we   = cpu_wr;
                cpu_rdata = wram_rdata;
            end
            16'b111?_????_????_????: begin  // E000-FFFF
                // This range contains many sub-regions
                // ...see full source for details...
            end
        endcase
    end
```

The first four ranges (ROM, VRAM, ExtRAM, WRAM) are simple: each covers a
power-of-two sized region that maps cleanly to the upper address bits. The
`casez` wildcard (`?`) matches either 0 or 1 for the don't-care bits.

### The E000–FFFF Sub-Regions

The range starting at 0xE000 is trickier — it packs several devices into a
2 KB space. We handle this with nested `if` statements inside the `casez`
case:

```systemverilog
            16'b111?_????_????_????: begin
                if (cpu_addr <= 16'hFDFF) begin
                    // Echo RAM → same as WRAM
                    wram_cs   = 1'b1;
                    wram_addr = cpu_addr[12:0];
                    wram_we   = cpu_wr;
                    cpu_rdata = wram_rdata;
                end else if (cpu_addr <= 16'hFE9F) begin
                    cpu_rdata = 8'hFF;  // OAM stub
                end else if (cpu_addr <= 16'hFEFF) begin
                    cpu_rdata = 8'hFF;  // Unusable
                end else if (cpu_addr <= 16'hFF7F) begin
                    // I/O registers
                    io_cs     = 1'b1;
                    io_rd     = cpu_rd;
                    io_wr     = cpu_wr;
                    cpu_rdata = io_rdata;
                end else if (cpu_addr <= 16'hFFFE) begin
                    // HRAM
                    hram_cs   = 1'b1;
                    hram_we   = cpu_wr;
                    cpu_rdata = hram_rdata;
                end else begin
                    // FFFF: IE register
                    ie_cs     = 1'b1;
                    ie_we     = cpu_wr;
                    cpu_rdata = ie_rdata;
                end
            end
```

Echo RAM at E000–FDFF maps to exactly the same WRAM addresses as C000–DDFF.
Since `cpu_addr[12:0]` for 0xE000 is 0x0000 (same as 0xC000), the local
address calculation is the same as for direct WRAM access.

### Why No Clock?

The bus module is **purely combinational** — the `module` declaration has no
`clk` input. This is intentional. The address decoder is just wires and muxes.
It introduces zero latency: the CPU presents an address, and the correct
device's data appears on `cpu_rdata` in the same combinational cycle.

This matters because our CPU expects combinational memory reads — it presents
`mem_addr` and reads `mem_rdata` before the clock edge. Putting a register in
the bus would add a cycle of latency and break this timing model.

## Testing the Bus

### Unit Test (sim/tb/tb_bus.cpp)

Since the bus has no clock, we don't use the `Testbench<T>` wrapper (which
expects a `clk` port). Instead we drive the Verilator model directly with
`eval()`:

```cpp
#include "Vbus.h"
#include <verilated.h>

static void probe(Vbus* d, uint16_t addr, uint8_t rom_rd = 0xAA,
                  uint8_t wram_rd = 0xBB, uint8_t hram_rd = 0xCC,
                  uint8_t io_rd = 0xDD, uint8_t ie_rd = 0xEE) {
    d->cpu_addr   = addr;
    d->cpu_rd     = 1;
    d->cpu_wr     = 0;
    d->rom_rdata  = rom_rd;
    d->wram_rdata = wram_rd;
    d->hram_rdata = hram_rd;
    d->io_rdata   = io_rd;
    d->ie_rdata   = ie_rd;
    d->eval();
}
```

The `probe` helper sets an address and provides fake read data for each device
(0xAA for ROM, 0xBB for WRAM, etc.). After `eval()`, we check:

- **Which chip-select fired** — exactly one should be active.
- **Local address** — verify the mapping (e.g., 0xC100 → wram_addr 0x0100).
- **Read data mux** — `cpu_rdata` should match the active device's data.
- **Open bus** — unmapped regions return 0xFF.

The test covers 20 cases: ROM (0x0000, 0x4000, 0x7FFF), VRAM/ExtRAM stubs,
WRAM (0xC000, 0xC100, 0xDFFF), Echo RAM (0xE000, 0xFDFF), OAM/unusable stubs,
I/O (0xFF00, 0xFF7F), HRAM (0xFF80, 0xFFFE), IE (0xFFFF), and write routing
for WRAM, I/O, and IE.

### Integration Test (sim/tb/tb_cpu_bus.cpp)

This test wires the real CPU to the bus with combinational memory arrays in a
top-level wrapper (`sim/top/cpu_bus_top.sv`). A hex file
(`sim/data/cpu_bus_test.hex`) contains a test program that:

1. Fetches instructions from **ROM** (the program runs at all = ROM works)
2. Writes 0x42 to **WRAM** at 0xC000, reads it back into B
3. Writes 0xAB to **HRAM** via `LDH (0x80),A`, reads it back into C
4. Writes 0x33 to WRAM at 0xC010, reads it through **Echo RAM** at 0xE010 into D
5. Calls a subroutine at 0x0030 with `CALL`/`RET`, which pushes the return
   address onto the **stack** (SP defaults to 0xFFFE, which is HRAM)

Expected results: A=0x77, B=0x42, C=0xAB, D=0x33, E=0x77.

#### The Top-Level Wrapper

`sim/top/cpu_bus_top.sv` instantiates the CPU, bus, and memory arrays:

```systemverilog
module cpu_bus_top #(
    parameter int ROM_SIZE = 256,
    parameter     ROM_FILE = ""
) (
    input  logic        clk,
    input  logic        reset,
    output logic        halted,
    // ...debug ports...
);
    cpu  u_cpu  ( .clk(clk), .mem_addr(cpu_addr), ... );
    bus  u_bus  ( .cpu_addr(cpu_addr), .cpu_rdata(cpu_rdata), ... );

    // ROM: combinational read
    logic [7:0] rom_mem [0:ROM_SIZE-1];
    assign rom_rdata = rom_mem[rom_addr[$clog2(ROM_SIZE)-1:0]];

    // WRAM: combinational read, synchronous write
    logic [7:0] wram_mem [0:8191];
    assign wram_rdata = wram_mem[wram_addr];
    always_ff @(posedge clk)
        if (wram_cs && wram_we) wram_mem[wram_addr] <= wram_wdata;

    // HRAM, IE: same pattern...
```

The memory arrays use `assign` for reads (combinational, same-cycle) and
`always_ff` for writes (registered, takes effect on the clock edge). This
matches the CPU's timing model.

#### Combinational Loop Warning

When Verilator sees the CPU's combinational output (`mem_addr`) feeding through
the bus back into `mem_rdata` (which the CPU reads combinationally), it flags a
`UNOPTFLAT` warning about circular combinational logic. This is expected — it's
the same loop that exists when the CPU testbench does
`tb.dut->mem_rdata = memory[tb.dut->mem_addr]`. We suppress it with
`-Wno-UNOPTFLAT` in the Verilator flags.

## Building and Running

```bash
# Run just the bus unit test
mise run sim:bus

# Run the CPU+bus integration test
mise run sim:cpu_bus

# Run the full simulation suite
mise run sim
```

## What's Next

The CPU can now access memory through a proper address decoder. In the next
tutorial we'll embed a test program in BRAM, wire the CPU and bus to real
memory primitives, and run it on the actual FPGA hardware for the first time.
