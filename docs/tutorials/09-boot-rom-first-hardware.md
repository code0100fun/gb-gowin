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
    input  logic       btn_s1,     // reset (active low)
    input  logic       btn_s2,     // unused
    output logic [5:0] led         // onboard LEDs (active low)
);
```

The parameters default to our test ROM so synthesis just works without extra
configuration. The ports match `constraints.cst` from tutorial 02.

### Reset Synchronizer

The button is an asynchronous input — it can change at any time relative to the
clock. Using it directly as a reset risks metastability (the flip-flop sees the
input during its setup/hold window and enters an undefined state). A two-stage
synchronizer eliminates this:

```systemverilog
    logic [1:0] rst_sync;
    logic       reset;

    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], ~btn_s1};  // btn is active low
    end
    assign reset = rst_sync[1];
```

The `~btn_s1` inverts the active-low button to active-high reset. Two flip-flops
in series give the metastable signal time to settle before it reaches the CPU.

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
    initial begin
        for (int i = 0; i < ROM_SIZE; i++) rom_mem[i] = 8'h00;
        if (ROM_FILE != "")
            $readmemh(ROM_FILE, rom_mem);
    end
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

The testbench (`sim/tb/tb_gb_top.cpp`) drives the reset button, waits 50
cycles, and checks the LED output:

```cpp
    tb.dut->btn_s1 = 0;  // press reset
    tb.tick(5);
    tb.dut->btn_s1 = 1;  // release
    tb.tick(3);           // synchronizer propagation
    tb.tick(50);          // run program

    uint8_t led_out = tb.dut->led & 0x3F;
    uint8_t led_reg = (~led_out) & 0x3F;
    tb.check(led_reg == 0x1F, "LED register = 0x1F");
```

## Building and Running

```bash
# Simulate
mise run sim:gb_top

# Full build (synth → place-and-route → bitstream)
mise run build

# Flash to Tang Nano 20K
mise run flash
```

After flashing, the five lower LEDs should light up immediately. Press S1 to
reset — the LEDs will briefly go dark, then light up again as the CPU re-
executes the program in under a microsecond.

## What's Next

We have a working Game Boy CPU running on real FPGA hardware. The next step is
adding the interrupt controller (IF/IE registers, interrupt dispatch, HALT
wake-up) so the system can respond to events from peripherals like the timer
and PPU.
