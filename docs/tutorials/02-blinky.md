# Tutorial 02 — Blinky

Time to make hardware do something. In this tutorial we'll write a blinking LED
design, create a constraint file to map our signals to physical pins, and
synthesize and flash it to the Tang Nano 20K. By the end, you'll have LEDs
blinking on your board — proof that the entire toolchain works end-to-end.

## The Design

Our blinky is simple: a counter that increments every clock cycle. When the
counter's upper bits change, the LEDs toggle. With a 27 MHz clock, we need to
count to about 13.5 million to get a 1 Hz blink (half-second on, half-second
off).

## The Tang Nano 20K Pins We'll Use

| Signal | Pin | Description |
|--------|-----|-------------|
| `clk`  | 4   | 27 MHz crystal oscillator |
| `led[0]` | 15  | LED 0 |
| `led[1]` | 16  | LED 1 |
| `led[2]` | 17  | LED 2 |
| `led[3]` | 18  | LED 3 |
| `led[4]` | 19  | LED 4 |
| `led[5]` | 20  | LED 5 |
| `btn_s1`  | 88  | User button S1 (active low) |
| `btn_s2`  | 87  | User button S2 (active low) |

The LEDs on the Tang Nano 20K are active low — driving a pin LOW turns the LED
ON. The buttons are also active low with internal pull-ups — they read LOW when
pressed.

## Step 1: Write the Constraint File

The constraint file tells the place-and-route tool which physical pin each
signal in your design connects to. Create `rtl/platform/constraints.cst`:

```
IO_LOC "clk" 4;
IO_PORT "clk" IO_TYPE=LVCMOS33;

IO_LOC "led[0]" 15;
IO_LOC "led[1]" 16;
IO_LOC "led[2]" 17;
IO_LOC "led[3]" 18;
IO_LOC "led[4]" 19;
IO_LOC "led[5]" 20;
IO_PORT "led[0]" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "led[1]" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "led[2]" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "led[3]" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "led[4]" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "led[5]" IO_TYPE=LVCMOS33 DRIVE=8;

IO_LOC "btn_s1" 88;
IO_LOC "btn_s2" 87;
IO_PORT "btn_s1" IO_TYPE=LVCMOS33 PULL_MODE=UP;
IO_PORT "btn_s2" IO_TYPE=LVCMOS33 PULL_MODE=UP;
```

Let's break down the syntax:

- `IO_LOC "signal" pin;` — maps a signal name to a physical pin number.
- `IO_PORT "signal" IO_TYPE=LVCMOS33;` — sets the electrical standard. LVCMOS33
  means 3.3V LVCMOS, which is what the Tang Nano 20K I/O banks use.
- `DRIVE=8` — sets the output drive strength in milliamps. 8 mA is plenty for
  an LED.
- `PULL_MODE=UP` — enables the internal pull-up resistor, so the button reads
  HIGH when not pressed.

We're including the buttons and all 6 LEDs in the constraint file even though
our first blinky won't use them all. This saves us from updating the file later.

## Step 2: Write the Blinky Module

Create `rtl/platform/blinky.sv`:

```systemverilog
module blinky (
    input  logic       clk,
    input  logic       btn_s1,
    input  logic       btn_s2,
    output logic [5:0] led
);

    // 27 MHz clock. To blink at ~1 Hz we need a ~25-bit counter.
    // Bit 24 toggles every 2^24 / 27_000_000 ≈ 0.62 seconds.
    // Bit 23 toggles every 2^23 / 27_000_000 ≈ 0.31 seconds.
    localparam int COUNTER_WIDTH = 25;

    logic [COUNTER_WIDTH-1:0] counter;

    always_ff @(posedge clk) begin
        counter <= counter + 1;
    end

    // Drive LEDs from the upper bits of the counter.
    // LEDs are active low, so invert the counter bits.
    // When btn_s1 is pressed (low), shift to a faster blink rate.
    always_comb begin
        if (!btn_s1)
            // Fast mode: use bits [21:16] — blinks ~8x faster
            led = ~counter[21:16];
        else
            // Normal mode: use bits [24:19] — leisurely blink
            led = ~counter[24:19];
    end

endmodule
```

Let's walk through every piece:

### Module Declaration

```systemverilog
module blinky (
    input  logic       clk,
    input  logic       btn_s1,
    input  logic       btn_s2,
    output logic [5:0] led
);
```

This declares a module named `blinky` with:
- `clk` — the 27 MHz clock input
- `btn_s1`, `btn_s2` — the two user buttons (active low)
- `led[5:0]` — the six LED outputs

The signal names here must match the names in the constraint file exactly.

### The Counter

```systemverilog
logic [COUNTER_WIDTH-1:0] counter;

always_ff @(posedge clk) begin
    counter <= counter + 1;
end
```

This is a 25-bit free-running counter. On every rising edge of the 27 MHz clock,
it increments by 1. When it overflows (reaches 2^25 - 1), it wraps back to 0.

We didn't include a reset. For a simple counter this is fine — the FPGA
initializes all flip-flops to 0 on power-up (this is a Gowin-specific
behavior; on Xilinx or Lattice FPGAs you'd want an explicit reset). For more
complex designs we'll always include resets.

### Driving the LEDs

```systemverilog
always_comb begin
    if (!btn_s1)
        led = ~counter[21:16];
    else
        led = ~counter[24:19];
end
```

This is combinational logic — no clock, no state. It continuously selects 6 bits
from the counter and inverts them (because the LEDs are active low).

- In normal mode, bits [24:19] create a slow cascading blink pattern. Bit 24
  toggles about every 0.62 seconds.
- When S1 is held, bits [21:16] give a faster pattern — about 8x faster.

Each LED blinks at a different rate because each bit of the counter toggles at
double the frequency of the bit above it. This creates a binary counting
pattern on the LEDs.

### Why No Reset?

You might wonder about the missing reset signal. On Gowin FPGAs, all flip-flops
initialize to 0 when the bitstream is loaded. For this simple design, that's
good enough — the counter starts at 0 and begins counting immediately.

In later tutorials, when we build the Game Boy core, we'll always include proper
reset logic because:
- It makes simulation deterministic
- It lets us reset the system without reloading the bitstream
- It's good practice for reliable designs

## Step 3: Build and Flash

Update the `mise.toml` to point to our blinky source. Edit the `[env]` section
and the `synth` task:

In `mise.toml`, set `TOP = "blinky"` and update `SV_FILES` in the `[env]`
section, then the synth task will use these variables.

For now, let's just run the commands directly to understand what each step does:

### Synthesize

```bash
mkdir -p build
yosys -p "read_verilog -sv rtl/platform/blinky.sv; synth_gowin -top blinky -json build/synth.json"
```

You'll see Yosys output showing:
- How many LUTs your design uses (should be around 25–30)
- How many flip-flops (25 for the counter)
- Any warnings (there shouldn't be any)

### Place and Route

```bash
nextpnr-himbaechel --json build/synth.json --write build/pnr.json \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
  --vopt cst=rtl/platform/constraints.cst
```

nextpnr will show the resource utilization — what percentage of the FPGA you're
using. For blinky, it'll be well under 1%.

### Generate Bitstream

```bash
gowin_pack -d GW2AR-18C -o build/blinky.fs build/pnr.json
```

### Flash

Plug in your Tang Nano 20K and run:

```bash
openFPGALoader -b tangnano20k build/blinky.fs
```

The LEDs should start blinking immediately. Hold the S1 button to see them
speed up.

### Using mise

Once you've verified the manual steps work, update `mise.toml` so you can run
`mise run flash` in the future. Set these in the `[env]` section:

```toml
TOP = "blinky"
SV_FILES = "rtl/platform/blinky.sv"
```

Then `mise run flash` will synthesize, place and route, pack, and flash in one
command.

## Step 4: Experiment

Now that you have a working design on the board, try modifying it:

1. **Change the blink rate.** What happens if you use `counter[22:17]` instead
   of `counter[24:19]`? Predict the new rate before you try it.

2. **Add S2 functionality.** Make S2 freeze the counter (stop it from
   incrementing). Hint: wrap the counter increment in `if (!btn_s2)`.

3. **Knight Rider pattern.** Instead of a binary counter, make a single lit LED
   sweep back and forth across the 6 LEDs. This requires an FSM or a
   shift register with direction control. Give it a try — it's a great exercise
   in sequential logic design.

## What Just Happened

Let's appreciate what the toolchain did:

1. **Yosys** read 25 lines of SystemVerilog and produced a netlist: 25
   flip-flops for the counter, a few LUTs for the increment logic and the mux,
   and I/O buffers for the pins.

2. **nextpnr-himbaechel** took that netlist and found a physical location for each
   flip-flop and LUT on the GW2AR-18 die, then routed all the wires between
   them while respecting timing constraints.

3. **gowin_pack** (Apicula) converted the placement and routing into the binary
   bitstream format the FPGA expects.

4. **openFPGAloader** sent the bitstream over USB, and the FPGA reconfigured
   itself in milliseconds.

This entire flow — from SystemVerilog to running hardware — takes about 5–10
seconds for a design this small. For the full Game Boy core it'll be longer, but
still under a minute.

## What's Next

In [Tutorial 03](03-simulation-and-testbenches.md) we'll add simulation to our
workflow. We'll write a Verilator testbench for the blinky module, generate
waveforms, and establish the test-driven development cycle that we'll use for
every Game Boy component.
