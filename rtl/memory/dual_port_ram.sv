// True dual-port synchronous RAM.
//
// Two independent ports with separate clocks, addresses, and data paths.
// Each port can read and write independently. Both ports share the same
// underlying memory array.
//
// Used in the Game Boy for:
//   - VRAM: CPU writes tiles/maps, PPU reads them for rendering
//   - Framebuffer: PPU writes pixels (GB clock), LCD reads them (SPI clock)
//
// Behavior when both ports access the same address simultaneously is
// undefined — the design must avoid this (the Game Boy's PPU mode
// restrictions naturally prevent it for VRAM).
module dual_port_ram #(
    parameter int ADDR_WIDTH = 10,
    parameter int DATA_WIDTH = 8
) (
    // Port A
    input  logic                   clk_a,
    input  logic                   we_a,
    input  logic [ADDR_WIDTH-1:0]  addr_a,
    input  logic [DATA_WIDTH-1:0]  wdata_a,
    output logic [DATA_WIDTH-1:0]  rdata_a,

    // Port B
    input  logic                   clk_b,
    input  logic                   we_b,
    input  logic [ADDR_WIDTH-1:0]  addr_b,
    input  logic [DATA_WIDTH-1:0]  wdata_b,
    output logic [DATA_WIDTH-1:0]  rdata_b
);

    // verilator lint_off MULTIDRIVEN
    logic [DATA_WIDTH-1:0] mem [0:2**ADDR_WIDTH-1];
    // verilator lint_on MULTIDRIVEN

    always_ff @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end

    always_ff @(posedge clk_b) begin
        if (we_b)
            mem[addr_b] <= wdata_b;
        rdata_b <= mem[addr_b];
    end

endmodule
