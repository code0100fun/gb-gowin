// Standalone MBC1 test wrapper — no CPU needed.
//
// Includes a combinational ROM array and synchronous-write external RAM
// for verifying MBC1 address translation end-to-end. ROM is initialized
// with rom_mem[i] = i[7:0] so each byte reveals its ROM address.
module mbc1_top #(
    parameter int ROM_SIZE   = 32768,  // 32 KB = 2 banks
    parameter int EXTRAM_SIZE = 8192   // 8 KB = 1 bank
) (
    input  logic        clk,
    input  logic        reset,

    // Simulated CPU bus
    input  logic [15:0] cpu_addr,
    input  logic        cpu_rd,
    input  logic        cpu_wr,
    input  logic [7:0]  cpu_wdata,
    output logic [7:0]  cpu_rdata,

    // Debug
    output logic [20:0] dbg_rom_addr,
    output logic [14:0] dbg_extram_addr,
    output logic        dbg_extram_en,
    output logic [4:0]  dbg_rom_bank,
    output logic [1:0]  dbg_ram_bank,
    output logic        dbg_bank_mode,
    output logic        dbg_ram_en
);

    // ---------------------------------------------------------------
    // MBC1
    // ---------------------------------------------------------------
    logic [20:0] mbc_rom_addr;
    logic [14:0] extram_addr;
    logic        extram_en;

    mbc1 u_mbc1 (
        .clk          (clk),
        .reset        (reset),
        .cpu_addr     (cpu_addr),
        .cpu_wr       (cpu_wr),
        .cpu_wdata    (cpu_wdata),
        .rom_addr     (mbc_rom_addr),
        .extram_addr  (extram_addr),
        .extram_en    (extram_en),
        .dbg_rom_bank (dbg_rom_bank),
        .dbg_ram_bank (dbg_ram_bank),
        .dbg_bank_mode(dbg_bank_mode),
        .dbg_ram_en   (dbg_ram_en)
    );

    assign dbg_rom_addr    = mbc_rom_addr;
    assign dbg_extram_addr = extram_addr;
    assign dbg_extram_en   = extram_en;

    // ---------------------------------------------------------------
    // ROM (combinational read, initialized with address pattern)
    // ---------------------------------------------------------------
    logic [7:0] rom_mem [0:ROM_SIZE-1];
    initial begin
        for (int i = 0; i < ROM_SIZE; i++)
            rom_mem[i] = i[7:0];
    end

    // ---------------------------------------------------------------
    // External RAM (combinational read, synchronous write)
    // ---------------------------------------------------------------
    logic [7:0] extram_mem [0:EXTRAM_SIZE-1];
    initial begin
        for (int i = 0; i < EXTRAM_SIZE; i++)
            extram_mem[i] = 8'h00;
    end

    always_ff @(posedge clk) begin
        if (extram_en && cpu_wr)
            extram_mem[extram_addr[$clog2(EXTRAM_SIZE)-1:0]] <= cpu_wdata;
    end

    // ---------------------------------------------------------------
    // Read mux
    // ---------------------------------------------------------------
    always_comb begin
        cpu_rdata = 8'hFF;
        if (!cpu_addr[15]) begin
            // 0000-7FFF: ROM via MBC1 translated address
            cpu_rdata = rom_mem[mbc_rom_addr[$clog2(ROM_SIZE)-1:0]];
        end else if (cpu_addr[15:13] == 3'b101) begin
            // A000-BFFF: External RAM
            if (extram_en)
                cpu_rdata = extram_mem[extram_addr[$clog2(EXTRAM_SIZE)-1:0]];
            else
                cpu_rdata = 8'hFF;
        end
    end

endmodule
