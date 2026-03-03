# Tutorial 17 — Joypad Input

The Game Boy's JOYP register (FF00) is currently stubbed — reads return 0x00.
Games that poll button state or rely on the joypad interrupt won't work. Even
simple title screens that wait for Start won't advance.

This tutorial adds 8 pushbuttons on breadboard GPIO pins, mapped to JOYP with
a 2-FF synchronizer, 3-sample debouncer, and the joypad interrupt (IF bit 4).

## Game Boy Button Matrix

The original Game Boy arranges its 8 buttons in a 2×4 matrix. The CPU selects
one or both columns by writing to JOYP bits 5–4, then reads the row state from
bits 3–0. Everything is active low — writing 0 selects a column, and a pressed
button reads as 0:

| Bit | Write (select) | Read: P14=0 (directions) | Read: P15=0 (actions) |
|-----|----------------|--------------------------|----------------------|
| 5 | P15 — action column | — | — |
| 4 | P14 — direction column | — | — |
| 3 | — | Down | Start |
| 2 | — | Up | Select |
| 1 | — | Left | B |
| 0 | — | Right | A |

Bits 7–6 are unused and always read as 1. When both columns are selected
(P14=P15=0), the result is the AND of both rows — any pressed button on either
column shows up.

The joypad interrupt fires when any selected P10–P13 line transitions from 1
to 0 (a button press). Games use this to wake from HALT while waiting for
input.

## Hardware Setup

Eight breadboard pushbuttons each connect a GPIO pin to 3.3V when pressed.
With the Apicula toolchain, pins float LOW when undriven (PULL_MODE=UP is
ignored), so unpressed reads as 0 and pressed reads as 1 — the opposite of
the active-low JOYP convention. The joypad module inverts this internally.

Pin assignments (left-side GPIO header on the Tang Nano 20K):

| Button | Pin | Signal |
|--------|-----|--------|
| Right | 25 | `btn_right` |
| Left | 26 | `btn_left` |
| Up | 27 | `btn_up` |
| Down | 28 | `btn_down` |
| A | 29 | `btn_a` |
| B | 30 | `btn_b` |
| Select | 31 | `btn_select` |
| Start | 32 | `btn_start` |

## Synchronizer

GPIO pins are asynchronous to the system clock. Without synchronization, the
flip-flops sampling button state could enter metastability — a state between 0
and 1 that propagates unpredictably. A 2-FF chain prevents this:

```systemverilog
    logic [7:0] btn_sync1, btn_sync2;
    always_ff @(posedge clk) begin
        btn_sync1 <= btn;
        btn_sync2 <= btn_sync1;
    end
```

The synchronized value `btn_sync2` is stable and safe to use in all downstream
logic. The 2-cycle latency is negligible for button input.

## Debouncer

Mechanical pushbuttons bounce — a single press can produce dozens of rapid
0→1→0 transitions over a few milliseconds. Without debouncing, the joypad
interrupt would fire repeatedly and the button state would flicker.

The debouncer uses a shared sample counter that divides the 27 MHz clock down
to approximately 1 kHz (every 27,000 cycles). At each sample tick, the
synchronized button value is shifted into a 3-bit shift register per button.
The debounced state only changes when all 3 bits agree:

```systemverilog
    localparam int CNT_WIDTH = $clog2(DEBOUNCE_CYCLES);
    logic [CNT_WIDTH-1:0] sample_cnt;
    wire sample_tick = (sample_cnt == CNT_WIDTH'(DEBOUNCE_CYCLES - 1));

    logic [2:0] btn_shift [0:7];
    logic [7:0] btn_stable;

    always_ff @(posedge clk) begin
        if (reset) begin
            sample_cnt <= '0;
            for (int i = 0; i < 8; i++) btn_shift[i] <= 3'b000;
            btn_stable <= 8'h00;
        end else begin
            if (sample_tick)
                sample_cnt <= '0;
            else
                sample_cnt <= sample_cnt + 1;

            if (sample_tick) begin
                for (int i = 0; i < 8; i++) begin
                    btn_shift[i] <= {btn_shift[i][1:0], btn_sync2[i]};
                    if ({btn_shift[i][1:0], btn_sync2[i]} == 3'b111)
                        btn_stable[i] <= 1'b1;
                    else if ({btn_shift[i][1:0], btn_sync2[i]} == 3'b000)
                        btn_stable[i] <= 1'b0;
                end
            end
        end
    end
```

With `DEBOUNCE_CYCLES=27000`, three consecutive samples span about 3 ms — long
enough to reject contact bounce but short enough for responsive gameplay.
The parameter is overridden to 4 in the simulation wrapper for fast testing.

## JOYP Read Logic

The CPU writes bits 5–4 to select which column(s) to read. The debounced
button states are split into direction and action groups, then gated by the
column select:

```systemverilog
    logic [1:0] reg_select;  // {P15, P14}

    wire [3:0] dpad   = btn_stable[3:0];  // {down, up, left, right}
    wire [3:0] action = btn_stable[7:4];  // {start, select, b, a}

    logic [3:0] p10_p13;
    always_comb begin
        p10_p13 = 4'b1111;  // all released (active low)
        if (!reg_select[0]) p10_p13 = p10_p13 & ~dpad;    // P14=0
        if (!reg_select[1]) p10_p13 = p10_p13 & ~action;  // P15=0
    end

    wire [7:0] joyp_read = {2'b11, reg_select, p10_p13};
```

The `btn_stable` signals are active high (1 = pressed), but JOYP reads are
active low (0 = pressed). The bitwise AND with `~dpad` / `~action` handles
the inversion — a pressed button (stable=1) clears the corresponding bit in
`p10_p13`.

## Joypad Interrupt

The joypad interrupt fires on any 1→0 transition of the selected P10–P13
lines. This is a rising-edge detector on the inverted signal:

```systemverilog
    logic [3:0] prev_p10_p13;
    always_ff @(posedge clk) begin
        if (reset) begin
            prev_p10_p13 <= 4'b1111;
            irq <= 1'b0;
        end else begin
            prev_p10_p13 <= p10_p13;
            irq <= |(prev_p10_p13 & ~p10_p13);
        end
    end
```

The interrupt is a single-cycle pulse — `prev & ~current` detects exactly
which bits transitioned from 1 to 0, and the OR-reduction triggers if any did.

## Integration

In `gb_top.sv`, the 8 individual button pins are combined into a bus and
passed to the joypad module:

```systemverilog
    wire [7:0] btn_bus = {btn_start, btn_select, btn_b, btn_a,
                          btn_down, btn_up, btn_left, btn_right};

    joypad u_joypad (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (io_cs),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (joypad_rdata),
        .io_rdata_valid (joypad_rdata_valid),
        .btn            (btn_bus),
        .irq            (joypad_irq)
    );
```

The joypad interrupt sets IF bit 4:

```systemverilog
    if (joypad_irq) next_if = next_if | 5'b10000;
```

And `joypad_rdata_valid` joins the I/O read mux priority chain after the
timer:

```systemverilog
    if (ppu_rdata_valid)
        io_rdata = ppu_rdata;
    else if (timer_rdata_valid)
        io_rdata = timer_rdata;
    else if (joypad_rdata_valid)
        io_rdata = joypad_rdata;
    else ...
```

## Simulation

The test wrapper (`joypad_top.sv`) is standalone — no CPU, bus, or memory.
It hardwires `io_cs=1` and directly exposes the I/O bus signals for the
testbench to drive. `DEBOUNCE_CYCLES` defaults to 4 for fast simulation.

Seven tests verify the joypad module:

| Test | What it checks |
|------|---------------|
| Default JOYP read | Both columns deselected, no buttons → reads 0xFF |
| Direction select | P14=0, press Right → bit 0 reads 0 |
| Action select | P15=0, press A → bit 0 reads 0 |
| Column isolation | P14=0 only, press A → bit 0 still 1 (wrong column) |
| Both columns selected | P14=P15=0, Right + Start → both appear |
| Debounce rejects glitch | 1-tick pulse rejected; sustained press accepted |
| Joypad interrupt | Button press fires exactly one IRQ pulse |

## What's Next

Tutorial 18 adds a UART debug console — a transmitter, receiver, and command
processor connected to the Tang Nano 20K's built-in USB bridge. Type `r` in
a terminal to dump all CPU registers and interrupt state. This will be
invaluable for debugging the MBC1 mapper and real game ROMs that follow.
