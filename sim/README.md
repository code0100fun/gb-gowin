# Simulation

Verilator testbenches written in Zig using [zig-verilator](../../zig-verilator/).

## Directory structure

```
sim/
  test/       Zig testbenches (tb_*.zig)
  top/        Simulation-only top modules (e.g. cpu_bus_top.sv)
  data/       Hex files loaded by ROM modules during simulation
  roms/       Game Boy ROM files (gitignored)
```

## Running tests

Run all testbenches:

```sh
mise run test
```

Run a single testbench:

```sh
mise run test:cpu
mise run test:alu
mise run test:decoder
mise run test:bus
mise run test:regfile
mise run test:rom
mise run test:blinky
mise run test:single_port_ram
mise run test:dual_port_ram
mise run test:cpu_bus
mise run test:gb_top
```

Or directly with zig (requires the glibc target workaround on Arch/CachyOS):

```sh
zig build test -Dtarget=x86_64-linux-gnu.2.38 --summary all
zig build test:cpu -Dtarget=x86_64-linux-gnu.2.38 --summary all
```

## How it works

Each testbench imports a Verilator model generated at build time by `zig-verilator`:

```zig
const cpu = @import("cpu");

test "basic loads and ALU" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();

    dut.set(.op, 0x80);
    dut.eval();
    try std.testing.expectEqual(@as(u64, 0x03), dut.get(.dbg_c));
}
```

Models are defined in `build.zig` with `verilator.addModel()`. Combinational modules
use `.clock = null`; clocked modules get an auto-generated `tick()` method.

## VCD waveform tracing

To debug signals with a waveform viewer (GTKWave, Surfer, etc.), pass
`.trace_file` when initializing the model:

```zig
test "debug ALU" {
    var dut = try alu.Model.init(.{ .trace_file = "alu_debug.vcd" });
    defer dut.deinit();

    dut.set(.op, 0);
    dut.set(.a, 0xFF);
    dut.set(.b, 0x01);
    dut.eval();
    // ...
}
```

The VCD file is written to the working directory. Open it with:

```sh
gtkwave alu_debug.vcd
# or
surfer alu_debug.vcd
```

The model must have `.trace = true` in its `build.zig` definition for tracing to
work (most models already do). Tracing adds overhead, so only enable
`.trace_file` when actively debugging — leave it off for normal test runs.

## Testbench inventory

| Testbench | Module | Type | Tests |
|---|---|---|---|
| `tb_alu.zig` | ALU | combinational | 12 groups, 129 vectors |
| `tb_decoder.zig` | instruction decoder | combinational | 8 groups, all 256+256 opcodes |
| `tb_bus.zig` | memory bus | combinational | 20 address space checks |
| `tb_regfile.zig` | register file | clocked | 8 tests (r8, r16, flags, SP/PC) |
| `tb_rom.zig` | ROM | clocked | 4 tests (read, consistency, latency) |
| `tb_single_port_ram.zig` | SRAM | clocked | 5 tests (write, read, overwrite, WE gating) |
| `tb_dual_port_ram.zig` | dual-port RAM | manual clock | 5 tests (cross-port, independent clocks) |
| `tb_cpu.zig` | CPU | clocked | 15 instruction group tests |
| `tb_cpu_bus.zig` | CPU + bus integration | clocked | 1 integration test (WRAM, HRAM, Echo, CALL/RET) |
| `tb_blinky.zig` | blinky | clocked | 4 tests (counter, fast mode, normal mode) |
| `tb_gb_top.zig` | FPGA top | clocked | 1 boot test (LED output) |
