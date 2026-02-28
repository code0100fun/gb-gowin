# Tutorial 06 — CPU: Instruction Decoder

The instruction decoder is the brain of the CPU — it looks at the opcode byte
and determines what the CPU should do: which registers to read, what ALU
operation to perform, how many clock cycles to spend, and whether to access
memory. In this tutorial we build a purely combinational decoder and
exhaustively verify its cycle timing against the full LR35902 opcode table.

## How LR35902 Opcodes Are Structured

**Source:** [Pan Docs — CPU Instruction Set](https://gbdev.io/pandocs/CPU_Instruction_Set.html),
[Opcode Tables](https://gbdev.io/gb-opcodes/optables/)

Every instruction starts with a 1-byte opcode (0x00–0xFF). The opcode's bits
have a regular structure that makes decoding efficient:

```
  7  6  5  4  3  2  1  0
 ├──┤  ├────┤  ├────┤
 block  dst/op  src/reg
```

### The Four Blocks

Bits [7:6] divide the 256 opcodes into four blocks:

| Bits [7:6] | Range | Contents |
|-----------|-------|----------|
| 00 | 0x00–0x3F | Misc: 16-bit loads, INC/DEC, rotates, JR |
| 01 | 0x40–0x7F | 8-bit register-to-register LD (+ HALT at 0x76) |
| 10 | 0x80–0xBF | 8-bit ALU operations (ADD, SUB, AND, etc.) |
| 11 | 0xC0–0xFF | Jumps, calls, returns, stack ops, CB prefix |

### Register Encoding in Opcode Bits

For Blocks 1 and 2, the remaining bits encode registers directly:

```
Block 1: LD dst, src
  opcode = 01 [dst:3] [src:3]
                ↑ r8_dst   ↑ r8_src

Block 2: ALU_OP A, src
  opcode = 10 [alu:3] [src:3]
                ↑ ALU op    ↑ r8_src
```

The 3-bit register encoding matches what we built in the register file:

| Bits | Register | Bits | Register |
|------|----------|------|----------|
| 000 | B | 100 | H |
| 001 | C | 101 | L |
| 010 | D | 110 | [HL] (memory) |
| 011 | E | 111 | A |

Index 6 means "memory at address HL" — the CPU must do a bus read or write
instead of a register access. This adds one extra M-cycle to the instruction.

### ALU Operation Encoding

The ALU operation bits [5:3] in Block 2 map directly to our ALU's operation
encoding from Tutorial 05:

| Bits [5:3] | Operation | Bits [5:3] | Operation |
|-----------|-----------|-----------|-----------|
| 000 | ADD | 100 | AND |
| 001 | ADC | 101 | XOR |
| 010 | SUB | 110 | OR |
| 011 | SBC | 111 | CP |

This isn't a coincidence — we designed the ALU encoding to match. The decoder
can pass these bits straight through without translation.

### CB Prefix

Opcode 0xCB is a prefix — it tells the CPU to fetch a second byte and decode
it as a CB instruction. The CB opcode structure:

```
CB opcode:  [group:2] [bit/op:3] [r8:3]

Group 00: Rotate/shift (RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL)
Group 01: BIT b, r8
Group 10: RES b, r8
Group 11: SET b, r8
```

For BIT/RES/SET, bits [5:3] are the bit index (0–7) instead of the operation.

## M-Cycle Timing

Every instruction takes 1–6 **M-cycles** (1 M-cycle = 4 T-cycles at 4.19 MHz).
Each M-cycle performs at most one bus access (read or write). The key insight
is that there are only about 15 distinct timing patterns:

| M-cycles | Pattern | Example instructions |
|----------|---------|---------------------|
| 1 | fetch | NOP, LD r8,r8, ALU A,r8, HALT |
| 2 | fetch→read | LD r8,u8, ALU A,(HL), ALU A,u8 |
| 2 | fetch→write | LD (BC),A, LD (HL),r8 |
| 2 | fetch→internal | INC r16, ADD HL,r16, LD SP,HL |
| 3 | fetch→read→read | LD r16,u16, POP r16 |
| 3 | fetch→read→write | INC (HL), LDH (FF00+u8),A |
| 3 | fetch→read→internal | JR i8 (taken), LD HL,SP+i8 |
| 4 | fetch→read→read→internal | JP u16, RET |
| 4 | fetch→internal→write→write | PUSH r16, RST n |
| 4 | fetch→read→read→write | LD (u16),A |
| 4 | fetch→read→internal→write | ADD SP,i8 |
| 5 | fetch→internal→read→read→internal | RET cond (taken) |
| 5 | fetch→read→read→write→write | LD (u16),SP |
| 6 | fetch→read→read→internal→write→write | CALL u16 |

### Conditional Instructions

Conditional branches have **different cycle counts** depending on whether the
condition is met:

| Instruction | Taken | Not taken |
|------------|-------|-----------|
| JR cond,i8 | 3 | 2 |
| JP cond,u16 | 4 | 3 |
| CALL cond,u16 | 6 | 3 |
| RET cond | 5 | 2 |

The condition codes are encoded in bits [4:3]:

| Bits [4:3] | Condition | Flag test |
|-----------|-----------|-----------|
| 00 | NZ | Z == 0 |
| 01 | Z | Z == 1 |
| 10 | NC | C == 0 |
| 11 | C | C == 1 |

## The Decoder Module

Create `rtl/core/cpu/decoder.sv`. The decoder is purely combinational — no
clock, no state. It takes the opcode and produces control signals immediately.

### Interface

```systemverilog
module decoder (
    input  logic [7:0]  opcode,
    input  logic        cb_prefix,   // 1 = CB-prefixed instruction
    input  logic        cond_met,    // 1 = branch condition satisfied

    output logic [2:0]  mcycles,     // Total M-cycles for this decode

    // Decoded opcode fields (directly extracted from opcode bits)
    output logic [2:0]  r8_src,      // opcode[2:0]
    output logic [2:0]  r8_dst,      // opcode[5:3]
    output logic [1:0]  r16_idx,     // opcode[5:4]
    output logic [1:0]  cond_code,   // opcode[4:3]
    output logic [2:0]  rst_vec,     // opcode[5:3] — RST target (×8)
    output logic [2:0]  cb_bit_idx,  // opcode[5:3] — BIT/SET/RES index

    output logic [4:0]  alu_op,      // ALU operation (matches alu.sv)

    output logic        is_cb_prefix,
    output logic        uses_hl_indirect,
    output logic        is_halt,
    output logic        is_ei,
    output logic        is_di
);
```

### Opcode Field Extraction

Many fields are just direct bit slices — no logic needed:

```systemverilog
assign r8_src    = opcode[2:0];
assign r8_dst    = opcode[5:3];
assign r16_idx   = opcode[5:4];
assign cond_code = opcode[4:3];
assign rst_vec   = opcode[5:3];
assign cb_bit_idx = opcode[5:3];
```

### M-Cycle Count Logic

The cycle count is the decoder's most critical output — if it's wrong,
instruction timing is wrong and everything breaks. We use a `casez` statement
with specific opcodes taking priority over wildcard patterns:

```systemverilog
casez (opcode)
    // Block 0: specific opcodes first
    8'h00: mcycles = 3'd1; // NOP
    8'h08: mcycles = 3'd5; // LD (u16),SP
    8'h18: mcycles = 3'd3; // JR i8
    8'h20, 8'h28,
    8'h30, 8'h38: mcycles = cond_met ? 3'd3 : 3'd2; // JR cond

    // Block 0: wildcard patterns for regular groups
    8'b00_??_0001: mcycles = 3'd3; // LD r16,u16
    8'b00_??_0011: mcycles = 3'd2; // INC r16
    // ...

    // Block 1: HALT before LD patterns
    8'h76:         mcycles = 3'd1; // HALT (not LD (HL),(HL))
    8'b01_110_???: mcycles = 3'd2; // LD (HL),r8
    8'b01_???_110: mcycles = 3'd2; // LD r8,(HL)
    8'b01_???_???: mcycles = 3'd1; // LD r8,r8

    // Block 2
    8'b10_???_110: mcycles = 3'd2; // ALU A,(HL)
    8'b10_???_???: mcycles = 3'd1; // ALU A,r8

    // Block 3: specific opcodes for irregular instructions
    8'hC0, 8'hC8,
    8'hD0, 8'hD8: mcycles = cond_met ? 3'd5 : 3'd2; // RET cond
    // ... etc
endcase
```

The `casez` uses `?` as a wildcard (matches 0 or 1). Verilator warns about
overlapping patterns (e.g., `8'h34` and `8'b00_???_100` both match INC (HL)),
but since `casez` uses first-match priority, the specific opcode wins. We
suppress this with `lint_off CASEOVERLAP`.

### ALU Operation Decode

For Block 2 and Block 3 immediate ALU instructions, the ALU operation maps
directly from opcode bits:

```systemverilog
2'b10: alu_op = {2'b00, opcode[5:3]};  // Block 2: ALU A,r8
2'b11: begin
    if (opcode[2:0] == 3'b110)
        alu_op = {2'b00, opcode[5:3]};  // Block 3: ALU A,u8
end
```

For CB-prefix instructions, the operation category comes from bits [7:6]:

```systemverilog
2'b00: alu_op = {2'b01, opcode[5:3]};  // Rotate/shift
2'b01: alu_op = {2'b10, 3'b000};       // BIT
2'b10: alu_op = {2'b10, 3'b001};       // RES
2'b11: alu_op = {2'b10, 3'b010};       // SET
```

### CB Prefix Handling

When the CPU encounters opcode 0xCB, the decoder sets `is_cb_prefix=1`. The
CPU then fetches the next byte and feeds it back to the decoder with
`cb_prefix=1`. The decoder then outputs the CB instruction's cycle count:

- Register operand (r8 ≠ 6): **1 M-cycle** (execute during fetch)
- BIT n,(HL): **2 M-cycles** (fetch + read)
- Other (HL): **3 M-cycles** (fetch + read + write)

Total instruction time = 1 (CB prefix) + CB mcycles.

## Testing

### Exhaustive Cycle Count Verification

The testbench hardcodes the expected M-cycle count for every opcode in a
256-entry lookup table and checks all of them:

```cpp
static const uint8_t BASE_MCYCLES_TAKEN[256] = {
    //      0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    /* 0 */ 1, 3, 2, 2, 1, 1, 2, 1, 5, 2, 2, 2, 1, 1, 2, 1,
    /* 1 */ 1, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    // ... all 256 entries
};

for (int op = 0; op < 256; op++) {
    dut->opcode    = op;
    dut->cb_prefix = 0;
    dut->cond_met  = 1;
    dut->eval();
    assert(dut->mcycles == BASE_MCYCLES_TAKEN[op]);
}
```

The test suite covers **868 test vectors** across 8 groups:

| Test | Count | What it verifies |
|------|-------|-----------------|
| Base opcodes (taken) | 256 | M-cycles for every opcode with branch taken |
| Conditional (not taken) | 16 | M-cycles for all 16 conditional opcodes |
| CB opcodes | 256 | M-cycles for every CB-prefixed opcode |
| ALU decode (Block 2) | 64 | alu_op for all 64 Block 2 opcodes |
| ALU decode (immediate) | 8 | alu_op for all 8 immediate ALU opcodes |
| CB ALU decode | 256 | alu_op for all 256 CB opcodes |
| Instruction flags | 5 | HALT, EI, DI, CB prefix detection |
| [HL] indirect | 7 | Correct detection in Block 1, 2, and CB |

## Running the Tests

```bash
mise run sim:decoder

# Or all tests
mise run sim
```

Expected output:

```
[sim:decoder] --- Results: 868 passed, 0 failed ---
```

## What the Decoder Doesn't Do (Yet)

This decoder handles opcode classification and timing, but it doesn't yet
generate the per-M-cycle bus control signals (address source, read/write
direction, register write-back). Those signals will be generated by the CPU
controller in [Tutorial 07](07-cpu-execution.md), which integrates the
decoder with the register file and ALU into a complete, cycle-accurate CPU.

## What's Next

In [Tutorial 07](07-cpu-execution.md) we integrate the register file, ALU,
and decoder into `cpu.sv` — the complete LR35902 CPU. The CPU controller uses
the decoder's outputs to drive an M-cycle state machine that fetches opcodes,
reads operands, executes ALU operations, and writes results back. We'll test
it by running small hand-written programs and comparing register traces against
a known-good reference.
