const std = @import("std");
const alu = @import("alu");

const TestVec = struct {
    name: []const u8,
    op: u8,
    a: u8,
    b: u8 = 0,
    bit_sel: u8 = 0,
    flags_in: u8 = 0,
    exp_result: u8,
    exp_flags: u8,
};

const F_Z = 1 << 3;
const F_N = 1 << 2;
const F_H = 1 << 1;
const F_C = 1 << 0;

fn runTests(dut: *alu.Model, tests: []const TestVec) !void {
    var pass: usize = 0;
    for (tests) |t| {
        dut.set(.op, t.op);
        dut.set(.a, t.a);
        dut.set(.b, t.b);
        dut.set(.bit_sel, t.bit_sel);
        dut.set(.flags_in, t.flags_in);
        dut.eval();

        const result: u8 = @truncate(dut.get(.result));
        const flags: u8 = @truncate(dut.get(.flags_out));

        if (result != t.exp_result or flags != t.exp_flags) {
            std.debug.print("  FAIL [{s}]: a=0x{x:0>2} b=0x{x:0>2} got result=0x{x:0>2} flags=0b{b:0>4}, expected result=0x{x:0>2} flags=0b{b:0>4}\n", .{ t.name, t.a, t.b, result, @as(u4, @truncate(flags)), t.exp_result, @as(u4, @truncate(t.exp_flags)) });
            return error.TestFailed;
        }
        pass += 1;
    }
    std.debug.print("  {d}/{d} passed\n", .{ pass, tests.len });
}

// ALU operation encoding
const OP_ADD = 0b00_000;
const OP_ADC = 0b00_001;
const OP_SUB = 0b00_010;
const OP_SBC = 0b00_011;
const OP_AND = 0b00_100;
const OP_XOR = 0b00_101;
const OP_OR = 0b00_110;
const OP_CP = 0b00_111;
const OP_RLC = 0b01_000;
const OP_RRC = 0b01_001;
const OP_RL = 0b01_010;
const OP_RR = 0b01_011;
const OP_SLA = 0b01_100;
const OP_SRA = 0b01_101;
const OP_SWAP = 0b01_110;
const OP_SRL = 0b01_111;
const OP_BIT = 0b10_000;
const OP_RES = 0b10_001;
const OP_SET = 0b10_010;
const OP_INC = 0b11_000;
const OP_DEC = 0b11_001;
const OP_DAA = 0b11_010;
const OP_CPL = 0b11_011;
const OP_SCF = 0b11_100;
const OP_CCF = 0b11_101;
const OP_RLCA = 0b11_110;
const OP_RRCA = 0b11_111;

test "ADD" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "0+0", .op = OP_ADD, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "1+1", .op = OP_ADD, .a = 0x01, .b = 0x01, .exp_result = 0x02, .exp_flags = 0 },
        .{ .name = "0xFF+1", .op = OP_ADD, .a = 0xFF, .b = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_H | F_C },
        .{ .name = "0x0F+0x01", .op = OP_ADD, .a = 0x0F, .b = 0x01, .exp_result = 0x10, .exp_flags = F_H },
        .{ .name = "0xF0+0x10", .op = OP_ADD, .a = 0xF0, .b = 0x10, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "0x80+0x80", .op = OP_ADD, .a = 0x80, .b = 0x80, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "0x3A+0xC6", .op = OP_ADD, .a = 0x3A, .b = 0xC6, .exp_result = 0x00, .exp_flags = F_Z | F_H | F_C },
        .{ .name = "0x0E+0x01", .op = OP_ADD, .a = 0x0E, .b = 0x01, .exp_result = 0x0F, .exp_flags = 0 },
        .{ .name = "0x08+0x08", .op = OP_ADD, .a = 0x08, .b = 0x08, .exp_result = 0x10, .exp_flags = F_H },
        .{ .name = "0x50+0x50", .op = OP_ADD, .a = 0x50, .b = 0x50, .exp_result = 0xA0, .exp_flags = 0 },
    });
}

test "ADC" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "0+0+0", .op = OP_ADC, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "0+0+C", .op = OP_ADC, .a = 0x00, .b = 0x00, .flags_in = F_C, .exp_result = 0x01, .exp_flags = 0 },
        .{ .name = "0xFF+0+C", .op = OP_ADC, .a = 0xFF, .b = 0x00, .flags_in = F_C, .exp_result = 0x00, .exp_flags = F_Z | F_H | F_C },
        .{ .name = "0x0F+0+C", .op = OP_ADC, .a = 0x0F, .b = 0x00, .flags_in = F_C, .exp_result = 0x10, .exp_flags = F_H },
        .{ .name = "0x0E+0x01+C", .op = OP_ADC, .a = 0x0E, .b = 0x01, .flags_in = F_C, .exp_result = 0x10, .exp_flags = F_H },
        .{ .name = "0xFF+0xFF+C", .op = OP_ADC, .a = 0xFF, .b = 0xFF, .flags_in = F_C, .exp_result = 0xFF, .exp_flags = F_H | F_C },
        .{ .name = "0x01+0x01+0", .op = OP_ADC, .a = 0x01, .b = 0x01, .exp_result = 0x02, .exp_flags = 0 },
    });
}

test "SUB" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "0-0", .op = OP_SUB, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "1-1", .op = OP_SUB, .a = 0x01, .b = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "0-1", .op = OP_SUB, .a = 0x00, .b = 0x01, .exp_result = 0xFF, .exp_flags = F_N | F_H | F_C },
        .{ .name = "0x10-0x01", .op = OP_SUB, .a = 0x10, .b = 0x01, .exp_result = 0x0F, .exp_flags = F_N | F_H },
        .{ .name = "0x80-0x01", .op = OP_SUB, .a = 0x80, .b = 0x01, .exp_result = 0x7F, .exp_flags = F_N | F_H },
        .{ .name = "0x3E-0x3E", .op = OP_SUB, .a = 0x3E, .b = 0x3E, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "0x3E-0x0F", .op = OP_SUB, .a = 0x3E, .b = 0x0F, .exp_result = 0x2F, .exp_flags = F_N | F_H },
        .{ .name = "0x3E-0x40", .op = OP_SUB, .a = 0x3E, .b = 0x40, .exp_result = 0xFE, .exp_flags = F_N | F_C },
    });
}

test "SBC" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "0-0-0", .op = OP_SBC, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "0-0-C", .op = OP_SBC, .a = 0x00, .b = 0x00, .flags_in = F_C, .exp_result = 0xFF, .exp_flags = F_N | F_H | F_C },
        .{ .name = "1-0-C", .op = OP_SBC, .a = 0x01, .b = 0x00, .flags_in = F_C, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "0x10-0x01-C", .op = OP_SBC, .a = 0x10, .b = 0x01, .flags_in = F_C, .exp_result = 0x0E, .exp_flags = F_N | F_H },
        .{ .name = "0x3B-0x4F-C", .op = OP_SBC, .a = 0x3B, .b = 0x4F, .flags_in = F_C, .exp_result = 0xEB, .exp_flags = F_N | F_H | F_C },
    });
}

test "AND XOR OR" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "AND 0xFF,0xFF", .op = OP_AND, .a = 0xFF, .b = 0xFF, .exp_result = 0xFF, .exp_flags = F_H },
        .{ .name = "AND 0xFF,0x00", .op = OP_AND, .a = 0xFF, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z | F_H },
        .{ .name = "AND 0xF0,0x0F", .op = OP_AND, .a = 0xF0, .b = 0x0F, .exp_result = 0x00, .exp_flags = F_Z | F_H },
        .{ .name = "AND 0xA5,0x5A", .op = OP_AND, .a = 0xA5, .b = 0x5A, .exp_result = 0x00, .exp_flags = F_Z | F_H },
        .{ .name = "AND 0xAA,0xFF", .op = OP_AND, .a = 0xAA, .b = 0xFF, .exp_result = 0xAA, .exp_flags = F_H },
        .{ .name = "XOR 0xFF,0xFF", .op = OP_XOR, .a = 0xFF, .b = 0xFF, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "XOR 0xFF,0x00", .op = OP_XOR, .a = 0xFF, .b = 0x00, .exp_result = 0xFF, .exp_flags = 0 },
        .{ .name = "XOR 0xA5,0x5A", .op = OP_XOR, .a = 0xA5, .b = 0x5A, .exp_result = 0xFF, .exp_flags = 0 },
        .{ .name = "XOR 0x00,0x00", .op = OP_XOR, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "OR 0x00,0x00", .op = OP_OR, .a = 0x00, .b = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "OR 0xF0,0x0F", .op = OP_OR, .a = 0xF0, .b = 0x0F, .exp_result = 0xFF, .exp_flags = 0 },
        .{ .name = "OR 0x00,0xFF", .op = OP_OR, .a = 0x00, .b = 0xFF, .exp_result = 0xFF, .exp_flags = 0 },
        .{ .name = "OR 0xA0,0x05", .op = OP_OR, .a = 0xA0, .b = 0x05, .exp_result = 0xA5, .exp_flags = 0 },
    });
}

test "CP" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "CP 0x3C,0x3C", .op = OP_CP, .a = 0x3C, .b = 0x3C, .exp_result = 0x3C, .exp_flags = F_Z | F_N },
        .{ .name = "CP 0x3C,0x2F", .op = OP_CP, .a = 0x3C, .b = 0x2F, .exp_result = 0x3C, .exp_flags = F_N | F_H },
        .{ .name = "CP 0x3C,0x40", .op = OP_CP, .a = 0x3C, .b = 0x40, .exp_result = 0x3C, .exp_flags = F_N | F_C },
        .{ .name = "CP 0x00,0x01", .op = OP_CP, .a = 0x00, .b = 0x01, .exp_result = 0x00, .exp_flags = F_N | F_H | F_C },
    });
}

test "INC DEC" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "INC 0", .op = OP_INC, .a = 0x00, .exp_result = 0x01, .exp_flags = 0 },
        .{ .name = "INC 0x0F", .op = OP_INC, .a = 0x0F, .exp_result = 0x10, .exp_flags = F_H },
        .{ .name = "INC 0xFF", .op = OP_INC, .a = 0xFF, .exp_result = 0x00, .exp_flags = F_Z | F_H },
        .{ .name = "INC 0 +C", .op = OP_INC, .a = 0x00, .flags_in = F_C, .exp_result = 0x01, .exp_flags = F_C },
        .{ .name = "INC 0xFF +C", .op = OP_INC, .a = 0xFF, .flags_in = F_C, .exp_result = 0x00, .exp_flags = F_Z | F_H | F_C },
        .{ .name = "DEC 1", .op = OP_DEC, .a = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_N },
        .{ .name = "DEC 0x10", .op = OP_DEC, .a = 0x10, .exp_result = 0x0F, .exp_flags = F_N | F_H },
        .{ .name = "DEC 0", .op = OP_DEC, .a = 0x00, .exp_result = 0xFF, .exp_flags = F_N | F_H },
        .{ .name = "DEC 0 +C", .op = OP_DEC, .a = 0x00, .flags_in = F_C, .exp_result = 0xFF, .exp_flags = F_N | F_H | F_C },
        .{ .name = "DEC 0x20", .op = OP_DEC, .a = 0x20, .exp_result = 0x1F, .exp_flags = F_N | F_H },
    });
}

test "CB rotates and shifts" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "RLC 0x80", .op = OP_RLC, .a = 0x80, .exp_result = 0x01, .exp_flags = F_C },
        .{ .name = "RLC 0x01", .op = OP_RLC, .a = 0x01, .exp_result = 0x02, .exp_flags = 0 },
        .{ .name = "RLC 0x00", .op = OP_RLC, .a = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "RLC 0xFF", .op = OP_RLC, .a = 0xFF, .exp_result = 0xFF, .exp_flags = F_C },
        .{ .name = "RLC 0x85", .op = OP_RLC, .a = 0x85, .exp_result = 0x0B, .exp_flags = F_C },
        .{ .name = "RRC 0x01", .op = OP_RRC, .a = 0x01, .exp_result = 0x80, .exp_flags = F_C },
        .{ .name = "RRC 0x80", .op = OP_RRC, .a = 0x80, .exp_result = 0x40, .exp_flags = 0 },
        .{ .name = "RRC 0x00", .op = OP_RRC, .a = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "RRC 0xFF", .op = OP_RRC, .a = 0xFF, .exp_result = 0xFF, .exp_flags = F_C },
        .{ .name = "RL 0x80 C=0", .op = OP_RL, .a = 0x80, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "RL 0x80 C=1", .op = OP_RL, .a = 0x80, .flags_in = F_C, .exp_result = 0x01, .exp_flags = F_C },
        .{ .name = "RL 0x01 C=0", .op = OP_RL, .a = 0x01, .exp_result = 0x02, .exp_flags = 0 },
        .{ .name = "RL 0x00 C=1", .op = OP_RL, .a = 0x00, .flags_in = F_C, .exp_result = 0x01, .exp_flags = 0 },
        .{ .name = "RR 0x01 C=0", .op = OP_RR, .a = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "RR 0x01 C=1", .op = OP_RR, .a = 0x01, .flags_in = F_C, .exp_result = 0x80, .exp_flags = F_C },
        .{ .name = "RR 0x80 C=0", .op = OP_RR, .a = 0x80, .exp_result = 0x40, .exp_flags = 0 },
        .{ .name = "RR 0x00 C=1", .op = OP_RR, .a = 0x00, .flags_in = F_C, .exp_result = 0x80, .exp_flags = 0 },
        .{ .name = "SLA 0x80", .op = OP_SLA, .a = 0x80, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "SLA 0x01", .op = OP_SLA, .a = 0x01, .exp_result = 0x02, .exp_flags = 0 },
        .{ .name = "SLA 0xFF", .op = OP_SLA, .a = 0xFF, .exp_result = 0xFE, .exp_flags = F_C },
        .{ .name = "SRA 0x80", .op = OP_SRA, .a = 0x80, .exp_result = 0xC0, .exp_flags = 0 },
        .{ .name = "SRA 0x01", .op = OP_SRA, .a = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "SRA 0x81", .op = OP_SRA, .a = 0x81, .exp_result = 0xC0, .exp_flags = F_C },
        .{ .name = "SRA 0x7E", .op = OP_SRA, .a = 0x7E, .exp_result = 0x3F, .exp_flags = 0 },
        .{ .name = "SWAP 0xF0", .op = OP_SWAP, .a = 0xF0, .exp_result = 0x0F, .exp_flags = 0 },
        .{ .name = "SWAP 0x12", .op = OP_SWAP, .a = 0x12, .exp_result = 0x21, .exp_flags = 0 },
        .{ .name = "SWAP 0x00", .op = OP_SWAP, .a = 0x00, .exp_result = 0x00, .exp_flags = F_Z },
        .{ .name = "SWAP 0xAB", .op = OP_SWAP, .a = 0xAB, .exp_result = 0xBA, .exp_flags = 0 },
        .{ .name = "SRL 0x80", .op = OP_SRL, .a = 0x80, .exp_result = 0x40, .exp_flags = 0 },
        .{ .name = "SRL 0x01", .op = OP_SRL, .a = 0x01, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "SRL 0xFF", .op = OP_SRL, .a = 0xFF, .exp_result = 0x7F, .exp_flags = F_C },
    });
}

test "BIT RES SET" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "BIT 0,0x01", .op = OP_BIT, .a = 0x01, .bit_sel = 0, .exp_result = 0x01, .exp_flags = F_H },
        .{ .name = "BIT 0,0xFE", .op = OP_BIT, .a = 0xFE, .bit_sel = 0, .exp_result = 0xFE, .exp_flags = F_Z | F_H },
        .{ .name = "BIT 7,0x80", .op = OP_BIT, .a = 0x80, .bit_sel = 7, .exp_result = 0x80, .exp_flags = F_H },
        .{ .name = "BIT 7,0x7F", .op = OP_BIT, .a = 0x7F, .bit_sel = 7, .exp_result = 0x7F, .exp_flags = F_Z | F_H },
        .{ .name = "BIT 3,0x08", .op = OP_BIT, .a = 0x08, .bit_sel = 3, .exp_result = 0x08, .exp_flags = F_H },
        .{ .name = "BIT 3,0xF7", .op = OP_BIT, .a = 0xF7, .bit_sel = 3, .exp_result = 0xF7, .exp_flags = F_Z | F_H },
        .{ .name = "BIT 0,0x01+C", .op = OP_BIT, .a = 0x01, .bit_sel = 0, .flags_in = F_C, .exp_result = 0x01, .exp_flags = F_H | F_C },
        .{ .name = "RES 0,0xFF", .op = OP_RES, .a = 0xFF, .bit_sel = 0, .exp_result = 0xFE, .exp_flags = 0 },
        .{ .name = "RES 7,0xFF", .op = OP_RES, .a = 0xFF, .bit_sel = 7, .exp_result = 0x7F, .exp_flags = 0 },
        .{ .name = "RES 3,0xFF", .op = OP_RES, .a = 0xFF, .bit_sel = 3, .exp_result = 0xF7, .exp_flags = 0 },
        .{ .name = "RES 0,0x00", .op = OP_RES, .a = 0x00, .bit_sel = 0, .exp_result = 0x00, .exp_flags = 0 },
        .{ .name = "RES 4,0xFF+C", .op = OP_RES, .a = 0xFF, .bit_sel = 4, .flags_in = F_C, .exp_result = 0xEF, .exp_flags = F_C },
        .{ .name = "SET 0,0x00", .op = OP_SET, .a = 0x00, .bit_sel = 0, .exp_result = 0x01, .exp_flags = 0 },
        .{ .name = "SET 7,0x00", .op = OP_SET, .a = 0x00, .bit_sel = 7, .exp_result = 0x80, .exp_flags = 0 },
        .{ .name = "SET 3,0x00", .op = OP_SET, .a = 0x00, .bit_sel = 3, .exp_result = 0x08, .exp_flags = 0 },
        .{ .name = "SET 7,0xFF", .op = OP_SET, .a = 0xFF, .bit_sel = 7, .exp_result = 0xFF, .exp_flags = 0 },
        .{ .name = "SET 4,0x00+C", .op = OP_SET, .a = 0x00, .bit_sel = 4, .flags_in = F_C, .exp_result = 0x10, .exp_flags = F_C },
    });
}

test "accumulator rotates" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "RLCA 0x80", .op = OP_RLCA, .a = 0x80, .bit_sel = 0, .exp_result = 0x01, .exp_flags = F_C },
        .{ .name = "RLCA 0x01", .op = OP_RLCA, .a = 0x01, .bit_sel = 0, .exp_result = 0x02, .exp_flags = 0 },
        .{ .name = "RLCA 0x00", .op = OP_RLCA, .a = 0x00, .bit_sel = 0, .exp_result = 0x00, .exp_flags = 0 },
        .{ .name = "RLCA 0x85", .op = OP_RLCA, .a = 0x85, .bit_sel = 0, .exp_result = 0x0B, .exp_flags = F_C },
        .{ .name = "RLA 0x80 C=0", .op = OP_RLCA, .a = 0x80, .bit_sel = 1, .exp_result = 0x00, .exp_flags = F_C },
        .{ .name = "RLA 0x80 C=1", .op = OP_RLCA, .a = 0x80, .bit_sel = 1, .flags_in = F_C, .exp_result = 0x01, .exp_flags = F_C },
        .{ .name = "RLA 0x00 C=1", .op = OP_RLCA, .a = 0x00, .bit_sel = 1, .flags_in = F_C, .exp_result = 0x01, .exp_flags = 0 },
        .{ .name = "RRCA 0x01", .op = OP_RRCA, .a = 0x01, .bit_sel = 0, .exp_result = 0x80, .exp_flags = F_C },
        .{ .name = "RRCA 0x80", .op = OP_RRCA, .a = 0x80, .bit_sel = 0, .exp_result = 0x40, .exp_flags = 0 },
        .{ .name = "RRCA 0x00", .op = OP_RRCA, .a = 0x00, .bit_sel = 0, .exp_result = 0x00, .exp_flags = 0 },
        .{ .name = "RRA 0x01 C=0", .op = OP_RRCA, .a = 0x01, .bit_sel = 1, .exp_result = 0x00, .exp_flags = F_C },
        .{ .name = "RRA 0x01 C=1", .op = OP_RRCA, .a = 0x01, .bit_sel = 1, .flags_in = F_C, .exp_result = 0x80, .exp_flags = F_C },
        .{ .name = "RRA 0x00 C=1", .op = OP_RRCA, .a = 0x00, .bit_sel = 1, .flags_in = F_C, .exp_result = 0x80, .exp_flags = 0 },
    });
}

test "DAA" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "DAA 0x0A N=0", .op = OP_DAA, .a = 0x0A, .exp_result = 0x10, .exp_flags = 0 },
        .{ .name = "DAA 0x12 N=0", .op = OP_DAA, .a = 0x12, .exp_result = 0x12, .exp_flags = 0 },
        .{ .name = "DAA 0x9A N=0", .op = OP_DAA, .a = 0x9A, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "DAA 0x0F N=0 H=1", .op = OP_DAA, .a = 0x0F, .flags_in = F_H, .exp_result = 0x15, .exp_flags = 0 },
        .{ .name = "DAA 0x00 N=0 C=1", .op = OP_DAA, .a = 0x00, .flags_in = F_C, .exp_result = 0x60, .exp_flags = F_C },
        .{ .name = "DAA 0xA0 N=0", .op = OP_DAA, .a = 0xA0, .exp_result = 0x00, .exp_flags = F_Z | F_C },
        .{ .name = "DAA 0x99 N=0", .op = OP_DAA, .a = 0x99, .exp_result = 0x99, .exp_flags = 0 },
        .{ .name = "DAA 0x0F N=1 H=1", .op = OP_DAA, .a = 0x0F, .flags_in = F_N | F_H, .exp_result = 0x09, .exp_flags = F_N },
        .{ .name = "DAA 0x45 N=1", .op = OP_DAA, .a = 0x45, .flags_in = F_N, .exp_result = 0x45, .exp_flags = F_N },
        .{ .name = "DAA 0x00 N=1 C=1", .op = OP_DAA, .a = 0x00, .flags_in = F_N | F_C, .exp_result = 0xA0, .exp_flags = F_N | F_C },
    });
}

test "CPL SCF CCF" {
    var dut = try alu.Model.init(.{});
    defer dut.deinit();
    try runTests(&dut, &.{
        .{ .name = "CPL 0xFF", .op = OP_CPL, .a = 0xFF, .exp_result = 0x00, .exp_flags = F_N | F_H },
        .{ .name = "CPL 0x00", .op = OP_CPL, .a = 0x00, .exp_result = 0xFF, .exp_flags = F_N | F_H },
        .{ .name = "CPL 0xA5", .op = OP_CPL, .a = 0xA5, .exp_result = 0x5A, .exp_flags = F_N | F_H },
        .{ .name = "CPL 0 +Z+C", .op = OP_CPL, .a = 0x00, .flags_in = F_Z | F_C, .exp_result = 0xFF, .exp_flags = F_Z | F_N | F_H | F_C },
        .{ .name = "SCF", .op = OP_SCF, .a = 0x42, .exp_result = 0x42, .exp_flags = F_C },
        .{ .name = "SCF +Z", .op = OP_SCF, .a = 0x42, .flags_in = F_Z, .exp_result = 0x42, .exp_flags = F_Z | F_C },
        .{ .name = "SCF +NH", .op = OP_SCF, .a = 0x42, .flags_in = F_N | F_H, .exp_result = 0x42, .exp_flags = F_C },
        .{ .name = "CCF C=0", .op = OP_CCF, .a = 0x42, .exp_result = 0x42, .exp_flags = F_C },
        .{ .name = "CCF C=1", .op = OP_CCF, .a = 0x42, .flags_in = F_C, .exp_result = 0x42, .exp_flags = 0 },
        .{ .name = "CCF +Z,C=0", .op = OP_CCF, .a = 0x42, .flags_in = F_Z, .exp_result = 0x42, .exp_flags = F_Z | F_C },
        .{ .name = "CCF +ZNH,C=1", .op = OP_CCF, .a = 0x42, .flags_in = F_Z | F_N | F_H | F_C, .exp_result = 0x42, .exp_flags = F_Z },
    });
}
