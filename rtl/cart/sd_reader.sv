// SD card reader — initialization and single-block sector read.
//
// Handles the SD card SPI initialization sequence (CMD0, CMD8,
// ACMD41, CMD58, CMD16) and provides a sector-level read interface.
// Supports both SDHC (sector addressing) and SDSC (byte addressing).
module sd_reader (
    input  logic        clk,
    input  logic        reset,

    // sd_spi byte interface
    output logic [7:0]  spi_tx,
    output logic        spi_start,
    input  logic [7:0]  spi_rx,
    input  logic        spi_busy,
    input  logic        spi_done,
    output logic        spi_cs_en,
    output logic        spi_slow_clk,

    // Sector read interface
    input  logic [31:0] sector,
    input  logic        read_start,
    output logic [7:0]  read_data,
    output logic        read_valid,   // pulse per byte (512 per sector)
    output logic        read_done,    // pulse when sector complete
    output logic        ready,        // card initialized, idle
    output logic        err,          // init failed
    output logic        sdhc          // 1 = SDHC (sector addr), 0 = SDSC (byte addr)
);

    // --- State machine ---
    typedef enum logic [3:0] {
        S_POWER_UP,
        S_SEND_CMD,
        S_WAIT_RESP,
        S_CMD8_TAIL,
        S_WAIT_TOKEN,
        S_READ_DATA,
        S_READ_CRC,
        S_FINISH_CMD,
        S_READY,
        S_ERROR
    } state_t;

    state_t state;

    // Which command sequence step we're on
    typedef enum logic [2:0] {
        STEP_CMD0,
        STEP_CMD8,
        STEP_CMD55,
        STEP_ACMD41,
        STEP_CMD58,
        STEP_CMD16,
        STEP_CMD17
    } step_t;

    step_t step;

    // Command buffer and send index
    logic [47:0] cmd_buf;
    logic [2:0]  send_idx;     // 0-5 = sending command bytes

    // Counters
    logic [3:0]  powerup_cnt;  // 0-10 power-up bytes
    logic [15:0] poll_cnt;     // response/token poll attempts
    logic [2:0]  tail_cnt;     // remaining R7 bytes
    logic [9:0]  data_cnt;     // 0-511 data bytes
    logic        crc_cnt;      // 0-1 CRC bytes
    logic [15:0] retry_cnt;    // ACMD41 retry counter

    // Build a 6-byte SD command: {01,index[5:0]} + arg[31:0] + crc[7:0]
    function automatic [47:0] make_cmd(
        input logic [5:0] idx,
        input logic [31:0] arg,
        input logic [7:0] crc
    );
        make_cmd = {2'b01, idx, arg, crc};
    endfunction

    // Flag: need to start an SPI byte this cycle
    logic do_send;
    logic [7:0] do_send_data;

    always_ff @(posedge clk) begin
        if (reset) begin
            state        <= S_POWER_UP;
            step         <= STEP_CMD0;
            spi_tx       <= 8'hFF;
            spi_start    <= 1'b0;
            spi_cs_en    <= 1'b0;
            spi_slow_clk <= 1'b1;
            ready        <= 1'b0;
            err          <= 1'b0;
            sdhc         <= 1'b0;
            read_valid   <= 1'b0;
            read_done    <= 1'b0;
            read_data    <= 8'h00;
            powerup_cnt  <= 4'd0;
            retry_cnt    <= 16'd0;
        end else begin
            spi_start  <= 1'b0;
            read_valid <= 1'b0;
            read_done  <= 1'b0;

            case (state)
                // -------------------------------------------------------
                // Power-up: send 10 bytes of 0xFF with CS high (80 clocks)
                // -------------------------------------------------------
                S_POWER_UP: begin
                    spi_cs_en <= 1'b0; // CS high
                    if (!spi_busy && !spi_start) begin
                        if (powerup_cnt == 4'd10) begin
                            // Start CMD0
                            step    <= STEP_CMD0;
                            cmd_buf <= make_cmd(6'd0, 32'h0, 8'h95);
                            state   <= S_SEND_CMD;
                            send_idx <= 3'd0;
                            spi_cs_en <= 1'b1;
                        end else begin
                            spi_tx    <= 8'hFF;
                            spi_start <= 1'b1;
                            powerup_cnt <= powerup_cnt + 4'd1;
                        end
                    end
                end

                // -------------------------------------------------------
                // Send 6 command bytes from cmd_buf
                // -------------------------------------------------------
                S_SEND_CMD: begin
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= cmd_buf[47:40];
                        spi_start <= 1'b1;
                        cmd_buf   <= {cmd_buf[39:0], 8'h00};
                        if (send_idx == 3'd5) begin
                            state    <= S_WAIT_RESP;
                            poll_cnt <= 16'd0;
                        end else begin
                            send_idx <= send_idx + 3'd1;
                        end
                    end
                end

                // -------------------------------------------------------
                // Poll for R1 response (first byte with bit 7 = 0)
                // -------------------------------------------------------
                S_WAIT_RESP: begin
                    if (spi_done) begin
                        if (spi_rx[7] == 1'b0) begin
                            // Got R1 response — dispatch based on step
                            case (step)
                                STEP_CMD0: begin
                                    if (spi_rx == 8'h01) begin
                                        // Idle — send CMD8
                                        state   <= S_FINISH_CMD;
                                    end else
                                        state <= S_ERROR;
                                end
                                STEP_CMD8: begin
                                    // Read 4 more R7 bytes
                                    tail_cnt <= 3'd4;
                                    state    <= S_CMD8_TAIL;
                                end
                                STEP_CMD55: begin
                                    // Proceed to ACMD41
                                    state <= S_FINISH_CMD;
                                end
                                STEP_ACMD41: begin
                                    if (spi_rx == 8'h00) begin
                                        // Ready — send CMD16
                                        retry_cnt <= 16'd0;
                                        state <= S_FINISH_CMD;
                                    end else if (spi_rx == 8'h01) begin
                                        // Still initializing, retry
                                        retry_cnt <= retry_cnt + 16'd1;
                                        if (retry_cnt > 16'd10000)
                                            state <= S_ERROR;
                                        else
                                            state <= S_FINISH_CMD;
                                    end else
                                        state <= S_ERROR;
                                end
                                STEP_CMD58: begin
                                    if (spi_rx == 8'h00) begin
                                        // Read 4 OCR bytes
                                        tail_cnt <= 3'd4;
                                        state    <= S_CMD8_TAIL;
                                    end else
                                        state <= S_ERROR;
                                end
                                STEP_CMD16: begin
                                    // Done — switch to fast clock, ready
                                    spi_cs_en    <= 1'b0;
                                    spi_slow_clk <= 1'b0;
                                    ready        <= 1'b1;
                                    state        <= S_READY;
                                end
                                STEP_CMD17: begin
                                    if (spi_rx == 8'h00) begin
                                        // Wait for data token
                                        poll_cnt <= 16'd0;
                                        state    <= S_WAIT_TOKEN;
                                    end else
                                        state <= S_ERROR;
                                end
                                default: state <= S_ERROR;
                            endcase
                        end else if (poll_cnt < 16'd255) begin
                            poll_cnt  <= poll_cnt + 16'd1;
                        end else begin
                            state <= S_ERROR;
                        end
                    end
                    // Keep clocking to receive response
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                // Read remaining R7 bytes (CMD8 response tail)
                // -------------------------------------------------------
                S_CMD8_TAIL: begin
                    if (spi_done) begin
                        // Capture CCS bit from first OCR byte (CMD58)
                        if (step == STEP_CMD58 && tail_cnt == 3'd4)
                            sdhc <= spi_rx[6];
                        if (tail_cnt == 3'd1)
                            state <= S_FINISH_CMD;
                        else
                            tail_cnt <= tail_cnt - 3'd1;
                    end
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                // Deassert CS, then start next command
                // -------------------------------------------------------
                S_FINISH_CMD: begin
                    spi_cs_en <= 1'b0;
                    if (!spi_busy) begin
                        case (step)
                            STEP_CMD0: begin
                                step    <= STEP_CMD8;
                                cmd_buf <= make_cmd(6'd8, 32'h0000_01AA, 8'h87);
                                send_idx <= 3'd0;
                                spi_cs_en <= 1'b1;
                                state   <= S_SEND_CMD;
                            end
                            STEP_CMD8: begin
                                step    <= STEP_CMD55;
                                cmd_buf <= make_cmd(6'd55, 32'h0, 8'hFF);
                                send_idx <= 3'd0;
                                spi_cs_en <= 1'b1;
                                state   <= S_SEND_CMD;
                            end
                            STEP_CMD55: begin
                                step    <= STEP_ACMD41;
                                cmd_buf <= make_cmd(6'd41, 32'h4000_0000, 8'hFF);
                                send_idx <= 3'd0;
                                spi_cs_en <= 1'b1;
                                state   <= S_SEND_CMD;
                            end
                            STEP_ACMD41: begin
                                if (retry_cnt > 16'd0 && ready == 1'b0) begin
                                    // Need to retry — back to CMD55
                                    step    <= STEP_CMD55;
                                    cmd_buf <= make_cmd(6'd55, 32'h0, 8'hFF);
                                    send_idx <= 3'd0;
                                    spi_cs_en <= 1'b1;
                                    state   <= S_SEND_CMD;
                                end else begin
                                    // ACMD41 returned 0x00 — send CMD58 to check SDHC/SDSC
                                    step    <= STEP_CMD58;
                                    cmd_buf <= make_cmd(6'd58, 32'h0, 8'hFF);
                                    send_idx <= 3'd0;
                                    spi_cs_en <= 1'b1;
                                    state   <= S_SEND_CMD;
                                end
                            end
                            STEP_CMD58: begin
                                // CMD58 done — send CMD16 (set block size 512)
                                step    <= STEP_CMD16;
                                cmd_buf <= make_cmd(6'd16, 32'h0000_0200, 8'hFF);
                                send_idx <= 3'd0;
                                spi_cs_en <= 1'b1;
                                state   <= S_SEND_CMD;
                            end
                            default: state <= S_ERROR;
                        endcase
                    end
                end

                // -------------------------------------------------------
                // Ready — idle, waiting for read_start
                // -------------------------------------------------------
                S_READY: begin
                    if (read_start) begin
                        step     <= STEP_CMD17;
                        send_idx <= 3'd0;
                        spi_cs_en <= 1'b1;
                        state    <= S_SEND_CMD;
                        // SDHC: sector addressing, SDSC: byte addressing (sector * 512)
                        if (sdhc)
                            cmd_buf <= make_cmd(6'd17, sector, 8'hFF);
                        else
                            cmd_buf <= make_cmd(6'd17, {sector[22:0], 9'd0}, 8'hFF);
                    end
                end

                // -------------------------------------------------------
                // Wait for data start token (0xFE)
                // -------------------------------------------------------
                S_WAIT_TOKEN: begin
                    if (spi_done) begin
                        if (spi_rx == 8'hFE) begin
                            data_cnt <= 10'd0;
                            state    <= S_READ_DATA;
                        end else if (poll_cnt < 16'd65535) begin
                            poll_cnt <= poll_cnt + 16'd1;
                        end else begin
                            state <= S_ERROR;
                        end
                    end
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                // Read 512 data bytes
                // -------------------------------------------------------
                S_READ_DATA: begin
                    if (spi_done) begin
                        read_data  <= spi_rx;
                        read_valid <= 1'b1;
                        if (data_cnt == 10'd511) begin
                            crc_cnt <= 1'b0;
                            state   <= S_READ_CRC;
                        end else begin
                            data_cnt <= data_cnt + 10'd1;
                        end
                    end
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                // Read 2 CRC bytes (discarded)
                // -------------------------------------------------------
                S_READ_CRC: begin
                    if (spi_done) begin
                        if (crc_cnt) begin
                            spi_cs_en <= 1'b0;
                            read_done <= 1'b1;
                            state     <= S_READY;
                        end else begin
                            crc_cnt <= 1'b1;
                        end
                    end
                    if (!spi_busy && !spi_start) begin
                        spi_tx    <= 8'hFF;
                        spi_start <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                S_ERROR: begin
                    spi_cs_en <= 1'b0;
                    err       <= 1'b1;
                end

                default: state <= S_ERROR;
            endcase
        end
    end

endmodule
