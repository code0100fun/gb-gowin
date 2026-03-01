# Tutorial 03 — Simulation and Testbenches

Flashing an LED and checking it by eye is fine for "hello world," but it won't
scale. The Game Boy CPU has 512 opcodes. The PPU has sub-scanline timing edge
cases. We need to test all of this programmatically, in simulation, before
anything touches the board.

In this tutorial we'll:
1. Set up the zig-verilator library for testbench development
2. Write a Zig testbench for our blinky module
3. Generate and view waveforms in Surfer
4. Wire it all up so `mise run test` runs every testbench in the project

This establishes the workflow we'll use for the entire Game Boy build: **write
test → write RTL → simulate → synthesize → flash.**

## How Verilator Works

Verilator is not a traditional simulator — it's a *compiler*. It translates
your SystemVerilog into a C++ class, then you write a program that drives
the inputs and checks the outputs.

The traditional flow uses C++ testbenches, but we use a Zig wrapper library
called [zig-verilator](https://github.com/code0100fun/zig-verilator) that handles the C++ interop
automatically:

```
  blinky.sv  ──→  Verilator  ──→  C++ model  ──→  zig-verilator  ──→  Zig API
                                                                         │
  blinky.zig  ───────────────────────────────────────────────────────→ zig build test
                                                                         │
                                                                    PASS / FAIL
                                                                         │
                                                                    blinky.vcd (optional)
```

The `zig-verilator` library:
1. Runs `verilator --cc` on your SystemVerilog sources
2. Parses the generated C++ headers to discover all signals
3. Generates a C shim with `extern "C"` getters/setters
4. Compiles everything and exposes a type-safe Zig `Model` struct

The generated model has typed accessors for each port:
- `dut.get(.led)` — read the LED output
- `dut.set(.btn_s1, 1)` — drive the button input
- `dut.eval()` — propagate combinational logic
- `dut.tick()` — one clock cycle (rising + falling edge)

## The zig-verilator API

Instead of writing C++ boilerplate in every testbench, we use the zig-verilator
library. Each model is defined in `build.zig` and imported into the test file.

| Method | What it does |
|--------|-------------|
| `Model.init(.{})` | Create model instance |
| `Model.init(.{ .trace_file = "build/out.vcd" })` | Create model with VCD tracing |
| `dut.deinit()` | Clean up (use with `defer`) |
| `dut.set(.signal, value)` | Drive an input signal |
| `dut.get(.signal)` | Read any signal (input or output) |
| `dut.eval()` | Propagate combinational logic |
| `dut.tick()` | One clock cycle (rising + falling edge) |

### Clock Generation

The `tick()` method drives one complete clock cycle:

```
tick():
    clk = 1  →  eval()  →  trace dump (rising edge)
    clk = 0  →  eval()  →  trace dump (falling edge)
    tick_count++
```

Trace timestamps use `*10` spacing so there's room for sub-cycle events in the
waveform. The `eval()` call tells Verilator to propagate all combinational
logic — without it, outputs won't update.

### VCD Tracing

Pass `.trace_file` when initializing the model to enable waveform output:

```zig
var dut = try blinky.Model.init(.{ .trace_file = "build/blinky.vcd" });
defer dut.deinit();
```

Use the `build/` directory for VCD files — it's already gitignored and keeps
trace output out of the project root.

VCD (Value Change Dump) files record every signal change. You can view them in
Surfer (the VSCode extension or standalone app). The file can get large for long
simulations — for the blinky running 1.7M cycles, the VCD is ~88 MB. For the
Game Boy core we'll switch to FST format (more compact), but VCD is simpler to
start with.

The model must have `.trace = true` in its `build.zig` definition for tracing
to work (most models already do). Leave `.trace_file` off during normal test
runs — only enable it when actively debugging.

### Build System Integration

Models are defined in `build.zig` using `verilator.addModel()`:

```zig
const verilator = @import("zig_verilator");

const blinky_mod = verilator.addModel(b, .{
    .name = "blinky",
    .sources = &.{"rtl/platform/blinky.sv"},
    .target = target,
    .optimize = optimize,
    .trace = true,
    .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
});
```

Then the test file imports the generated model:

```zig
const blinky = @import("blinky");
```

## Writing the Blinky Testbench

Create `sim/test/blinky.zig`:

```zig
const std = @import("std");
const blinky = @import("blinky");

test "counter increments - LEDs change over time" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 1); // not pressed (active low)
    dut.set(.btn_s2, 1);

    const initial_led: u8 = @truncate(dut.get(.led));

    // Run 2^20 cycles — bit 19 will have toggled
    var i: u32 = 0;
    while (i < (1 << 20)) : (i += 1) dut.tick();

    const later_led: u8 = @truncate(dut.get(.led));
    try std.testing.expect(initial_led != later_led);
}

test "normal mode - LED[0] toggles after 2^19 cycles" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 1);
    dut.set(.btn_s2, 1);
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    var i: u32 = 0;
    while (i < (1 << 19)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    try std.testing.expect((led_before ^ led_after) & 0x01 != 0);
}

test "fast mode - LED[0] toggles after 2^16 cycles when S1 pressed" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    dut.set(.btn_s1, 0); // pressed (active low)
    dut.set(.btn_s2, 1);
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    var i: u32 = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    try std.testing.expect((led_before ^ led_after) & 0x01 != 0);
}

test "releasing S1 returns to normal mode" {
    var dut = try blinky.Model.init(.{});
    defer dut.deinit();

    // Start in fast mode
    dut.set(.btn_s1, 0);
    dut.set(.btn_s2, 1);
    var i: u32 = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();

    // Release button
    dut.set(.btn_s1, 1);
    dut.tick();

    const led_before: u8 = @truncate(dut.get(.led));
    i = 0;
    while (i < (1 << 16)) : (i += 1) dut.tick();
    const led_after: u8 = @truncate(dut.get(.led));

    // In normal mode, 2^16 cycles should NOT toggle LED[0]
    try std.testing.expectEqual(@as(u8, 0), (led_before ^ led_after) & 0x01);
}
```

Let's walk through the testing strategy:

### Test 1: Something Happens

The simplest possible test — do the LEDs change at all? We run for 2^20
(~1 million) cycles and check that the LED state isn't frozen. This catches
trivial bugs like forgetting to connect the clock.

### Tests 2–3: Correct Mode Behavior

We can't directly read the internal counter (it's not a port), but we can
verify the *observable behavior*: in normal mode, LED[0] toggles every 2^19
cycles (because it's driven by counter bit 19). In fast mode, it toggles every
2^16 cycles.

### Test 4: Mode Switching

Verifies that releasing the button actually changes behavior — the LED rate
should slow back down.

## Building and Running

### Using mise

```bash
# Run all testbenches
mise run test

# Run just the blinky testbench
mise run test:blinky
```

### Directly with zig

On Arch/CachyOS, a glibc target workaround is needed:

```bash
# Run all testbenches
zig build test -Dtarget=x86_64-linux-gnu.2.38 --summary all

# Run just blinky
zig build test:blinky -Dtarget=x86_64-linux-gnu.2.38 --summary all
```

Zig's test runner produces structured output with test names, pass/fail status,
and stack traces on failure — no manual bookkeeping needed.

## Viewing Waveforms

To generate a VCD file, temporarily add `.trace_file` to any test:

```zig
test "debug blinky" {
    var dut = try blinky.Model.init(.{ .trace_file = "build/blinky.vcd" });
    defer dut.deinit();
    // ... test code ...
}
```

Open the VCD in Surfer:

- **VSCode:** Just click on `build/blinky.vcd` in the file explorer — the
  Surfer extension (`surfer-project.surfer`) opens it automatically.
- **Standalone:** Run `surfer build/blinky.vcd` from the terminal.

In Surfer:
1. Browse the signal hierarchy to find `TOP > blinky`
2. Add the signals you want to inspect: `clk`, `counter[24:0]`, `led[5:0]`, `btn_s1`
3. Use the zoom controls to see the LED toggling pattern

You should see:
- `clk` toggling every half-cycle
- `counter` incrementing every rising edge
- `led` bits changing at different rates (each bit is half the frequency of the
  bit below it)
- The LED pattern shifting to faster bits when `btn_s1` goes low

### Pro Tips for Surfer

- **Zoom to fit:** Press `F` to fit the entire simulation in view
- **Zoom in/out:** Scroll wheel or `+`/`-` keys
- **Radix:** Right-click a signal to change its display format (Hex, Decimal, Binary)
- **Search signals:** Use the search bar to quickly filter signals by name

## A Note on VCD File Size

The blinky VCD is ~88 MB for ~1.7 million cycles. For the Game Boy core running
millions of cycles, VCD files would be enormous. In later tutorials we'll switch
to **FST format** (Verilator supports it natively) which compresses much better.
For now, VCD is fine for small modules.

## The Test-Driven Workflow

From here on, every module we build follows this cycle:

```
1. Read the spec         (Pan Docs for Game Boy components)
       ↓
2. Write the testbench   (what should the module do?)
       ↓
3. Write the RTL         (make the tests pass)
       ↓
4. Simulate              (mise run test)
       ↓
5. Debug with waveforms  (surfer if tests fail)
       ↓
6. Synthesize and flash  (mise run flash — when hardware is relevant)
```

Writing the test first forces you to think about the interface and expected
behavior before getting lost in implementation details. When a test fails, the
waveform shows you exactly what happened cycle-by-cycle.

## Exercises

1. **Add a cycle-count test.** Add a test to `sim/test/blinky.zig` that
   verifies after exactly 2^25 cycles, LED[5] (driven by counter[24]) has
   toggled exactly once. This tests the full counter range.

2. **Add btn_s2 functionality.** In Tutorial 02's exercises, you were
   challenged to make S2 freeze the counter. If you implemented that, write a
   test: press S2, run 1000 cycles, verify LEDs don't change. Release S2, run
   1000 cycles, verify they do.

3. **Experiment with waveforms.** Add `.trace_file = "build/blinky_debug.vcd"` to a
   test, run it, and open the VCD in Surfer. Measure the exact cycle count
   between LED transitions. Does it match your calculations from Tutorial 02?

## What's Next

In [Tutorial 04](04-memory-primitives.md) we'll build the memory blocks that
the Game Boy needs — single-port RAM, dual-port RAM, and ROM — all with
testbenches. These are the building blocks for VRAM, WRAM, HRAM, and the boot
ROM.
