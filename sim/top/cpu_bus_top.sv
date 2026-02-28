// Integration test wrapper: CPU + bus + combinational memory arrays.
//
// Memory is implemented as plain arrays with combinational reads,
// matching the timing model the CPU expects (data available in the
// same cycle the address is presented).
module cpu_bus_top #(
    parameter int ROM_SIZE  = 256,    // bytes (default small for tests)
    parameter     ROM_FILE  = ""
) (
    input  logic        clk,
    input  logic        reset,

    // Debug / status
    output logic        halted,
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [7:0]  dbg_a, dbg_f,
    output logic [7:0]  dbg_b, dbg_c,
    output logic [7:0]  dbg_d, dbg_e,
    output logic [7:0]  dbg_h, dbg_l
);

    // CPU ↔ bus wires
    logic [15:0] cpu_addr;
    logic        cpu_rd, cpu_wr;
    logic [7:0]  cpu_wdata, cpu_rdata;

    // Bus ↔ device wires
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
        .halted   (halted),
        .dbg_pc   (dbg_pc),
        .dbg_sp   (dbg_sp),
        .dbg_a    (dbg_a), .dbg_f(dbg_f),
        .dbg_b    (dbg_b), .dbg_c(dbg_c),
        .dbg_d    (dbg_d), .dbg_e(dbg_e),
        .dbg_h    (dbg_h), .dbg_l(dbg_l)
    );

    // ---------------------------------------------------------------
    // Address decoder / read mux
    // ---------------------------------------------------------------
    bus u_bus (
        .cpu_addr  (cpu_addr),
        .cpu_rd    (cpu_rd),
        .cpu_wr    (cpu_wr),
        .cpu_wdata (cpu_wdata),
        .cpu_rdata (cpu_rdata),

        .rom_addr  (rom_addr),
        .rom_cs    (rom_cs),
        .rom_rdata (rom_rdata),

        .wram_addr (wram_addr),
        .wram_cs   (wram_cs),
        .wram_we   (wram_we),
        .wram_wdata(wram_wdata),
        .wram_rdata(wram_rdata),

        .hram_addr (hram_addr),
        .hram_cs   (hram_cs),
        .hram_we   (hram_we),
        .hram_wdata(hram_wdata),
        .hram_rdata(hram_rdata),

        .io_addr   (io_addr),
        .io_cs     (io_cs),
        .io_rd     (io_rd),
        .io_wr     (io_wr),
        .io_wdata  (io_wdata),
        .io_rdata  (io_rdata),

        .ie_cs     (ie_cs),
        .ie_we     (ie_we),
        .ie_wdata  (ie_wdata),
        .ie_rdata  (ie_rdata)
    );

    // ---------------------------------------------------------------
    // Memory arrays (combinational reads for simulation)
    // ---------------------------------------------------------------

    // ROM (combinational read, initialized from hex file)
    logic [7:0] rom_mem [0:ROM_SIZE-1];
    initial begin
        for (int i = 0; i < ROM_SIZE; i++) rom_mem[i] = 8'h00;
        if (ROM_FILE != "")
            $readmemh(ROM_FILE, rom_mem);
    end
    assign rom_rdata = rom_mem[rom_addr[$clog2(ROM_SIZE)-1:0]];

    // WRAM (8 KB, combinational read, synchronous write)
    logic [7:0] wram_mem [0:8191];
    initial for (int i = 0; i < 8192; i++) wram_mem[i] = 8'h00;
    assign wram_rdata = wram_mem[wram_addr];
    always_ff @(posedge clk) begin
        if (wram_cs && wram_we)
            wram_mem[wram_addr] <= wram_wdata;
    end

    // HRAM (127 bytes, combinational read, synchronous write)
    logic [7:0] hram_mem [0:126];
    initial for (int i = 0; i < 127; i++) hram_mem[i] = 8'h00;
    assign hram_rdata = hram_mem[hram_addr];
    always_ff @(posedge clk) begin
        if (hram_cs && hram_we)
            hram_mem[hram_addr] <= hram_wdata;
    end

    // I/O stub: reads 0x00 for now (peripherals will be added later)
    assign io_rdata = 8'h00;

    // IE register (single byte)
    logic [7:0] ie_reg;
    initial ie_reg = 8'h00;
    assign ie_rdata = ie_reg;
    always_ff @(posedge clk) begin
        if (ie_cs && ie_we)
            ie_reg <= ie_wdata;
    end

endmodule
