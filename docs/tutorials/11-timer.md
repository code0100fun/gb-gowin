# Tutorial 11 — Timer

The interrupt system from Tutorial 10 is wired up and ready, but nothing fires
it yet. The timer is the simplest peripheral that generates interrupts and the
first one we'll implement. When the timer counter overflows, it sets IF bit 2
and the CPU dispatches to vector `0x0050`.

In this tutorial we add the four timer registers (DIV, TIMA, TMA, TAC), the
clock selection logic, and overflow detection — exercising the interrupt system
end-to-end for the first time.

**Source:** [Pan Docs — Timer and Divider](https://gbdev.io/pandocs/Timer_and_Divider_Registers.html)

## Timer Registers

The Game Boy timer occupies four I/O addresses:

| Address | Name | Description |
|---------|------|-------------|
| FF04    | DIV  | Divider — upper byte of a free-running 16-bit counter |
| FF05    | TIMA | Timer counter — incremented at a selectable rate |
| FF06    | TMA  | Timer modulo — reload value for TIMA after overflow |
| FF07    | TAC  | Timer control — enable bit and clock select |

### DIV (FF04)

Internally, the timer has a 16-bit counter (`div_ctr`) that increments every
M-cycle. The DIV register exposes only the upper byte (`div_ctr[15:8]`), so it
appears to increment once every 256 M-cycles (64 µs, or 16384 Hz).

Writing *any* value to FF04 resets the entire 16-bit counter to zero. This is
important because the lower bits of `div_ctr` drive the TIMA clock — resetting
DIV can cause an unexpected TIMA increment.

### TIMA (FF05)

The timer counter. TIMA is clocked by a bit of the internal `div_ctr` selected
by TAC. When TIMA overflows (increments past 0xFF), two things happen:

1. TIMA is reloaded with the value in TMA.
2. The Timer interrupt fires (IF bit 2 is set).

### TMA (FF06)

The modulo register. Holds the value loaded into TIMA after an overflow. If
TMA is 0x00, the timer counts the full 256 values between interrupts. If TMA
is 0xF0, only 16 increments occur before the next overflow.

### TAC (FF07)

Timer control. Only the lower 3 bits matter (upper 5 read as 1):

| Bit | Function |
|-----|----------|
| 2   | Enable — 1 = TIMA counts, 0 = TIMA is frozen |
| 1:0 | Clock select — which `div_ctr` bit clocks TIMA |

## Clock Selection

The clock select field picks which bit of the internal 16-bit counter drives
TIMA. Since each `div_ctr` bit toggles at a different rate, this controls how
fast TIMA counts:

| TAC[1:0] | div_ctr bit | M-cycles per tick | Frequency  |
|----------|-------------|-------------------|------------|
| 00       | 7           | 256               | 4,096 Hz   |
| 01       | 1           | 4                 | 262,144 Hz |
| 10       | 3           | 16                | 65,536 Hz  |
| 11       | 5           | 64                | 16,384 Hz  |

TIMA increments on the **falling edge** of `(enable AND selected_bit)`. The
timer tracks the previous value of this combined signal and increments TIMA
when it transitions from 1 to 0.

## Implementation

The timer is a standalone module in `rtl/io/timer.sv`. It connects to the
shared I/O bus and outputs a one-cycle IRQ pulse on overflow.

### Module Interface

```systemverilog
module timer (
    input  logic       clk,
    input  logic       reset,
    input  logic       io_cs,
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,
    output logic       io_rdata_valid,
    output logic       irq,
    // Debug outputs (unused in synthesis)
    output logic [15:0] dbg_div_ctr,
    output logic [7:0]  dbg_tima,
    output logic [7:0]  dbg_tma,
    output logic [7:0]  dbg_tac
);
```

The `io_rdata_valid` signal tells the parent module when the timer owns the
current I/O address. This lets the top-level mux the timer's read data in
without a large centralized case statement.

### Clock Select and Edge Detection

```systemverilog
logic selected_bit;
always_comb begin
    unique case (tac[1:0])
        2'b00: selected_bit = div_ctr[7];
        2'b01: selected_bit = div_ctr[1];
        2'b10: selected_bit = div_ctr[3];
        2'b11: selected_bit = div_ctr[5];
    endcase
end

wire tick_bit = tac[2] & selected_bit;
wire tima_tick = prev_bit & ~tick_bit;
```

The `tick_bit` signal combines the enable bit with the selected counter bit.
When `tick_bit` transitions from 1 to 0 (detected by comparing with the
registered `prev_bit`), TIMA increments.

### Sequential Logic

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        div_ctr  <= 16'h0000;
        tima     <= 8'h00;
        tma      <= 8'h00;
        tac      <= 3'b000;
        prev_bit <= 1'b0;
        irq      <= 1'b0;
    end else begin
        irq <= 1'b0;
        div_ctr <= div_ctr + 16'd1;
        prev_bit <= tick_bit;

        if (tima_tick) begin
            if (tima == 8'hFF) begin
                tima <= tma;
                irq  <= 1'b1;
            end else begin
                tima <= tima + 8'd1;
            end
        end

        if (io_cs && io_wr) begin
            unique case (io_addr)
                7'h04: begin div_ctr <= 16'h0000; prev_bit <= 1'b0; end
                7'h05: tima <= io_wdata;
                7'h06: tma  <= io_wdata;
                7'h07: tac  <= io_wdata[2:0];
                default: ;
            endcase
        end
    end
end
```

The IRQ pulse is cleared every cycle and only set for one clock on overflow.
I/O writes appear after the increment logic so a CPU write to TIMA takes
precedence over an increment in the same cycle.

## Top-Level Wiring

In `gb_top.sv`, the timer is instantiated and connected to the I/O bus:

```systemverilog
timer u_timer (
    .clk            (clk),
    .reset          (reset),
    .io_cs          (io_cs),
    .io_addr        (io_addr),
    .io_wr          (io_wr),
    .io_wdata       (io_wdata),
    .io_rdata       (timer_rdata),
    .io_rdata_valid (timer_rdata_valid),
    .irq            (timer_irq),
    .dbg_div_ctr    (), .dbg_tima(),
    .dbg_tma        (), .dbg_tac ()
);
```

The timer's IRQ is wired into the IF register:

```systemverilog
always_ff @(posedge clk) begin
    if (reset)
        if_reg <= 5'h00;
    else if (int_ack != 5'b0)
        if_reg <= if_reg & ~int_ack;
    else if (timer_irq)
        if_reg <= if_reg | 5'b00100;   // bit 2 = Timer
    else if (io_cs && io_wr && io_addr == 7'h0F)
        if_reg <= io_wdata[4:0];
end
```

And the I/O read mux uses `io_rdata_valid` to select the timer's data:

```systemverilog
always_comb begin
    if (timer_rdata_valid)
        io_rdata = timer_rdata;
    else begin
        unique case (io_addr)
            7'h01:   io_rdata = led_reg;
            7'h0F:   io_rdata = {3'b111, if_reg};
            default: io_rdata = 8'h00;
        endcase
    end
end
```

## Simulation Wrapper

The simulation wrapper `sim/top/timer_top.sv` extends the CPU+bus integration
testbench with the timer instance. It exposes debug outputs for direct
observation of the timer's internal state:

```systemverilog
output logic [15:0] dbg_div,
output logic [7:0]  dbg_tima,
output logic [7:0]  dbg_tma,
output logic [7:0]  dbg_tac
```

These let tests verify register values without writing a ROM program that reads
them back through the CPU.

## Testing

The timer testbench (`sim/test/timer.zig`) uses a ROM program that sets up the
timer and waits for the interrupt:

| Address | Instruction     | Effect |
|---------|-----------------|--------|
| 0x00    | LD SP, 0xFFFE   | Set up stack |
| 0x03    | LD A, 0x04      | IE = Timer bit |
| 0x05    | LDH (0xFF), A   | Write IE |
| 0x07    | LD A, 0xF0      | TIMA start value (near overflow) |
| 0x09    | LDH (0x05), A   | Write TIMA |
| 0x0B    | LD A, 0x42      | TMA reload value |
| 0x0D    | LDH (0x06), A   | Write TMA |
| 0x0F    | LD A, 0x05      | TAC = enable + fastest clock |
| 0x11    | LDH (0x07), A   | Write TAC |
| 0x13    | EI              | Enable interrupts |
| 0x14    | NOP             | EI delay slot |
| 0x15    | HALT            | Wait for timer interrupt |
| 0x50    | LD A, 0x55      | Timer ISR |
| 0x52    | RETI            | Return from interrupt |

Seven tests cover the timer's behavior:

1. **DIV increments** — verify the free-running counter
2. **DIV write resets** — confirm write-to-FF04 zeroes the counter
3. **TIMA counts at fastest rate** — TAC=0x05, one increment per 4 M-cycles
4. **TIMA overflow fires interrupt** — IF bit 2 set on overflow
5. **TMA reload after overflow** — TIMA reloads from TMA
6. **TAC disable stops TIMA** — TIMA frozen when enable bit is 0
7. **End-to-end interrupt dispatch** — full flow through ISR and back

## Building and Running

Run just the timer tests:

```
mise run test:timer
```

Run the full test suite (98 tests across 13 modules):

```
mise run test
```

Synthesize for the Tang Nano 20K:

```
mise run synth -- gb_top
```

## What's Next

With the timer firing interrupts, the system is ready for its first display
output. In Tutorial 12 we'll build the ST7789 SPI LCD driver to render pixels
on the Tang Nano 20K's on-board display — the first step toward getting the PPU
visible on real hardware.
