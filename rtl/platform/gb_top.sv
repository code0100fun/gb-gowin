// Game Boy FPGA top-level — Tang Nano 20K.
//
// Wires CPU → bus → ROM / WRAM / HRAM with an LED register for
// visible output. VRAM and WRAM use BSRAM (synchronous reads);
// the CPU pauses for one cycle via mem_wait during BSRAM reads.
//
// When USE_SD=1 (synthesis): ROM and External RAM are backed by SDRAM
// (up to 2 MB ROM, 32 KB ExtRAM). sd_boot loads ROM from SD card into
// SDRAM, then CPU reads through the SDRAM controller. SDRAM reads take
// ~5 cycles (vs 1 for BSRAM). VRAM/WRAM stay in BSRAM.
module gb_top #(
    parameter int ROM_SIZE = 256,
    parameter     ROM_FILE = "sim/data/boot_test.hex",
    parameter int USE_SD   = 0     // 0=embedded ROM, 1=SD card boot + SDRAM
) (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset (active low)
    input  logic       btn_s2,     // unused
    output logic [5:0] led,        // onboard LEDs (active low)

    // ST7789 SPI LCD
    output logic       lcd_rst,
    output logic       lcd_cs,
    output logic       lcd_dc,
    output logic       lcd_sclk,
    output logic       lcd_mosi,
    output logic       lcd_bl,

    // SD card (built-in microSD slot, SPI mode)
    output logic       sd_clk,
    output logic       sd_cmd,     // MOSI
    input  logic       sd_dat0,    // MISO
    output logic       sd_dat1,    // unused, active high
    output logic       sd_dat2,    // unused, active high
    output logic       sd_dat3,    // CS (directly from sd_spi cs_n)

    // Joypad buttons (active high — GPIO pulled to 3.3V when pressed)
    input  logic       btn_right,
    input  logic       btn_left,
    input  logic       btn_up,
    input  logic       btn_down,
    input  logic       btn_a,
    input  logic       btn_b,
    input  logic       btn_select,
    input  logic       btn_start,

    // UART debug console (BL616 USB bridge, pins 69/70)
    output logic       uart_tx,
    input  logic       uart_rx,

    // SDRAM (embedded GW2AR-18 MCM — "magic" IOL/IOR pin names)
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_wen_n,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    output logic [3:0]  O_sdram_dqm,
    inout  logic [31:0] IO_sdram_dq
);

    // ---------------------------------------------------------------
    // Reset synchronizer (btn_s1 is async, active low)
    // ---------------------------------------------------------------
    // Power-on reset: free-running counter counts up from 0 (Gowin FF default).
    // Reset deasserts when bit 4 is set (after 16 clocks).
    // btn_s1 re-asserts reset when pressed. On this board btn_s1 reads 1
    // when pressed (Apicula doesn't apply PULL_MODE=UP, so pin floats low
    // when not pressed, and the button pulls it high).
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)             // btn_s1=1 when pressed → reset
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire hw_reset = !por_cnt[4];

    // ---------------------------------------------------------------
    // SD boot — holds CPU in reset until ROM loaded
    // ---------------------------------------------------------------
    logic        boot_done;
    logic [22:0] sd_rom_addr;
    logic [7:0]  sd_rom_data;
    logic        sd_rom_wr;
    logic        sd_boot_error;
    logic [2:0]  sd_error_code;

    // SDRAM controller wires (driven inside USE_SD generate block)
    logic        sdram_busy;

    generate
        if (USE_SD != 0) begin : gen_sd_boot
            // SD card SPI wires
            logic [7:0] spi_tx;
            logic       spi_start;
            logic [7:0] spi_rx;
            logic       spi_busy;
            logic       spi_done;
            logic       spi_cs_en;
            logic       spi_slow_clk;
            logic       spi_sclk, spi_mosi, spi_miso, spi_cs_n;

            // sd_reader wires
            logic [31:0] sd_sector;
            logic        sd_read_start;
            logic [7:0]  sd_read_data;
            logic        sd_read_valid;
            logic        sd_read_done;
            logic        sd_ready;
            logic        sd_err;

            sd_spi u_sd_spi (
                .clk      (clk),
                .reset    (hw_reset),
                .sclk     (spi_sclk),
                .mosi     (spi_mosi),
                .miso     (spi_miso),
                .cs_n     (spi_cs_n),
                .tx_data  (spi_tx),
                .start    (spi_start),
                .rx_data  (spi_rx),
                .busy     (spi_busy),
                .done     (spi_done),
                .cs_en    (spi_cs_en),
                .slow_clk (spi_slow_clk)
            );

            sd_reader u_sd_reader (
                .clk          (clk),
                .reset        (hw_reset),
                .spi_tx       (spi_tx),
                .spi_start    (spi_start),
                .spi_rx       (spi_rx),
                .spi_busy     (spi_busy),
                .spi_done     (spi_done),
                .spi_cs_en    (spi_cs_en),
                .spi_slow_clk (spi_slow_clk),
                .sector       (sd_sector),
                .read_start   (sd_read_start),
                .read_data    (sd_read_data),
                .read_valid   (sd_read_valid),
                .read_done    (sd_read_done),
                .ready        (sd_ready),
                .err          (sd_err),
                .sdhc         ()
            );

            sd_boot u_sd_boot (
                .clk           (clk),
                .reset         (hw_reset),
                .sd_sector     (sd_sector),
                .sd_read_start (sd_read_start),
                .sd_read_data  (sd_read_data),
                .sd_read_valid (sd_read_valid),
                .sd_read_done  (sd_read_done),
                .sd_ready      (sd_ready),
                .sd_error      (sd_err),
                .rom_addr      (sd_rom_addr),
                .rom_data      (sd_rom_data),
                .rom_wr        (sd_rom_wr),
                .sdram_busy    (sdram_busy),
                .done          (boot_done),
                .boot_error    (sd_boot_error),
                .error_code    (sd_error_code)
            );

            // SD card pin assignments
            assign sd_clk  = spi_sclk;
            assign sd_cmd  = spi_mosi;
            assign spi_miso = sd_dat0;
            assign sd_dat3 = spi_cs_n;
            assign sd_dat1 = 1'b1;  // unused, tie high
            assign sd_dat2 = 1'b1;  // unused, tie high
        end else begin : gen_no_sd
            // No SD boot — ROM preloaded, boot immediately done
            assign boot_done     = 1'b1;
            assign sd_rom_addr   = 23'd0;
            assign sd_rom_data   = 8'd0;
            assign sd_rom_wr     = 1'b0;
            assign sd_boot_error = 1'b0;
            assign sd_error_code = 3'd0;
            assign sd_clk  = 1'b0;
            assign sd_cmd  = 1'b1;
            assign sd_dat1 = 1'b1;
            assign sd_dat2 = 1'b1;
            assign sd_dat3 = 1'b1;
        end
    endgenerate

    // CPU reset = hardware reset OR boot not yet complete
    wire reset = hw_reset || !boot_done;

    // ---------------------------------------------------------------
    // CPU ↔ bus wires
    // ---------------------------------------------------------------
    logic [15:0] cpu_addr;
    logic        cpu_rd, cpu_wr;
    logic [7:0]  cpu_wdata, cpu_rdata;

    logic [14:0] rom_addr;       // bus output (unused — MBC1 provides translated addr)
    logic        rom_cs;
    logic [7:0]  rom_rdata;

    logic [20:0] mbc_rom_addr;  // MBC1 translated ROM address

    logic [12:0] vram_addr;
    logic        vram_cs, vram_we;
    logic [7:0]  vram_wdata, vram_rdata;

    logic [12:0] wram_addr;
    logic        wram_cs, wram_we;
    logic [7:0]  wram_wdata, wram_rdata;

    logic [6:0]  hram_addr;
    logic        hram_cs, hram_we;
    logic [7:0]  hram_wdata, hram_rdata;

    logic [6:0]  io_addr;
    logic        io_cs, io_rd, io_wr;
    logic [7:0]  io_wdata, io_rdata;

    logic [7:0]  oam_addr;
    logic        oam_cs, oam_we;
    logic [7:0]  oam_wdata, oam_rdata;

    logic        extram_cs, extram_we;
    logic [7:0]  extram_wdata, extram_rdata;
    logic [14:0] extram_addr;
    logic        extram_en;

    logic        ie_cs, ie_we;
    logic [7:0]  ie_wdata, ie_rdata;

    logic        halted;

    // Interrupt wires
    logic [4:0]  int_req;
    logic [4:0]  int_ack;

    // ---------------------------------------------------------------
    // CPU
    // ---------------------------------------------------------------
    // CPU debug wires
    logic [15:0] dbg_pc, dbg_sp;
    logic [7:0]  dbg_a, dbg_f, dbg_b, dbg_c, dbg_d, dbg_e, dbg_h, dbg_l;

    cpu u_cpu (
        .clk      (clk),
        .reset    (reset),
        .mem_addr (cpu_addr),
        .mem_rd   (cpu_rd),
        .mem_wr   (cpu_wr),
        .mem_wdata(cpu_wdata),
        .mem_rdata(cpu_rdata),
        .mem_wait (mem_wait),
        .int_req  (int_req),
        .int_ack  (int_ack),
        .halted   (halted),
        .dbg_pc   (dbg_pc), .dbg_sp(dbg_sp),
        .dbg_a    (dbg_a),  .dbg_f (dbg_f),
        .dbg_b    (dbg_b),  .dbg_c (dbg_c),
        .dbg_d    (dbg_d),  .dbg_e (dbg_e),
        .dbg_h    (dbg_h),  .dbg_l (dbg_l)
    );

    // ---------------------------------------------------------------
    // Address decoder
    // ---------------------------------------------------------------
    bus u_bus (
        .cpu_addr  (cpu_addr),
        .cpu_rd    (cpu_rd),
        .cpu_wr    (cpu_wr),
        .cpu_wdata (cpu_wdata),
        .cpu_rdata (cpu_rdata),
        .rom_addr  (rom_addr),  .rom_cs (rom_cs),  .rom_rdata (rom_rdata),
        .vram_addr (vram_addr), .vram_cs(vram_cs),  .vram_we   (vram_we),
        .vram_wdata(vram_wdata),.vram_rdata(vram_rdata),
        .wram_addr (wram_addr), .wram_cs(wram_cs),  .wram_we   (wram_we),
        .wram_wdata(wram_wdata),.wram_rdata(wram_rdata),
        .hram_addr (hram_addr), .hram_cs(hram_cs),  .hram_we   (hram_we),
        .hram_wdata(hram_wdata),.hram_rdata(hram_rdata),
        .io_addr   (io_addr),   .io_cs  (io_cs),    .io_rd     (io_rd),
        .io_wr     (io_wr),     .io_wdata(io_wdata), .io_rdata  (io_rdata),
        .oam_addr  (oam_addr),  .oam_cs (oam_cs),   .oam_we    (oam_we),
        .oam_wdata (oam_wdata), .oam_rdata(oam_rdata),
        .extram_cs (extram_cs), .extram_we(extram_we),
        .extram_wdata(extram_wdata), .extram_rdata(extram_rdata),
        .extram_en (extram_en),
        .ie_cs     (ie_cs),     .ie_we  (ie_we),
        .ie_wdata  (ie_wdata),  .ie_rdata(ie_rdata)
    );

    // ---------------------------------------------------------------
    // MBC1 mapper — bank registers + address translation
    // ---------------------------------------------------------------
    mbc1 u_mbc1 (
        .clk          (clk),
        .reset        (reset),
        .cpu_addr     (cpu_addr),
        .cpu_wr       (cpu_wr),
        .cpu_wdata    (cpu_wdata),
        .rom_addr     (mbc_rom_addr),
        .extram_addr  (extram_addr),
        .extram_en    (extram_en),
        .dbg_rom_bank (),
        .dbg_ram_bank (),
        .dbg_bank_mode(),
        .dbg_ram_en   ()
    );

    // ---------------------------------------------------------------
    // ROM / External RAM — SDRAM (USE_SD=1) or BSRAM/distrib (USE_SD=0)
    // ---------------------------------------------------------------
    // SDRAM wait signal (only meaningful when USE_SD=1)
    logic sdram_mem_wait;

    generate
        if (USE_SD != 0) begin : gen_sdram
            // -----------------------------------------------------------
            // SDRAM controller (split DQ — tristate below)
            // -----------------------------------------------------------
            logic [31:0] sdram_dq_out, sdram_dq_in;
            logic        sdram_dq_oe;
            logic        sdram_rd, sdram_wr, sdram_refresh;
            logic [22:0] sdram_a;
            logic [7:0]  sdram_din, sdram_dout;
            logic        sdram_data_ready;

            sdram_ctrl u_sdram (
                .clk(clk), .reset(hw_reset),
                .rd(sdram_rd), .wr(sdram_wr), .refresh(sdram_refresh),
                .addr(sdram_a), .din(sdram_din),
                .dout(sdram_dout), .data_ready(sdram_data_ready), .busy(sdram_busy),
                .sdram_clk(O_sdram_clk), .sdram_cke(O_sdram_cke),
                .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
                .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n),
                .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba),
                .sdram_dqm(O_sdram_dqm),
                .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe),
                .sdram_dq_in(sdram_dq_in)
            );

            // Synthesis tristate for SDRAM data bus
            assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 32'bZ;
            assign sdram_dq_in = IO_sdram_dq;

            // -----------------------------------------------------------
            // Refresh timer (~400 cycles at 27 MHz → ~15 µs)
            // -----------------------------------------------------------
            logic [8:0] ref_timer;
            logic       ref_needed;

            always_ff @(posedge clk) begin
                if (hw_reset) begin
                    ref_timer  <= 9'd0;
                    ref_needed <= 1'b0;
                end else begin
                    if (ref_timer == 9'd400) begin
                        ref_timer  <= 9'd0;
                        ref_needed <= 1'b1;
                    end else begin
                        ref_timer <= ref_timer + 9'd1;
                    end
                    if (sdram_refresh)
                        ref_needed <= 1'b0;
                end
            end

            // -----------------------------------------------------------
            // CPU SDRAM access tracking
            // -----------------------------------------------------------
            wire cpu_sdram_rd = rom_cs && cpu_rd;
            wire cpu_sdram_wr = extram_cs && extram_en && cpu_wr;
            wire cpu_sdram_extram_rd = extram_cs && extram_en && cpu_rd;

            // SDRAM address from CPU: ROM at 0x000000, ExtRAM at 0x200000
            wire [22:0] cpu_sdram_addr = rom_cs ? {2'b00, mbc_rom_addr} :
                                                  {8'h20, extram_addr};

            // FSM: track SDRAM access lifecycle during CPU run mode
            typedef enum logic [1:0] {
                SCPU_IDLE,
                SCPU_WAIT,
                SCPU_DONE
            } scpu_state_t;

            scpu_state_t scpu_state;
            logic [7:0]  sdram_rdata_latched;

            always_ff @(posedge clk) begin
                if (reset) begin
                    scpu_state <= SCPU_IDLE;
                    sdram_rdata_latched <= 8'd0;
                end else begin
                    case (scpu_state)
                        SCPU_IDLE: begin
                            if ((cpu_sdram_rd || cpu_sdram_extram_rd || cpu_sdram_wr) &&
                                boot_done && !sdram_busy)
                                scpu_state <= SCPU_WAIT;
                        end
                        SCPU_WAIT: begin
                            if (sdram_data_ready) begin
                                sdram_rdata_latched <= sdram_dout;
                                scpu_state <= SCPU_DONE;
                            end else if (cpu_sdram_wr && !sdram_busy) begin
                                // Write complete (busy dropped after write cycle)
                                scpu_state <= SCPU_DONE;
                            end
                        end
                        SCPU_DONE: begin
                            // CPU will proceed (mem_wait=0), then on next cycle
                            // cpu_rd/cpu_wr will drop, returning us to IDLE
                            if (!cpu_sdram_rd && !cpu_sdram_extram_rd && !cpu_sdram_wr)
                                scpu_state <= SCPU_IDLE;
                        end
                        default: scpu_state <= SCPU_IDLE;
                    endcase
                end
            end

            // Route SDRAM data to bus read ports
            assign rom_rdata    = sdram_rdata_latched;
            assign extram_rdata = sdram_rdata_latched;

            // SDRAM mem_wait: active during any CPU SDRAM access until done
            wire cpu_sdram_access = cpu_sdram_rd || cpu_sdram_extram_rd || cpu_sdram_wr;
            assign sdram_mem_wait = boot_done && cpu_sdram_access &&
                                    scpu_state != SCPU_DONE;

            // -----------------------------------------------------------
            // SDRAM command arbiter (boot mode vs run mode)
            // -----------------------------------------------------------
            // Pulse generation: issue rd/wr only on IDLE→WAIT transition
            wire cpu_rd_pulse = boot_done &&
                                (cpu_sdram_rd || cpu_sdram_extram_rd) &&
                                scpu_state == SCPU_IDLE && !sdram_busy;
            wire cpu_wr_pulse = boot_done &&
                                cpu_sdram_wr &&
                                scpu_state == SCPU_IDLE && !sdram_busy;

            always_comb begin
                sdram_rd      = 1'b0;
                sdram_wr      = 1'b0;
                sdram_refresh = 1'b0;
                sdram_a       = 23'd0;
                sdram_din     = 8'd0;

                if (!boot_done) begin
                    // Boot mode: sd_boot writes ROM data to SDRAM
                    if (sd_rom_wr && !sdram_busy) begin
                        sdram_wr  = 1'b1;
                        sdram_a   = sd_rom_addr;
                        sdram_din = sd_rom_data;
                    end else if (ref_needed && !sdram_busy) begin
                        sdram_refresh = 1'b1;
                    end
                end else begin
                    // Run mode: CPU reads/writes + refresh
                    if (cpu_rd_pulse) begin
                        sdram_rd = 1'b1;
                        sdram_a  = cpu_sdram_addr;
                    end else if (cpu_wr_pulse) begin
                        sdram_wr  = 1'b1;
                        sdram_a   = cpu_sdram_addr;
                        sdram_din = extram_wdata;
                    end else if (ref_needed && !sdram_busy) begin
                        sdram_refresh = 1'b1;
                    end
                end
            end

        end else begin : gen_no_sdram
            // No SDRAM — tie outputs low, DQ undriven
            assign O_sdram_clk  = 1'b0;
            assign O_sdram_cke  = 1'b0;
            assign O_sdram_cs_n = 1'b1;
            assign O_sdram_ras_n = 1'b1;
            assign O_sdram_cas_n = 1'b1;
            assign O_sdram_wen_n = 1'b1;
            assign O_sdram_addr = 11'd0;
            assign O_sdram_ba   = 2'd0;
            assign O_sdram_dqm  = 4'd0;
            assign IO_sdram_dq  = 32'bZ;
            assign sdram_busy   = 1'b0;
            assign sdram_mem_wait = 1'b0;

            // ROM — distributed RAM for simulation (small ROMs, combinational read)
            logic [7:0] rom_mem [0:ROM_SIZE-1];
            initial if (ROM_FILE != "")
                $readmemh(ROM_FILE, rom_mem);
            assign rom_rdata = rom_mem[mbc_rom_addr[$clog2(ROM_SIZE)-1:0]];

            // External RAM — 32 KB BSRAM (MBC1: 4 banks × 8 KB)
            single_port_ram #(.ADDR_WIDTH(15), .DATA_WIDTH(8)) u_extram (
                .clk  (clk),
                .we   (extram_cs && extram_we),
                .addr (extram_addr),
                .wdata(extram_wdata),
                .rdata(extram_rdata)
            );
        end
    endgenerate;

    // ---------------------------------------------------------------
    // WRAM — 8 KB BSRAM (synchronous reads, 1-cycle latency)
    // ---------------------------------------------------------------
    single_port_ram #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_wram (
        .clk  (clk),
        .we   (wram_cs && wram_we),
        .addr (wram_addr),
        .wdata(wram_wdata),
        .rdata(wram_rdata)
    );

    // ---------------------------------------------------------------
    // HRAM (127 bytes, combinational read, synchronous write)
    // ---------------------------------------------------------------
    logic [7:0] hram_mem [0:126];
    assign hram_rdata = hram_mem[hram_addr];
    always_ff @(posedge clk) begin
        if (hram_cs && hram_we)
            hram_mem[hram_addr] <= hram_wdata;
    end

    // ---------------------------------------------------------------
    // Wait-state generation
    // ---------------------------------------------------------------
    // BSRAM reads (VRAM, WRAM) take 1 extra cycle.
    // When USE_SD=1, ROM and ExtRAM go through SDRAM (~5 cycles).
    // When USE_SD=0, ExtRAM is also BSRAM (1 cycle), ROM is combinational.
    logic bsram_read_done;
    wire bsram_rd = USE_SD != 0 ?
        (vram_cs || wram_cs) && cpu_rd :
        (vram_cs || wram_cs || extram_cs) && cpu_rd;
    always_ff @(posedge clk) begin
        if (reset)
            bsram_read_done <= 1'b0;
        else
            bsram_read_done <= bsram_rd && !bsram_read_done;
    end
    wire mem_wait = (bsram_rd && !bsram_read_done) || sdram_mem_wait;

    // ---------------------------------------------------------------
    // I/O registers
    // ---------------------------------------------------------------
    logic [7:0] led_reg;
    initial led_reg = 8'h00;

    always_ff @(posedge clk) begin
        if (reset)
            led_reg <= 8'h00;
        else if (io_cs && io_wr && io_addr == 7'h50)
            led_reg <= io_wdata;
    end

    // LEDs are active low
    assign led = ~led_reg[5:0];

    // ---------------------------------------------------------------
    // Timer (FF04–FF07)
    // ---------------------------------------------------------------
    logic [7:0] timer_rdata;
    logic       timer_rdata_valid;
    logic       timer_irq;

    timer u_timer (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (io_cs),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (timer_rdata),
        .io_rdata_valid (timer_rdata_valid),
        .irq            (timer_irq),
        .dbg_div_ctr    (),
        .dbg_tima       (),
        .dbg_tma        (),
        .dbg_tac        ()
    );

    // ---------------------------------------------------------------
    // Joypad (FF00)
    // ---------------------------------------------------------------
    logic [7:0] joypad_rdata;
    logic       joypad_rdata_valid;
    logic       joypad_irq;

    wire [7:0] btn_bus = {btn_start, btn_select, btn_b, btn_a,
                          btn_down, btn_up, btn_left, btn_right};

    joypad u_joypad (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (io_cs),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (joypad_rdata),
        .io_rdata_valid (joypad_rdata_valid),
        .btn            (btn_bus),
        .irq            (joypad_irq)
    );

    // ---------------------------------------------------------------
    // Serial port (FF01–FF02)
    // ---------------------------------------------------------------
    logic [7:0] serial_rdata;
    logic       serial_rdata_valid;
    logic       serial_irq;

    serial u_serial (
        .clk            (clk),
        .reset          (reset),
        .io_cs          (io_cs),
        .io_addr        (io_addr),
        .io_wr          (io_wr),
        .io_wdata       (io_wdata),
        .io_rdata       (serial_rdata),
        .io_rdata_valid (serial_rdata_valid),
        .irq            (serial_irq),
        .dbg_sb         (),
        .dbg_sc         ()
    );

    // ---------------------------------------------------------------
    // IF register (FF0F) — interrupt flags
    // ---------------------------------------------------------------
    logic [4:0] if_reg;
    initial if_reg = 5'h00;

    // Compute next IF value combinationally — parallel OR allows
    // multiple interrupt sources to set their bits in the same cycle.
    logic [4:0] next_if;
    always_comb begin
        next_if = if_reg;
        if (ppu_irq_vblank) next_if = next_if | 5'b00001;
        if (ppu_irq_stat)   next_if = next_if | 5'b00010;
        if (timer_irq)      next_if = next_if | 5'b00100;
        if (serial_irq)     next_if = next_if | 5'b01000;
        if (joypad_irq)     next_if = next_if | 5'b10000;
        if (io_cs && io_wr && io_addr == 7'h0F)
            next_if = io_wdata[4:0];
        if (int_ack != 5'b0)
            next_if = next_if & ~int_ack;
    end

    always_ff @(posedge clk) begin
        if (reset)
            if_reg <= 5'h00;
        else
            if_reg <= next_if;
    end

    // I/O read mux
    always_comb begin
        if (ppu_rdata_valid)
            io_rdata = ppu_rdata;
        else if (timer_rdata_valid)
            io_rdata = timer_rdata;
        else if (joypad_rdata_valid)
            io_rdata = joypad_rdata;
        else if (serial_rdata_valid)
            io_rdata = serial_rdata;
        else begin
            unique case (io_addr)
                7'h50:   io_rdata = led_reg;
                7'h0F:   io_rdata = {3'b111, if_reg};
                default: io_rdata = 8'h00;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // IE register (FFFF) — interrupt enable
    // ---------------------------------------------------------------
    logic [7:0] ie_reg;
    initial ie_reg = 8'h00;
    assign ie_rdata = ie_reg;
    always_ff @(posedge clk) begin
        if (reset)
            ie_reg <= 8'h00;
        else if (ie_cs && ie_we)
            ie_reg <= ie_wdata;
    end

    // ---------------------------------------------------------------
    // Interrupt request: IF & IE
    // ---------------------------------------------------------------
    assign int_req = if_reg & ie_reg[4:0];

    // ---------------------------------------------------------------
    // PPU (FF40–FF4B) — VRAM lives inside the PPU module
    // ---------------------------------------------------------------
    logic [7:0]  ppu_rdata;
    logic        ppu_rdata_valid;
    logic        ppu_irq_vblank;
    logic        ppu_irq_stat;

    logic [7:0]  lcd_pixel_x;
    logic [7:0]  lcd_pixel_y;
    logic [15:0] lcd_pixel_data;
    logic        lcd_pixel_req;
    logic        lcd_pixel_ready;

    ppu u_ppu (
        .clk              (clk),
        .reset            (reset),
        .cpu_vram_addr    (vram_addr),
        .cpu_vram_cs      (vram_cs),
        .cpu_vram_we      (vram_we),
        .cpu_vram_wdata   (vram_wdata),
        .cpu_vram_rdata   (vram_rdata),
        .cpu_oam_addr     (oam_addr),
        .cpu_oam_cs       (oam_cs),
        .cpu_oam_we       (oam_we),
        .cpu_oam_wdata    (oam_wdata),
        .cpu_oam_rdata    (oam_rdata),
        .io_cs            (io_cs),
        .io_addr          (io_addr),
        .io_wr            (io_wr),
        .io_rd            (io_rd),
        .io_wdata         (io_wdata),
        .io_rdata         (ppu_rdata),
        .io_rdata_valid   (ppu_rdata_valid),
        .pixel_x          (lcd_pixel_x),
        .pixel_y          (lcd_pixel_y),
        .pixel_fetch      (lcd_pixel_req),
        .pixel_data       (lcd_pixel_data),
        .pixel_data_valid (lcd_pixel_ready),
        .irq_vblank       (ppu_irq_vblank),
        .irq_stat         (ppu_irq_stat)
    );

    // ---------------------------------------------------------------
    // Debug UART console
    // ---------------------------------------------------------------
    debug_console u_debug (
        .clk         (clk),
        .reset       (reset),
        .uart_rx_pin (uart_rx),
        .uart_tx_pin (uart_tx),
        .dbg_pc      (dbg_pc),
        .dbg_sp      (dbg_sp),
        .dbg_a       (dbg_a),
        .dbg_f       (dbg_f),
        .dbg_b       (dbg_b),
        .dbg_c       (dbg_c),
        .dbg_d       (dbg_d),
        .dbg_e       (dbg_e),
        .dbg_h       (dbg_h),
        .dbg_l       (dbg_l),
        .dbg_halted  (halted),
        .dbg_if      ({3'b111, if_reg}),
        .dbg_ie      (ie_reg)
    );

    // ---------------------------------------------------------------
    // ST7789 LCD — driven by PPU pixel output
    // ---------------------------------------------------------------
    st7789 u_lcd (
        .clk        (clk),
        .reset      (reset),
        .lcd_rst    (lcd_rst),
        .lcd_cs     (lcd_cs),
        .lcd_dc     (lcd_dc),
        .lcd_sclk   (lcd_sclk),
        .lcd_mosi   (lcd_mosi),
        .lcd_bl     (lcd_bl),
        .pixel_data (lcd_pixel_data),
        .pixel_ready(lcd_pixel_ready),
        .pixel_x    (lcd_pixel_x),
        .pixel_y    (lcd_pixel_y),
        .pixel_req  (lcd_pixel_req),
        .busy       ()
    );

endmodule
