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

    // Interrupt request lines (directly set IF bits)
    input  logic [4:0]  int_request,

    // Debug / status
    output logic        halted,
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [7:0]  dbg_a, dbg_f,
    output logic [7:0]  dbg_b, dbg_c,
    output logic [7:0]  dbg_d, dbg_e,
    output logic [7:0]  dbg_h, dbg_l,
    output logic [7:0]  dbg_ie,
    output logic [7:0]  dbg_if
);

    // CPU ↔ bus wires
    logic [15:0] cpu_addr;
    logic        cpu_rd, cpu_wr;
    logic [7:0]  cpu_wdata, cpu_rdata;

    // Bus ↔ device wires
    logic [14:0] rom_addr;
    logic        rom_cs;
    logic [7:0]  rom_rdata;

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

    logic        ie_cs, ie_we;
    logic [7:0]  ie_wdata, ie_rdata;

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
        .mem_wait (1'b0),
        .int_req  (int_req),
        .int_ack  (int_ack),
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

        .vram_addr (vram_addr),
        .vram_cs   (vram_cs),
        .vram_we   (vram_we),
        .vram_wdata(vram_wdata),
        .vram_rdata(vram_rdata),

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

        .oam_addr  (oam_addr),
        .oam_cs    (oam_cs),
        .oam_we    (oam_we),
        .oam_wdata (oam_wdata),
        .oam_rdata (oam_rdata),

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

    // VRAM (8 KB, combinational read, synchronous write)
    logic [7:0] vram_mem [0:8191];
    initial for (int i = 0; i < 8192; i++) vram_mem[i] = 8'h00;
    assign vram_rdata = vram_mem[vram_addr];
    always_ff @(posedge clk) begin
        if (vram_cs && vram_we)
            vram_mem[vram_addr] <= vram_wdata;
    end

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

    // OAM (160 bytes, combinational read, synchronous write)
    logic [7:0] oam_mem [0:159];
    initial for (int i = 0; i < 160; i++) oam_mem[i] = 8'h00;
    assign oam_rdata = oam_mem[oam_addr];
    always_ff @(posedge clk) begin
        if (oam_cs && oam_we)
            oam_mem[oam_addr] <= oam_wdata;
    end

    // ---------------------------------------------------------------
    // IF register (FF0F) — interrupt flags
    // ---------------------------------------------------------------
    logic [4:0] if_reg;
    initial if_reg = 5'h00;

    always_ff @(posedge clk) begin
        if (reset)
            if_reg <= 5'h00;
        else begin
            // External sources set bits (OR'd in)
            if (int_request != 5'b0)
                if_reg <= if_reg | int_request;
            // CPU write replaces value
            if (io_cs && io_wr && io_addr == 7'h0F)
                if_reg <= io_wdata[4:0];
            // Dispatch acknowledge clears bit (highest priority)
            if (int_ack != 5'b0)
                if_reg <= if_reg & ~int_ack;
        end
    end

    // I/O read mux
    always_comb begin
        unique case (io_addr)
            7'h0F:   io_rdata = {3'b111, if_reg};
            default: io_rdata = 8'h00;
        endcase
    end

    // ---------------------------------------------------------------
    // IE register (FFFF)
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

    // Debug outputs
    assign dbg_ie = ie_reg;
    assign dbg_if = {3'b111, if_reg};

endmodule
