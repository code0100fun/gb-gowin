// Game Boy FPGA top-level — Tang Nano 20K.
//
// Wires CPU → bus → ROM / WRAM / HRAM with an LED register for
// visible output. Memory uses combinational reads (distributed RAM).
module gb_top #(
    parameter int ROM_SIZE = 256,
    parameter     ROM_FILE = "sim/data/boot_test.hex"
) (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset (active low)
    input  logic       btn_s2,     // unused
    output logic [5:0] led         // onboard LEDs (active low)
);

    // ---------------------------------------------------------------
    // Reset synchronizer (btn_s1 is async, active low)
    // ---------------------------------------------------------------
    logic [1:0] rst_sync;
    logic       reset;

    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], ~btn_s1};
    end
    assign reset = rst_sync[1];

    // ---------------------------------------------------------------
    // CPU ↔ bus wires
    // ---------------------------------------------------------------
    logic [15:0] cpu_addr;
    logic        cpu_rd, cpu_wr;
    logic [7:0]  cpu_wdata, cpu_rdata;

    logic [14:0] rom_addr;
    logic        rom_cs;
    logic [7:0]  rom_rdata;

    logic [12:0] wram_addr;
    logic        wram_cs, wram_we;
    logic [7:0]  wram_wdata, wram_rdata;

    logic [6:0]  hram_addr;
    logic        hram_cs, hram_we;
    logic [7:0]  hram_wdata, hram_rdata;

    logic [6:0]  io_addr;
    logic        io_cs, io_rd, io_wr;
    logic [7:0]  io_wdata, io_rdata;

    logic        ie_cs, ie_we;
    logic [7:0]  ie_wdata, ie_rdata;

    logic        halted;

    // Interrupt wires
    logic [4:0]  int_req;
    logic [4:0]  int_ack;

    // ---------------------------------------------------------------
    // CPU
    // ---------------------------------------------------------------
    cpu u_cpu (
        .clk      (clk),
        .reset    (reset),
        .mem_addr (cpu_addr),
        .mem_rd   (cpu_rd),
        .mem_wr   (cpu_wr),
        .mem_wdata(cpu_wdata),
        .mem_rdata(cpu_rdata),
        .int_req  (int_req),
        .int_ack  (int_ack),
        .halted   (halted),
        .dbg_pc   (), .dbg_sp(),
        .dbg_a    (), .dbg_f (),
        .dbg_b    (), .dbg_c (),
        .dbg_d    (), .dbg_e (),
        .dbg_h    (), .dbg_l ()
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
        .wram_addr (wram_addr), .wram_cs(wram_cs),  .wram_we   (wram_we),
        .wram_wdata(wram_wdata),.wram_rdata(wram_rdata),
        .hram_addr (hram_addr), .hram_cs(hram_cs),  .hram_we   (hram_we),
        .hram_wdata(hram_wdata),.hram_rdata(hram_rdata),
        .io_addr   (io_addr),   .io_cs  (io_cs),    .io_rd     (io_rd),
        .io_wr     (io_wr),     .io_wdata(io_wdata), .io_rdata  (io_rdata),
        .ie_cs     (ie_cs),     .ie_we  (ie_we),
        .ie_wdata  (ie_wdata),  .ie_rdata(ie_rdata)
    );

    // ---------------------------------------------------------------
    // ROM (combinational read, distributed RAM)
    // ---------------------------------------------------------------
    logic [7:0] rom_mem [0:ROM_SIZE-1];
    initial begin
        for (int i = 0; i < ROM_SIZE; i++) rom_mem[i] = 8'h00;
        if (ROM_FILE != "")
            $readmemh(ROM_FILE, rom_mem);
    end
    assign rom_rdata = rom_mem[rom_addr[$clog2(ROM_SIZE)-1:0]];

    // ---------------------------------------------------------------
    // WRAM — stub for now (8 KB distributed RAM exceeds LUT budget).
    // Will be replaced with BSRAM in a later tutorial.
    // ---------------------------------------------------------------
    assign wram_rdata = 8'hFF;

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
    // I/O registers
    // ---------------------------------------------------------------
    logic [7:0] led_reg;
    initial led_reg = 8'h00;

    always_ff @(posedge clk) begin
        if (reset)
            led_reg <= 8'h00;
        else if (io_cs && io_wr && io_addr == 7'h01)
            led_reg <= io_wdata;
    end

    // LEDs are active low
    assign led = ~led_reg[5:0];

    // ---------------------------------------------------------------
    // IF register (FF0F) — interrupt flags
    // ---------------------------------------------------------------
    logic [4:0] if_reg;
    initial if_reg = 5'h00;

    always_ff @(posedge clk) begin
        if (reset)
            if_reg <= 5'h00;
        else if (int_ack != 5'b0)
            if_reg <= if_reg & ~int_ack;
        else if (io_cs && io_wr && io_addr == 7'h0F)
            if_reg <= io_wdata[4:0];
        // Future: external sources OR bits in (timer, PPU, etc.)
    end

    // I/O read mux
    always_comb begin
        unique case (io_addr)
            7'h01:   io_rdata = led_reg;
            7'h0F:   io_rdata = {3'b111, if_reg};
            default: io_rdata = 8'h00;
        endcase
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

endmodule
