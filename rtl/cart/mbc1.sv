// MBC1 memory bank controller.
//
// Monitors CPU address bus writes to 0000-7FFF to update internal bank
// registers. Outputs translated ROM and external RAM addresses based on
// the current banking mode.
//
// Supports up to 2 MB ROM (128 banks × 16 KB) and 32 KB external RAM
// (4 banks × 8 KB).
//
// Register map (written via ROM address space):
//   0000-1FFF  RAM Enable    — lower nibble == 0xA enables
//   2000-3FFF  ROM Bank      — 5-bit bank number (0 maps to 1)
//   4000-5FFF  RAM Bank      — 2-bit (also upper ROM bits)
//   6000-7FFF  Banking Mode  — 0=ROM, 1=RAM/Advanced
module mbc1 (
    input  logic        clk,
    input  logic        reset,

    // CPU bus (directly monitored)
    input  logic [15:0] cpu_addr,
    input  logic        cpu_wr,
    input  logic [7:0]  cpu_wdata,

    // Translated ROM address (21 bits = 2 MB)
    output logic [20:0] rom_addr,

    // External RAM
    output logic [14:0] extram_addr,  // 15 bits = 32 KB
    output logic        extram_en,    // RAM enabled + A000-BFFF addressed

    // Debug
    output logic [4:0]  dbg_rom_bank,
    output logic [1:0]  dbg_ram_bank,
    output logic        dbg_bank_mode,
    output logic        dbg_ram_en
);

    // ---------------------------------------------------------------
    // Bank registers (all reset to 0 via Gowin GSR)
    // ---------------------------------------------------------------
    logic        ram_en;
    logic [4:0]  rom_bank;
    logic [1:0]  ram_bank;
    logic        bank_mode;

    assign dbg_rom_bank  = rom_bank;
    assign dbg_ram_bank  = ram_bank;
    assign dbg_bank_mode = bank_mode;
    assign dbg_ram_en    = ram_en;

    // ---------------------------------------------------------------
    // Register writes
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            ram_en    <= 1'b0;
            rom_bank  <= 5'd0;
            ram_bank  <= 2'd0;
            bank_mode <= 1'b0;
        end else if (cpu_wr && !cpu_addr[15]) begin
            // Writes to 0000-7FFF update MBC registers
            case (cpu_addr[14:13])
                2'b00: ram_en    <= (cpu_wdata[3:0] == 4'hA);
                2'b01: rom_bank  <= cpu_wdata[4:0];
                2'b10: ram_bank  <= cpu_wdata[1:0];
                2'b11: bank_mode <= cpu_wdata[0];
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Address translation
    // ---------------------------------------------------------------
    // Bank 0 → 1 fixup: ROM bank register value 0 selects bank 1
    wire [4:0] rom_bank_adj = (rom_bank == 5'd0) ? 5'd1 : rom_bank;

    always_comb begin
        // --- ROM address ---
        if (!cpu_addr[14]) begin
            // 0000-3FFF: Bank 0 window
            if (bank_mode)
                rom_addr = {ram_bank, 5'd0, cpu_addr[13:0]};
            else
                rom_addr = {2'b00, 5'd0, cpu_addr[13:0]};
        end else begin
            // 4000-7FFF: Switchable bank
            rom_addr = {ram_bank, rom_bank_adj, cpu_addr[13:0]};
        end

        // --- External RAM address ---
        if (bank_mode)
            extram_addr = {ram_bank, cpu_addr[12:0]};
        else
            extram_addr = {2'b00, cpu_addr[12:0]};

        // RAM accessible only when enabled AND address is A000-BFFF
        extram_en = ram_en && (cpu_addr[15:13] == 3'b101);
    end

endmodule
