# Tutorial 20 — MBC1 Memory Bank Controller

So far our Game Boy can only address 32 KB of ROM — enough for a handful of
early titles but not much else. Real cartridges include a memory bank
controller (MBC) chip that lets the CPU page through much larger ROM chips
and optional external RAM. MBC1 is the most common mapper, used by Tetris,
Super Mario Land, The Legend of Zelda: Link's Awakening, and hundreds of
others. This tutorial adds full MBC1 support, unlocking up to 2 MB of ROM
(128 banks) and 32 KB of external RAM (4 banks).

## How MBC1 Works

The Game Boy CPU sees a 16-bit address space. The cartridge ROM is mapped
to 0000–7FFF (32 KB), split into two 16 KB windows:

- **0000–3FFF**: Bank 0 window (usually fixed to ROM bank 0)
- **4000–7FFF**: Switchable bank window

The MBC1 chip on the cartridge intercepts *writes* to the ROM address range
(0000–7FFF) and uses them to set internal bank registers. Reads still come
from ROM — the writes are "write-only" from the ROM's perspective but
update the MBC's banking state.

### Register Map

| Address Range | Register | Width | Description |
|:-------------|:---------|:------|:------------|
| 0000–1FFF | RAM Enable | 4 bits | Lower nibble == 0xA enables external RAM |
| 2000–3FFF | ROM Bank | 5 bits | Selects ROM bank for 4000–7FFF (0 maps to 1) |
| 4000–5FFF | RAM Bank | 2 bits | Upper ROM bits or RAM bank select |
| 6000–7FFF | Banking Mode | 1 bit | 0 = ROM mode, 1 = RAM/Advanced mode |

**Bank 0-to-1 fixup**: When the ROM bank register is 0, the switchable
window still uses bank 1. Writing 0x00 to 2000–3FFF is the same as writing
0x01. This prevents the switchable window from duplicating the bank 0
window.

### Address Translation

The MBC1 translates CPU addresses into physical ROM/RAM addresses:

**ROM (21-bit address = 2 MB)**:
- 0000–3FFF (bank 0 window):
  - Mode 0: `{2'b00, 5'b00000, cpu_addr[13:0]}` — always bank 0
  - Mode 1: `{ram_bank, 5'b00000, cpu_addr[13:0]}` — banks 0x00/0x20/0x40/0x60
- 4000–7FFF (switchable bank):
  - `{ram_bank, rom_bank_adj, cpu_addr[13:0]}`

**External RAM (15-bit address = 32 KB)**:
- Mode 0: `{2'b00, cpu_addr[12:0]}` — always bank 0
- Mode 1: `{ram_bank, cpu_addr[12:0]}` — 4 banks

External RAM only responds when enabled *and* the address is in A000–BFFF.

## Implementation

### MBC1 Module

The MBC1 module monitors the CPU bus directly — it watches `cpu_addr`,
`cpu_wr`, and `cpu_wdata` without going through the address decoder. It
checks `!cpu_addr[15]` to catch writes to 0000–7FFF, then decodes by
`cpu_addr[14:13]`:

```systemverilog
module mbc1 (
    input  logic        clk,
    input  logic        reset,
    input  logic [15:0] cpu_addr,
    input  logic        cpu_wr,
    input  logic [7:0]  cpu_wdata,
    output logic [20:0] rom_addr,
    output logic [14:0] extram_addr,
    output logic        extram_en,
    // Debug outputs...
);
```

The register writes use a simple case statement:

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        ram_en    <= 1'b0;
        rom_bank  <= 5'd0;
        ram_bank  <= 2'd0;
        bank_mode <= 1'b0;
    end else if (cpu_wr && !cpu_addr[15]) begin
        case (cpu_addr[14:13])
            2'b00: ram_en    <= (cpu_wdata[3:0] == 4'hA);
            2'b01: rom_bank  <= cpu_wdata[4:0];
            2'b10: ram_bank  <= cpu_wdata[1:0];
            2'b11: bank_mode <= cpu_wdata[0];
        endcase
    end
end
```

Address translation is purely combinational. The bank 0-to-1 fixup is a
one-liner:

```systemverilog
wire [4:0] rom_bank_adj = (rom_bank == 5'd0) ? 5'd1 : rom_bank;
```

The `extram_en` output combines the RAM enable register with an address
range check:

```systemverilog
extram_en = ram_en && (cpu_addr[15:13] == 3'b101);
```

### Bus Changes

The bus module gains five new ports for external RAM:

```systemverilog
output logic        extram_cs,
output logic        extram_we,
output logic [7:0]  extram_wdata,
input  logic [7:0]  extram_rdata,
input  logic        extram_en      // from MBC1
```

The A000–BFFF region, previously a stub returning 0xFF, now checks
`extram_en`:

```systemverilog
// External RAM: A000-BFFF
16'b101?_????_????_????: begin
    if (extram_en) begin
        extram_cs = 1'b1;
        extram_we = cpu_wr;
        cpu_rdata = extram_rdata;
    end else begin
        cpu_rdata = 8'hFF;
    end
end
```

When `extram_en` is low (the default), reads still return 0xFF, so all
existing bus tests pass without changes.

### gb_top Integration

Three additions to the top-level module:

1. **MBC1 instance** — wired to `cpu_addr`, `cpu_wr`, `cpu_wdata`. Its
   `rom_addr` output replaces the direct `rom_addr` indexing into ROM BRAM.

2. **External RAM** — a 32 KB `single_port_ram` instance, addressed by the
   MBC1's `extram_addr` output. The bus's `extram_cs && extram_we` drives
   the write enable.

3. **Wait state update** — `extram_cs` is added to the BSRAM read wait
   condition alongside `vram_cs` and `wram_cs`, since external RAM is also
   synchronous BSRAM.

## Test Results

The MBC1 testbench verifies all banking behaviors:

```
$ mise run test:mbc1
12/12 tests passed
```

| Test | Verifies |
|:-----|:---------|
| Power-on defaults | All registers zero after reset |
| Bank 0 window | 0000–3FFF maps to ROM bank 0 |
| Bank 0→1 fixup | Writing 0 to rom_bank, 4000–7FFF uses bank 1 |
| ROM bank switch | Bank 5 at 4000–7FFF gives correct address |
| Only 5 bits | Writing 0xFF stores 0x1F |
| Upper ROM bits | ram_bank=2 sets bits [20:19] |
| Mode 1 low bank | Mode 1 + ram_bank=2 → bank 0 window changes |
| RAM enable/disable | 0x0A enables, 0x0B disables, 0x3A enables |
| ExtRAM read/write | Write 0x42 to A000, read back |
| ExtRAM disabled | Returns 0xFF when ram_en=0 |
| RAM banking mode 1 | extram_addr uses ram_bank in mode 1 |
| Writes above 0x7FFF | No effect on MBC registers |

Full regression:

```
$ mise run test
162/162 tests passed
```

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `rtl/cart/mbc1.sv` | Created | Bank registers + address translation |
| `sim/top/mbc1_top.sv` | Created | Standalone test wrapper with ROM + ExtRAM |
| `sim/test/mbc1.zig` | Created | 12 MBC1 tests |
| `rtl/core/bus.sv` | Modified | Added extram ports for A000–BFFF |
| `rtl/platform/gb_top.sv` | Modified | MBC1 instance, ExtRAM BSRAM, wait states |
| `sim/top/cpu_bus_top.sv` | Modified | Connected new extram bus ports |
| `sim/top/timer_top.sv` | Modified | Connected new extram bus ports |
| `build.zig` | Modified | Added mbc1_mod + test, gb_top sources |
| `mise.toml` | Modified | mbc1.sv in synth, test:mbc1 task |

## What's Next

Tutorial 21 adds SD card ROM loading — an SPI SD card reader that lists
.gb files on a FAT32 partition using the ST7789 display and joypad for
selection. This replaces the BRAM boot ROM with a proper boot menu,
letting us load real game ROMs into SDRAM.
