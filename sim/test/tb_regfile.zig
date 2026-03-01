const std = @import("std");
const regfile = @import("regfile");
const print = std.debug.print;

fn clearWe(dut: *regfile.Model) void {
    dut.set(.r8_we, 0);
    dut.set(.r16_we, 0);
    dut.set(.r16stk_we, 0);
    dut.set(.flags_we, 0);
    dut.set(.sp_we, 0);
    dut.set(.pc_we, 0);
}

test "8-bit register write/read" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Write a distinct value to each register: B=0x11, C=0x22, ..., A=0x77
    const vals = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x77 };
    for (0..8) |i| {
        if (i == 6) continue; // skip [HL] index
        clearWe(&dut);
        dut.set(.r8_we, 1);
        dut.set(.r8_wsel, @as(u8, @truncate(i)));
        dut.set(.r8_wdata, vals[i]);
        dut.tick();
    }

    // Read them all back (combinational — no tick needed after setting rsel)
    const reg_names = [8][]const u8{ "B", "C", "D", "E", "H", "L", "[HL]", "A" };
    clearWe(&dut);
    for (0..8) |i| {
        dut.set(.r8_rsel, @as(u8, @truncate(i)));
        dut.eval();
        const got = dut.get(.r8_rdata);
        print("    r8[{d}] {s} = 0x{x:0>2}\n", .{ i, reg_names[i], @as(u8, @truncate(got)) });
        if (i == 6) {
            try std.testing.expectEqual(@as(u64, 0xFF), got);
        } else {
            try std.testing.expectEqual(@as(u64, vals[i]), got);
        }
    }
}

test "16-bit pair reads (r16)" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Write B=0x11, C=0x22, D=0x33, E=0x44, H=0x55, L=0x66, A=0x77
    const vals = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x77 };
    for (0..8) |i| {
        if (i == 6) continue;
        clearWe(&dut);
        dut.set(.r8_we, 1);
        dut.set(.r8_wsel, @as(u8, @truncate(i)));
        dut.set(.r8_wdata, vals[i]);
        dut.tick();
    }

    // Set SP to a known value
    clearWe(&dut);
    dut.set(.sp_we, 1);
    dut.set(.sp_wdata, 0xABCD);
    dut.tick();

    const expected_r16 = [4]u64{ 0x1122, 0x3344, 0x5566, 0xABCD };
    const pair_names = [4][]const u8{ "BC", "DE", "HL", "SP" };
    clearWe(&dut);
    for (0..4) |i| {
        dut.set(.r16_rsel, @as(u8, @truncate(i)));
        dut.eval();
        const got = dut.get(.r16_rdata);
        print("    r16[{d}] {s} = 0x{x:0>4}\n", .{ i, pair_names[i], @as(u16, @truncate(got)) });
        try std.testing.expectEqual(expected_r16[i], got);
    }
}

test "16-bit pair write (r16)" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Write BC via r16
    clearWe(&dut);
    dut.set(.r16_we, 1);
    dut.set(.r16_wsel, 0); // BC
    dut.set(.r16_wdata, 0xBEEF);
    dut.tick();

    // Verify BC
    clearWe(&dut);
    dut.set(.r16_rsel, 0);
    dut.eval();
    print("    BC = 0x{x:0>4}\n", .{@as(u16, @truncate(dut.get(.r16_rdata)))});
    try std.testing.expectEqual(@as(u64, 0xBEEF), dut.get(.r16_rdata));

    // Verify B and C individually
    dut.set(.r8_rsel, 0); // B
    dut.eval();
    print("    B = 0x{x:0>2}, C = ", .{@as(u8, @truncate(dut.get(.r8_rdata)))});
    try std.testing.expectEqual(@as(u64, 0xBE), dut.get(.r8_rdata));

    dut.set(.r8_rsel, 1); // C
    dut.eval();
    print("0x{x:0>2}\n", .{@as(u8, @truncate(dut.get(.r8_rdata)))});
    try std.testing.expectEqual(@as(u64, 0xEF), dut.get(.r8_rdata));
}

test "stack pair read/write (r16stk)" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Write A=0x77
    clearWe(&dut);
    dut.set(.r8_we, 1);
    dut.set(.r8_wsel, 7); // A
    dut.set(.r8_wdata, 0x77);
    dut.tick();

    // Write flags
    clearWe(&dut);
    dut.set(.flags_we, 1);
    dut.set(.flags_wdata, 0b1010); // Z=1, N=0, H=1, C=0 → F=0xA0
    dut.tick();

    // Read AF via r16stk
    clearWe(&dut);
    dut.set(.r16stk_rsel, 3); // AF
    dut.eval();
    print("    AF = 0x{x:0>4} (expect 0x77A0)\n", .{@as(u16, @truncate(dut.get(.r16stk_rdata)))});
    try std.testing.expectEqual(@as(u64, 0x77A0), dut.get(.r16stk_rdata));

    // Write AF via r16stk — low nibble of F should be masked
    clearWe(&dut);
    dut.set(.r16stk_we, 1);
    dut.set(.r16stk_wsel, 3); // AF
    dut.set(.r16stk_wdata, 0x12FF); // A=0x12, F=0xFF → should become 0xF0
    dut.tick();

    clearWe(&dut);
    dut.set(.r16stk_rsel, 3);
    dut.eval();
    print("    POP AF masks F lower nibble: 0x12FF -> 0x{x:0>4}\n", .{@as(u16, @truncate(dut.get(.r16stk_rdata)))});
    try std.testing.expectEqual(@as(u64, 0x12F0), dut.get(.r16stk_rdata));
}

test "flag access" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Set all flags
    clearWe(&dut);
    dut.set(.flags_we, 1);
    dut.set(.flags_wdata, 0b1111);
    dut.tick();

    clearWe(&dut);
    dut.eval();
    print("    flags = 0b{b:0>4} (ZNHC, expect 1111)\n", .{@as(u4, @truncate(dut.get(.flags)))});
    try std.testing.expectEqual(@as(u64, 0b1111), dut.get(.flags));

    // Clear all flags
    dut.set(.flags_we, 1);
    dut.set(.flags_wdata, 0b0000);
    dut.tick();

    clearWe(&dut);
    dut.eval();
    print("    flags = 0b{b:0>4} (expect 0000)\n", .{@as(u4, @truncate(dut.get(.flags)))});
    try std.testing.expectEqual(@as(u64, 0b0000), dut.get(.flags));

    // Set just Z and C
    dut.set(.flags_we, 1);
    dut.set(.flags_wdata, 0b1001);
    dut.tick();

    clearWe(&dut);
    dut.eval();
    print("    flags = 0b{b:0>4} (Z+C, expect 1001)\n", .{@as(u4, @truncate(dut.get(.flags)))});
    try std.testing.expectEqual(@as(u64, 0b1001), dut.get(.flags));
}

test "SP and PC" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    clearWe(&dut);
    dut.set(.sp_we, 1);
    dut.set(.sp_wdata, 0xFFFE);
    dut.set(.pc_we, 1);
    dut.set(.pc_wdata, 0x0100);
    dut.tick();

    clearWe(&dut);
    dut.eval();
    print("    SP = 0x{x:0>4}, PC = 0x{x:0>4}\n", .{
        @as(u16, @truncate(dut.get(.sp))),
        @as(u16, @truncate(dut.get(.pc))),
    });
    try std.testing.expectEqual(@as(u64, 0xFFFE), dut.get(.sp));
    try std.testing.expectEqual(@as(u64, 0x0100), dut.get(.pc));
}

test "direct register outputs" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    const dvals = [8]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11 };
    for (0..8) |i| {
        if (i == 6) continue;
        clearWe(&dut);
        dut.set(.r8_we, 1);
        dut.set(.r8_wsel, @as(u8, @truncate(i)));
        dut.set(.r8_wdata, dvals[i]);
        dut.tick();
    }

    clearWe(&dut);
    dut.eval();
    print("    out: B={x:0>2} C={x:0>2} D={x:0>2} E={x:0>2} H={x:0>2} L={x:0>2} A={x:0>2}\n", .{
        @as(u8, @truncate(dut.get(.out_b))),
        @as(u8, @truncate(dut.get(.out_c))),
        @as(u8, @truncate(dut.get(.out_d))),
        @as(u8, @truncate(dut.get(.out_e))),
        @as(u8, @truncate(dut.get(.out_h))),
        @as(u8, @truncate(dut.get(.out_l))),
        @as(u8, @truncate(dut.get(.out_a))),
    });
    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.out_b));
    try std.testing.expectEqual(@as(u64, 0xBB), dut.get(.out_c));
    try std.testing.expectEqual(@as(u64, 0xCC), dut.get(.out_d));
    try std.testing.expectEqual(@as(u64, 0xDD), dut.get(.out_e));
    try std.testing.expectEqual(@as(u64, 0xEE), dut.get(.out_h));
    try std.testing.expectEqual(@as(u64, 0xFF), dut.get(.out_l));
    try std.testing.expectEqual(@as(u64, 0x11), dut.get(.out_a));
}

test "write priority (r8 vs r16)" {
    var dut = try regfile.Model.init(.{});
    defer dut.deinit();

    clearWe(&dut);
    dut.tick();

    // Write B=0xAA via r8
    clearWe(&dut);
    dut.set(.r8_we, 1);
    dut.set(.r8_wsel, 0); // B
    dut.set(.r8_wdata, 0xAA);
    dut.tick();

    clearWe(&dut);
    dut.set(.r8_rsel, 0);
    dut.eval();
    print("    B after r8 write: 0x{x:0>2} (expect 0xAA)\n", .{@as(u8, @truncate(dut.get(.r8_rdata)))});
    try std.testing.expectEqual(@as(u64, 0xAA), dut.get(.r8_rdata));

    // Now r16 write to BC
    clearWe(&dut);
    dut.set(.r16_we, 1);
    dut.set(.r16_wsel, 0); // BC
    dut.set(.r16_wdata, 0x9988);
    dut.tick();

    clearWe(&dut);
    dut.set(.r8_rsel, 0); // B
    dut.eval();
    print("    B after r16 write BC=0x9988: 0x{x:0>2} (expect 0x99)\n", .{@as(u8, @truncate(dut.get(.r8_rdata)))});
    try std.testing.expectEqual(@as(u64, 0x99), dut.get(.r8_rdata));
}
