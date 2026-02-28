# Game Boy DMG on Tang Nano 20K

A Game Boy (DMG) implemented in SystemVerilog on the
[Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
(Gowin GW2AR-18 FPGA). Built from first principles using the
[Pan Docs](https://gbdev.io/pandocs/) as the primary reference.

## Status

Work in progress — following a tutorial-driven development approach.

| Component | Status |
|-----------|--------|
| CPU (LR35902) | Registers, ALU, decoder, full instruction execution |
| Memory bus | Address decoder with ROM, WRAM, HRAM, I/O, IE |
| Memory primitives | Single-port RAM, dual-port RAM, ROM |
| PPU | Not started |
| APU | Not started |
| Timer | Not started |
| Joypad | Not started |
| LCD (ST7789) | Not started |
| Cartridge / MBC | Not started |

## Toolchain

Fully open-source:

- **Synthesis:** [Yosys](https://github.com/YosysHQ/yosys)
- **Place & Route:** [nextpnr-himbaechel](https://github.com/YosysHQ/nextpnr) (Gowin backend)
- **Bitstream:** [Apicula](https://github.com/YosysHQ/apicula) (`gowin_pack`)
- **Flash:** [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
- **Simulation:** [Verilator](https://github.com/verilator/verilator)
- **Task runner:** [mise](https://mise.jdx.dev/)

## Quick Start

```bash
# Install dependencies (Arch/CachyOS)
mise run deps

# Run all testbenches
mise run sim

# Build and flash to Tang Nano 20K
mise run flash
```

## Project Structure

```
rtl/
  core/cpu/     CPU — regfile, ALU, decoder, execution engine
  core/bus.sv   Address decoder / memory bus
  memory/       RAM and ROM primitives (BSRAM-inferred)
  platform/     Board-specific (constraints, blinky)
sim/
  tb/           Verilator C++ testbenches
  common/       Testbench helper class
  data/         Test ROM hex files
docs/
  tutorials/    Step-by-step build tutorials (00–23)
```

## Tutorials

The project is developed through a series of tutorials in `docs/tutorials/`:

0. [Toolchain Setup](docs/tutorials/00-toolchain-setup.md)
1. [FPGA Fundamentals](docs/tutorials/01-fpga-fundamentals.md)
2. [Blinky](docs/tutorials/02-blinky.md)
3. [Simulation and Testbenches](docs/tutorials/03-simulation-and-testbenches.md)
4. [Memory Primitives](docs/tutorials/04-memory-primitives.md)
5. [CPU: Registers and ALU](docs/tutorials/05-cpu-registers-and-alu.md)
6. [CPU: Instruction Decoder](docs/tutorials/06-cpu-instruction-decoder.md)
7. [CPU: Instruction Execution](docs/tutorials/07-cpu-execution.md)
8. [Memory Bus](docs/tutorials/08-memory-bus.md)

See [docs/tutorials/TODO.md](docs/tutorials/TODO.md) for the full roadmap.

## Hardware

- **Board:** Tang Nano 20K
- **FPGA:** Gowin GW2AR-18 (20,736 LUT4s, 828K BSRAM, 64Mbit SDRAM)
- **Display:** ST7789 SPI LCD (240×240, on-board)
- **Input:** Pushbuttons on breadboard (8 GPIO)
- **Audio:** PWM on GPIO pin

## License

Apache 2.0
