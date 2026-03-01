# Tutorial 10 — Interrupts

The CPU from Tutorial 09 runs programs start to finish, but it has no way to
respond to external events. When the timer overflows, a button is pressed, or
the PPU finishes a frame, the CPU needs to stop what it's doing and jump to a
handler. That's what the interrupt system provides.

In this tutorial we add the complete Game Boy interrupt mechanism: the IF and IE
registers, a 5-M-cycle interrupt dispatch sequence, HALT wake-up, and the
infamous HALT bug.

**Source:** [Pan Docs — Interrupts](https://gbdev.io/pandocs/Interrupts.html)

## The Game Boy Interrupt System

The system has three pieces:

1. **IME** (Interrupt Master Enable) — a single bit inside the CPU, not
   memory-mapped. Controlled by `EI`, `DI`, and `RETI`. When IME=0, no
   interrupts are dispatched regardless of IF and IE.

2. **IE** (0xFFFF) — Interrupt Enable register. A 5-bit mask selecting which
   interrupt sources can fire. We already have this register from Tutorial 09.

3. **IF** (0xFF0F) — Interrupt Flag register. Each bit is set by hardware when
   the corresponding event occurs. The CPU (or the program) can also write to
   IF directly.

The five interrupt sources, from highest to lowest priority:

| Bit | Source  | Vector | Trigger |
|-----|---------|--------|---------|
| 0   | VBlank  | 0x0040 | PPU enters VBlank (once per frame) |
| 1   | STAT    | 0x0048 | PPU STAT condition (LYC match, mode change) |
| 2   | Timer   | 0x0050 | TIMA register overflows |
| 3   | Serial  | 0x0058 | Serial transfer complete |
| 4   | Joypad  | 0x0060 | Button press (active-low transition) |

An interrupt fires when **all three** conditions are met:
- IME = 1
- The corresponding IE bit is set
- The corresponding IF bit is set

The CPU checks `IF & IE` at every instruction boundary. The lowest set bit wins
(VBlank has the highest priority).

## Interrupt Dispatch Timing

When the CPU detects a pending interrupt between instructions, it enters a
5-M-cycle dispatch sequence — essentially a hardware-generated `CALL` to the
interrupt vector:

```
M-cycle  Action
───────  ──────────────────────────────
  0      Internal delay (no bus activity)
  1      Internal delay (no bus activity)
  2      SP-- (decrement stack pointer)
  3      Push PC high byte to [SP], SP--
  4      Push PC low byte to [SP], set PC = vector
```

This is identical to the RST instruction (which takes 4 M-cycles: fetch + 3
execute) but with two internal delay cycles instead of a fetch. Compare:

```
RST:       [fetch] [SP--] [push hi, SP--] [push lo, jump]
Dispatch:  [nop]   [nop]  [SP--] [push hi, SP--] [push lo, jump]
```

During M-cycle 4, the CPU also clears the IF bit that triggered the dispatch
and clears IME (preventing nested interrupts until the handler re-enables them
with `EI` or `RETI`).

## HALT and Wake-up

The `HALT` instruction stops the CPU until an interrupt is pending. The behavior
depends on IME:

**HALT with IME=1:** The CPU sleeps until `(IF & IE) != 0`, then wakes and
dispatches the interrupt normally. This is the common case — a game loop that
calls `HALT` to wait for VBlank.

**HALT with IME=0:** The CPU sleeps until `(IF & IE) != 0`, then wakes and
resumes execution at the next instruction — but **without dispatching** the
interrupt. This also triggers the **HALT bug**: the first byte after wake-up is
read twice (PC fails to increment on the first fetch). Placing a `NOP` after
`HALT` in IME=0 code absorbs the double-read harmlessly.

## CPU Changes

### New Ports

The CPU needs two new signals to communicate with the IF/IE registers:

```systemverilog
    // Interrupt interface
    input  logic [4:0]  int_req,    // IF & IE (pre-masked pending interrupts)
    output logic [4:0]  int_ack,    // one-hot: bit to clear in IF during dispatch
```

The top-level module computes `int_req = if_reg & ie_reg[4:0]` and feeds it to
the CPU. When the CPU dispatches an interrupt, it pulses the corresponding
`int_ack` bit so the top-level can clear the IF flag.

### New Internal State

```systemverilog
    logic        int_dispatch;  // interrupt dispatch sequence in progress
    logic [2:0]  int_vec_idx;   // which interrupt (0-4) is being dispatched
    logic        halt_bug;      // suppress PC++ on next fetch after HALT bug
```

### Priority Encoder

A simple combinational priority encoder selects the highest-priority (lowest
bit number) pending interrupt:

```systemverilog
    logic [2:0] int_select;
    logic       int_pending;

    always_comb begin
        if      (int_req[0]) begin int_select = 3'd0; int_pending = 1'b1; end
        else if (int_req[1]) begin int_select = 3'd1; int_pending = 1'b1; end
        else if (int_req[2]) begin int_select = 3'd2; int_pending = 1'b1; end
        else if (int_req[3]) begin int_select = 3'd3; int_pending = 1'b1; end
        else if (int_req[4]) begin int_select = 3'd4; int_pending = 1'b1; end
        else                 begin int_select = 3'd0; int_pending = 1'b0; end
    end
```

The interrupt vector address is computed from the latched index using bit
manipulation — each vector is 8 bytes apart starting at 0x0040:

```systemverilog
    wire [15:0] dispatch_vector = {8'h00, 2'b01, int_vec_idx, 3'b000};
    // idx 0 → 0x0040, idx 1 → 0x0048, ..., idx 4 → 0x0060
```

### Dispatch State Machine (Combinational)

The dispatch sequence is inserted into the `always_comb` block as a new branch
before `halt_mode`, mirroring the RST push-and-jump pattern:

```systemverilog
    end else if (int_dispatch) begin
        unique case (m_cycle)
            3'd0: begin end  // Internal delay
            3'd1: begin end  // Internal delay
            3'd2: begin
                rf_sp_we    = 1'b1;
                rf_sp_wdata = rf_sp - 16'd1;
            end
            3'd3: begin
                mem_addr  = rf_sp;
                mem_wr    = 1'b1;
                mem_wdata = rf_pc[15:8];
                rf_sp_we    = 1'b1;
                rf_sp_wdata = rf_sp - 16'd1;
            end
            3'd4: begin
                mem_addr  = rf_sp;
                mem_wr    = 1'b1;
                mem_wdata = rf_pc[7:0];
                rf_pc_we    = 1'b1;
                rf_pc_wdata = dispatch_vector;
                int_ack     = 5'b1 << int_vec_idx;
            end
            default: ;
        endcase
    end else if (halt_mode) begin
```

The HALT bug is handled in the fetch phase by suppressing `PC++`:

```systemverilog
    // Default: PC++ on every fetch (suppressed by HALT bug)
    rf_pc_we    = !halt_bug;
    rf_pc_wdata = rf_pc + 16'd1;
```

### Dispatch State Machine (Sequential)

The `always_ff` block gains three new sections:

**HALT wake-up** — when the CPU is halted and `IF & IE != 0`:

```systemverilog
    end else if (halt_mode) begin
        if (int_pending) begin
            halt_mode <= 1'b0;
            if (ime) begin
                int_dispatch <= 1'b1;
                int_vec_idx  <= int_select;
                m_cycle      <= 3'd0;
            end else begin
                halt_bug <= 1'b1;
            end
        end
    end
```

**Dispatch advancement** — counts through the 5 dispatch M-cycles:

```systemverilog
    end else if (int_dispatch) begin
        if (m_cycle == 3'd4) begin
            int_dispatch <= 1'b0;
            ime          <= 1'b0;
            m_cycle      <= 3'd0;
        end else begin
            m_cycle <= m_cycle + 3'd1;
        end
    end
```

**Interrupt check at instruction boundaries** — at both single-cycle and
multi-cycle completion points:

```systemverilog
    // At instruction completion:
    if (ime && int_pending) begin
        int_dispatch <= 1'b1;
        int_vec_idx  <= int_select;
        m_cycle      <= 3'd0;
    end else begin
        m_cycle <= 3'd0;
    end
```

This check runs where `m_cycle` would normally return to 0 — at the end of
single-cycle instructions (in the fetch phase) and at the end of multi-cycle
instructions (when `m_cycle == dec_mcycles - 1`).

## Top-Level Wiring

### IF Register

The IF register lives in `gb_top.sv` alongside the IE register. It occupies
I/O address 0x0F (mapped to memory address 0xFF0F by the bus):

```systemverilog
    logic [4:0] if_reg;

    always_ff @(posedge clk) begin
        if (reset)
            if_reg <= 5'h00;
        else if (int_ack != 5'b0)
            if_reg <= if_reg & ~int_ack;       // dispatch clears bit
        else if (io_cs && io_wr && io_addr == 7'h0F)
            if_reg <= io_wdata[4:0];           // CPU write replaces value
        // Future: external sources OR bits in (timer, PPU, etc.)
    end
```

The I/O read mux is expanded to return IF when reading 0xFF0F. The upper 3
bits read as 1, matching real hardware:

```systemverilog
    always_comb begin
        unique case (io_addr)
            7'h01:   io_rdata = led_reg;
            7'h0F:   io_rdata = {3'b111, if_reg};
            default: io_rdata = 8'h00;
        endcase
    end
```

### Interrupt Request

The `int_req` signal fed to the CPU is simply `IF & IE`:

```systemverilog
    assign int_req = if_reg & ie_reg[4:0];
```

No external interrupt sources are wired yet — those will arrive with the timer
(Tutorial 11), PPU (Tutorials 13–15), and other peripherals.

## Simulation Wrapper

The `cpu_bus_top.sv` test wrapper mirrors the `gb_top` changes and adds an
`int_request` input so the testbench can trigger interrupts externally:

```systemverilog
    input  logic [4:0]  int_request,    // external interrupt sources
    // ...
    output logic [7:0]  dbg_ie,         // IE register (for test visibility)
    output logic [7:0]  dbg_if          // IF register (for test visibility)
```

The IF register combines external requests, CPU writes, and dispatch
acknowledgment:

```systemverilog
    always_ff @(posedge clk) begin
        if (reset)
            if_reg <= 5'h00;
        else begin
            if (int_request != 5'b0)
                if_reg <= if_reg | int_request;     // external sets bits
            if (io_cs && io_wr && io_addr == 7'h0F)
                if_reg <= io_wdata[4:0];            // CPU write replaces
            if (int_ack != 5'b0)
                if_reg <= if_reg & ~int_ack;        // dispatch clears bit
        end
    end
```

## Testing

### CPU-Level Tests (cpu.zig)

Six new tests exercise the interrupt system using the flat 64KB memory model.
The testbench drives `int_req` directly and simulates the IF register by
clearing `int_req` bits when `int_ack` fires:

| Test | Program | Verifies |
|------|---------|----------|
| Basic dispatch | EI; NOP; HALT + ISR at 0x0040 | Wake, 5-cycle dispatch, ISR runs, RETI returns |
| Priority | Two interrupts at once | Lower bit (VBlank) wins over higher bit (STAT) |
| HALT IME=0 | DI; HALT; NOP; LD A,0x42; HALT | Wake without dispatch, resumes execution |
| HALT bug | DI; HALT; NOP; LD A,0x42; HALT | NOP read twice (PC not incremented), then normal |
| EI delay | EI; LD A,0x42 + ISR | LD A executes before dispatch (EI has 1-instruction delay) |
| DI prevents | DI; LD A,0x42; HALT | No dispatch when IME=0, CPU halts normally |

### Bus Integration Tests (interrupts.zig)

Two tests exercise the full interrupt path through the IF/IE registers:

| Test | Verifies |
|------|----------|
| End-to-end | CPU writes IE, testbench triggers int_request, dispatch through IF/IE, RETI returns |
| IF register | External request sets IF bits, read back via debug output |

## Building and Running

```bash
# Run CPU-level interrupt tests
mise run test:cpu

# Run bus integration interrupt tests
mise run test:interrupts

# Run all testbenches
mise run test

# Synthesize for FPGA
mise run build -- gb_top
```

## What's Next

The interrupt system is complete but has no interrupt sources yet — IF stays
zero unless the CPU writes to it directly. In Tutorial 11 we add the timer
(DIV, TIMA, TMA, TAC registers), which will be the first peripheral to fire
a real interrupt and exercise this system end-to-end.
