# Tutorial Roadmap

Completed tutorials are marked with checkmarks. Remaining tutorials have brief
descriptions of scope and goals.

## Foundations (00–04)

- [x] **00 — Toolchain Setup**: Install Yosys, nextpnr-himbaechel, Apicula,
  openFPGAloader, and Verilator on Arch/CachyOS. Configure mise.toml task
  runner.
- [x] **01 — FPGA Fundamentals**: Combinational vs sequential logic, LUTs,
  flip-flops, clock domains. Mental model for how HDL maps to hardware.
- [x] **02 — Blinky**: First design on the Tang Nano 20K. Clock divider,
  constraints file, full synth→PnR→pack→flash flow.
- [x] **03 — Simulation and Testbenches**: Verilator + zig-verilator testbenches
  in Zig, VCD waveform output, `zig build test` integration, mise task runner.
- [x] **04 — Memory Primitives**: Single-port RAM, dual-port RAM, and ROM
  modules. BRAM inference on Gowin. Hex file initialization.

## CPU (05–10)

- [x] **05 — CPU: Registers and ALU**: Register file (A/F/B/C/D/E/H/L/SP/PC)
  with r8, r16, and r16stk read/write ports. Combinational ALU with all 8-bit
  arithmetic/logic ops, shifts, rotates, bit ops, and misc (DAA/CPL/SCF/CCF).
- [x] **06 — CPU: Instruction Decoder**: Combinational decoder mapping every
  opcode to control signals, ALU operation, and M-cycle count. CB prefix
  support. Exhaustive cycle-count verification against the full opcode table.
- [x] **07 — CPU: Instruction Execution**: Integrate regfile, ALU, and decoder
  into a complete CPU with M-cycle state machine. Fetch/decode/execute loop,
  CB prefix handling, conditional branches. 15 test programs covering all
  instruction groups.
- [x] **08 — Memory Bus**: Address decoder that maps the CPU's memory port onto
  the Game Boy address space: 0000–7FFF ROM, C000–DFFF WRAM, FF80–FFFE HRAM,
  FF00–FF7F I/O stubs. Active-device select lines, active-device read mux.
  Test with the CPU executing from ROM into RAM.
- [x] **09 — Boot ROM and First Hardware Run**: Embed a small test program in
  BRAM as the boot ROM. Wire CPU → bus → ROM → WRAM on the actual FPGA.
  Verify execution by toggling an LED or writing a known pattern to memory.
  First time real hardware runs real instructions.
- [x] **10 — Interrupts**: Interrupt controller with IF and IE registers at
  FF0F/FFFF. Interrupt dispatch (vector lookup, push PC, jump). HALT wake-up
  on pending interrupt. EI/DI/RETI integration with the existing CPU IME
  logic. Five interrupt sources (VBlank, STAT, Timer, Serial, Joypad) wired
  as active-high request lines.

## Peripherals (11–19)

- [x] **11 — Timer**: DIV register (FF04) free-running at 16384 Hz. TIMA/TMA/TAC
  (FF05–FF07) programmable timer with four selectable frequencies. Timer
  overflow fires the Timer interrupt. First peripheral to exercise the
  interrupt system end-to-end.
- [x] **12 — ST7789 LCD Driver**: SPI controller for the Tang Nano 20K's
  on-board 240×240 ST7789 display. Initialization sequence, pixel streaming
  from a framebuffer, 160×144 centered with border. Directly driven from a
  simple test pattern before the PPU exists.
- [x] **13 — PPU: Background and Window**: Pixel FIFO for background tile
  rendering. VRAM (8000–9FFF), tile data/map addressing, SCX/SCY scrolling.
  Window layer (WX/WY). LCDC register for master enable/tile select. Output
  to the ST7789 framebuffer.
- [x] **14 — BSRAM Memory**: Migrate VRAM and WRAM from distributed RAM to
  BSRAM for FPGA resource efficiency. CPU wait states for synchronous read
  latency, PPU tile-fetch pipeline FSM, ST7789 pixel_ready handshake.
- [x] **15 — PPU: Sprites**: OAM (FE00–FE9F) with 40 sprite entries. Sprite
  priority, 10-per-line limit, 8×8 and 8×16 modes. OBP0/OBP1 palettes.
  Per-scanline sprite scan, tile pre-fetch, and combinational pixel mixing.
- [x] **16 — PPU: Timing and STAT**: Accurate mode transitions (OAM scan →
  pixel transfer → HBlank → VBlank). LY/LYC comparison, STAT interrupt
  sources. Correct cycle timing so real games don't glitch.
- [x] **17 — Joypad Input**: 8 pushbuttons on breadboard GPIO mapped to the
  JOYP register (FF00). Column/row multiplexing matching the original Game
  Boy matrix. Debouncing. Joypad interrupt on button press.
- [x] **18 — Debug UART Console**: UART TX/RX modules connected to the Tang
  Nano 20K's BL616 USB bridge (pins 69/70). Command-driven debug console
  that dumps CPU registers and interrupt state to a terminal. Commands:
  `?` (help), `p` (PC), `r` (full register dump).
- [x] **19 — Serial Port**: Minimal serial (link cable) implementation. SB/SC
  registers (FF01–FF02). Internal clock mode for single-player games that
  check serial. Serial interrupt.

## Cartridge and External Memory (20–22)

- [x] **20 — MBC1 Mapper**: Bank switching for ROM (up to 2 MB) and optional
  RAM (up to 32 KB). Register writes at 0000–7FFF to control bank select.
  Mode 0 (ROM banking) and Mode 1 (RAM banking). Enough to run most classic
  titles.
- [ ] **21 — SD Card ROM Loading**: SPI SD card reader. FAT32 file listing on
  the ST7789 display with joypad selection. Load a .gb ROM from SD into
  SDRAM. Replace the BRAM boot ROM with a proper boot menu.
- [ ] **22 — SDRAM Controller**: Interface to the Tang Nano 20K's on-board
  HY57V641620F 64Mbit SDRAM. Initialization sequence, read/write burst
  timing, refresh. Map cartridge ROM and external RAM through SDRAM for
  games larger than BRAM allows.

## Audio (23)

- [ ] **23 — Audio (Channels 1–4)**: Square wave channels 1–2 (with sweep on
  ch1), wave channel 3 (custom waveform), noise channel 4 (LFSR). NR1x–NR5x
  registers. Channel mixing into a single output. PWM DAC on a GPIO pin.

## System Integration (24–25)

- [ ] **24 — DMA and System Polish**: OAM DMA (FF46) transferring 160 bytes in
  160 M-cycles with bus conflict handling. Remaining I/O register stubs.
  Edge cases and accuracy fixes found during game testing.
- [ ] **25 — Running Real Games**: End-to-end testing with Tetris, Dr. Mario,
  and other DMG titles. Debugging workflow for when games break. Performance
  profiling and FPGA resource usage. Where to go next (GBC, link cable,
  save states).
