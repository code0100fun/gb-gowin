# Tutorial 09 — Boot ROM and First Hardware Run

Time to leave simulation behind and run real instructions on real hardware. In
this tutorial we embed a small test program in the FPGA, wire up the CPU, bus,
and memory, and verify execution by lighting LEDs on the Tang Nano 20K.

## The Goal

A 14-byte program stored in ROM that:

1. Loads two values into registers (proves **ROM fetch** works)
2. XORs them together (proves the **ALU** works)
3. Writes the result to HRAM and reads it back (proves **HRAM** works)
4. Writes the final value to an LED register (proves **I/O writes** work)

If five LEDs light up in binary pattern `011111`, the entire chain — clock,
reset, CPU, bus, ROM, HRAM, and I/O — is working correctly.

## The Test Program

```
Address  Hex       Instruction        Effect
──────── ───────── ────────────────── ──────────────────
0x00     3E 15     LD A, 0x15         A = 0b010101
0x02     06 0A     LD B, 0x0A         B = 0b001010
0x04     A8        XOR A, B           A = 0x1F (0b011111)
0x05     E0 80     LDH (0x80), A      [FF80] = 0x1F (HRAM write)
0x07     3E 00     LD A, 0x00         A = 0 (clear)
0x09     F0 80     LDH A, (0x80)      A = 0x1F (HRAM read)
0x0B     E0 01     LDH (0x01), A      [FF01] = 0x1F (LED register)
0x0D     76        HALT               done
```

The hex file (`sim/data/boot_test.hex`) is just these 14 bytes, one per line.

## The FPGA Top Module

Create `rtl/platform/gb_top.sv`. This is the first real "system on chip" — it
connects all the pieces we've built so far.

### Port List

```systemverilog
module gb_top #(
    parameter int ROM_SIZE = 256,
    parameter     ROM_FILE = "sim/data/boot_test.hex"
) (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset (active high with Apicula)
    input  logic       btn_s2,     // unused
    output logic [5:0] led         // onboard LEDs (active low)
);
```

The parameters default to our test ROM so synthesis just works without extra
configuration. The ports match `constraints.cst` from tutorial 02.

### Power-On Reset

The CPU needs a clean reset pulse at power-on. On the Gowin GW2AR-18, all
flip-flops initialize to 0 via the Global Set/Reset (GSR) network. We use a
free-running counter that counts up from 0 and deasserts reset when it
saturates:

```systemverilog
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)             // btn_s1=1 when pressed → reset
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];
```

At power-on, `por_cnt` is 0 → `reset = 1`. The counter increments each clock
cycle and reset deasserts after 16 clocks (~0.6 µs at 27 MHz). Pressing
`btn_s1` clears the counter and re-asserts reset.

**Why not a synchronizer?** A traditional two-FF synchronizer would shift in
the idle button state on every clock. But the open-source Apicula toolchain
does not apply `PULL_MODE=UP` from constraint files, so `btn_s1` floats low
when not pressed and reads high when pressed (active high). A synchronizer
that depends on the button's idle state for power-on reset won't work if the
pin floats to an unexpected value. The counter approach is self-starting — it
doesn't depend on any external pin to begin counting.

### CPU and Bus Wiring

The CPU and bus are instantiated and connected exactly as in the tutorial 08
integration test. The CPU's debug ports are left unconnected (not needed on
hardware):

```systemverilog
    cpu u_cpu (
        .clk(clk), .reset(reset),
        .mem_addr(cpu_addr), .mem_rd(cpu_rd), .mem_wr(cpu_wr),
        .mem_wdata(cpu_wdata), .mem_rdata(cpu_rdata),
        .halted(halted),
        .dbg_pc(), .dbg_sp(),
        .dbg_a(), .dbg_f(), .dbg_b(), .dbg_c(),
        .dbg_d(), .dbg_e(), .dbg_h(), .dbg_l()
    );
```

### Memory: Distributed RAM

The key architectural decision: all memory uses **combinational reads**
(`assign rdata = mem[addr]`). Yosys implements these as distributed RAM — small
lookup tables built from the FPGA's LUTs rather than dedicated BSRAM blocks.

```systemverilog
    // ROM (combinational read)
    logic [7:0] rom_mem [0:ROM_SIZE-1];
    initial if (ROM_FILE != "")
        $readmemh(ROM_FILE, rom_mem);
    assign rom_rdata = rom_mem[rom_addr[$clog2(ROM_SIZE)-1:0]];

    // HRAM (127 bytes, combinational read, synchronous write)
    logic [7:0] hram_mem [0:126];
    assign hram_rdata = hram_mem[hram_addr];
    always_ff @(posedge clk) begin
        if (hram_cs && hram_we)
            hram_mem[hram_addr] <= hram_wdata;
    end
```

This works because the CPU expects data in the same cycle it presents the
address (combinational memory model from tutorial 07). Distributed RAM
delivers exactly that — no clock-cycle delay.

**Why not BSRAM?** Block SRAM has registered outputs — data appears one cycle
after the address. Our CPU's combinational read model doesn't account for that
latency. We'll solve this properly when we add the SDRAM controller in a later
tutorial. For now, distributed RAM handles ROM (256 B) and HRAM (127 B) easily.

**What about WRAM?** 8 KB of distributed RAM would consume too many LUTs (the
GW2AR-18 only has ~20K LUT4s). WRAM is stubbed out for this tutorial — the bus
returns 0xFF for WRAM addresses. The test program only uses HRAM.

### LED Register

A single I/O register at address FF01 drives the onboard LEDs:

```systemverilog
    logic [7:0] led_reg;

    always_ff @(posedge clk) begin
        if (reset)
            led_reg <= 8'h00;
        else if (io_cs && io_wr && io_addr == 7'h01)
            led_reg <= io_wdata;
    end

    assign io_rdata = (io_addr == 7'h01) ? led_reg : 8'h00;
    assign led = ~led_reg[5:0];  // LEDs are active low
```

The CPU writes to FF01 using `LDH (0x01), A`. The `~` inversion accounts for
the Tang Nano 20K's active-low LED drivers.

## Resource Usage

After synthesis and place-and-route:

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT4 | 4,299 | 20,736 | 20% |
| DFF | 235 | 15,552 | 1% |
| RAM16SDP4 | 16 | 648 | 2% |
| BSRAM | 0 | 46 | 0% |

Plenty of room for the PPU, timer, and other peripherals.

## Synthesis Fix: Latch Inference

During synthesis, Yosys flagged a latch on `push_val` in the CPU's PUSH
instruction handler. This variable was declared inside a `casez` branch and
wasn't assigned in all paths of the enclosing `always_comb`. The fix: add a
default initialization before the `unique case`:

```systemverilog
    logic [15:0] push_val;
    push_val = 16'h0000;           // ← added
    unique case (ir[5:4])
        2'd0: push_val = {rf_out_b, rf_out_c};
        // ...
    endcase
```

This is a common SystemVerilog pitfall — simulation tools like Verilator don't
care (they track all branches), but synthesis tools require every signal in an
`always_comb` to be assigned on every path.

## Simulation Testbench

The testbench (`sim/test/gb_top.zig`) simulates the exact FPGA power-on
sequence: `btn_s1 = 0` (not pressed, floats low), then waits for the POR
counter to release reset and the CPU to execute the program:

```zig
test "power-on reset — LED output" {
    var dut = try gb_top.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 0); // not pressed (floats low on hardware)
    dut.set(.btn_s2, 1);

    // Run enough cycles for POR (16 clocks) + program execution (~14 M-cycles)
    for (0..100) |_| dut.tick();

    // LEDs are active low: led = ~led_reg[5:0].
    // Expected led_reg = 0x1F (binary 011111).
    const led_out: u8 = @truncate(dut.get(.led) & 0x3F);
    const led_reg = (~led_out) & 0x3F;
    try std.testing.expectEqual(@as(u8, 0x1F), led_reg);
}
```

## Building and Running

```bash
# Simulate
mise run test:gb_top

# Full build (synth → place-and-route → bitstream)
mise run build

# Flash to Tang Nano 20K
mise run flash
```

After flashing, the five lower LEDs should light up immediately. Press S1 to
reset — the LEDs will go dark, then light up again as the POR counter releases
reset and the CPU re-executes the program in under a microsecond.

## What's Next

We have a working Game Boy CPU running on real FPGA hardware. The next step is
adding the interrupt controller (IF/IE registers, interrupt dispatch, HALT
wake-up) so the system can respond to events from peripherals like the timer
and PPU.
