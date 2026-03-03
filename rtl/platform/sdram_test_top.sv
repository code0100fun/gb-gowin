// SDRAM hardware test — write patterns, read back, verify, report over UART.
//
// Uses the Tang Nano 20K's embedded 64 Mbit SDRAM (GW2AR-18 MCM).
// Tests single byte, DQM byte offsets, and 1 MB block write/verify.
// Interleaves refresh every ~400 cycles during block test.
//
// UART output (115200 baud):
//   >    Boot started
//   1    Test 1 pass (single byte write/read)
//   2    Test 2 pass (4 byte offsets)
//   3    Test 3 pass (1 MB block write/verify)
//   OK   All tests passed
//   !N   Test N failed
//
// Flash and test:
//   mise run flash -- sdram_test_top
//   picocom -b 115200 /dev/ttyUSB1
//   (press S1 to reset and re-test)
module sdram_test_top (
    input  logic        clk,        // 27 MHz
    input  logic        btn_s1,     // reset / re-test
    input  logic        btn_s2,     // unused
    output logic [5:0]  led,        // onboard LEDs (active low)

    // UART
    output logic        uart_tx,
    input  logic        uart_rx,    // unused

    // SDRAM (physical pins — "magic" names for open-source toolchain)
    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_wen_n,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    output logic [3:0]  O_sdram_dqm,
    inout  logic [31:0] IO_sdram_dq
);

    // ---------------------------------------------------------------
    // Power-on reset (btn_s1 re-asserts)
    // ---------------------------------------------------------------
    logic [4:0] por_cnt;
    always_ff @(posedge clk) begin
        if (btn_s1)
            por_cnt <= 5'd0;
        else if (!por_cnt[4])
            por_cnt <= por_cnt + 5'd1;
    end
    wire reset = !por_cnt[4];

    // ---------------------------------------------------------------
    // SDRAM controller (split DQ — synthesis tristate below)
    // ---------------------------------------------------------------
    logic [31:0] sdram_dq_out, sdram_dq_in;
    logic        sdram_dq_oe;
    logic        sdram_rd, sdram_wr, sdram_refresh;
    logic [22:0] sdram_a;
    logic [7:0]  sdram_din, sdram_dout;
    logic        sdram_data_ready, sdram_busy;

    sdram_ctrl u_sdram (
        .clk(clk), .reset(reset),
        .rd(sdram_rd), .wr(sdram_wr), .refresh(sdram_refresh),
        .addr(sdram_a), .din(sdram_din),
        .dout(sdram_dout), .data_ready(sdram_data_ready), .busy(sdram_busy),
        .sdram_clk(O_sdram_clk), .sdram_cke(O_sdram_cke),
        .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
        .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n),
        .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba),
        .sdram_dqm(O_sdram_dqm),
        .sdram_dq_out(sdram_dq_out), .sdram_dq_oe(sdram_dq_oe),
        .sdram_dq_in(sdram_dq_in)
    );

    // Synthesis tristate for SDRAM data bus
    assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 32'bZ;
    assign sdram_dq_in = IO_sdram_dq;

    // ---------------------------------------------------------------
    // UART TX
    // ---------------------------------------------------------------
    logic [7:0] tx_byte;
    logic       tx_valid, tx_ready;

    uart_tx u_uart (
        .clk(clk), .reset(reset),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready),
        .tx(uart_tx)
    );

    // ---------------------------------------------------------------
    // Refresh timer (~400 cycles at 27 MHz)
    // ---------------------------------------------------------------
    logic [8:0] ref_timer;
    logic       ref_needed;

    always_ff @(posedge clk) begin
        if (reset) begin
            ref_timer  <= 9'd0;
            ref_needed <= 1'b0;
        end else begin
            if (ref_timer == 9'd400) begin
                ref_timer  <= 9'd0;
                ref_needed <= 1'b1;
            end else begin
                ref_timer <= ref_timer + 9'd1;
            end
            if (sdram_refresh)
                ref_needed <= 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Test FSM
    // ---------------------------------------------------------------
    typedef enum logic [4:0] {
        S_PRINT_CHAR,    // Print pending_char, goto return_state
        S_PRINT_ERR2,    // Print err_char2, goto S_ERROR
        S_INIT_WAIT,     // Wait for SDRAM init
        S_T1_WR,         // Test 1: write 0xAB to addr 0
        S_T1_WR_WAIT,
        S_T1_RD,         // Test 1: read addr 0
        S_T1_RD_WAIT,
        S_T2_WR,         // Test 2: write byte offset (sub_idx 0-3)
        S_T2_WR_WAIT,
        S_T2_RD,         // Test 2: read byte offset
        S_T2_RD_WAIT,
        S_T3_WR,         // Test 3: block write (0 to 1M-1)
        S_T3_WR_WAIT,
        S_T3_RD,         // Test 3: block read
        S_T3_RD_WAIT,
        S_T3_DONE,       // Report block results
        S_REFRESH,       // Issue refresh
        S_REFRESH_WAIT,
        S_OK,            // Print "OK\r\n"
        S_IDLE,
        S_ERROR
    } state_t;

    state_t state, return_state, refresh_return;
    logic [7:0]  pending_char, err_char2;
    logic        skip_busy;      // Skip first !busy check after command
    logic [1:0]  sub_idx;        // Test 2: byte offset 0-3
    logic [19:0] blk_addr;       // Test 3: block address counter
    logic [15:0] err_count;      // Test 3: error counter
    logic [2:0]  ok_idx;         // "OK\r\n" output index

    // Test 2 expected data values
    function automatic [7:0] t2_data(input [1:0] idx);
        case (idx)
            2'd0: t2_data = 8'h11;
            2'd1: t2_data = 8'h22;
            2'd2: t2_data = 8'h33;
            2'd3: t2_data = 8'h44;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_PRINT_CHAR;
            return_state   <= S_INIT_WAIT;
            refresh_return <= S_INIT_WAIT;
            pending_char   <= ">";
            err_char2      <= 8'd0;
            sdram_rd       <= 1'b0;
            sdram_wr       <= 1'b0;
            sdram_refresh  <= 1'b0;
            sdram_a        <= 23'd0;
            sdram_din      <= 8'd0;
            tx_valid       <= 1'b0;
            skip_busy      <= 1'b0;
            sub_idx        <= 2'd0;
            blk_addr       <= 20'd0;
            err_count      <= 16'd0;
            ok_idx         <= 3'd0;
        end else begin
            // Defaults each cycle
            sdram_rd      <= 1'b0;
            sdram_wr      <= 1'b0;
            sdram_refresh <= 1'b0;
            tx_valid      <= 1'b0;

            case (state)
                // =============================================================
                // Reusable print states
                // =============================================================
                S_PRINT_CHAR: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= pending_char;
                        tx_valid <= 1'b1;
                        state    <= return_state;
                    end
                end

                S_PRINT_ERR2: begin
                    if (tx_ready && !tx_valid) begin
                        tx_byte  <= err_char2;
                        tx_valid <= 1'b1;
                        state    <= S_ERROR;
                    end
                end

                // =============================================================
                // Wait for SDRAM init (power-on + config)
                // =============================================================
                S_INIT_WAIT: begin
                    if (!sdram_busy)
                        state <= S_T1_WR;
                end

                // =============================================================
                // Test 1: Single byte write/read at address 0
                // =============================================================
                S_T1_WR: begin
                    sdram_a   <= 23'h000000;
                    sdram_din <= 8'hAB;
                    sdram_wr  <= 1'b1;
                    skip_busy <= 1'b1;
                    state     <= S_T1_WR_WAIT;
                end

                S_T1_WR_WAIT: begin
                    if (skip_busy)
                        skip_busy <= 1'b0;
                    else if (!sdram_busy)
                        state <= S_T1_RD;
                end

                S_T1_RD: begin
                    sdram_a  <= 23'h000000;
                    sdram_rd <= 1'b1;
                    state    <= S_T1_RD_WAIT;
                end

                S_T1_RD_WAIT: begin
                    if (sdram_data_ready) begin
                        if (sdram_dout == 8'hAB) begin
                            pending_char <= "1";
                            return_state <= S_T2_WR;
                            sub_idx      <= 2'd0;
                            state        <= S_PRINT_CHAR;
                        end else begin
                            pending_char <= "!";
                            err_char2    <= "1";
                            return_state <= S_PRINT_ERR2;
                            state        <= S_PRINT_CHAR;
                        end
                    end
                end

                // =============================================================
                // Test 2: Four byte offsets (DQM masking)
                // =============================================================
                S_T2_WR: begin
                    sdram_a   <= 23'h000100 + {21'd0, sub_idx};
                    sdram_din <= t2_data(sub_idx);
                    sdram_wr  <= 1'b1;
                    skip_busy <= 1'b1;
                    state     <= S_T2_WR_WAIT;
                end

                S_T2_WR_WAIT: begin
                    if (skip_busy)
                        skip_busy <= 1'b0;
                    else if (!sdram_busy) begin
                        if (sub_idx == 2'd3) begin
                            sub_idx <= 2'd0;
                            state   <= S_T2_RD;
                        end else begin
                            sub_idx <= sub_idx + 2'd1;
                            state   <= S_T2_WR;
                        end
                    end
                end

                S_T2_RD: begin
                    sdram_a  <= 23'h000100 + {21'd0, sub_idx};
                    sdram_rd <= 1'b1;
                    state    <= S_T2_RD_WAIT;
                end

                S_T2_RD_WAIT: begin
                    if (sdram_data_ready) begin
                        if (sdram_dout != t2_data(sub_idx)) begin
                            pending_char <= "!";
                            err_char2    <= "2";
                            return_state <= S_PRINT_ERR2;
                            state        <= S_PRINT_CHAR;
                        end else if (sub_idx == 2'd3) begin
                            pending_char <= "2";
                            return_state <= S_T3_WR;
                            blk_addr     <= 20'd0;
                            state        <= S_PRINT_CHAR;
                        end else begin
                            sub_idx <= sub_idx + 2'd1;
                            state   <= S_T2_RD;
                        end
                    end
                end

                // =============================================================
                // Test 3: 1 MB block write/read/verify
                // =============================================================
                S_T3_WR: begin
                    if (ref_needed) begin
                        refresh_return <= S_T3_WR;
                        state          <= S_REFRESH;
                    end else begin
                        sdram_a   <= {3'd0, blk_addr};
                        sdram_din <= blk_addr[7:0];
                        sdram_wr  <= 1'b1;
                        skip_busy <= 1'b1;
                        state     <= S_T3_WR_WAIT;
                    end
                end

                S_T3_WR_WAIT: begin
                    if (skip_busy)
                        skip_busy <= 1'b0;
                    else if (!sdram_busy) begin
                        if (blk_addr == 20'hFFFFF) begin
                            blk_addr  <= 20'd0;
                            err_count <= 16'd0;
                            state     <= S_T3_RD;
                        end else begin
                            blk_addr <= blk_addr + 20'd1;
                            state    <= S_T3_WR;
                        end
                    end
                end

                S_T3_RD: begin
                    if (ref_needed) begin
                        refresh_return <= S_T3_RD;
                        state          <= S_REFRESH;
                    end else begin
                        sdram_a  <= {3'd0, blk_addr};
                        sdram_rd <= 1'b1;
                        state    <= S_T3_RD_WAIT;
                    end
                end

                S_T3_RD_WAIT: begin
                    if (sdram_data_ready) begin
                        if (sdram_dout != blk_addr[7:0])
                            err_count <= err_count + 16'd1;
                        if (blk_addr == 20'hFFFFF)
                            state <= S_T3_DONE;
                        else begin
                            blk_addr <= blk_addr + 20'd1;
                            state    <= S_T3_RD;
                        end
                    end
                end

                S_T3_DONE: begin
                    if (err_count == 16'd0) begin
                        pending_char <= "3";
                        return_state <= S_OK;
                        ok_idx       <= 3'd0;
                        state        <= S_PRINT_CHAR;
                    end else begin
                        pending_char <= "!";
                        err_char2    <= "3";
                        return_state <= S_PRINT_ERR2;
                        state        <= S_PRINT_CHAR;
                    end
                end

                // =============================================================
                // Refresh (detour during block test)
                // =============================================================
                S_REFRESH: begin
                    sdram_refresh <= 1'b1;
                    skip_busy     <= 1'b1;
                    state         <= S_REFRESH_WAIT;
                end

                S_REFRESH_WAIT: begin
                    if (skip_busy)
                        skip_busy <= 1'b0;
                    else if (!sdram_busy)
                        state <= refresh_return;
                end

                // =============================================================
                // Results
                // =============================================================
                S_OK: begin
                    if (tx_ready && !tx_valid) begin
                        case (ok_idx)
                            3'd0: tx_byte <= "O";
                            3'd1: tx_byte <= "K";
                            3'd2: tx_byte <= 8'h0D;
                            3'd3: tx_byte <= 8'h0A;
                            default: tx_byte <= 8'h00;
                        endcase
                        tx_valid <= 1'b1;
                        if (ok_idx == 3'd3)
                            state <= S_IDLE;
                        else
                            ok_idx <= ok_idx + 3'd1;
                    end
                end

                S_IDLE: begin
                    // Done — press btn_s1 to re-test
                end

                S_ERROR: begin
                    // Error — press btn_s1 to retry
                end

                default: state <= S_ERROR;
            endcase
        end
    end

    // LEDs: progress indicator (active low)
    always_comb begin
        case (state)
            S_ERROR:                    led = 6'b000000;       // All on
            S_IDLE:                     led = 6'b101010;       // Alternating
            S_T3_WR, S_T3_WR_WAIT:     led = ~blk_addr[19:14]; // Write progress
            S_T3_RD, S_T3_RD_WAIT:     led = ~blk_addr[19:14]; // Read progress
            default:                    led = ~{1'b0, state};
        endcase
    end

endmodule
