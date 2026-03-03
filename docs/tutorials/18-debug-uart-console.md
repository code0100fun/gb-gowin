# Tutorial 18 — Debug UART Console

Debugging an FPGA design with LEDs is painful — six bits of output, no
context, and lots of reflashing. Before tackling the MBC1 mapper and real game
ROMs, we need a proper debug channel. This tutorial adds a UART transmitter
and receiver connected to the Tang Nano 20K's built-in BL616 USB bridge, plus
a command-driven debug console that dumps CPU registers and interrupt state to
a terminal on the PC.

The BL616 chip on the Tang Nano 20K already provides a USB-to-UART bridge on
FPGA pins 69 (TX) and 70 (RX). No external hardware is needed — just
`picocom -b 115200 /dev/ttyUSB1`.

## UART Protocol

UART sends bytes as a serial bit stream. Each frame has:

```
idle(1)  start(0)  D0  D1  D2  D3  D4  D5  D6  D7  stop(1)  idle(1)...
```

- **Idle**: line held HIGH
- **Start bit**: one LOW bit signals the beginning of a frame
- **Data bits**: 8 bits, LSB first
- **Stop bit**: one HIGH bit marks the end
- **Baud rate**: both sides agree on the bit duration (115200 bits/sec = ~8.68 us/bit)

At 27 MHz with baud 115200, each bit lasts `27,000,000 / 115,200 = 234`
clock cycles. The 0.16% error from rounding is well within UART's ~2%
tolerance.

## Hardware: BL616 Bridge

The Tang Nano 20K's BL616 chip enumerates two USB serial devices:

- `/dev/ttyUSB0` — JTAG (used by openFPGALoader)
- `/dev/ttyUSB1` — UART bridge to FPGA pins 69/70

Pin assignments (internal board traces, not on GPIO header):

| Signal    | FPGA Pin | Direction | Description             |
|-----------|----------|-----------|-------------------------|
| `uart_tx` | 69       | Output    | FPGA transmits to PC    |
| `uart_rx` | 70       | Input     | PC transmits to FPGA    |

**Gotcha**: Close picocom before flashing — the JTAG programmer and UART
share the same USB connection.

## UART TX Module

`rtl/io/uart_tx.sv` — shift-register transmitter with a busy/ready handshake.

```systemverilog
module uart_tx #(
    parameter int CYCLES_PER_BIT = 234  // 27 MHz / 115200
) (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] data,
    input  logic       valid,   // pulse to start transmission
    output logic       ready,   // high when idle
    output logic       tx       // serial output (active high idle)
);
```

The state machine has four states:

- **IDLE**: `tx=1`, `ready=1`. On `valid` pulse: capture data, go to START.
- **START**: `tx=0` for `CYCLES_PER_BIT` cycles.
- **DATA**: shift out 8 bits LSB-first, `CYCLES_PER_BIT` each.
- **STOP**: `tx=1` for `CYCLES_PER_BIT` cycles, then back to IDLE.

A 3-bit `bit_idx` counter (0-7) tracks which data bit is being sent.
A `cycle_cnt` counter counts down within each bit period.

## UART RX Module

`rtl/io/uart_rx.sv` — samples at mid-bit using edge detection on the start bit.

```systemverilog
module uart_rx #(
    parameter int CYCLES_PER_BIT = 234
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       rx,       // serial input
    output logic [7:0] data,
    output logic       valid     // one-cycle pulse when byte received
);
```

Key design points:

- 2-FF synchronizer on `rx` to prevent metastability.
- **IDLE**: wait for `rx_sync` falling edge (start bit).
- **START**: wait `CYCLES_PER_BIT / 2` to reach mid-bit, verify still LOW.
- **DATA**: sample 8 bits at mid-bit (`CYCLES_PER_BIT` apart), shift into
  register LSB-first.
- **STOP**: verify stop bit is HIGH, pulse `valid` with received byte.

## Debug Console

`rtl/io/debug_console.sv` — receives single-character commands, responds with
formatted ASCII text.

```systemverilog
module debug_console #(
    parameter int CYCLES_PER_BIT = 234
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        uart_rx_pin,
    output logic        uart_tx_pin,
    input  logic [15:0] dbg_pc, dbg_sp,
    input  logic [7:0]  dbg_a, dbg_f, dbg_b, dbg_c,
    input  logic [7:0]  dbg_d, dbg_e, dbg_h, dbg_l,
    input  logic        dbg_halted,
    input  logic [7:0]  dbg_if, dbg_ie
);
```

### Commands

| Char | Response                                                          | Bytes |
|------|-------------------------------------------------------------------|-------|
| `?`  | `cmds: ? p r\r\n`                                                | 13    |
| `p`  | `PC=XXXX\r\n`                                                    | 9     |
| `r`  | `A=XX F=XX BC=XXXX DE=XXXX HL=XXXX SP=XXXX PC=XXXX IF=XX IE=XX\r\n` | 63    |

Newlines (`\r`, `\n`) and unknown characters are silently ignored.

### Internal Architecture

1. **UART TX/RX instances** — internal, driven by the CYCLES_PER_BIT parameter.
2. **Shadow registers** — when a command arrives, all debug inputs are captured
   into shadow registers so the response reflects a consistent snapshot (the
   CPU keeps running while the slow UART sends bytes).
3. **Response FSM** — four states:
   - **S_IDLE** waits for a valid command from RX.
   - **S_SEND** outputs the next response byte when TX is ready.
   - **S_LATCH** waits one cycle for the TX to latch the data and drop `ready`.
   - **S_WAIT** waits for TX to finish the byte, then advances the index.
4. **Hex conversion function**:
   ```systemverilog
   function automatic [7:0] hex(input [3:0] v);
       return (v < 4'd10) ? (8'd48 + {4'd0, v}) : (8'd55 + {4'd0, v});
   endfunction
   ```
   Maps 0-9 to '0'-'9', 10-15 to 'A'-'F'.

### S_LATCH: Why a One-Cycle Delay?

When S_SEND asserts `tx_valid` and transitions to the next state, the TX
module doesn't see `valid` until the next clock edge. Without the S_LATCH
state, the FSM would enter S_WAIT and immediately see `tx_ready=1` (because
the TX hasn't started yet), advancing to the next byte before the first one
was sent. The one-cycle S_LATCH delay lets the TX capture the data and drop
`ready` before S_WAIT starts polling it.

## Integration into gb_top.sv

Three changes to `rtl/platform/gb_top.sv`:

1. **Add UART pins** to the module port list:
   ```systemverilog
   output logic       uart_tx,
   input  logic       uart_rx
   ```

2. **Wire CPU debug signals** — change the unconnected `()` ports to named
   wires so the debug console can read them:
   ```systemverilog
   logic [15:0] dbg_pc, dbg_sp;
   logic [7:0]  dbg_a, dbg_f, dbg_b, dbg_c, dbg_d, dbg_e, dbg_h, dbg_l;
   ```

3. **Instantiate the debug console**:
   ```systemverilog
   debug_console u_debug (
       .clk(clk), .reset(reset),
       .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx),
       .dbg_pc(dbg_pc), .dbg_sp(dbg_sp),
       .dbg_a(dbg_a), .dbg_f(dbg_f),
       .dbg_b(dbg_b), .dbg_c(dbg_c),
       .dbg_d(dbg_d), .dbg_e(dbg_e),
       .dbg_h(dbg_h), .dbg_l(dbg_l),
       .dbg_halted(halted),
       .dbg_if({3'b111, if_reg}), .dbg_ie(ie_reg)
   );
   ```

## Pin Constraints

Add to `rtl/platform/constraints.cst`:

```
IO_LOC "uart_tx" 69;
IO_LOC "uart_rx" 70;
IO_PORT "uart_tx" IO_TYPE=LVCMOS33 DRIVE=8;
IO_PORT "uart_rx" IO_TYPE=LVCMOS33;
```

## Simulation

### UART Tests (`sim/test/uart.zig`) — 5 Tests

| # | Test               | What it verifies                                      |
|---|--------------------|-------------------------------------------------------|
| 1 | TX idle state      | TX line high, ready=1 when no data                    |
| 2 | TX sends 0x55      | Correct start/data/stop bit pattern and timing        |
| 3 | TX back-to-back    | Two bytes sent sequentially without gap                |
| 4 | RX receives 0xA3   | Bit-bang input, verify decoded byte and valid pulse    |
| 5 | TX-RX loopback     | Connect TX pin to RX pin in testbench, round-trip     |

Both test wrappers use `CYCLES_PER_BIT=4` for fast simulation (vs 234 for
hardware at 27 MHz / 115200 baud).

### Debug Console Tests (`sim/test/debug_console.zig`) — 4 Tests

Zig helpers `sendByte()` and `receiveByte()` bit-bang the UART protocol at
`CYCLES_PER_BIT=4` (40 ticks per byte frame).

| # | Test              | What it verifies                               |
|---|-------------------|------------------------------------------------|
| 1 | '?' command       | Receives `cmds: ? p r\r\n`                     |
| 2 | 'p' command       | Set PC=0x1234, receives `PC=1234\r\n`          |
| 3 | 'r' command       | Set known register values, verify full dump     |
| 4 | Unknown command   | Send 'x', verify no response (TX stays idle)   |

## Running the Tests

```bash
mise run test:uart            # 5 UART tests
mise run test:debug_console   # 4 console tests
mise run test                 # full 145-test suite
```

## Using the Console

After flashing:

```bash
# Close any openFPGALoader processes first
picocom -b 115200 /dev/ttyUSB1
```

Type `?` for help, `p` for PC, `r` for a full register dump:

```
> r
A=00 F=80 BC=0013 DE=00D8 HL=014D SP=FFFE PC=0064 IF=E1 IE=01
```

Exit picocom: `Ctrl-A`, `Ctrl-X`.

## Files Changed

| File                              | Action   | Description                          |
|-----------------------------------|----------|--------------------------------------|
| `rtl/io/uart_tx.sv`              | Created  | UART transmitter                     |
| `rtl/io/uart_rx.sv`              | Created  | UART receiver                        |
| `rtl/io/debug_console.sv`        | Created  | Command processor + response formatter |
| `sim/top/uart_top.sv`            | Created  | TX+RX test wrapper                   |
| `sim/top/debug_console_top.sv`   | Created  | Console test wrapper                 |
| `sim/test/uart.zig`              | Created  | 5 UART tests                         |
| `sim/test/debug_console.zig`     | Created  | 4 console tests                      |
| `build.zig`                      | Modified | Added uart_mod, debug_console_mod    |
| `rtl/platform/gb_top.sv`         | Modified | UART pins, CPU debug wires, console  |
| `rtl/platform/constraints.cst`   | Modified | UART TX/RX pins 69/70                |
| `mise.toml`                      | Modified | New sources and test tasks            |

## What's Next

Tutorial 19 adds a minimal serial port implementation — SB and SC registers
(FF01-FF02) with internal clock mode, enough for single-player games that
check the serial hardware.
