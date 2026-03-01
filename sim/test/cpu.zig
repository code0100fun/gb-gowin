const std = @import("std");
const cpu = @import("cpu");
const print = std.debug.print;

// 64KB memory model
var memory: [65536]u8 = undefined;

fn dumpRegs(dut: *cpu.Model) void {
    print("    PC={x:0>4} SP={x:0>4}\n", .{
        @as(u16, @truncate(dut.get(.dbg_pc))),
        @as(u16, @truncate(dut.get(.dbg_sp))),
    });
    print("    A={x:0>2} F={x:0>2} B={x:0>2} C={x:0>2} D={x:0>2} E={x:0>2} H={x:0>2} L={x:0>2}\n", .{
        @as(u8, @truncate(dut.get(.dbg_a))),
        @as(u8, @truncate(dut.get(.dbg_f))),
        @as(u8, @truncate(dut.get(.dbg_b))),
        @as(u8, @truncate(dut.get(.dbg_c))),
        @as(u8, @truncate(dut.get(.dbg_d))),
        @as(u8, @truncate(dut.get(.dbg_e))),
        @as(u8, @truncate(dut.get(.dbg_h))),
        @as(u8, @truncate(dut.get(.dbg_l))),
    });
}

fn runUntilHalt(dut: *cpu.Model, max_cycles: usize) usize {
    var cycles: usize = 0;
    while (cycles < max_cycles and dut.get(.halted) == 0) : (cycles += 1) {
        // Combinational memory: provide read data for current address
        dut.set(.mem_rdata, memory[@as(u16, @truncate(dut.get(.mem_addr)))]);
        dut.eval();

        // Handle memory writes BEFORE clock edge
        if (dut.get(.mem_wr) != 0) {
            memory[@as(u16, @truncate(dut.get(.mem_addr)))] = @truncate(dut.get(.mem_wdata));
        }

        // Clock edge
        dut.tick();

        // After clock: update read data for the new combinational state
        dut.set(.mem_rdata, memory[@as(u16, @truncate(dut.get(.mem_addr)))]);
        dut.eval();
    }
    return cycles;
}

fn resetCpu(dut: *cpu.Model) void {
    @memset(&memory, 0);
    dut.set(.reset, 1);
    dut.set(.mem_rdata, 0);
    dut.tick();
    dut.set(.reset, 0);
    dut.set(.mem_rdata, memory[@as(u16, @truncate(dut.get(.mem_addr)))]);
    dut.eval();
}

fn loadProg(prog: []const u8) void {
    @memcpy(memory[0..prog.len], prog);
}

test "basic loads and ALU" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD A,0x01; LD B,0x02; ADD A,B; LD C,A; SUB A,C; HALT
    loadProg(&.{ 0x3E, 0x01, 0x06, 0x02, 0x80, 0x4F, 0x91, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u64, 0x02), dut.get(.dbg_b));
    try std.testing.expectEqual(@as(u64, 0x03), dut.get(.dbg_c));
    // Z flag set, N flag set after SUB
    try std.testing.expect(dut.get(.dbg_f) & 0x80 != 0); // Z
    try std.testing.expect(dut.get(.dbg_f) & 0x40 != 0); // N
}

test "memory access through HL" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD H,0xC0; LD L,0x00; LD A,0x42; LD (HL),A; LD B,(HL); INC (HL); HALT
    loadProg(&.{ 0x26, 0xC0, 0x2E, 0x00, 0x3E, 0x42, 0x77, 0x46, 0x34, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xC000]={x:0>2}\n", .{memory[0xC000]});

    try std.testing.expectEqual(@as(u64, 0x42), dut.get(.dbg_b));
    try std.testing.expectEqual(@as(u8, 0x43), memory[0xC000]);
    try std.testing.expectEqual(@as(u64, 0xC0), dut.get(.dbg_h));
    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.dbg_l));
}

test "16-bit loads, PUSH/POP" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD DE,0x1234; PUSH DE; POP BC; HALT
    loadProg(&.{ 0x11, 0x34, 0x12, 0xD5, 0xC1, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x12), dut.get(.dbg_d));
    try std.testing.expectEqual(@as(u64, 0x34), dut.get(.dbg_e));
    try std.testing.expectEqual(@as(u64, 0x12), dut.get(.dbg_b));
    try std.testing.expectEqual(@as(u64, 0x34), dut.get(.dbg_c));
    try std.testing.expectEqual(@as(u64, 0xFFFE), dut.get(.dbg_sp));
}

test "jumps and calls" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // 0x0000: LD A,0x00; JP 0x0010
    // 0x0005: LD A,0xFF (skipped)
    // 0x0010: LD A,0x01; CALL 0x0020
    // 0x0015: HALT
    // 0x0020: LD A,0x77; RET
    memory[0x0000] = 0x3E;
    memory[0x0001] = 0x00;
    memory[0x0002] = 0xC3;
    memory[0x0003] = 0x10;
    memory[0x0004] = 0x00;
    memory[0x0005] = 0x3E;
    memory[0x0006] = 0xFF;

    memory[0x0010] = 0x3E;
    memory[0x0011] = 0x01;
    memory[0x0012] = 0xCD;
    memory[0x0013] = 0x20;
    memory[0x0014] = 0x00;
    memory[0x0015] = 0x76;

    memory[0x0020] = 0x3E;
    memory[0x0021] = 0x77;
    memory[0x0022] = 0xC9;

    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x77), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u64, 0x0016), dut.get(.dbg_pc));
    try std.testing.expectEqual(@as(u64, 0xFFFE), dut.get(.dbg_sp));
}

test "CB prefix and conditional JR" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD A,0x42; SWAP A; LD B,0x00; INC B; JR NZ,+2; LD A,0xFF; HALT
    loadProg(&.{ 0x3E, 0x42, 0xCB, 0x37, 0x06, 0x00, 0x04, 0x20, 0x02, 0x3E, 0xFF, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x24), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u64, 0x01), dut.get(.dbg_b));
}

test "HL increment/decrement loads" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD HL,0xC000; LD A,0xAA; LD (HL+),A; LD A,0xBB; LD (HL-),A;
    // LD A,(HL+); LD B,A; LD A,(HL-); HALT
    loadProg(&.{ 0x21, 0x00, 0xC0, 0x3E, 0xAA, 0x22, 0x3E, 0xBB, 0x32, 0x2A, 0x47, 0x3A, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xC000]={x:0>2} [0xC001]={x:0>2}\n", .{ memory[0xC000], memory[0xC001] });

    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.dbg_b));
    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.dbg_a));
    const hl = (dut.get(.dbg_h) << 8) | dut.get(.dbg_l);
    try std.testing.expectEqual(@as(u64, 0xC000), hl);
}

test "16-bit INC/DEC" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD BC,0x00FF; INC BC; LD DE,0x0100; DEC DE; HALT
    loadProg(&.{ 0x01, 0xFF, 0x00, 0x03, 0x11, 0x00, 0x01, 0x1B, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    const bc = (dut.get(.dbg_b) << 8) | dut.get(.dbg_c);
    const de = (dut.get(.dbg_d) << 8) | dut.get(.dbg_e);
    print("    BC={x:0>4} DE={x:0>4}\n", .{ @as(u16, @truncate(bc)), @as(u16, @truncate(de)) });
    try std.testing.expectEqual(@as(u64, 0x0100), bc);
    try std.testing.expectEqual(@as(u64, 0x00FF), de);
}

test "RST instruction" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // 0x0000: LD A,0x42; RST 0x08; HALT
    // 0x0008: LD A,0x99; RET
    memory[0x0000] = 0x3E;
    memory[0x0001] = 0x42;
    memory[0x0002] = 0xCF; // RST 0x08
    memory[0x0003] = 0x76;

    memory[0x0008] = 0x3E;
    memory[0x0009] = 0x99;
    memory[0x000A] = 0xC9;

    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x99), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u64, 0x0004), dut.get(.dbg_pc));
}

test "LDH instructions" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD A,0x55; LDH (0x80),A; LD A,0x00; LDH A,(0x80); HALT
    loadProg(&.{ 0x3E, 0x55, 0xE0, 0x80, 0x3E, 0x00, 0xF0, 0x80, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xFF80]={x:0>2}\n", .{memory[0xFF80]});

    try std.testing.expectEqual(@as(u64, 0x55), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u8, 0x55), memory[0xFF80]);
}

test "ADD HL, r16" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD HL,0x1000; LD BC,0x0234; ADD HL,BC; HALT
    loadProg(&.{ 0x21, 0x00, 0x10, 0x01, 0x34, 0x02, 0x09, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    const hl = (dut.get(.dbg_h) << 8) | dut.get(.dbg_l);
    print("    HL={x:0>4}\n", .{@as(u16, @truncate(hl))});
    try std.testing.expectEqual(@as(u64, 0x1234), hl);
    // N=0 for ADD HL
    try std.testing.expect(dut.get(.dbg_f) & 0x40 == 0);
}

test "LD (u16),A and LD A,(u16)" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD A,0xAB; LD (0xC100),A; LD A,0x00; LD A,(0xC100); HALT
    loadProg(&.{ 0x3E, 0xAB, 0xEA, 0x00, 0xC1, 0x3E, 0x00, 0xFA, 0x00, 0xC1, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xC100]={x:0>2}\n", .{memory[0xC100]});

    try std.testing.expectEqual(@as(u64, 0xAB), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u8, 0xAB), memory[0xC100]);
}

test "conditional RET" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // 0x0000: CALL 0x0010; HALT
    // 0x0010: LD A,0x01; OR A,A; RET Z; LD B,0xAA; RET
    memory[0x0000] = 0xCD;
    memory[0x0001] = 0x10;
    memory[0x0002] = 0x00;
    memory[0x0003] = 0x76;

    memory[0x0010] = 0x3E;
    memory[0x0011] = 0x01;
    memory[0x0012] = 0xB7;
    memory[0x0013] = 0xC8; // RET Z
    memory[0x0014] = 0x06;
    memory[0x0015] = 0xAA;
    memory[0x0016] = 0xC9;

    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.dbg_b));
    try std.testing.expectEqual(@as(u64, 0x01), dut.get(.dbg_a));
}

test "CB BIT/SET/RES" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD A,0x00; SET 3,A; BIT 3,A; RES 3,A; BIT 3,A; HALT
    loadProg(&.{ 0x3E, 0x00, 0xCB, 0xDF, 0xCB, 0x5F, 0xCB, 0x9F, 0xCB, 0x5F, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expectEqual(@as(u64, 0x00), dut.get(.dbg_a));
    // After last BIT 3,A: Z=1 (bit is clear)
    try std.testing.expect(dut.get(.dbg_f) & 0x80 != 0);
}

test "DEC (HL)" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD HL,0xC000; LD A,0x01; LD (HL),A; DEC (HL); HALT
    loadProg(&.{ 0x21, 0x00, 0xC0, 0x3E, 0x01, 0x77, 0x35, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xC000]={x:0>2}\n", .{memory[0xC000]});

    try std.testing.expectEqual(@as(u8, 0x00), memory[0xC000]);
    // Z flag should be set
    try std.testing.expect(dut.get(.dbg_f) & 0x80 != 0);
}

test "LD (HL), u8" {
    var dut = try cpu.Model.init(.{});
    defer dut.deinit();
    resetCpu(&dut);

    // LD HL,0xC000; LD (HL),0x5A; LD A,(HL); HALT
    loadProg(&.{ 0x21, 0x00, 0xC0, 0x36, 0x5A, 0x7E, 0x76 });
    const cycles = runUntilHalt(&dut, 1000);
    print("  {d} cycles\n", .{cycles});
    dumpRegs(&dut);
    print("    [0xC000]={x:0>2}\n", .{memory[0xC000]});

    try std.testing.expectEqual(@as(u64, 0x5A), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u8, 0x5A), memory[0xC000]);
}
