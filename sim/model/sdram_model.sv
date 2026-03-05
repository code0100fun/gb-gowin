// Behavioral SDRAM model for Verilator simulation.
//
// Models the embedded 64 Mbit SDRAM (32-bit data bus, 4 banks).
// Uses split DQ interface (no inout) for Verilator compatibility.
// Samples commands on negedge clk — this corresponds to posedge
// sdram_clk (since sdram_clk = ~clk), matching real SDRAM timing.
// Models CAS latency for reads via a pipeline.
//
// Memory is stored as a flat byte array, preloadable from test wrappers
// via the mem[] array.
module sdram_model #(
    parameter int ROW_WIDTH  = 11,
    parameter int COL_WIDTH  = 8,
    parameter int BANK_WIDTH = 2,
    parameter int DATA_WIDTH = 32,
    parameter int CAS        = 2
) (
    input  logic                      clk,
    // SDRAM interface (directly wired from controller)
    input  logic                      sdram_clk,
    input  logic                      sdram_cke,
    input  logic                      sdram_cs_n,
    input  logic                      sdram_ras_n,
    input  logic                      sdram_cas_n,
    input  logic                      sdram_we_n,
    input  logic [ROW_WIDTH-1:0]      sdram_addr,
    input  logic [BANK_WIDTH-1:0]     sdram_ba,
    input  logic [DATA_WIDTH/8-1:0]   sdram_dqm,
    // Split DQ
    input  logic [DATA_WIDTH-1:0]     sdram_dq_out,  // data from controller
    input  logic                      sdram_dq_oe,   // controller driving
    output logic [DATA_WIDTH-1:0]     sdram_dq_in    // data to controller
);

    // 8 MB flat byte storage
    localparam int MEM_SIZE = 2 ** 23;  // 8,388,608 bytes
    logic [7:0] mem [0:MEM_SIZE-1];

    // Per-bank active row tracking
    logic [ROW_WIDTH-1:0] active_row [0:3];
    logic                 row_active [0:3];

    // Command decoding
    wire [2:0] cmd_bits = {sdram_ras_n, sdram_cas_n, sdram_we_n};

    localparam logic [2:0] CMD_NOP       = 3'b111;
    localparam logic [2:0] CMD_ACTIVATE  = 3'b011;
    localparam logic [2:0] CMD_READ      = 3'b101;
    localparam logic [2:0] CMD_WRITE     = 3'b100;
    localparam logic [2:0] CMD_PRECHARGE = 3'b010;
    localparam logic [2:0] CMD_REFRESH   = 3'b001;
    localparam logic [2:0] CMD_MRS       = 3'b000;

    // CAS latency read pipeline
    // Each stage holds: {valid, 32-bit data}
    // CAS+1 stages: data enters stage 0 on the same negedge as the READ
    // command, then shifts through CAS more stages — total delay = CAS cycles.
    localparam int PIPE_DEPTH = CAS + 1;
    logic        pipe_valid [0:PIPE_DEPTH-1];
    logic [31:0] pipe_data  [0:PIPE_DEPTH-1];

    // Build a byte address from bank + active row + column
    function automatic [22:0] make_addr(
        input logic [BANK_WIDTH-1:0] bank,
        input logic [ROW_WIDTH-1:0]  row,
        input logic [COL_WIDTH-1:0]  col
    );
        make_addr = {bank, row, col, 2'b00};
    endfunction

    // Read a 32-bit word from the byte array
    function automatic [31:0] read_word(input logic [22:0] byte_addr);
        logic [22:0] base;
        base = {byte_addr[22:2], 2'b00};  // Word-align
        read_word = {mem[base+3], mem[base+2], mem[base+1], mem[base]};
    endfunction

    // Sample on negedge clk = posedge sdram_clk (real SDRAM sampling edge)
    always_ff @(negedge clk) begin
        if (!sdram_cs_n && sdram_cke) begin
            // Advance CAS pipeline
            for (int i = PIPE_DEPTH-1; i > 0; i--) begin
                pipe_valid[i] <= pipe_valid[i-1];
                pipe_data[i]  <= pipe_data[i-1];
            end
            pipe_valid[0] <= 1'b0;
            pipe_data[0]  <= 32'd0;

            case (cmd_bits)
                CMD_ACTIVATE: begin
                    active_row[sdram_ba] <= sdram_addr;
                    row_active[sdram_ba] <= 1'b1;
                end

                CMD_READ: begin
                    // Queue read data into pipeline stage 0
                    if (row_active[sdram_ba]) begin
                        logic [22:0] rd_addr;
                        rd_addr = make_addr(
                            sdram_ba,
                            active_row[sdram_ba],
                            sdram_addr[COL_WIDTH-1:0]
                        );
                        pipe_valid[0] <= 1'b1;
                        pipe_data[0]  <= read_word(rd_addr);
                    end
                    // Auto-precharge if A10 set
                    if (sdram_addr[10])
                        row_active[sdram_ba] <= 1'b0;
                end

                CMD_WRITE: begin
                    if (row_active[sdram_ba]) begin
                        logic [22:0] wr_addr;
                        wr_addr = make_addr(
                            sdram_ba,
                            active_row[sdram_ba],
                            sdram_addr[COL_WIDTH-1:0]
                        );
                        // Apply DQM: 0 = write, 1 = mask (don't write)
                        if (!sdram_dqm[0]) mem[wr_addr]   <= sdram_dq_out[7:0];
                        if (!sdram_dqm[1]) mem[wr_addr+1] <= sdram_dq_out[15:8];
                        if (!sdram_dqm[2]) mem[wr_addr+2] <= sdram_dq_out[23:16];
                        if (!sdram_dqm[3]) mem[wr_addr+3] <= sdram_dq_out[31:24];
                    end
                    // Auto-precharge if A10 set
                    if (sdram_addr[10])
                        row_active[sdram_ba] <= 1'b0;
                end

                CMD_PRECHARGE: begin
                    if (sdram_addr[10]) begin
                        // Precharge all banks
                        for (int i = 0; i < 4; i++)
                            row_active[i] <= 1'b0;
                    end else begin
                        row_active[sdram_ba] <= 1'b0;
                    end
                end

                CMD_MRS: begin
                    // Mode register set — we just accept it
                end

                CMD_REFRESH: begin
                    // Auto-refresh — no action needed in behavioral model
                end

                CMD_NOP: begin
                    // Nothing
                end

                default: ;
            endcase
        end else begin
            // CS high or CKE low — still advance pipeline
            for (int i = PIPE_DEPTH-1; i > 0; i--) begin
                pipe_valid[i] <= pipe_valid[i-1];
                pipe_data[i]  <= pipe_data[i-1];
            end
            pipe_valid[0] <= 1'b0;
            pipe_data[0]  <= 32'd0;
        end
    end

    // Drive DQ output when CAS pipeline delivers data
    always_comb begin
        if (pipe_valid[PIPE_DEPTH-1])
            sdram_dq_in = pipe_data[PIPE_DEPTH-1];
        else
            sdram_dq_in = 32'hZZZZZZZZ;
    end

    // Initialize memory and state
    initial begin
        for (int i = 0; i < MEM_SIZE; i++)
            mem[i] = 8'h00;
        for (int i = 0; i < 4; i++) begin
            active_row[i] = '0;
            row_active[i] = 1'b0;
        end
        for (int i = 0; i < PIPE_DEPTH; i++) begin
            pipe_valid[i] = 1'b0;
            pipe_data[i]  = 32'd0;
        end
    end

endmodule
