const std = @import("std");
const cpu_bus = @import("cpu_bus_top");
const print = std.debug.print;

fn runUntilHalt(dut: *cpu_bus.Model, max_cycles: usize) usize {
    var cycles: usize = 0;
    while (cycles < max_cycles and dut.get(.halted) == 0) : (cycles += 1) {
        dut.tick();
    }
    return cycles;
}

fn dumpRegs(dut: *cpu_bus.Model) void {
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

test "CPU+bus integration" {
    var dut = try cpu_bus.Model.init(.{});
    defer dut.deinit();

    // Reset
    dut.set(.reset, 1);
    dut.tick();
    dut.set(.reset, 0);

    const cycles = runUntilHalt(&dut, 2000);
    print("  Program completed in {d} cycles\n", .{cycles});
    dumpRegs(&dut);

    try std.testing.expect(dut.get(.halted) != 0);
    print("    WRAM write+read: B=0x{x:0>2} (expect 0x42)\n", .{@as(u8, @truncate(dut.get(.dbg_b)))});
    try std.testing.expectEqual(@as(u64, 0x42), dut.get(.dbg_b));
    print("    HRAM write+read: C=0x{x:0>2} (expect 0xAB)\n", .{@as(u8, @truncate(dut.get(.dbg_c)))});
    try std.testing.expectEqual(@as(u64, 0xAB), dut.get(.dbg_c));
    print("    Echo RAM read:   D=0x{x:0>2} (expect 0x33)\n", .{@as(u8, @truncate(dut.get(.dbg_d)))});
    try std.testing.expectEqual(@as(u64, 0x33), dut.get(.dbg_d));
    print("    CALL/RET stack:  E=0x{x:0>2} (expect 0x77)\n", .{@as(u8, @truncate(dut.get(.dbg_e)))});
    try std.testing.expectEqual(@as(u64, 0x77), dut.get(.dbg_e));
    print("    Subroutine ret:  A=0x{x:0>2} (expect 0x77)\n", .{@as(u8, @truncate(dut.get(.dbg_a)))});
    try std.testing.expectEqual(@as(u64, 0x77), dut.get(.dbg_a));
}
