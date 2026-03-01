const std = @import("std");
const decoder = @import("decoder");
const print = std.debug.print;

// Expected M-cycle counts for all 256 base opcodes (branch taken).
const BASE_MCYCLES_TAKEN = [256]u8{
    //      0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    // 0
    1, 3, 2, 2, 1, 1, 2, 1, 5, 2, 2, 2, 1, 1, 2, 1,
    // 1
    1, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    // 2
    3, 3, 2, 2, 1, 1, 2, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    // 3
    3, 3, 2, 2, 3, 3, 3, 1, 3, 2, 2, 2, 1, 1, 2, 1,
    // 4
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // 5
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // 6
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // 7
    2, 2, 2, 2, 2, 2, 1, 2, 1, 1, 1, 1, 1, 1, 2, 1,
    // 8
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // 9
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // A
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // B
    1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1,
    // C
    5, 3, 4, 4, 6, 4, 2, 4, 5, 4, 4, 1, 6, 6, 2, 4,
    // D
    5, 3, 4, 1, 6, 4, 2, 4, 5, 4, 4, 1, 6, 1, 2, 4,
    // E
    3, 3, 2, 1, 1, 4, 2, 4, 4, 1, 4, 1, 1, 1, 2, 4,
    // F
    3, 3, 2, 1, 1, 4, 2, 4, 3, 2, 4, 1, 1, 1, 2, 4,
};

const CondEntry = struct { opcode: u8, mcycles_not_taken: u8 };
const COND_NOT_TAKEN = [_]CondEntry{
    // JR cond
    .{ .opcode = 0x20, .mcycles_not_taken = 2 },
    .{ .opcode = 0x28, .mcycles_not_taken = 2 },
    .{ .opcode = 0x30, .mcycles_not_taken = 2 },
    .{ .opcode = 0x38, .mcycles_not_taken = 2 },
    // RET cond
    .{ .opcode = 0xC0, .mcycles_not_taken = 2 },
    .{ .opcode = 0xC8, .mcycles_not_taken = 2 },
    .{ .opcode = 0xD0, .mcycles_not_taken = 2 },
    .{ .opcode = 0xD8, .mcycles_not_taken = 2 },
    // JP cond,u16
    .{ .opcode = 0xC2, .mcycles_not_taken = 3 },
    .{ .opcode = 0xCA, .mcycles_not_taken = 3 },
    .{ .opcode = 0xD2, .mcycles_not_taken = 3 },
    .{ .opcode = 0xDA, .mcycles_not_taken = 3 },
    // CALL cond,u16
    .{ .opcode = 0xC4, .mcycles_not_taken = 3 },
    .{ .opcode = 0xCC, .mcycles_not_taken = 3 },
    .{ .opcode = 0xD4, .mcycles_not_taken = 3 },
    .{ .opcode = 0xDC, .mcycles_not_taken = 3 },
};

test "base opcode M-cycles (branch taken)" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    var pass: usize = 0;
    for (0..256) |op| {
        dut.set(.opcode, @as(u8, @truncate(op)));
        dut.set(.cb_prefix, 0);
        dut.set(.cond_met, 1);
        dut.eval();

        const expected: u64 = BASE_MCYCLES_TAKEN[op];
        const got = dut.get(.mcycles);
        if (got != expected) {
            print("  FAIL: opcode 0x{x:0>2}: got {d}, expected {d}\n", .{ op, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/256 passed\n", .{pass});
}

test "conditional opcodes M-cycles (not taken)" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    var pass: usize = 0;
    for (COND_NOT_TAKEN) |entry| {
        dut.set(.opcode, entry.opcode);
        dut.set(.cb_prefix, 0);
        dut.set(.cond_met, 0);
        dut.eval();

        const expected: u64 = entry.mcycles_not_taken;
        const got = dut.get(.mcycles);
        if (got != expected) {
            print("  FAIL: opcode 0x{x:0>2} not-taken: got {d}, expected {d}\n", .{ entry.opcode, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/{d} conditional opcodes passed\n", .{ pass, COND_NOT_TAKEN.len });
}

test "CB opcode M-cycles" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    var pass: usize = 0;
    for (0..256) |op| {
        dut.set(.opcode, @as(u8, @truncate(op)));
        dut.set(.cb_prefix, 1);
        dut.set(.cond_met, 0);
        dut.eval();

        const expected: u64 = if ((op & 0x07) != 0x06)
            1
        else if ((op & 0xC0) == 0x40)
            2
        else
            3;

        const got = dut.get(.mcycles);
        if (got != expected) {
            print("  FAIL: CB 0x{x:0>2}: got {d}, expected {d}\n", .{ op, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/256 CB opcodes passed\n", .{pass});
}

test "ALU op decode (Block 2)" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    // Block 2: opcodes 0x80-0xBF, ALU op = opcode[5:3]
    var pass: usize = 0;
    for (0x80..0xC0) |op| {
        dut.set(.opcode, @as(u8, @truncate(op)));
        dut.set(.cb_prefix, 0);
        dut.set(.cond_met, 0);
        dut.eval();

        const expected: u64 = (op >> 3) & 0x07;
        const got = dut.get(.alu_op);
        if (got != expected) {
            print("  FAIL: opcode 0x{x:0>2}: alu_op got {d}, expected {d}\n", .{ op, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/64 Block 2 ALU ops passed\n", .{pass});
}

test "ALU op decode (Block 3 immediate)" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    const imm_ops = [_]u8{ 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE };
    var pass: usize = 0;
    for (imm_ops) |op| {
        dut.set(.opcode, op);
        dut.set(.cb_prefix, 0);
        dut.set(.cond_met, 0);
        dut.eval();

        const expected: u64 = (op >> 3) & 0x07;
        const got = dut.get(.alu_op);
        if (got != expected) {
            print("  FAIL: opcode 0x{x:0>2}: alu_op got {d}, expected {d}\n", .{ op, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/8 Block 3 immediate ALU ops passed\n", .{pass});
}

test "CB ALU op decode" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    var pass: usize = 0;
    for (0..256) |op| {
        dut.set(.opcode, @as(u8, @truncate(op)));
        dut.set(.cb_prefix, 1);
        dut.set(.cond_met, 0);
        dut.eval();

        const expected: u64 = switch ((op >> 6) & 0x03) {
            0 => 0x08 | ((op >> 3) & 0x07), // 01_xxx
            1 => 0x10, // BIT
            2 => 0x11, // RES
            3 => 0x12, // SET
            else => unreachable,
        };
        const got = dut.get(.alu_op);
        if (got != expected) {
            print("  FAIL: CB 0x{x:0>2}: alu_op got 0x{x:0>2}, expected 0x{x:0>2}\n", .{ op, got, expected });
            return error.TestUnexpectedResult;
        }
        pass += 1;
    }
    print("  {d}/256 CB ALU ops passed\n", .{pass});
}

test "instruction flags" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    // HALT
    dut.set(.opcode, 0x76);
    dut.set(.cb_prefix, 0);
    dut.set(.cond_met, 0);
    dut.eval();
    try std.testing.expect(dut.get(.is_halt) != 0);

    // EI
    dut.set(.opcode, 0xFB);
    dut.eval();
    try std.testing.expect(dut.get(.is_ei) != 0);

    // DI
    dut.set(.opcode, 0xF3);
    dut.eval();
    try std.testing.expect(dut.get(.is_di) != 0);

    // CB prefix
    dut.set(.opcode, 0xCB);
    dut.eval();
    try std.testing.expect(dut.get(.is_cb_prefix) != 0);

    // Non-HALT should not have is_halt
    dut.set(.opcode, 0x00);
    dut.eval();
    try std.testing.expect(dut.get(.is_halt) == 0);
}

test "[HL] indirect detection" {
    var dut = try decoder.Model.init(.{});
    defer dut.deinit();

    // Block 1: LD B,(HL) = 0x46, src=110
    dut.set(.opcode, 0x46);
    dut.set(.cb_prefix, 0);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) != 0);

    // Block 1: LD (HL),B = 0x70, dst=110
    dut.set(.opcode, 0x70);
    dut.set(.cb_prefix, 0);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) != 0);

    // Block 1: LD B,C = 0x41, no (HL)
    dut.set(.opcode, 0x41);
    dut.set(.cb_prefix, 0);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) == 0);

    // Block 2: ADD A,(HL) = 0x86, src=110
    dut.set(.opcode, 0x86);
    dut.set(.cb_prefix, 0);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) != 0);

    // Block 2: ADD A,B = 0x80, no (HL)
    dut.set(.opcode, 0x80);
    dut.set(.cb_prefix, 0);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) == 0);

    // CB: RLC (HL) = CB 0x06
    dut.set(.opcode, 0x06);
    dut.set(.cb_prefix, 1);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) != 0);

    // CB: RLC B = CB 0x00
    dut.set(.opcode, 0x00);
    dut.set(.cb_prefix, 1);
    dut.eval();
    try std.testing.expect(dut.get(.uses_hl_indirect) == 0);
}
