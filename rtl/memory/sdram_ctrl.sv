// SDRAM controller — initialization, byte read/write, and auto-refresh.
//
// Drives the embedded 64 Mbit SDRAM in the GW2AR-18 (Tang Nano 20K).
// Provides a simple byte-addressed interface: pulse rd or wr with a
// 23-bit address, wait for data_ready (read) or !busy (write).
//
// At 27 MHz all SDRAM timing constraints are very relaxed (37 ns cycle
// vs 20 ns tRCD/tRP typical). The SDRAM clock is output as ~clk
// (180-degree phase shift) — no PLL required at this frequency.
//
// Address decomposition (23-bit byte address into 32-bit-wide SDRAM):
//   addr[22:21] = bank     (2 bits,  4 banks)
//   addr[20:10] = row      (11 bits, 2048 rows)
//   addr[9:2]   = column   (8 bits,  256 words)
//   addr[1:0]   = byte_off (2 bits,  byte within 32-bit word)
module sdram_ctrl #(
    parameter int FREQ       = 27_000_000,
    parameter int ROW_WIDTH  = 11,
    parameter int COL_WIDTH  = 8,
    parameter int BANK_WIDTH = 2,
    parameter int DATA_WIDTH = 32,
    // Timing parameters (cycles) — tuned for 27 MHz
    parameter int CAS   = 2,   // CAS latency
    parameter int T_WR  = 2,   // Write recovery
    parameter int T_MRD = 2,   // Mode register set delay
    parameter int T_RP  = 1,   // Precharge to activate
    parameter int T_RCD = 1,   // Activate to read/write
    parameter int T_RC  = 2    // Refresh/activate cycle time
) (
    input  logic        clk,
    input  logic        reset,

    // --- User interface ---
    input  logic        rd,           // Pulse: start byte read
    input  logic        wr,           // Pulse: start byte write
    input  logic        refresh,      // Pulse: request auto-refresh
    input  logic [22:0] addr,         // Byte address (8 MB)
    input  logic [7:0]  din,          // Write data (latched on wr)
    output logic [7:0]  dout,         // Read data (valid when data_ready=1)
    output logic        data_ready,   // Pulse: read data available
    output logic        busy,         // 1 = executing a command

    // --- SDRAM physical interface (active accent accent low accent control) ---
    output logic                      sdram_clk,
    output logic                      sdram_cke,
    output logic                      sdram_cs_n,
    output logic                      sdram_ras_n,
    output logic                      sdram_cas_n,
    output logic                      sdram_we_n,
    output logic [ROW_WIDTH-1:0]      sdram_addr,
    output logic [BANK_WIDTH-1:0]     sdram_ba,
    output logic [DATA_WIDTH/8-1:0]   sdram_dqm,
    // Split DQ bus (Verilator-compatible; synthesis wrapper creates tristate)
    output logic [DATA_WIDTH-1:0]     sdram_dq_out,
    output logic                      sdram_dq_oe,
    input  logic [DATA_WIDTH-1:0]     sdram_dq_in
);

    // ---------------------------------------------------------------
    // SDRAM commands encoded as {RAS#, CAS#, WE#}
    // ---------------------------------------------------------------
    localparam logic [2:0] CMD_NOP       = 3'b111;
    localparam logic [2:0] CMD_ACTIVATE  = 3'b011;
    localparam logic [2:0] CMD_READ      = 3'b101;
    localparam logic [2:0] CMD_WRITE     = 3'b100;
    localparam logic [2:0] CMD_PRECHARGE = 3'b010;
    localparam logic [2:0] CMD_REFRESH   = 3'b001;
    localparam logic [2:0] CMD_MRS       = 3'b000;

    // Mode register: CAS=2, burst length=1, sequential, write burst=single
    localparam logic [ROW_WIDTH-1:0] MODE_REG = {4'b0, CAS[2:0], 1'b0, 3'b000};

    // Power-on delay: 200 µs
    localparam int INIT_CYCLES = FREQ / 1_000_000 * 200;

    // ---------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------
    typedef enum logic [2:0] {
        S_INIT,
        S_CONFIG,
        S_IDLE,
        S_READ,
        S_WRITE,
        S_REFRESH
    } state_t;

    state_t state;

    // Cycle counter within current state
    logic [12:0] cycle;   // 13 bits: enough for INIT_CYCLES (5400 at 27 MHz)

    // Latched command parameters
    logic [22:0] addr_buf;
    logic [7:0]  din_buf;
    logic [1:0]  byte_off;  // addr_buf[1:0] latched for read byte select

    // Address decomposition helpers
    wire [BANK_WIDTH-1:0] cmd_bank = addr_buf[22:21];
    wire [ROW_WIDTH-1:0]  cmd_row  = addr_buf[20:10];
    wire [COL_WIDTH-1:0]  cmd_col  = addr_buf[9:2];

    // ---------------------------------------------------------------
    // SDRAM clock: inverted system clock (180° phase shift)
    // ---------------------------------------------------------------
    assign sdram_clk = ~clk;
    assign sdram_cke = 1'b1;

    // ---------------------------------------------------------------
    // Issue an SDRAM command
    // ---------------------------------------------------------------
    logic [2:0] cmd;

    always_comb begin
        sdram_cs_n  = 1'b0;   // Always selected (single chip)
        sdram_ras_n = cmd[2];
        sdram_cas_n = cmd[1];
        sdram_we_n  = cmd[0];
    end

    // ---------------------------------------------------------------
    // Config sub-sequence timing
    // ---------------------------------------------------------------
    localparam int CFG_PRECHARGE = 0;
    localparam int CFG_REFRESH1  = CFG_PRECHARGE + T_RP;
    localparam int CFG_REFRESH2  = CFG_REFRESH1 + T_RC;
    localparam int CFG_MRS       = CFG_REFRESH2 + T_RC;
    localparam int CFG_DONE      = CFG_MRS + T_MRD;

    // ---------------------------------------------------------------
    // Read/Write timing offsets
    // ---------------------------------------------------------------
    localparam int RD_ACTIVATE   = 0;
    localparam int RD_CMD        = RD_ACTIVATE + T_RCD;
    localparam int RD_DATA       = RD_CMD + CAS;
    localparam int RD_DONE       = RD_DATA + 1;

    localparam int WR_ACTIVATE   = 0;
    localparam int WR_CMD        = WR_ACTIVATE + T_RCD;
    localparam int WR_DONE       = WR_CMD + 1 + T_WR + T_RP;

    localparam int REF_DONE      = T_RC;

    // ---------------------------------------------------------------
    // Main FSM
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= S_INIT;
            cycle      <= 13'd0;
            busy       <= 1'b1;
            data_ready <= 1'b0;
            dout       <= 8'd0;
            cmd        <= CMD_NOP;
            sdram_addr <= '0;
            sdram_ba   <= '0;
            sdram_dqm  <= '0;
            sdram_dq_out <= '0;
            sdram_dq_oe  <= 1'b0;
            addr_buf   <= '0;
            din_buf    <= '0;
            byte_off   <= '0;
        end else begin
            // Defaults each cycle
            cmd        <= CMD_NOP;
            data_ready <= 1'b0;
            sdram_dq_oe <= 1'b0;
            sdram_dqm  <= 4'b0000;

            case (state)
                // ---------------------------------------------------
                // Power-on delay: wait 200 µs
                // ---------------------------------------------------
                S_INIT: begin
                    if (cycle == INIT_CYCLES[12:0]) begin
                        state <= S_CONFIG;
                        cycle <= 13'd0;
                    end else begin
                        cycle <= cycle + 13'd1;
                    end
                end

                // ---------------------------------------------------
                // Configuration: Precharge All → 2× Refresh → MRS
                // ---------------------------------------------------
                S_CONFIG: begin
                    cycle <= cycle + 13'd1;

                    if (cycle == CFG_PRECHARGE[12:0]) begin
                        cmd <= CMD_PRECHARGE;
                        sdram_addr[10] <= 1'b1;  // All banks
                    end

                    if (cycle == CFG_REFRESH1[12:0]) begin
                        cmd <= CMD_REFRESH;
                    end

                    if (cycle == CFG_REFRESH2[12:0]) begin
                        cmd <= CMD_REFRESH;
                    end

                    if (cycle == CFG_MRS[12:0]) begin
                        cmd <= CMD_MRS;
                        sdram_addr <= MODE_REG;
                        sdram_ba   <= '0;
                    end

                    if (cycle == CFG_DONE[12:0]) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                    end
                end

                // ---------------------------------------------------
                // Idle: accept commands
                // ---------------------------------------------------
                S_IDLE: begin
                    if (rd) begin
                        state    <= S_READ;
                        cycle    <= 13'd0;
                        busy     <= 1'b1;
                        addr_buf <= addr;
                        byte_off <= addr[1:0];
                    end else if (wr) begin
                        state    <= S_WRITE;
                        cycle    <= 13'd0;
                        busy     <= 1'b1;
                        addr_buf <= addr;
                        din_buf  <= din;
                    end else if (refresh) begin
                        state <= S_REFRESH;
                        cycle <= 13'd0;
                        busy  <= 1'b1;
                    end
                end

                // ---------------------------------------------------
                // Read: Activate → Read (auto-precharge) → CAS → data
                // ---------------------------------------------------
                S_READ: begin
                    cycle <= cycle + 13'd1;

                    if (cycle == RD_ACTIVATE[12:0]) begin
                        cmd        <= CMD_ACTIVATE;
                        sdram_ba   <= cmd_bank;
                        sdram_addr <= cmd_row;
                    end

                    if (cycle == RD_CMD[12:0]) begin
                        cmd        <= CMD_READ;
                        sdram_ba   <= cmd_bank;
                        sdram_addr <= '0;
                        sdram_addr[10]            <= 1'b1;  // Auto-precharge
                        sdram_addr[COL_WIDTH-1:0] <= cmd_col;
                        sdram_dqm  <= 4'b0000;  // Read all bytes
                    end

                    if (cycle == RD_DATA[12:0]) begin
                        data_ready <= 1'b1;
                        // Select the requested byte from the 32-bit word
                        case (byte_off)
                            2'd0: dout <= sdram_dq_in[7:0];
                            2'd1: dout <= sdram_dq_in[15:8];
                            2'd2: dout <= sdram_dq_in[23:16];
                            2'd3: dout <= sdram_dq_in[31:24];
                        endcase
                    end

                    if (cycle == RD_DONE[12:0]) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                    end
                end

                // ---------------------------------------------------
                // Write: Activate → Write (auto-precharge) → recovery
                // ---------------------------------------------------
                S_WRITE: begin
                    cycle <= cycle + 13'd1;

                    if (cycle == WR_ACTIVATE[12:0]) begin
                        cmd        <= CMD_ACTIVATE;
                        sdram_ba   <= cmd_bank;
                        sdram_addr <= cmd_row;
                    end

                    if (cycle == WR_CMD[12:0]) begin
                        cmd        <= CMD_WRITE;
                        sdram_ba   <= cmd_bank;
                        sdram_addr <= '0;
                        sdram_addr[10]            <= 1'b1;  // Auto-precharge
                        sdram_addr[COL_WIDTH-1:0] <= cmd_col;
                        // Broadcast data, mask selects the target byte
                        sdram_dq_out <= {din_buf, din_buf, din_buf, din_buf};
                        sdram_dq_oe  <= 1'b1;
                        case (addr_buf[1:0])
                            2'd0: sdram_dqm <= 4'b1110;
                            2'd1: sdram_dqm <= 4'b1101;
                            2'd2: sdram_dqm <= 4'b1011;
                            2'd3: sdram_dqm <= 4'b0111;
                        endcase
                    end

                    // Deassert DQ drive after one cycle
                    if (cycle == WR_CMD[12:0] + 13'd1) begin
                        sdram_dq_oe <= 1'b0;
                    end

                    if (cycle == WR_DONE[12:0]) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                    end
                end

                // ---------------------------------------------------
                // Refresh: Auto-refresh → wait T_RC
                // ---------------------------------------------------
                S_REFRESH: begin
                    cycle <= cycle + 13'd1;

                    if (cycle == 13'd0) begin
                        cmd <= CMD_REFRESH;
                    end

                    if (cycle == REF_DONE[12:0]) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                    end
                end

                default: state <= S_INIT;
            endcase
        end
    end

endmodule
