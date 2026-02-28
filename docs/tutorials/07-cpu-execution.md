# Tutorial 07 — CPU: Instruction Execution

Tutorials 05 and 06 built the three CPU sub-modules individually: the register
file, the ALU, and the instruction decoder. Each one is purely combinational (or
a simple register bank) and was tested in isolation. In this tutorial we connect
them together inside a top-level `cpu.sv` module that fetches opcodes from
memory, decodes them, and executes the full LR35902 instruction set.

**Source:** [Pan Docs — CPU](https://gbdev.io/pandocs/CPU_Registers_and_Flags.html)

## How the Sub-modules Connect

```
                  ┌───────────────────────────────────┐
   mem_rdata ────>│              CPU                   │
                  │                                    │
                  │   ┌──────────┐   ┌──────────┐     │
                  │   │ DECODER  │   │   ALU    │     │
                  │   │          │   │          │     │
                  │   │ opcode──>│   │ a,b ──> result│ │
                  │   │ mcycles  │   │ flags_out│     │
                  │   └──────────┘   └──────────┘     │
                  │                                    │
                  │   ┌──────────────────────────┐     │
                  │   │       REGISTER FILE      │     │
                  │   │  A F B C D E H L SP PC   │     │
                  │   └──────────────────────────┘     │
                  │                                    │
   mem_addr  <────│   ir, m_cycle, z_reg, w_reg        │
   mem_rd    <────│   cb_mode, halt_mode               │
   mem_wr    <────│                                    │
   mem_wdata <────│                                    │
                  └───────────────────────────────────┘
```

The **decoder** sees the active opcode and tells the CPU how many M-cycles the
instruction takes, which registers are involved, and what ALU operation to use.

The **ALU** is a pure function: give it two operands and an operation, and it
returns a result plus updated flags.

The **register file** stores all CPU registers and accepts write commands.

The **CPU** orchestrates everything through a state machine that advances one
M-cycle per clock tick.

## The M-cycle State Machine

The Game Boy CPU runs at ~1 MHz (4.19 MHz clock / 4). Each "machine cycle"
(M-cycle) is 4 clock ticks, but since our memory model is combinational (reads
complete in the same cycle), we model each M-cycle as a single clock edge.

The CPU has two phases:

### FETCH (m_cycle == 0)

1. Present `PC` on the memory bus, assert `mem_rd`
2. The decoder operates on the byte from memory (`mem_rdata`)
3. Latch the opcode into the instruction register (`ir`)
4. Increment PC
5. If the instruction is single-cycle (e.g., `NOP`, `LD r8,r8`, `ADD A,r8`):
   execute immediately and stay in FETCH
6. If multi-cycle: advance to `m_cycle = 1`

### EXECUTE (m_cycle > 0)

Each M-cycle performs one bus operation (read, write, or internal) based on the
instruction and current cycle number. When the last M-cycle completes, return to
FETCH.

## Combinational vs Registered Signals

A critical architectural decision: **register write controls must be
combinational**, not registered. If the CPU's `always_ff` sets
`rf_r8_we <= 1`, the regfile won't see it until the *next* clock edge — one
cycle too late.

Instead, all write enables, write selects, and write data are computed in
`always_comb`. They take effect on the same clock edge where the state machine
advances. The `always_ff` block only updates internal CPU state:

| Combinational (`always_comb`) | Registered (`always_ff`) |
|-------------------------------|--------------------------|
| `mem_addr`, `mem_rd`, `mem_wr` | `ir` (instruction register) |
| `rf_r8_we/wsel/wdata` | `m_cycle` (state counter) |
| `rf_r16_we/wsel/wdata` | `z_reg`, `w_reg` (temp regs) |
| `rf_flags_we/wdata` | `cb_mode`, `halt_mode` |
| `rf_sp_we/wdata`, `rf_pc_we/wdata` | `ime`, `ie_delay` |
| `alu_a`, `alu_b`, `alu_op` | |

## 1-cycle vs Multi-cycle Execution

### Single-cycle Instructions

These complete entirely during the FETCH phase. The decoder identifies them
(`mcycles == 1`), and the combinational block generates the appropriate register
writes immediately:

- `NOP` — no writes
- `LD r8, r8` — write source register value to destination
- `ALU A, r8` — ALU result written to A, flags updated
- `INC/DEC r8` — ALU INC/DEC, result to register
- `RLCA/RLA/RRCA/RRA/DAA/CPL/SCF/CCF` — ALU misc ops on A
- `JP HL` — set PC to HL
- `DI/EI` — toggle interrupt master enable
- `HALT` — enter halt mode

### Multi-cycle Example: LD r8, u8 (2 M-cycles)

```
M0 (FETCH): Read opcode from [PC], PC++, latch IR, advance to M1
M1 (EXEC):  Read immediate from [PC], write to destination register, PC++
            → Return to FETCH
```

### Multi-cycle Example: CALL u16 (6 M-cycles)

```
M0 (FETCH): Read opcode from [PC], PC++
M1: Read address low byte from [PC], PC++, latch into z_reg
M2: Read address high byte from [PC], PC++, latch into w_reg
M3: Internal — decrement SP
M4: Write PC high byte to [SP], decrement SP
M5: Write PC low byte to [SP], set PC to {w_reg, z_reg}
    → Return to FETCH (now executing at the call target)
```

## CB Prefix Handling

The `0xCB` prefix byte tells the CPU that the *next* byte is a CB-prefixed
opcode (bit operations and shifts).

1. CPU fetches `0xCB` — the decoder sets `is_cb_prefix`. The CPU sets
   `cb_mode = 1` and stays in FETCH (doesn't advance to EXECUTE).
2. Next FETCH: the decoder sees `cb_prefix = 1` and decodes the CB opcode.
3. Single-cycle CB instructions (register targets) execute in FETCH.
4. Multi-cycle CB instructions (`(HL)` targets: read, operate, write back) use
   2-3 M-cycles.
5. `cb_mode` is cleared when the instruction completes.

## Condition Evaluation

Four condition codes appear in `JR`, `JP`, `CALL`, and `RET`:

| Code | Mnemonic | Test |
|------|----------|------|
| 00 | NZ | Z flag == 0 |
| 01 | Z  | Z flag == 1 |
| 10 | NC | C flag == 0 |
| 11 | C  | C flag == 1 |

The condition result feeds into the decoder's `cond_met` input, which changes
the `mcycles` count: a taken branch uses more cycles than a not-taken one.

```systemverilog
wire cond_result = (dec_cond_code == 2'd0) ? !rf_flags[3] :  // NZ
                   (dec_cond_code == 2'd1) ?  rf_flags[3] :  // Z
                   (dec_cond_code == 2'd2) ? !rf_flags[0] :  // NC
                                               rf_flags[0];  // C
```

## Avoiding Combinational Loops

When the register file's read port is driven AND read in the same `always_comb`
block, Verilator detects a circular dependency. We solve this by using **direct
register outputs** (`out_a`, `out_b`, etc.) added to the register file in this
tutorial, plus a helper mux for 16-bit pairs:

```systemverilog
// r16 pair value from direct outputs (no combinational loop)
logic [15:0] r16_val;
always_comb begin
    unique case (dec_r16_idx)
        2'd0: r16_val = {rf_out_b, rf_out_c};
        2'd1: r16_val = {rf_out_d, rf_out_e};
        2'd2: r16_val = hl_val;
        2'd3: r16_val = rf_sp;
    endcase
end
```

## Register File Changes

We added 8 direct output ports to `regfile.sv`:

```systemverilog
output logic [7:0] out_a, out_f, out_b, out_c, out_d, out_e, out_h, out_l;

assign out_a = reg_a;
assign out_f = reg_f;
// ... etc
```

These are simple wires — no new muxes, no new logic. They let the CPU read any
register at any time without competing for the existing read ports.

## Test Strategy

The testbench (`sim/tb/tb_cpu.cpp`) uses a 64KB memory array with combinational
reads. Each test loads a small program, runs until HALT, and checks final
register values.

### Test Programs

| # | Instructions Tested | What It Verifies |
|---|---------------------|------------------|
| 1 | LD A,u8; LD B,u8; ADD; LD r,r; SUB | Basic loads and ALU |
| 2 | LD H/L; LD (HL),A; LD B,(HL); INC (HL) | Memory through HL |
| 3 | LD DE,u16; PUSH DE; POP BC | 16-bit loads, stack ops |
| 4 | JP u16; CALL u16; RET | Control flow |
| 5 | CB SWAP; INC; JR NZ | CB prefix, conditional jump |
| 6 | LD (HL+),A; LD (HL-),A; LD A,(HL+/-) | HL auto-increment/decrement |
| 7 | LD BC,u16; INC BC; LD DE,u16; DEC DE | 16-bit arithmetic |
| 8 | RST 0x08; RET | RST vector call |
| 9 | LDH (u8),A; LDH A,(u8) | High-page I/O |
| 10 | LD HL,u16; LD BC,u16; ADD HL,BC | 16-bit ADD |
| 11 | LD (u16),A; LD A,(u16) | Absolute address loads |
| 12 | CALL; OR; RET Z (not taken); RET | Conditional return |
| 13 | SET; BIT; RES; BIT | CB bit operations |
| 14 | LD (HL),A; DEC (HL) | Memory decrement |
| 15 | LD (HL),u8; LD A,(HL) | Immediate to memory |

## Building and Running

```bash
# Run just the CPU testbench
mise run sim:cpu

# Run the full simulation suite (all modules)
mise run sim
```

## What's Next

The CPU can now execute every base and CB-prefixed instruction. The next step is
connecting it to a memory bus with address decoding, so it can access ROM,
RAM, and I/O registers — the beginning of a complete Game Boy system.
