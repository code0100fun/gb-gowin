// Synchronous ROM initialized from a hex file.
//
// The INIT_FILE parameter points to a file in $readmemh format — one hex
// value per line (e.g., "FF", "00", "A5"). Yosys reads this at synthesis
// time and initializes the BSRAM contents.
//
// Used in the Game Boy for:
//   - Boot ROM (256 bytes)
//   - BRAM-embedded test ROMs (up to ~32 KB)
module rom #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 8,
    parameter     INIT_FILE  = ""
) (
    input  logic                   clk,
    input  logic [ADDR_WIDTH-1:0]  addr,
    output logic [DATA_WIDTH-1:0]  rdata
);

    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        rdata <= mem[addr];
    end

endmodule
