# Tutorial 00 — Toolchain Setup

In this tutorial we'll install the complete open-source FPGA toolchain for the
Tang Nano 20K and set up our development environment. By the end, you'll have
every tool needed to write SystemVerilog, simulate it, synthesize it, and flash
it to your board.

## What We're Installing

The open-source FPGA flow for Gowin chips looks like this:

```
  SystemVerilog        Yosys           nextpnr-himbaechel   gowin_pack      openFPGAloader
  source files   -->  (synthesis)  -->  (place & route)  -->  (bitstream)  -->  (flash to board)
     .sv              netlist.json      routed.json          bitstream.fs       Tang Nano 20K
```

1. **Yosys** — reads your SystemVerilog, optimizes the logic, and maps it to
   the FPGA's primitives (LUTs, flip-flops, BRAM). This is called *synthesis*.
2. **nextpnr-himbaechel** — takes the synthesized netlist and decides where each
   logic element physically goes on the chip and how to route the wires between
   them. This is *place and route*. (Gowin support lives inside nextpnr's
   "himbaechel" framework — a modular architecture backend.)
3. **Apicula / gowin_pack** — Apicula is the reverse-engineered Gowin FPGA
   database. The `gowin_pack` tool (installed via `pip install apycula`) converts
   the placed-and-routed design into the binary bitstream the FPGA understands.
4. **openFPGAloader** — uploads the bitstream to your Tang Nano 20K over USB.
5. **Verilator** — a fast, open-source simulator that compiles your
   SystemVerilog into C++ for simulation and testing. We'll use it for all our
   testbenches.
6. **Surfer** — a modern waveform viewer for inspecting simulation output
   (VCD/FST/GHW files). Essential for debugging timing issues. Available as a
   [VSCode extension](https://marketplace.visualstudio.com/items?itemName=surfer-project.surfer)
   or as a [standalone app](https://surfer-project.org/).

## Prerequisites

**Required now:**
- A Tang Nano 20K board (with USB-C cable)
- A computer running Linux (this tutorial uses Arch/CachyOS, but the tools are
  available on most distributions)
- An AUR helper like `paru` (for Arch-based distros)
- [mise](https://mise.jdx.dev/) task runner (`curl https://mise.run | sh`)

**Needed for later tutorials:**
- ST7789 SPI LCD display (240x240 or 240x320) — Tutorial 11
- Breadboard + 8 pushbuttons + pull-up resistors — Tutorial 17
- MicroSD card (FAT32 formatted, for loading ROMs) — Tutorial 20
- Jumper wires for connecting LCD, buttons, and SD card to the GPIO header

## Installing the Tools

### Arch Linux / CachyOS

The quickest way is to use the mise tasks we've set up:

```bash
mise run deps
```

This runs three sub-tasks:

1. **`deps:pacman`** — installs Yosys, Verilator, openFPGAloader, and
   build dependencies from the official Arch repos
2. **`deps:pip`** — installs `apycula` (provides the `gowin_pack` command)
3. **`deps:nextpnr`** — clones nextpnr from GitHub and builds it with only the
   Gowin/himbaechel backend

We build nextpnr from source because the AUR packages are unreliable — the
`nextpnr-himbaechel-git` package pulls in unnecessary Xilinx dependencies, and
the old `nextpnr-gowin-git` package no longer builds (the standalone Gowin
architecture was removed upstream).

If you prefer to run each step manually:

```bash
# Official repo packages
sudo pacman -S --needed yosys verilator openfpgaloader \
  cmake boost eigen python

# Apicula — provides gowin_pack for bitstream generation
pip install apycula

# Build nextpnr with only Gowin support
git clone https://github.com/YosysHQ/nextpnr.git
cd nextpnr
cmake -B build -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin
cmake --build build -j$(nproc)
sudo cmake --install build
```

### Other Distributions

<details>
<summary>Ubuntu / Debian</summary>

```bash
# Yosys, Verilator
sudo apt install yosys verilator

# nextpnr with himbaechel Gowin backend — build from source
# See: https://github.com/YosysHQ/nextpnr (build with -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin)

# Apicula (gowin_pack)
pip install apycula

# openFPGAloader — build from source
# See: https://github.com/trabucayre/openFPGALoader
```

</details>

<details>
<summary>Building from source (any distro)</summary>

If packages are unavailable or outdated, you can build everything from source.
The key repositories are:

- Yosys: https://github.com/YosysHQ/yosys
- nextpnr: https://github.com/YosysHQ/nextpnr (build with `-DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin`)
- Apicula: https://github.com/YosysHQ/apicula
- openFPGAloader: https://github.com/trabucayre/openFPGALoader
- Verilator: https://github.com/verilator/verilator

</details>

## Verify the Installation

Run each of these commands and confirm you get version output (not "command not
found"):

```bash
yosys --version
# Expected: Yosys 0.54 or later

nextpnr-himbaechel --version
# Expected: nextpnr-himbaechel -- Next Generation Place and Route (version string)

gowin_pack --help
# Expected: usage: gowin_pack [-h] ...

openFPGALoader --detect
# Expected: Shows your Tang Nano 20K if it's plugged in
# If the board isn't connected yet, just verify the command exists

verilator --version
# Expected: Verilator 5.x

surfer --version  # if using standalone app
# Or install the VSCode extension: surfer-project.surfer
```

### Connecting the Tang Nano 20K

Plug the board into your computer via USB-C. On Linux you may need to add a
udev rule so you can flash without root:

```bash
# Create a udev rule for the FTDI chip on the Tang Nano 20K
sudo tee /etc/udev/rules.d/99-tang-nano.rules << 'EOF'
# Gowin FPGA (Tang Nano 20K via BL616 debugger)
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0666"
# Sipeed BL616 debugger
ATTRS{idVendor}=="359f", ATTRS{idProduct}=="3101", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug and re-plug the board, then verify:

```bash
openFPGALoader --detect
```

You should see output identifying the GW2AR-18 FPGA.

## VSCode Setup

Install these two extensions:

### Lushay Code

- **Extension ID:** `lushay-labs.lushay-code`
- **What it does:** Integrates the entire open-source Gowin FPGA workflow
  (Yosys, nextpnr, Apicula, openFPGAloader) directly into VSCode. You can
  synthesize and flash from the editor. It also provides Verilator-based linting
  for real-time error checking as you type.
- **Install:** Open VSCode, press `Ctrl+Shift+X`, search "Lushay Code", install.

### Surfer Waveform Viewer

- **Extension ID:** `surfer-project.surfer`
- **What it does:** A modern waveform viewer that opens VCD, FST, and GHW files
  directly in VSCode. Use it to debug simulation output without leaving the
  editor. It auto-activates when you open a waveform file.
- **Install:** Search "Surfer" in the extensions marketplace.
- **Standalone:** If you're not using VSCode, download the standalone app from
  https://surfer-project.org/

### Verilog-HDL / SystemVerilog / Bluespec

- **Extension ID:** `mshr-h.VerilogHDL`
- **What it does:** Syntax highlighting, code navigation (go to definition,
  find references), and code completion for SystemVerilog files.
- **Install:** Search "Verilog-HDL" in the extensions marketplace.

After installing both, open the `gb-gowin` project folder in VSCode. The Lushay
Code extension should detect the project structure automatically.

## Project Structure

We've already created the directory structure. Here's what each directory is for:

```
gb-gowin/
├── docs/tutorials/     # These tutorials
├── rtl/                # Synthesizable SystemVerilog source
│   ├── core/           # Game Boy core modules
│   │   ├── cpu/        # LR35902 CPU (ALU, registers, decoder)
│   │   ├── ppu/        # Pixel Processing Unit
│   │   └── apu/        # Audio Processing Unit
│   ├── memory/         # Memory bus, VRAM, WRAM, HRAM
│   ├── cartridge/      # MBC implementations
│   ├── platform/       # Tang Nano 20K specific (top, constraints, PLL)
│   └── lcd/            # ST7789 SPI LCD driver
├── sim/                # Simulation and testing
│   ├── tb/             # Verilator C++ testbenches
│   ├── common/         # Shared test utilities
│   └── roms/           # Test ROMs (not committed — supply your own)
├── scripts/            # Build and utility scripts
└── mise.toml           # Task runner (synth, pnr, pack, flash, sim)
```

## The Task Runner (mise)

We use [mise](https://mise.jdx.dev/) as our task runner. The `mise.toml` in the
project root defines all our build tasks. For now some tasks reference
placeholder source files — we'll fill those in starting with Tutorial 02.

The key targets are:

| Target | What it does |
|--------|-------------|
| `mise run sim` | Run all Verilator testbenches |
| `mise run synth` | Synthesize with Yosys |
| `mise run pnr` | Place and route with nextpnr-himbaechel |
| `mise run pack` | Generate bitstream with Apicula |
| `mise run flash` | Upload bitstream to the board |
| `mise run clean` | Remove build artifacts |
| `mise run build` | synth → pnr → pack |

Take a look at the `mise.toml` in the project root to see how these are wired up.

## The Synthesis Flow in Detail

When you run `mise run build`, here's what happens step by step:

### 1. Synthesis (Yosys)

```bash
yosys -p "read_verilog -sv rtl/platform/top.sv; synth_gowin -top top -json build/synth.json"
```

Yosys reads your SystemVerilog, infers the logic (registers, multiplexers,
memories), and optimizes it into a netlist of Gowin FPGA primitives. The output
is a JSON file describing the netlist.

### 2. Place and Route (nextpnr-himbaechel)

```bash
nextpnr-himbaechel --json build/synth.json --write build/pnr.json \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
  --vopt cst=rtl/platform/constraints.cst
```

nextpnr reads the netlist and the constraint file (which maps your design's I/O
signals to physical pins on the FPGA), then figures out where to place each
logic element and how to route the wires. The `--device` flag specifies the
exact FPGA variant, and `--vopt family=` tells the himbaechel Gowin backend
which chip family to target. The constraint file is passed via `--vopt cst=`.

### 3. Bitstream Generation (Apicula / gowin_pack)

```bash
gowin_pack -d GW2AR-18C -o build/gb.fs build/pnr.json
```

This converts the placed-and-routed design into the binary bitstream format that
the FPGA understands.

### 4. Flash

```bash
openFPGALoader -b tangnano20k build/gb.fs
```

This uploads the bitstream to the Tang Nano 20K over USB. The FPGA starts
running your design immediately.

## What's Next

In [Tutorial 01](01-fpga-fundamentals.md) we'll cover the fundamental concepts
of FPGA design — how hardware description languages differ from software
programming, what happens on a clock edge, and how to think about designing
circuits in SystemVerilog.

Then in [Tutorial 02](02-blinky.md) we'll write our first real design: a
blinking LED, synthesized and running on the Tang Nano 20K.
