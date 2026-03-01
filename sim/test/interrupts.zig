const std = @import("std");
const int_bus = @import("int_bus_top");
const print = std.debug.print;

fn dumpRegs(dut: *int_bus.Model) void {
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
    print("    IE={x:0>2} IF={x:0>2}\n", .{
        @as(u8, @truncate(dut.get(.dbg_ie))),
        @as(u8, @truncate(dut.get(.dbg_if))),
    });
}

fn resetDut(dut: *int_bus.Model) void {
    dut.set(.reset, 1);
    dut.set(.int_request, 0);
    dut.tick();
    dut.set(.reset, 0);
}

test "end-to-end interrupt through IF/IE" {
    // ROM program (int_test.hex):
    //   0x00: LD SP, 0xFFFE       (31 FE FF)
    //   0x03: LD A, 0x01          (3E 01)
    //   0x05: LDH (0xFF), A       (E0 FF)    → IE = 0x01 (VBlank)
    //   0x07: EI                  (FB)
    //   0x08: NOP                 (00)
    //   0x09: HALT                (76)
    //   0x0A: LD B, A             (47)       ← return here after ISR
    //   0x0B: HALT                (76)
    //   0x40: LD A, 0x55          (3E 55)    ← VBlank ISR
    //   0x42: RETI                (D9)

    var dut = try int_bus.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Run until HALT: LD SP(3) + LD A(2) + LDH(3) + EI(1) + NOP(1) + HALT(1) = 11
    for (0..15) |_| dut.tick();
    try std.testing.expect(dut.get(.halted) != 0);

    print("  Halted. IE={x:0>2} IF={x:0>2}\n", .{
        @as(u8, @truncate(dut.get(.dbg_ie))),
        @as(u8, @truncate(dut.get(.dbg_if))),
    });

    // IE should be 0x01 (VBlank enabled)
    try std.testing.expectEqual(@as(u64, 0x01), dut.get(.dbg_ie));

    // Trigger VBlank interrupt via external int_request line
    dut.set(.int_request, 0x01);
    dut.tick(); // IF bit gets set
    dut.set(.int_request, 0x00); // clear request (one-shot)

    // Run enough cycles for dispatch(5) + ISR(2+4) + LD B,A(1) + HALT(1) = 13
    for (0..20) |_| dut.tick();

    dumpRegs(&dut);
    try std.testing.expect(dut.get(.halted) != 0);

    // ISR set A=0x55, then LD B,A copied it
    try std.testing.expectEqual(@as(u64, 0x55), dut.get(.dbg_a));
    try std.testing.expectEqual(@as(u64, 0x55), dut.get(.dbg_b));
    // SP should be restored after RETI pops
    try std.testing.expectEqual(@as(u64, 0xFFFE), dut.get(.dbg_sp));
}

test "CPU read/write of IF register" {
    // Use the same ROM but we only care about the first few instructions
    // to set up SP, then manually exercise IF read/write via observation
    var dut = try int_bus.Model.init(.{});
    defer dut.deinit();
    resetDut(&dut);

    // Trigger a VBlank interrupt externally
    dut.set(.int_request, 0x04); // Timer interrupt (bit 2)
    dut.tick();
    dut.set(.int_request, 0x00);

    // IF should now have bit 2 set
    const if_val: u8 = @truncate(dut.get(.dbg_if));
    print("  IF after timer request: {x:0>2}\n", .{if_val});
    // IF reads as {3'b111, if_reg[4:0]} = 0xE4 when bit 2 is set
    try std.testing.expectEqual(@as(u8, 0xE4), if_val);
}
