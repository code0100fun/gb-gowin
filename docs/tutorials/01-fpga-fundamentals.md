# Tutorial 01 — FPGA Fundamentals

Before we write any SystemVerilog, we need to understand how FPGAs work and how
designing hardware differs from writing software. This tutorial is all concepts
— no code yet. Take your time with it. These ideas will inform every design
decision we make throughout the project.

## What Is an FPGA?

An FPGA (Field-Programmable Gate Array) is a chip filled with configurable logic
blocks and programmable interconnects. When you "program" an FPGA, you're not
running instructions like a CPU does — you're configuring the chip's wiring to
become a specific digital circuit.

Our Tang Nano 20K contains a Gowin GW2AR-18 FPGA. Think of it as a blank canvas
containing:

- **20,736 LUT4s** — 4-input lookup tables that implement combinational logic
- **15,552 Flip-Flops** — 1-bit memory elements that store state
- **828 Kbits of Block SRAM** — larger memory blocks for RAMs and ROMs
- **64 Mbits of SDRAM** — external (but on-package) dynamic memory
- **2 PLLs** — clock management units that multiply/divide clock frequencies
- **Programmable I/O pins** — connections to the outside world

When we write SystemVerilog and synthesize it, the tools figure out how to
configure these resources to implement our design.

## Hardware vs Software: The Key Mental Shift

In software, your code runs sequentially — one instruction at a time, top to
bottom. In hardware, **everything runs simultaneously**.

Consider this SystemVerilog:

```systemverilog
assign a = b & c;
assign d = e | f;
```

These aren't two sequential statements. They describe two independent pieces of
hardware — an AND gate and an OR gate — that operate **at the same time,
continuously**. The AND gate is always computing `b & c` and driving `a` with
the result. The OR gate is always computing `e | f` and driving `d`. Neither
waits for the other.

This is the single most important concept to internalize: **you are describing
circuits, not procedures.**

## Combinational vs Sequential Logic

All digital circuits are built from two types of logic:

### Combinational Logic

Combinational logic computes an output purely from its current inputs, with no
memory. The output changes whenever any input changes (after a small propagation
delay).

Examples: AND/OR/XOR gates, multiplexers, adders, decoders.

In SystemVerilog, we describe combinational logic with `always_comb` or
continuous `assign` statements:

```systemverilog
// A 2-to-1 multiplexer using assign
assign y = sel ? a : b;

// The same thing using always_comb
always_comb begin
    if (sel)
        y = a;
    else
        y = b;
end
```

Both describe the same circuit: a multiplexer. The output `y` is always equal to
`a` when `sel` is high, or `b` when `sel` is low. There's no clock involved —
the output updates continuously.

### Sequential Logic

Sequential logic has memory — its output depends on both the current inputs and
its stored state. The stored state changes on the edge of a clock signal.

The fundamental building block of sequential logic is the **flip-flop** (also
called a register). A flip-flop captures its input on the rising edge of the
clock and holds it until the next rising edge.

In SystemVerilog, we describe sequential logic with `always_ff`:

```systemverilog
always_ff @(posedge clk) begin
    if (rst)
        count <= 8'd0;
    else
        count <= count + 8'd1;
end
```

This describes an 8-bit counter. On every rising edge of `clk`:
- If `rst` is high, `count` becomes 0
- Otherwise, `count` becomes `count + 1`

Between clock edges, `count` holds its value. This is what makes it sequential —
it remembers.

### The `<=` Operator (Non-Blocking Assignment)

Notice the `<=` operator in the `always_ff` block. This is a **non-blocking
assignment**. It means "schedule this value to be updated at the end of the
current time step." This is different from `=` (blocking assignment, used in
`always_comb`).

**Rule of thumb:**
- Use `=` inside `always_comb` (combinational logic)
- Use `<=` inside `always_ff` (sequential logic)

Mixing them up is a common source of bugs. The synthesis tools will usually warn
you, and Verilator will flag it as an error.

## Clocks and Synchronous Design

Almost all FPGA designs are **synchronous** — everything is coordinated by a
clock signal. The clock is a square wave that toggles between 0 and 1 at a fixed
frequency. Our Tang Nano 20K has a 27 MHz oscillator, meaning the clock toggles
27 million times per second.

On every rising edge of the clock, all flip-flops simultaneously capture their
inputs. Between clock edges, combinational logic computes the next values. This
creates a predictable, repeatable pipeline:

```
         ┌───┐   ┌───┐   ┌───┐   ┌───┐
  clk ───┘   └───┘   └───┘   └───┘   └───
         ↑       ↑       ↑       ↑
      capture  capture  capture  capture
```

Between each rising edge, combinational logic has time to settle to the correct
output. As long as the logic settles before the next clock edge (this is called
meeting **timing**), the design works correctly.

### Why Synchronous?

You might wonder: why not just let signals propagate freely without a clock?
This is called asynchronous design, and it's much harder to get right. Different
paths through combinational logic take different amounts of time, leading to
**glitches** — brief incorrect values as signals settle. The clock acts as a
synchronization barrier that eliminates these problems.

## LUTs: How Logic Is Implemented

A **LUT4** (4-input lookup table) is the basic logic element in our FPGA. It's
a tiny memory (16 bits) that can implement any Boolean function of 4 inputs.

For example, a 2-input AND gate uses a LUT4 configured as:

| Input A | Input B | Output |
|---------|---------|--------|
| 0       | 0       | 0      |
| 0       | 1       | 0      |
| 1       | 0       | 0      |
| 1       | 1       | 1      |

The synthesis tools figure out how to map your logic into LUT4s. A simple AND
gate needs one LUT. A complex expression might need several LUTs chained
together. The more complex your combinational logic, the more LUTs it uses and
the longer the propagation delay.

Our GW2AR-18 has 20,736 LUT4s. A Game Boy core typically uses 5,000–8,000 LUTs,
so we have plenty of room.

## Flip-Flops: How State Is Stored

Each LUT4 in the FPGA is paired with a flip-flop. When you declare a `logic`
variable and assign it inside an `always_ff` block, the synthesis tool maps it
to one or more flip-flops.

An 8-bit register like our counter uses 8 flip-flops — one per bit. Our
GW2AR-18 has 15,552 flip-flops, which is more than enough for the Game Boy's
registers, counters, and state machines.

## Block SRAM (BSRAM)

For larger memories (like the Game Boy's 8KB VRAM or 8KB WRAM), flip-flops would
be wasteful. Instead, the FPGA provides **Block SRAM** — dedicated memory blocks
that are much denser than flip-flops.

The GW2AR-18 has 828 Kbits of BSRAM, organized as 46 blocks of 18 Kbits each.
Each block can be configured as various widths and depths (e.g., 2048×8, 1024×16).

When you write a RAM in a certain style, the synthesis tools automatically use
BSRAM. We'll cover the exact patterns in Tutorial 04.

The Game Boy needs roughly:
- VRAM: 8 KB (65,536 bits)
- WRAM: 8 KB (65,536 bits)
- OAM: 160 bytes (1,280 bits)
- HRAM: 127 bytes (1,016 bits)
- Boot ROM: 256 bytes (2,048 bits)

Total: ~134 Kbits. Well within our 828 Kbit budget.

## Finite State Machines (FSMs)

An FSM is a circuit that moves between a fixed set of **states** based on its
inputs. FSMs are everywhere in digital design — they control instruction
execution in CPUs, manage bus protocols, sequence display timing, and more.

An FSM has three parts:
1. **State register** — flip-flops that store the current state
2. **Next-state logic** — combinational logic that computes the next state from
   the current state and inputs
3. **Output logic** — combinational logic that computes outputs from the current
   state (and optionally inputs)

Here's a simple FSM in SystemVerilog:

```systemverilog
typedef enum logic [1:0] {
    IDLE,
    LOADING,
    RUNNING,
    DONE
} state_t;

state_t state, next_state;

// State register (sequential)
always_ff @(posedge clk) begin
    if (rst)
        state <= IDLE;
    else
        state <= next_state;
end

// Next-state logic (combinational)
always_comb begin
    next_state = state; // default: stay in current state
    case (state)
        IDLE:    if (start)    next_state = LOADING;
        LOADING: if (loaded)   next_state = RUNNING;
        RUNNING: if (finished) next_state = DONE;
        DONE:                  next_state = IDLE;
    endcase
end
```

Let's break this down:

- `typedef enum logic [1:0]` defines a 2-bit enumerated type with named states.
  This is much more readable than raw binary values.
- The `always_ff` block is the state register — it updates `state` on each clock
  edge.
- The `always_comb` block is the next-state logic — it computes `next_state`
  from the current `state` and input signals.
- The `next_state = state` default prevents accidentally creating latches (which
  we'll discuss shortly).

The Game Boy CPU is essentially a complex FSM. The PPU (pixel processing unit)
is another one. Understanding FSMs well is crucial.

## Common Pitfalls

### Latches (The Accidental Enemy)

A **latch** is a memory element that's transparent when its enable signal is
high (unlike a flip-flop, which only captures on an edge). Latches are almost
never what you want in FPGA design — they cause timing analysis problems and
subtle bugs.

Latches are created accidentally when you don't assign a value to a signal in
every path through a combinational block:

```systemverilog
// BAD — creates a latch for y when sel is 0
always_comb begin
    if (sel)
        y = a;
    // Missing else! What is y when sel is 0?
    // The tool infers a latch to "remember" the old value.
end

// GOOD — no latch
always_comb begin
    if (sel)
        y = a;
    else
        y = b;
end
```

**Prevention:** Always assign a default value at the top of `always_comb`
blocks, or make sure every branch of every `if`/`case` assigns every output.
Yosys and Verilator will warn you about inferred latches.

### Combinational Loops

A combinational loop is when the output of a combinational block feeds back into
its own input without a register in between:

```systemverilog
// BAD — combinational loop
assign a = b + 1;
assign b = a + 1;  // a depends on b depends on a...
```

This creates an unstable circuit with no well-defined value. Always break
feedback loops with a register (flip-flop).

## Clock Domains

A **clock domain** is a group of flip-flops driven by the same clock. When you
have multiple clocks in a design (which we will — one for the Game Boy core, one
for the SPI LCD), signals crossing between domains need special handling.

The problem: if a signal changes right as the receiving clock captures it, the
flip-flop can enter a **metastable** state — neither 0 nor 1 — which can
corrupt downstream logic.

The solution is a **synchronizer** — typically two flip-flops in series in the
receiving clock domain:

```systemverilog
// Synchronize signal from clk_a domain to clk_b domain
logic sync_stage1, sync_stage2;

always_ff @(posedge clk_b) begin
    sync_stage1 <= signal_from_clk_a;
    sync_stage2 <= sync_stage1;
end

// Use sync_stage2 — it's safe in the clk_b domain
```

For our project, the main clock domain crossing is between the Game Boy core
clock (~4.19 MHz) and the SPI LCD clock. We'll handle this with a dual-port RAM
framebuffer — each port runs on its own clock, and the RAM handles the domain
crossing internally.

## SystemVerilog Basics

Here's a quick reference for the SystemVerilog features we'll use most:

### `logic` Type

Use `logic` for all signals. It replaces the old Verilog `reg` and `wire`
types:

```systemverilog
logic        single_bit;
logic [7:0]  byte_signal;    // 8 bits, [MSB:LSB]
logic [15:0] word_signal;    // 16 bits
```

### `localparam`

Constants that don't become ports:

```systemverilog
localparam int CLOCK_FREQ = 27_000_000;  // 27 MHz
localparam int COUNTER_MAX = CLOCK_FREQ - 1;
```

The underscores in `27_000_000` are just for readability — the compiler ignores
them.

### `typedef enum`

Named states for FSMs and named constants:

```systemverilog
typedef enum logic [2:0] {
    ADD  = 3'b000,
    SUB  = 3'b001,
    AND  = 3'b010,
    OR   = 3'b011,
    XOR  = 3'b100
} alu_op_t;

alu_op_t operation;
```

### `struct packed`

Group related signals together:

```systemverilog
typedef struct packed {
    logic z;  // Zero flag
    logic n;  // Subtract flag
    logic h;  // Half-carry flag
    logic c;  // Carry flag
} flags_t;

flags_t flags;

// Access fields
assign is_zero = flags.z;
```

`packed` means the struct is stored as a contiguous bit vector. This is
important for synthesis — unpacked structs may not synthesize predictably.

### Number Literals

SystemVerilog number literals specify the width, base, and value:

```systemverilog
8'd255       // 8-bit decimal 255
8'hFF        // 8-bit hex FF (same as above)
8'b1111_1111 // 8-bit binary (same as above)
4'b0         // 4-bit zero (0000)
16'hDEAD     // 16-bit hex
'0           // All bits zero (width inferred from context)
'1           // All bits one
```

Always specify the width explicitly. Using unsized literals like `255` can lead
to subtle bugs when the tool infers the wrong width.

### Concatenation and Replication

```systemverilog
logic [7:0] high, low;
logic [15:0] combined;

assign combined = {high, low};      // Concatenation
assign all_ones = {8{1'b1}};        // Replication: 8'b11111111
```

### Modules and Ports

Modules are the building blocks of a design. They have input and output ports:

```systemverilog
module adder (
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic [8:0] sum
);
    assign sum = a + b;
endmodule
```

Modules are instantiated (not "called") inside other modules:

```systemverilog
module top (
    input  logic       clk,
    input  logic [7:0] x, y,
    output logic [8:0] result
);
    adder my_adder (
        .a   (x),
        .b   (y),
        .sum (result)
    );
endmodule
```

The `.port(signal)` syntax is a named connection — the port name comes first,
then the signal it connects to. Always use named connections; positional
connections are error-prone.

## Exercises

These are not graded — they're just to check your understanding before moving
on.

1. **Combinational vs sequential:** You have a signal that should be high when
   `button_a` AND `button_b` are both pressed. Is this combinational or
   sequential logic? What SystemVerilog construct would you use?

2. **Counter:** Sketch (in pseudocode or SystemVerilog) a 4-bit counter that
   counts from 0 to 9, then wraps back to 0. What happens on count 10? How many
   flip-flops does it use?

3. **FSM design:** A vending machine accepts coins and dispenses an item when
   the total reaches 25 cents. It accepts nickels (5¢) and dimes (10¢). Sketch
   the states and transitions. How many states do you need?

4. **Resource estimation:** The Game Boy CPU has eight 8-bit registers plus two
   16-bit registers (SP and PC). How many flip-flops does just the register file
   need? (Answer: 8×8 + 2×16 = 96 flip-flops. Our FPGA has 15,552.)

## What's Next

In [Tutorial 02](02-blinky.md) we'll put these concepts into practice by
writing a blinking LED — our first real hardware design. We'll write the
SystemVerilog, create a constraint file to map signals to physical pins, and
synthesize and flash it to the Tang Nano 20K.
