# Tutorial 05 — CPU: Register File and ALU

The Game Boy's CPU — the Sharp LR35902 — is a modified Z80-like processor. In
this tutorial we'll build the two core data path components: the **register
file** (where data lives) and the **ALU** (where computation happens). These are
pure building blocks — they'll be wired together by the CPU control logic in
later tutorials.

## The LR35902 Register Architecture

**Source:** [Pan Docs — CPU Registers and Flags](https://gbdev.io/pandocs/CPU_Registers_and_Flags.html)

The LR35902 has eight 8-bit general-purpose registers that can also be accessed
as four 16-bit pairs:

```
  ┌───┬───┐
  │ A │ F │   AF — Accumulator + Flags
  ├───┼───┤
  │ B │ C │   BC — General purpose
  ├───┼───┤
  │ D │ E │   DE — General purpose
  ├───┼───┤
  │ H │ L │   HL — General purpose / memory pointer
  └───┴───┘
  ┌───────┐
  │  SP   │   Stack Pointer (16-bit)
  ├───────┤
  │  PC   │   Program Counter (16-bit)
  └───────┘
```

In each 16-bit pair, the first register is the **high byte** and the second is
the **low byte**. So `BC = {B, C}` where B occupies bits [15:8].

### The Flag Register (F)

The F register isn't a general-purpose register — it holds the CPU's condition
flags. Only the upper nibble is used; the lower nibble is **hardwired to zero**:

```
Bit:   7    6    5    4    3    2    1    0
       Z    N    H    C    0    0    0    0
       │    │    │    │
       │    │    │    └── Carry: overflow/borrow from bit 7
       │    │    └─────── Half-carry: overflow/borrow from bit 3 (for BCD)
       │    └──────────── Subtract: set by subtraction instructions (for DAA)
       └───────────────── Zero: set when result is zero
```

The lower nibble being always zero is a real hardware constraint that we must
enforce. When the CPU executes `POP AF` (popping a 16-bit value into A and F
from the stack), the low nibble of the value going into F must be masked off.
If you skip this, you'll fail Blargg's cpu_instrs test.

### Register Encoding in Opcodes

The LR35902 encodes register indices directly in the opcode bits. This is
important because our register file's addressing should match:

**8-bit register (r8) — 3-bit encoding:**

| Bits | Register |
|------|----------|
| 000 | B |
| 001 | C |
| 010 | D |
| 011 | E |
| 100 | H |
| 101 | L |
| 110 | [HL] (memory at address HL — not a register) |
| 111 | A |

Index 6 is special — it means "the byte in memory at the address HL points to."
The register file can't handle memory access, so it returns a placeholder for
index 6 and the CPU handles the memory read/write externally.

**16-bit register pair (r16) — 2-bit encoding:**

| Bits | Pair | Used by |
|------|------|---------|
| 00 | BC | Most 16-bit instructions |
| 01 | DE | |
| 10 | HL | |
| 11 | SP | LD r16,nn / INC r16 / DEC r16 / ADD HL,r16 |

**Stack pair (r16stk) — for PUSH/POP:**

| Bits | Pair |
|------|------|
| 00 | BC |
| 01 | DE |
| 10 | HL |
| 11 | **AF** (not SP!) |

This is a critical difference — PUSH/POP use AF where other 16-bit instructions
use SP. Getting this wrong is a common source of bugs.

## Module 1: Register File

Create `rtl/core/cpu/regfile.sv`:

```systemverilog
module regfile (
    input  logic        clk,

    // 8-bit register access
    input  logic [2:0]  r8_rsel,      // read select
    output logic [7:0]  r8_rdata,     // read data
    input  logic        r8_we,        // write enable
    input  logic [2:0]  r8_wsel,      // write select
    input  logic [7:0]  r8_wdata,     // write data

    // 16-bit pair access (r16: BC, DE, HL, SP)
    input  logic [1:0]  r16_rsel,     // read select
    output logic [15:0] r16_rdata,    // read data
    input  logic        r16_we,       // write enable
    input  logic [1:0]  r16_wsel,     // write select
    input  logic [15:0] r16_wdata,    // write data

    // 16-bit stack pair access (r16stk: BC, DE, HL, AF)
    input  logic [1:0]  r16stk_rsel,
    output logic [15:0] r16stk_rdata,
    input  logic        r16stk_we,
    input  logic [1:0]  r16stk_wsel,
    input  logic [15:0] r16stk_wdata,

    // Flag access
    output logic [3:0]  flags,        // {Z, N, H, C}
    input  logic        flags_we,
    input  logic [3:0]  flags_wdata,  // {Z, N, H, C}

    // SP / PC
    output logic [15:0] sp,
    input  logic        sp_we,
    input  logic [15:0] sp_wdata,

    output logic [15:0] pc,
    input  logic        pc_we,
    input  logic [15:0] pc_wdata
);

    // Storage: 8 individual registers + SP + PC
    logic [7:0] reg_a, reg_f;
    logic [7:0] reg_b, reg_c;
    logic [7:0] reg_d, reg_e;
    logic [7:0] reg_h, reg_l;
    logic [15:0] reg_sp, reg_pc;

    // Flag extraction — F upper nibble only, lower nibble always 0
    assign flags = reg_f[7:4];

    // SP / PC outputs
    assign sp = reg_sp;
    assign pc = reg_pc;

    // 8-bit read mux (combinational)
    always_comb begin
        unique case (r8_rsel)
            3'd0: r8_rdata = reg_b;
            3'd1: r8_rdata = reg_c;
            3'd2: r8_rdata = reg_d;
            3'd3: r8_rdata = reg_e;
            3'd4: r8_rdata = reg_h;
            3'd5: r8_rdata = reg_l;
            3'd6: r8_rdata = 8'hFF;  // [HL] placeholder
            3'd7: r8_rdata = reg_a;
        endcase
    end

    // 16-bit pair read mux (r16: BC, DE, HL, SP)
    always_comb begin
        unique case (r16_rsel)
            2'd0: r16_rdata = {reg_b, reg_c};
            2'd1: r16_rdata = {reg_d, reg_e};
            2'd2: r16_rdata = {reg_h, reg_l};
            2'd3: r16_rdata = reg_sp;
        endcase
    end

    // 16-bit stack pair read mux (r16stk: BC, DE, HL, AF)
    always_comb begin
        unique case (r16stk_rsel)
            2'd0: r16stk_rdata = {reg_b, reg_c};
            2'd1: r16stk_rdata = {reg_d, reg_e};
            2'd2: r16stk_rdata = {reg_h, reg_l};
            2'd3: r16stk_rdata = {reg_a, reg_f};
        endcase
    end

    // Write logic (synchronous)
    always_ff @(posedge clk) begin
        // 8-bit register writes
        if (r8_we) begin
            unique case (r8_wsel)
                3'd0: reg_b <= r8_wdata;
                3'd1: reg_c <= r8_wdata;
                3'd2: reg_d <= r8_wdata;
                3'd3: reg_e <= r8_wdata;
                3'd4: reg_h <= r8_wdata;
                3'd5: reg_l <= r8_wdata;
                3'd6: ;  // [HL] — ignored
                3'd7: reg_a <= r8_wdata;
            endcase
        end

        // 16-bit pair writes (r16: BC, DE, HL, SP)
        if (r16_we) begin
            unique case (r16_wsel)
                2'd0: {reg_b, reg_c} <= r16_wdata;
                2'd1: {reg_d, reg_e} <= r16_wdata;
                2'd2: {reg_h, reg_l} <= r16_wdata;
                2'd3: reg_sp         <= r16_wdata;
            endcase
        end

        // 16-bit stack pair writes (r16stk: BC, DE, HL, AF)
        if (r16stk_we) begin
            unique case (r16stk_wsel)
                2'd0: {reg_b, reg_c} <= r16stk_wdata;
                2'd1: {reg_d, reg_e} <= r16stk_wdata;
                2'd2: {reg_h, reg_l} <= r16stk_wdata;
                2'd3: begin
                    reg_a <= r16stk_wdata[15:8];
                    reg_f <= r16stk_wdata[7:0] & 8'hF0;  // mask low nibble
                end
            endcase
        end

        // Direct flag writes
        if (flags_we)
            reg_f <= {flags_wdata, 4'b0000};

        // SP / PC writes
        if (sp_we)
            reg_sp <= sp_wdata;
        if (pc_we)
            reg_pc <= pc_wdata;
    end

endmodule
```

### Design Decisions

**Why not use a register array?** You might expect to see `logic [7:0] regs[8]`
and index it directly. We use named registers instead for three reasons:

1. **16-bit pair access** — reading BC means reading both B and C in the same
   cycle. With a flat array, Yosys would need two read ports. Named registers
   let us concatenate them directly: `{reg_b, reg_c}`.

2. **Multiple read ports** — the CPU often needs to read two registers
   simultaneously (e.g., A and B for `ADD A,B`). Named registers give us as
   many read ports as we want, for free.

3. **Special handling** — F needs the low nibble mask, index 6 returns 0xFF
   instead of a register, and SP/PC are 16-bit. A uniform array would need
   special-case logic everywhere.

**Why are reads combinational but writes synchronous?** Read ports are just
multiplexers — pure combinational logic. The CPU sets `r8_rsel` and `r8_rdata`
is available immediately (same cycle). Writes happen on the clock edge, so the
new value is visible on the **next** read after the write.

This is different from the BSRAM-based memories in Tutorial 04 where reads were
also synchronous (one-cycle latency). The register file is small (8 bytes) so
it's built from flip-flops, not BSRAM, and can afford combinational reads.

**Why three separate 16-bit port groups?** The r16 encoding (BC, DE, HL, SP)
and r16stk encoding (BC, DE, HL, AF) differ in their last entry. Rather than
adding mux logic to switch between SP and AF based on the instruction type, we
provide both port groups and let the CPU control logic select the right one.

## Module 2: ALU

The ALU is purely combinational — it takes operands and an operation code, and
produces a result and updated flags in the same cycle. No clock needed.

**Source:** [Pan Docs — CPU Instruction Set](https://gbdev.io/pandocs/CPU_Instruction_Set.html)

Create `rtl/core/cpu/alu.sv`:

```systemverilog
module alu (
    // 8-bit ALU operation
    input  logic [7:0]  a,          // first operand (usually accumulator)
    input  logic [7:0]  b,          // second operand (register or immediate)
    input  logic [3:0]  flags_in,   // current flags {Z, N, H, C}
    input  logic [4:0]  op,         // operation select (see below)
    input  logic [2:0]  bit_sel,    // bit index for BIT/SET/RES

    output logic [7:0]  result,     // operation result
    output logic [3:0]  flags_out   // updated flags {Z, N, H, C}
);
```

### Operation Encoding

We encode all ALU operations in a 5-bit `op` signal. Bits [4:3] select the
category, bits [2:0] select the operation within that category:

```
op[4:3] = Category
  00 = 8-bit arithmetic/logic (ADD, ADC, SUB, SBC, AND, XOR, OR, CP)
  01 = Rotate/shift (RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL)
  10 = Bit operations (BIT, RES, SET)
  11 = Miscellaneous (INC, DEC, DAA, CPL, SCF, CCF, RLCA/RLA, RRCA/RRA)
```

The 8-bit arithmetic/logic encodings (category 00) match the opcode bits [5:3]
from Block 2 instructions (0x80–0xBF) exactly:

| op[2:0] | Operation | Flags: Z N H C |
|---------|-----------|----------------|
| 000 | ADD | Z 0 H C |
| 001 | ADC | Z 0 H C |
| 010 | SUB | Z 1 H C |
| 011 | SBC | Z 1 H C |
| 100 | AND | Z 0 **1** 0 |
| 101 | XOR | Z 0 0 0 |
| 110 | OR  | Z 0 0 0 |
| 111 | CP  | Z 1 H C |

The rotate/shift encodings (category 01) match the CB-prefix opcode bits [5:3]:

| op[2:0] | Operation | Description |
|---------|-----------|-------------|
| 000 | RLC  | Rotate left circular |
| 001 | RRC  | Rotate right circular |
| 010 | RL   | Rotate left through carry |
| 011 | RR   | Rotate right through carry |
| 100 | SLA  | Shift left arithmetic |
| 101 | SRA  | Shift right arithmetic (bit 7 preserved) |
| 110 | SWAP | Swap nibbles |
| 111 | SRL  | Shift right logical |

By making our encoding match the opcode structure, the instruction decoder
(Tutorial 06) can often pass opcode bits directly to the ALU without
translation.

### Half-Carry: The Tricky Flag

The half-carry (H) flag indicates a carry or borrow at bit 3 — the boundary
between the low and high nibbles. It exists for the DAA (Decimal Adjust
Accumulator) instruction, which does BCD correction.

For addition, we compute H by doing the add on just the lower nibbles with an
extra bit to catch the overflow:

```systemverilog
// 5-bit addition of lower nibbles
hsum5 = {1'b0, a[3:0]} + {1'b0, b[3:0]} + {4'd0, cin};
// H flag = bit 4 of the 5-bit result (the overflow bit)
flags_out[H] = hsum5[4];
```

For subtraction, the same principle applies but with subtraction — bit 4 of
the 5-bit result indicates a borrow:

```systemverilog
hsum5 = {1'b0, a[3:0]} - {1'b0, b[3:0]} - {4'd0, cin};
flags_out[H] = hsum5[4];  // borrow from upper nibble
```

### The Carry Flag and ADC/SBC

ADC (Add with Carry) and SBC (Subtract with Carry) use the existing carry flag
as an additional input:

```systemverilog
cin = (op == ADC) ? flags_in[C] : 1'b0;
sum9 = {1'b0, a} + {1'b0, b} + {8'd0, cin};
```

This is essential for multi-byte arithmetic. To add two 16-bit numbers
byte-by-byte, you ADD the low bytes, then ADC the high bytes — the carry from
the low addition flows through.

### CP: Compare Without Storing

CP (Compare) is identical to SUB except it doesn't write the result back to the
accumulator. It sets all four flags based on the subtraction, but the original
value of A is preserved:

```systemverilog
ALU_CP: begin
    // Compute subtraction for flags
    sum9 = {1'b0, a} - {1'b0, b};
    // Result is the original A, not the subtraction
    result = a;
    // But flags reflect the subtraction
    flags_out = {(sum9[7:0] == 0), 1'b1, hsum5[4], sum9[8]};
end
```

### INC and DEC: Carry Preserved

A subtle but important detail: INC and DEC update Z, N, and H flags but
**preserve the carry flag**. This matters because game code often does things
like:

```asm
    cp $10      ; sets carry if A < $10
    inc b       ; increment counter — must NOT touch carry!
    jr c, .loop ; branch based on the earlier CP
```

If INC modified the carry flag, the branch would use the wrong condition.

```systemverilog
OP_INC: begin
    result = a + 8'd1;
    hsum5  = {1'b0, a[3:0]} + 5'd1;
    flags_out = {(result == 0), 1'b0, hsum5[4], flags_in[0]};
    //                                           ^^^^^^^^^^^ C preserved!
end
```

### Accumulator Rotates vs CB Rotates

There are two sets of rotate instructions that look similar but differ in one
critical way:

| Instruction | Z flag | Encoding |
|-------------|--------|----------|
| RLCA, RRCA, RLA, RRA | **Always 0** | 1-byte opcodes (0x07, 0x0F, 0x17, 0x1F) |
| RLC A, RRC A, RL A, RR A | Set normally | CB-prefix (0xCB 0x07, etc.) |

The 1-byte accumulator rotates always clear Z, even if the result is zero. The
CB-prefix versions set Z based on the result. Getting this wrong will fail
Blargg's tests.

We handle this by using a separate category (11) for the accumulator rotates
and forcing Z=0 in their output:

```systemverilog
OP_RLCA: begin
    result = {a[6:0], a[7]};          // same rotation as RLC
    flags_out = {1'b0, 1'b0, 1'b0, a[7]};  // but Z is ALWAYS 0
end
```

### DAA: Decimal Adjust Accumulator

DAA is the most complex single ALU operation. It adjusts the accumulator after
a BCD (Binary-Coded Decimal) addition or subtraction so that each nibble
contains a valid decimal digit (0–9).

The algorithm depends on the N flag (was the last operation an addition or
subtraction?) and the H and C flags:

```
After addition (N=0):
  If H is set OR low nibble > 9:  add 0x06  (fix low digit)
  If C is set OR value > 0x99:    add 0x60  (fix high digit), set C

After subtraction (N=1):
  If H is set:                    subtract 0x06
  If C is set:                    subtract 0x60

Then: Z = (result == 0), N = unchanged, H = 0, C = may be set
```

DAA is used by games that display decimal scores. Without it working correctly,
score displays will be garbled.

### The Complete ALU

Here's the full implementation (see `rtl/core/cpu/alu.sv` for the complete
source with all operations):

```systemverilog
    // Category decode from 5-bit op
    logic [1:0] cat;
    logic [2:0] sub_op;
    assign cat    = op[4:3];
    assign sub_op = op[2:0];

    always_comb begin
        result    = 8'h00;
        flags_out = flags_in;  // default: preserve all flags

        unique case (cat)
            CAT_ALU8: begin
                // ADD, ADC, SUB, SBC, AND, XOR, OR, CP
                // ... (see full source)
            end

            CAT_SHIFT: begin
                // RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL
                // ... (see full source)
            end

            CAT_BIT: begin
                // BIT, RES, SET
                // ... (see full source)
            end

            CAT_MISC: begin
                // INC, DEC, DAA, CPL, SCF, CCF, RLCA/RLA, RRCA/RRA
                // ... (see full source)
            end
        endcase
    end
```

## Testing

### Register File Tests (`sim/tb/tb_regfile.cpp`)

| Test | What it verifies |
|------|--------------------|
| 8-bit write/read | Each register holds its value, [HL] returns 0xFF |
| 16-bit pair reads | BC, DE, HL combine correctly, SP reads separately |
| 16-bit pair write | Writing BC splits correctly to B and C |
| Stack pair (r16stk) | AF read/write, POP AF masks F lower nibble |
| Flag access | Set/clear individual flags via flags port |
| SP and PC | Direct 16-bit register writes and reads |
| Write priority | r8 and r16 writes work independently |

The POP AF masking test is especially important:

```cpp
// Write AF via r16stk — low nibble of F should be masked
tb.dut->r16stk_we    = 1;
tb.dut->r16stk_wsel  = 3;  // AF
tb.dut->r16stk_wdata = 0x12FF;  // A=0x12, F=0xFF → should become 0xF0
tb.tick();

tb.dut->r16stk_rsel = 3;
tb.dut->eval();
tb.check(tb.dut->r16stk_rdata == 0x12F0,
         "POP AF masks F lower nibble: 0x12FF → 0x12F0");
```

### ALU Tests (`sim/tb/tb_alu.cpp`)

The ALU testbench is data-driven — each test is a struct with inputs and
expected outputs, run through a common harness:

```cpp
struct TestVec {
    const char* name;
    uint8_t  op;
    uint8_t  a, b;
    uint8_t  bit_sel;
    uint8_t  flags_in;
    uint8_t  exp_result;
    uint8_t  exp_flags;
};
```

Since the ALU is purely combinational (no clock), we don't use the `Testbench`
template. Instead we just set inputs and call `eval()`:

```cpp
dut->op       = t.op;
dut->a        = t.a;
dut->b        = t.b;
dut->bit_sel  = t.bit_sel;
dut->flags_in = t.flags_in;
dut->eval();

bool result_ok = (dut->result == t.exp_result);
bool flags_ok  = (dut->flags_out == t.exp_flags);
```

The test suite covers **139 test vectors** across 12 groups:

| Group | Tests | What it covers |
|-------|-------|---------------|
| ADD | 10 | Zero, carry, half-carry, overflow |
| ADC | 7 | Carry-in behavior |
| SUB | 8 | Borrow, half-borrow |
| SBC | 5 | Borrow with carry-in |
| AND/XOR/OR | 13 | H=1 for AND, flags cleared for XOR/OR |
| CP | 4 | Result = A (not stored), flags from subtraction |
| INC/DEC | 10 | Half-carry, carry preservation |
| CB rotates/shifts | 31 | RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL |
| BIT/RES/SET | 17 | Z=~bit for BIT, flag preservation for RES/SET |
| Acc rotates | 13 | RLCA/RLA/RRCA/RRA — Z always cleared |
| DAA | 10 | BCD correction after add/sub, with H/C flags |
| CPL/SCF/CCF | 11 | Complement, set/complement carry, flag preservation |

## Running the Tests

```bash
# Run all testbenches
mise run sim

# Run just the new ones
mise run sim:regfile
mise run sim:alu
```

Expected output:

```
[sim:regfile] --- Results: 13 passed, 0 failed ---
[sim:alu]     --- Results: 139 passed, 0 failed ---
```

## Why Flip-Flops Instead of BSRAM?

In Tutorial 04 we used BSRAM for the larger memories (VRAM, WRAM, etc.). The
register file uses **flip-flops** instead. Here's why:

1. **Size** — 8 registers × 8 bits = 64 bits. BSRAM blocks are 18 Kbits
   minimum. Using one for 64 bits would waste 99.6% of it.

2. **Multiple read ports** — The CPU needs to read two registers and the flags
   simultaneously. BSRAM gives you at most 2 ports (true dual-port). Flip-flops
   give unlimited read ports — they're just multiplexers.

3. **Combinational reads** — The CPU needs register data in the same cycle it
   selects the register (for ALU operations). BSRAM has a one-cycle read
   latency. Flip-flops are immediate.

4. **Transparent writes** — When we write a register, we might need the new
   value immediately for the next micro-operation. Flip-flops support this
   naturally through forwarding logic.

The register file will use about 80 flip-flops (8 regs × 8 bits + SP + PC),
which is a tiny fraction of the GW2AR-18's 15,552 available FFs.

## What's Next

In [Tutorial 06](06-cpu-instruction-decoder.md) we'll build the instruction
decoder — the control logic that reads opcodes and generates the signals that
drive the register file and ALU. It decodes all 256 base opcodes plus 256
CB-prefixed opcodes, and manages the multi-cycle timing that each instruction
requires.
