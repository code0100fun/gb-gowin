// Single-port synchronous RAM.
//
// This coding style is recognized by Yosys and inferred as Gowin BSRAM.
// Read behavior: read-first (on simultaneous read+write to the same address,
// the OLD value is returned).
module single_port_ram #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8
) (
    input  logic                   clk,
    input  logic                   we,
    input  logic [ADDR_WIDTH-1:0]  addr,
    input  logic [DATA_WIDTH-1:0]  wdata,
    output logic [DATA_WIDTH-1:0]  rdata
);

    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];

    always_ff @(posedge clk) begin
        if (we)
            mem[addr] <= wdata;
        rdata <= mem[addr];
    end

endmodule
