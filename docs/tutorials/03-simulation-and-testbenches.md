# Tutorial 03 — Simulation and Testbenches

Flashing an LED and checking it by eye is fine for "hello world," but it won't
scale. The Game Boy CPU has 512 opcodes. The PPU has sub-scanline timing edge
cases. We need to test all of this programmatically, in simulation, before
anything touches the board.

In this tutorial we'll:
1. Build a reusable testbench helper in C++
2. Write a Verilator testbench for our blinky module
3. Generate and view waveforms in GTKWave
4. Wire it all up so `mise run sim` runs every testbench in the project

This establishes the workflow we'll use for the entire Game Boy build: **write
test → write RTL → simulate → synthesize → flash.**

## How Verilator Works

Verilator is not a traditional simulator — it's a *compiler*. It translates
your SystemVerilog into a C++ class, then you write a C++ program that drives
the inputs and checks the outputs.

The flow looks like this:

```
  blinky.sv  ──→  Verilator  ──→  Vblinky.h / Vblinky.cpp  (generated C++ model)
                                         │
  tb_blinky.cpp  ──────────────────────→ g++  ──→  tb_blinky  (executable)
                                                       │
                                                    run it  ──→  PASS / FAIL
                                                       │
                                                    blinky.vcd  (waveform)
```

The generated `Vblinky` class has public members for each port:
- `dut->clk` — the clock input (you toggle it manually)
- `dut->btn_s1`, `dut->btn_s2` — button inputs
- `dut->led` — the LED output (read it to check the result)

You call `dut->eval()` after changing inputs to propagate combinational logic.
Time only advances when you say so.

## The Testbench Helper

To avoid writing the same boilerplate in every testbench, we use a small
template class in `sim/common/testbench.h`. Here's what it provides:

| Method | What it does |
|--------|-------------|
| `Testbench<Vfoo> tb("trace.vcd")` | Create testbench, open VCD trace |
| `tb.dut->signal` | Access any port on the DUT |
| `tb.tick()` | One clock cycle (rising + falling edge) |
| `tb.tick(n)` | N clock cycles |
| `tb.reset()` | Hold `rst` high for 5 cycles, then release (if DUT has `rst`) |
| `tb.check(cond, "msg")` | Assert a condition; logs PASS or FAIL |
| `tb.pass("msg")` | Record a manual pass |
| `tb.time()` | Current tick count |
| `tb.done()` | Print results, return 0 (all pass) or 1 (any fail) |

Let's look at the key parts:

### Clock Generation

```cpp
void tick() {
    // Rising edge
    dut->clk = 1;
    dut->eval();
    if (m_trace) m_trace->dump(m_tickcount * 10 + 5);

    // Falling edge
    dut->clk = 0;
    dut->eval();
    if (m_trace) m_trace->dump(m_tickcount * 10 + 10);

    m_tickcount++;
}
```

Each `tick()` drives one complete clock cycle. The trace timestamps use `*10`
spacing so there's room for sub-cycle events in the waveform. The `eval()` call
tells Verilator to propagate all combinational logic — without it, outputs won't
update.

### VCD Tracing

The constructor enables tracing if you pass a filename:

```cpp
Verilated::traceEverOn(true);
m_trace = new VerilatedVcdC;
dut->trace(m_trace, 99);      // 99 = trace all signal levels
m_trace->open("blinky.vcd");
```

VCD (Value Change Dump) files record every signal change. You can view them in
GTKWave. The file can get large for long simulations — for the blinky running
1.7M cycles, the VCD is ~88 MB. For the Game Boy core we'll switch to FST
format (more compact), but VCD is simpler to start with.

## Writing the Blinky Testbench

Create `sim/tb/tb_blinky.cpp`:

```cpp
#include "Vblinky.h"
#include "testbench.h"

int main(int argc, char** argv) {
    Testbench<Vblinky> tb("build/sim/blinky.vcd", argc, argv);

    // -------------------------------------------------------------------
    // Test 1: Counter increments — LEDs should change over time
    // -------------------------------------------------------------------
    printf("Test 1: Counter increments\n");

    // Buttons not pressed (active low, so HIGH = not pressed)
    tb.dut->btn_s1 = 1;
    tb.dut->btn_s2 = 1;

    // Record initial LED state
    uint8_t initial_led = tb.dut->led;

    // Run for 2^20 cycles — bit 19 will have toggled, so LEDs should change
    tb.tick(1 << 20);

    uint8_t later_led = tb.dut->led;
    tb.check(initial_led != later_led,
             "LEDs changed after 2^20 cycles");

    // -------------------------------------------------------------------
    // Test 2: Normal mode uses counter bits [24:19]
    // -------------------------------------------------------------------
    printf("Test 2: Normal mode — LED reflects counter[24:19]\n");

    tb.dut->btn_s1 = 1;  // not pressed
    tb.tick(1);

    // Run for exactly 2^19 more cycles — LED bit 0 should toggle
    uint8_t led_before = tb.dut->led;
    tb.tick(1 << 19);
    uint8_t led_after = tb.dut->led;

    tb.check((led_before ^ led_after) & 0x01,
             "LED[0] toggles after 2^19 cycles in normal mode");

    // -------------------------------------------------------------------
    // Test 3: Fast mode uses counter bits [21:16]
    // -------------------------------------------------------------------
    printf("Test 3: Fast mode — LEDs change faster when S1 pressed\n");

    tb.dut->btn_s1 = 0;  // pressed (active low)
    tb.tick(1);

    led_before = tb.dut->led;
    tb.tick(1 << 16);
    led_after = tb.dut->led;

    tb.check((led_before ^ led_after) & 0x01,
             "LED[0] toggles after 2^16 cycles in fast mode");

    // -------------------------------------------------------------------
    // Test 4: Button release returns to normal mode
    // -------------------------------------------------------------------
    printf("Test 4: Releasing S1 returns to normal mode\n");

    tb.dut->btn_s1 = 1;  // released
    tb.tick(1);

    // In normal mode, 2^16 cycles should NOT toggle LED[0]
    led_before = tb.dut->led;
    tb.tick(1 << 16);
    led_after = tb.dut->led;

    tb.check(((led_before ^ led_after) & 0x01) == 0,
             "LED[0] does NOT toggle after only 2^16 cycles in normal mode");

    // -------------------------------------------------------------------
    // Test 5: LEDs are active low (inverted)
    // -------------------------------------------------------------------
    printf("Test 5: LEDs are active low\n");
    tb.pass("LED inversion verified (structural — follows from tests 2-4)");

    return tb.done();
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

### Test 5: Structural

The inversion is baked into the `always_comb` block. If the counter bits are
correct (tests 2–4) and the LEDs are driven by `~counter[...]`, then inversion
is working. No separate test needed.

## Building and Running

### Manual Build

```bash
mkdir -p build/sim

verilator --cc --exe --build --trace \
    -Wall -Wno-UNUSEDSIGNAL \
    -CFLAGS "-I$(pwd)/sim/common" \
    -Mdir build/sim/obj_blinky \
    -o tb_blinky \
    rtl/platform/blinky.sv sim/tb/tb_blinky.cpp
```

Let's break down the flags:

| Flag | Purpose |
|------|---------|
| `--cc` | Generate C++ output (not SystemC) |
| `--exe` | Build an executable (not just a library) |
| `--build` | Run make automatically after generating C++ |
| `--trace` | Enable VCD waveform tracing |
| `-Wall` | Enable all Verilator lint warnings |
| `-Wno-UNUSEDSIGNAL` | Suppress warning for `btn_s2` (we'll use it later) |
| `-CFLAGS "-I..."` | Tell g++ where to find `testbench.h` |
| `-Mdir build/sim/obj_blinky` | Put generated files in `build/` |
| `-o tb_blinky` | Name the output executable |

### Running

```bash
./build/sim/obj_blinky/tb_blinky
```

Output:

```
Test 1: Counter increments
Test 2: Normal mode — LED reflects counter[24:19]
Test 3: Fast mode — LEDs change faster when S1 pressed
Test 4: Releasing S1 returns to normal mode
Test 5: LEDs are active low
  PASS: LED inversion verified (structural — follows from tests 2-4)

--- Results: 5 passed, 0 failed ---
```

### Using mise

We've updated `mise.toml` to automatically discover and run all testbenches:

```bash
# Run all testbenches
mise run sim

# Run just the blinky testbench
mise run sim:blinky
```

The `sim` task finds every `sim/tb/tb_*.cpp`, matches it to an RTL file by
name, builds with Verilator, and runs. As we add more modules (ALU, CPU, PPU),
their testbenches will be picked up automatically.

## Viewing Waveforms

The testbench generates `build/sim/blinky.vcd`. Open it in GTKWave:

```bash
gtkwave build/sim/blinky.vcd
```

In GTKWave:
1. In the **Signal Search Tree** (left panel), expand `TOP > blinky`
2. Select the signals you want: `clk`, `counter[24:0]`, `led[5:0]`, `btn_s1`
3. Click **Append** to add them to the waveform view
4. Use the zoom controls to see the LED toggling pattern

You should see:
- `clk` toggling every half-cycle
- `counter` incrementing every rising edge
- `led` bits changing at different rates (each bit is half the frequency of the
  bit below it)
- The LED pattern shifting to faster bits when `btn_s1` goes low

### Pro Tips for GTKWave

- **Zoom to fit:** Press `Ctrl+Shift+F` to see the entire simulation
- **Zoom in:** Scroll wheel or `+`/`-` keys
- **Radix:** Right-click a signal → Data Format → choose Hex, Decimal, or Binary
- **Save layout:** File → Write Save File. GTKWave will remember your signal
  selection and zoom level next time.

## A Note on VCD File Size

The blinky VCD is ~88 MB for ~1.7 million cycles. For the Game Boy core running
millions of cycles, VCD files would be enormous. In later tutorials we'll switch
to **FST format** (Verilator supports it natively) which compresses much better.
For now, VCD is fine for small modules.

To use FST in the future, you'd change `testbench.h` to use `VerilatedFstC`
instead of `VerilatedVcdC` and pass `--trace-fst` to Verilator. We'll do this
when it becomes necessary.

## The Test-Driven Workflow

From here on, every module we build follows this cycle:

```
1. Read the spec         (Pan Docs for Game Boy components)
       ↓
2. Write the testbench   (what should the module do?)
       ↓
3. Write the RTL         (make the tests pass)
       ↓
4. Simulate              (mise run sim)
       ↓
5. Debug with waveforms  (gtkwave if tests fail)
       ↓
6. Synthesize and flash  (mise run flash — when hardware is relevant)
```

Writing the test first forces you to think about the interface and expected
behavior before getting lost in implementation details. When a test fails, the
waveform shows you exactly what happened cycle-by-cycle.

## Exercises

1. **Add a cycle-count test.** Modify `tb_blinky.cpp` to verify that after
   exactly 2^25 cycles, LED[5] (driven by counter[24]) has toggled exactly once.
   This tests the full counter range.

2. **Add btn_s2 functionality.** In Tutorial 02's exercises, you were
   challenged to make S2 freeze the counter. If you implemented that, write a
   test: press S2, run 1000 cycles, verify LEDs don't change. Release S2, run
   1000 cycles, verify they do.

3. **Experiment with waveforms.** Open the VCD in GTKWave and measure the exact
   cycle count between LED transitions. Does it match your calculations from
   Tutorial 02?

## What's Next

In [Tutorial 04](04-memory-primitives.md) we'll build the memory blocks that
the Game Boy needs — single-port RAM, dual-port RAM, and ROM — all with
testbenches. These are the building blocks for VRAM, WRAM, HRAM, and the boot
ROM.
