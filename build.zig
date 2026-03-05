const std = @import("std");
const verilator = @import("zig_verilator");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all Verilator testbenches");

    // ---- Combinational models (no clock) ----

    const alu_mod = verilator.addModel(b, .{
        .name = "alu",
        .sources = &.{"rtl/core/cpu/alu.sv"},
        .target = target,
        .optimize = optimize,
        .clock = null,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const decoder_mod = verilator.addModel(b, .{
        .name = "decoder",
        .sources = &.{"rtl/core/cpu/decoder.sv"},
        .target = target,
        .optimize = optimize,
        .clock = null,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const bus_mod = verilator.addModel(b, .{
        .name = "bus",
        .sources = &.{"rtl/core/bus.sv"},
        .target = target,
        .optimize = optimize,
        .clock = null,
        .trace = true,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    // ---- Clocked models ----

    const blinky_mod = verilator.addModel(b, .{
        .name = "blinky",
        .sources = &.{"rtl/platform/blinky.sv"},
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const single_port_ram_mod = verilator.addModel(b, .{
        .name = "single_port_ram",
        .sources = &.{"rtl/memory/single_port_ram.sv"},
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const dual_port_ram_mod = verilator.addModel(b, .{
        .name = "dual_port_ram",
        .sources = &.{"rtl/memory/dual_port_ram.sv"},
        .target = target,
        .optimize = optimize,
        .trace = true,
        .clock = null, // dual clock — manual tick
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const rom_mod = verilator.addModel(b, .{
        .name = "rom",
        .sources = &.{"rtl/memory/rom.sv"},
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-GADDR_WIDTH=8",
            "-GDATA_WIDTH=8",
            "-GINIT_FILE=\"sim/data/test_rom.hex\"",
        },
    });

    const regfile_mod = verilator.addModel(b, .{
        .name = "regfile",
        .sources = &.{"rtl/core/cpu/regfile.sv"},
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL" },
    });

    const cpu_mod = verilator.addModel(b, .{
        .name = "cpu",
        .sources = &.{
            "rtl/core/cpu/cpu.sv",
            "rtl/core/cpu/regfile.sv",
            "rtl/core/cpu/alu.sv",
            "rtl/core/cpu/decoder.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{ "-Wall", "-Wno-UNUSEDSIGNAL", "-Wno-CASEOVERLAP" },
    });

    const cpu_bus_mod = verilator.addModel(b, .{
        .name = "cpu_bus_top",
        .sources = &.{
            "sim/top/cpu_bus_top.sv",
            "rtl/core/bus.sv",
            "rtl/core/cpu/cpu.sv",
            "rtl/core/cpu/regfile.sv",
            "rtl/core/cpu/alu.sv",
            "rtl/core/cpu/decoder.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-CASEOVERLAP",
            "-Wno-UNOPTFLAT",
            "-Wno-PINCONNECTEMPTY",
            "-GROM_SIZE=64",
            "-GROM_FILE=\"sim/data/cpu_bus_test.hex\"",
        },
    });

    const int_bus_mod = verilator.addModel(b, .{
        .name = "int_bus_top",
        .top_module = "cpu_bus_top",
        .sources = &.{
            "sim/top/cpu_bus_top.sv",
            "rtl/core/bus.sv",
            "rtl/core/cpu/cpu.sv",
            "rtl/core/cpu/regfile.sv",
            "rtl/core/cpu/alu.sv",
            "rtl/core/cpu/decoder.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-CASEOVERLAP",
            "-Wno-UNOPTFLAT",
            "-Wno-PINCONNECTEMPTY",
            "--prefix",
            "Vint_bus_top",
            "-GROM_SIZE=128",
            "-GROM_FILE=\"sim/data/int_test.hex\"",
        },
    });

    const timer_mod = verilator.addModel(b, .{
        .name = "timer_top",
        .sources = &.{
            "sim/top/timer_top.sv",
            "rtl/io/timer.sv",
            "rtl/core/bus.sv",
            "rtl/core/cpu/cpu.sv",
            "rtl/core/cpu/regfile.sv",
            "rtl/core/cpu/alu.sv",
            "rtl/core/cpu/decoder.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-CASEOVERLAP",
            "-Wno-UNOPTFLAT",
            "-Wno-PINCONNECTEMPTY",
            "-GROM_SIZE=256",
            "-GROM_FILE=\"sim/data/timer_test.hex\"",
        },
    });

    const st7789_mod = verilator.addModel(b, .{
        .name = "st7789_top",
        .sources = &.{
            "sim/top/st7789_top.sv",
            "rtl/lcd/st7789.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
        },
    });

    const ppu_mod = verilator.addModel(b, .{
        .name = "ppu_top",
        .sources = &.{
            "sim/top/ppu_top.sv",
            "rtl/ppu/ppu.sv",
            "rtl/memory/dual_port_ram.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
        },
    });

    const joypad_mod = verilator.addModel(b, .{
        .name = "joypad_top",
        .sources = &.{
            "sim/top/joypad_top.sv",
            "rtl/io/joypad.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-PINCONNECTEMPTY",
        },
    });

    const uart_mod = verilator.addModel(b, .{
        .name = "uart_top",
        .sources = &.{
            "sim/top/uart_top.sv",
            "rtl/io/uart_tx.sv",
            "rtl/io/uart_rx.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
        },
    });

    const serial_mod = verilator.addModel(b, .{
        .name = "serial_top",
        .sources = &.{
            "sim/top/serial_top.sv",
            "rtl/io/serial.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-PINCONNECTEMPTY",
        },
    });

    const debug_console_mod = verilator.addModel(b, .{
        .name = "debug_console_top",
        .sources = &.{
            "sim/top/debug_console_top.sv",
            "rtl/io/debug_console.sv",
            "rtl/io/uart_tx.sv",
            "rtl/io/uart_rx.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
        },
    });

    const sd_spi_mod = verilator.addModel(b, .{
        .name = "sd_spi_top",
        .sources = &.{
            "sim/top/sd_spi_top.sv",
            "rtl/cart/sd_spi.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
        },
    });

    const sd_reader_mod = verilator.addModel(b, .{
        .name = "sd_reader_top",
        .sources = &.{
            "sim/top/sd_reader_top.sv",
            "sim/model/sd_card_model.sv",
            "rtl/cart/sd_reader.sv",
            "rtl/cart/sd_spi.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-INITIALDLY",
        },
    });

    const sd_boot_mod = verilator.addModel(b, .{
        .name = "sd_boot_top",
        .sources = &.{
            "sim/top/sd_boot_top.sv",
            "sim/model/sd_card_model.sv",
            "rtl/cart/sd_boot.sv",
            "rtl/cart/sd_reader.sv",
            "rtl/cart/sd_spi.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-UNUSEDPARAM",
            "-Wno-INITIALDLY",
            "-Wno-PINCONNECTEMPTY",
        },
    });

    const mbc1_mod = verilator.addModel(b, .{
        .name = "mbc1_top",
        .sources = &.{
            "sim/top/mbc1_top.sv",
            "rtl/cart/mbc1.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-PINCONNECTEMPTY",
        },
    });

    const sdram_ctrl_mod = verilator.addModel(b, .{
        .name = "sdram_ctrl_top",
        .sources = &.{
            "sim/top/sdram_ctrl_top.sv",
            "rtl/memory/sdram_ctrl.sv",
            "sim/model/sdram_model.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-INITIALDLY",
        },
    });

    const gb_top_mod = verilator.addModel(b, .{
        .name = "gb_top",
        .sources = &.{
            "rtl/platform/gb_top.sv",
            "rtl/ppu/ppu.sv",
            "rtl/memory/dual_port_ram.sv",
            "rtl/memory/single_port_ram.sv",
            "rtl/lcd/st7789.sv",
            "rtl/io/timer.sv",
            "rtl/io/joypad.sv",
            "rtl/io/uart_tx.sv",
            "rtl/io/uart_rx.sv",
            "rtl/io/debug_console.sv",
            "rtl/io/serial.sv",
            "rtl/cart/mbc1.sv",
            "rtl/cart/sd_spi.sv",
            "rtl/cart/sd_reader.sv",
            "rtl/cart/sd_boot.sv",
            "rtl/core/bus.sv",
            "rtl/core/cpu/cpu.sv",
            "rtl/core/cpu/regfile.sv",
            "rtl/core/cpu/alu.sv",
            "rtl/core/cpu/decoder.sv",
        },
        .target = target,
        .optimize = optimize,
        .trace = true,
        .verilator_flags = &.{
            "-Wall",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-CASEOVERLAP",
            "-Wno-UNOPTFLAT",
            "-Wno-PINCONNECTEMPTY",
            "-GROM_SIZE=64",
            "-GROM_FILE=\"sim/data/boot_test.hex\"",
            "-GPPU_PRESCALE=1",
        },
    });

    // ---- Test definitions ----

    const Test = struct { []const u8, []const u8, *std.Build.Module, []const u8 };
    const tests: []const Test = &.{
        .{ "sim/test/alu.zig", "alu", alu_mod, "test:alu" },
        .{ "sim/test/decoder.zig", "decoder", decoder_mod, "test:decoder" },
        .{ "sim/test/bus.zig", "bus", bus_mod, "test:bus" },
        .{ "sim/test/blinky.zig", "blinky", blinky_mod, "test:blinky" },
        .{ "sim/test/single_port_ram.zig", "single_port_ram", single_port_ram_mod, "test:single_port_ram" },
        .{ "sim/test/dual_port_ram.zig", "dual_port_ram", dual_port_ram_mod, "test:dual_port_ram" },
        .{ "sim/test/rom.zig", "rom", rom_mod, "test:rom" },
        .{ "sim/test/regfile.zig", "regfile", regfile_mod, "test:regfile" },
        .{ "sim/test/cpu.zig", "cpu", cpu_mod, "test:cpu" },
        .{ "sim/test/cpu_bus.zig", "cpu_bus_top", cpu_bus_mod, "test:cpu_bus" },
        .{ "sim/test/interrupts.zig", "int_bus_top", int_bus_mod, "test:interrupts" },
        .{ "sim/test/timer.zig", "timer_top", timer_mod, "test:timer" },
        .{ "sim/test/st7789.zig", "st7789_top", st7789_mod, "test:st7789" },
        .{ "sim/test/joypad.zig", "joypad_top", joypad_mod, "test:joypad" },
        .{ "sim/test/ppu.zig", "ppu_top", ppu_mod, "test:ppu" },
        .{ "sim/test/uart.zig", "uart_top", uart_mod, "test:uart" },
        .{ "sim/test/debug_console.zig", "debug_console_top", debug_console_mod, "test:debug_console" },
        .{ "sim/test/serial.zig", "serial_top", serial_mod, "test:serial" },
        .{ "sim/test/mbc1.zig", "mbc1_top", mbc1_mod, "test:mbc1" },
        .{ "sim/test/sd_spi.zig", "sd_spi_top", sd_spi_mod, "test:sd_spi" },
        .{ "sim/test/sd_reader.zig", "sd_reader_top", sd_reader_mod, "test:sd_reader" },
        .{ "sim/test/sd_boot.zig", "sd_boot_top", sd_boot_mod, "test:sd_boot" },
        .{ "sim/test/sdram_ctrl.zig", "sdram_ctrl_top", sdram_ctrl_mod, "test:sdram_ctrl" },
        .{ "sim/test/gb_top.zig", "gb_top", gb_top_mod, "test:gb_top" },
    };

    for (tests) |t| {
        const src_path, const import_name, const verilator_mod, const step_name = t;

        const mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport(import_name, verilator_mod);

        const test_compile = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(test_compile);

        // Individual test step
        b.step(step_name, b.fmt("Run {s}", .{step_name})).dependOn(&run.step);
        // Master test step
        test_step.dependOn(&run.step);
    }
}
