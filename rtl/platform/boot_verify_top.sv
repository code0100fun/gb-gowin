// SD boot → SDRAM readback verification.
//
// Loads a .gb ROM from SD card into SDRAM (via sd_boot), then reads back
// the Nintendo logo bytes (ROM offset 0x0104–0x0113) and outputs them
// via UART. Compares against the known logo and reports PASS/FAIL.
//
// UART output (115200 baud):
//   >MmVvRr.D                                   (boot progress)
//   CE ED 66 66 CC 0D 00 0B 03 73 00 83 00 0C 00 0D OK   (logo match)
//   XX XX XX ... FAIL                            (logo mismatch)
//
// LEDs: boot progress during boot, all ON = PASS, all OFF = FAIL.
module boot_verify_top (
    input  logic        clk,        // 27 MHz
    input  logic        btn_s1,     // reset
    input  logic        btn_s2,     // unused
    output logic [5:0]  led,

    // LCD (unused — tie to safe defaults for constraints compatibility)
    output logic        lcd_rst,
    output logic        lcd_cs,
    output logic        lcd_dc,
    output logic        lcd_sclk,
    output logic        lcd_mosi,
    output logic        lcd_bl,

    // SD card
    output logic        sd_clk,
    output logic        sd_cmd,
    input  logic        sd_dat0,
    output logic        sd_dat1,
    output logic        sd_dat2,
    output logic        sd_dat3,

    // Joypad (unused)
    input  logic        btn_right,
    input  logic        btn_left,
    input  logic        btn_up,
    input  logic        btn_down,
    input  logic        btn_a,
    input  logic        btn_b,
    input  logic        btn_select,
    input  logic        btn_start,

    // UART
    output logic        uart_tx,
    input  logic        uart_rx,

    // SDRAM
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

    // LCD — unused, safe defaults
    assign lcd_rst  = 1'b1;
    assign lcd_cs   = 1'b1;
    assign lcd_dc   = 1'b0;
    assign lcd_sclk = 1'b0;
    assign lcd_mosi = 1'b0;
    assign lcd_bl   = 1'b0;

    // ---------------------------------------------------------------
    // Power-on reset
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
    // SDRAM controller
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

    assign IO_sdram_dq = sdram_dq_oe ? sdram_dq_out : 32'bZ;
    assign sdram_dq_in = IO_sdram_dq;

    // ---------------------------------------------------------------
    // Refresh timer (~400 cycles)
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
    // SD boot — loads ROM from SD card into SDRAM
    // ---------------------------------------------------------------
    logic [7:0]  spi_tx, spi_rx;
    logic        spi_start, spi_busy, spi_done;
    logic        spi_cs_en, spi_slow_clk;
    logic        spi_sclk, spi_mosi, spi_miso, spi_cs_n;

    logic [31:0] sd_sector;
    logic        sd_read_start;
    logic [7:0]  sd_read_data;
    logic        sd_read_valid, sd_read_done;
    logic        sd_ready, sd_err;

    logic [22:0] sd_rom_addr;
    logic [7:0]  sd_rom_data;
    logic        sd_rom_wr;
    logic        boot_done, sd_boot_error;
    logic [2:0]  sd_error_code;
    logic [3:0]  sd_boot_state;

    sd_spi u_sd_spi (
        .clk(clk), .reset(reset),
        .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
        .tx_data(spi_tx), .start(spi_start), .rx_data(spi_rx),
        .busy(spi_busy), .done(spi_done),
        .cs_en(spi_cs_en), .slow_clk(spi_slow_clk)
    );

    sd_reader u_sd_reader (
        .clk(clk), .reset(reset),
        .spi_tx(spi_tx), .spi_start(spi_start),
        .spi_rx(spi_rx), .spi_busy(spi_busy), .spi_done(spi_done),
        .spi_cs_en(spi_cs_en), .spi_slow_clk(spi_slow_clk),
        .sector(sd_sector), .read_start(sd_read_start),
        .read_data(sd_read_data), .read_valid(sd_read_valid),
        .read_done(sd_read_done), .ready(sd_ready),
        .err(sd_err), .sdhc()
    );

    sd_boot u_sd_boot (
        .clk(clk), .reset(reset),
        .sd_sector(sd_sector), .sd_read_start(sd_read_start),
        .sd_read_data(sd_read_data), .sd_read_valid(sd_read_valid),
        .sd_read_done(sd_read_done), .sd_ready(sd_ready),
        .sd_error(sd_err),
        .rom_addr(sd_rom_addr), .rom_data(sd_rom_data), .rom_wr(sd_rom_wr),
        .sdram_busy(sdram_busy),
        .done(boot_done), .boot_error(sd_boot_error),
        .error_code(sd_error_code), .dbg_state(sd_boot_state)
    );

    // SD card pin assignments
    assign sd_clk  = spi_sclk;
    assign sd_cmd  = spi_mosi;
    assign spi_miso = sd_dat0;
    assign sd_dat3 = spi_cs_n;
    assign sd_dat1 = 1'b1;
    assign sd_dat2 = 1'b1;

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
    // Boot char queue — populated by boot state monitor, drained by FSM
    // ---------------------------------------------------------------
    logic [3:0] prev_boot_state;
    logic [7:0] boot_chars [0:7];
    logic [3:0] boot_head, boot_tail;
    logic [7:0] cluster_cnt;

    function automatic [7:0] state_char(input [3:0] s);
        case (s)
            4'd0:  state_char = ">";
            4'd1:  state_char = "M";
            4'd2:  state_char = "m";
            4'd3:  state_char = "V";
            4'd4:  state_char = "v";
            4'd5:  state_char = "R";
            4'd6:  state_char = "r";
            4'd9:  state_char = "D";
            4'd10: state_char = "!";
            default: state_char = "?";
        endcase
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            prev_boot_state <= 4'hF;
            boot_head       <= 4'd0;
            cluster_cnt     <= 8'd0;
        end else if (!boot_done) begin
            if (sd_boot_state != prev_boot_state) begin
                prev_boot_state <= sd_boot_state;
                if (sd_boot_state == 4'd8) begin
                    cluster_cnt <= cluster_cnt + 8'd1;
                    if (cluster_cnt[3:0] == 4'd0) begin
                        boot_chars[boot_head[2:0]] <= ".";
                        boot_head <= boot_head + 4'd1;
                    end
                end else if (sd_boot_state == 4'd7) begin
                    // skip S_READ_FAT
                end else if (sd_boot_state == 4'd10) begin
                    boot_chars[boot_head[2:0]] <= "!";
                    boot_chars[(boot_head[2:0] + 3'd1)] <= "0" + {5'd0, sd_error_code};
                    boot_head <= boot_head + 4'd2;
                end else if (sd_boot_state == 4'd9) begin
                    boot_chars[boot_head[2:0]] <= "D";
                    boot_chars[(boot_head[2:0] + 3'd1)] <= 8'h0A;
                    boot_head <= boot_head + 4'd2;
                end else begin
                    boot_chars[boot_head[2:0]] <= state_char(sd_boot_state);
                    boot_head <= boot_head + 4'd1;
                end
            end
        end
    end

    wire boot_chars_pending = (boot_tail != boot_head);

    // ---------------------------------------------------------------
    // Nintendo logo expected values (ROM offset 0x0104–0x0113)
    // ---------------------------------------------------------------
    function automatic [7:0] logo_byte(input [3:0] idx);
        case (idx)
            4'd0:  logo_byte = 8'hCE;
            4'd1:  logo_byte = 8'hED;
            4'd2:  logo_byte = 8'h66;
            4'd3:  logo_byte = 8'h66;
            4'd4:  logo_byte = 8'hCC;
            4'd5:  logo_byte = 8'h0D;
            4'd6:  logo_byte = 8'h00;
            4'd7:  logo_byte = 8'h0B;
            4'd8:  logo_byte = 8'h03;
            4'd9:  logo_byte = 8'h73;
            4'd10: logo_byte = 8'h00;
            4'd11: logo_byte = 8'h83;
            4'd12: logo_byte = 8'h00;
            4'd13: logo_byte = 8'h0C;
            4'd14: logo_byte = 8'h00;
            4'd15: logo_byte = 8'h0D;
        endcase
    endfunction

    // Hex nibble → ASCII
    function automatic [7:0] hex(input [3:0] v);
        if (v < 4'd10)
            hex = 8'd48 + {4'd0, v};
        else
            hex = 8'd55 + {4'd0, v};
    endfunction

    // ---------------------------------------------------------------
    // Main FSM — sends boot chars, then reads/verifies SDRAM bytes
    // ---------------------------------------------------------------
    typedef enum logic [3:0] {
        S_BOOT_DRAIN,     // drain boot char queue to UART
        S_BOOT_DRAIN_WAIT,
        S_FLUSH_WAIT,     // wait for boot_done + queue empty
        S_READ,
        S_READ_WAIT,
        S_PRINT_HI,
        S_PRINT_HI_WAIT,
        S_PRINT_LO,
        S_PRINT_LO_WAIT,
        S_PRINT_SP,
        S_PRINT_SP_WAIT,
        S_RESULT,
        S_RESULT_WAIT,
        S_IDLE,
        S_REFRESH,
        S_REFRESH_WAIT
    } state_t;

    state_t        state;
    logic [3:0]    read_idx;
    logic [7:0]    read_byte;
    logic          all_match;
    logic [2:0]    result_idx;
    state_t        refresh_ret;

    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= S_BOOT_DRAIN;
            boot_tail  <= 4'd0;
            read_idx   <= 4'd0;
            read_byte  <= 8'd0;
            all_match  <= 1'b1;
            result_idx <= 3'd0;
            tx_valid   <= 1'b0;
            tx_byte    <= 8'd0;
        end else begin
            tx_valid <= 1'b0;

            case (state)
                // --- Boot char drain: send queued boot chars to UART ---
                S_BOOT_DRAIN: begin
                    if (boot_chars_pending) begin
                        if (tx_ready) begin
                            tx_byte   <= boot_chars[boot_tail[2:0]];
                            tx_valid  <= 1'b1;
                            boot_tail <= boot_tail + 4'd1;
                            state     <= S_BOOT_DRAIN_WAIT;
                        end
                    end else if (boot_done) begin
                        // Queue empty and boot done — proceed to verify
                        state <= S_READ;
                    end
                    // else: queue empty but still booting — wait
                end

                S_BOOT_DRAIN_WAIT: begin
                    if (tx_ready)
                        state <= S_BOOT_DRAIN;
                end

                // --- SDRAM readback ---
                S_READ: begin
                    if (ref_needed) begin
                        refresh_ret <= S_READ;
                        state       <= S_REFRESH;
                    end else if (!sdram_busy) begin
                        state <= S_READ_WAIT;
                    end
                end

                S_READ_WAIT: begin
                    if (sdram_data_ready) begin
                        read_byte <= sdram_dout;
                        if (sdram_dout != logo_byte(read_idx))
                            all_match <= 1'b0;
                        state <= S_PRINT_HI;
                    end
                end

                // --- Print hex byte + space ---
                S_PRINT_HI: begin
                    if (tx_ready) begin
                        tx_byte  <= hex(read_byte[7:4]);
                        tx_valid <= 1'b1;
                        state    <= S_PRINT_HI_WAIT;
                    end
                end

                S_PRINT_HI_WAIT: begin
                    if (tx_ready)
                        state <= S_PRINT_LO;
                end

                S_PRINT_LO: begin
                    if (tx_ready) begin
                        tx_byte  <= hex(read_byte[3:0]);
                        tx_valid <= 1'b1;
                        state    <= S_PRINT_LO_WAIT;
                    end
                end

                S_PRINT_LO_WAIT: begin
                    if (tx_ready)
                        state <= S_PRINT_SP;
                end

                S_PRINT_SP: begin
                    if (tx_ready) begin
                        tx_byte  <= 8'h20;
                        tx_valid <= 1'b1;
                        state    <= S_PRINT_SP_WAIT;
                    end
                end

                S_PRINT_SP_WAIT: begin
                    if (tx_ready) begin
                        if (read_idx == 4'd15) begin
                            result_idx <= 3'd0;
                            state      <= S_RESULT;
                        end else begin
                            read_idx <= read_idx + 4'd1;
                            state    <= S_READ;
                        end
                    end
                end

                // --- Result: OK or FAIL ---
                S_RESULT: begin
                    if (tx_ready) begin
                        if (all_match) begin
                            case (result_idx)
                                3'd0: tx_byte <= "O";
                                3'd1: tx_byte <= "K";
                                3'd2: tx_byte <= 8'h0D;
                                3'd3: tx_byte <= 8'h0A;
                                default: tx_byte <= 8'h00;
                            endcase
                        end else begin
                            case (result_idx)
                                3'd0: tx_byte <= "F";
                                3'd1: tx_byte <= "A";
                                3'd2: tx_byte <= "I";
                                3'd3: tx_byte <= "L";
                                3'd4: tx_byte <= 8'h0D;
                                3'd5: tx_byte <= 8'h0A;
                                default: tx_byte <= 8'h00;
                            endcase
                        end
                        tx_valid <= 1'b1;
                        state    <= S_RESULT_WAIT;
                    end
                end

                S_RESULT_WAIT: begin
                    if (tx_ready) begin
                        if ((all_match && result_idx == 3'd3) ||
                            (!all_match && result_idx == 3'd5))
                            state <= S_IDLE;
                        else begin
                            result_idx <= result_idx + 3'd1;
                            state      <= S_RESULT;
                        end
                    end
                end

                // --- Refresh detour ---
                S_REFRESH: begin
                    state <= S_REFRESH_WAIT;
                end

                S_REFRESH_WAIT: begin
                    if (!sdram_busy)
                        state <= refresh_ret;
                end

                S_IDLE: begin
                    // Done — press btn_s1 to re-test
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // SDRAM command arbiter
    // ---------------------------------------------------------------
    wire verify_rd = (state == S_READ) && !ref_needed && !sdram_busy && boot_done;
    wire verify_refresh = (state == S_REFRESH) && !sdram_busy;

    always_comb begin
        sdram_rd      = 1'b0;
        sdram_wr      = 1'b0;
        sdram_refresh = 1'b0;
        sdram_a       = 23'd0;
        sdram_din     = 8'd0;

        if (!boot_done) begin
            if (sd_rom_wr && !sdram_busy) begin
                sdram_wr  = 1'b1;
                sdram_a   = sd_rom_addr;
                sdram_din = sd_rom_data;
            end else if (ref_needed && !sdram_busy) begin
                sdram_refresh = 1'b1;
            end
        end else begin
            if (verify_rd) begin
                sdram_rd = 1'b1;
                sdram_a  = 23'h000104 + {19'd0, read_idx};
            end else if (verify_refresh) begin
                sdram_refresh = 1'b1;
            end else if (ref_needed && !sdram_busy) begin
                sdram_refresh = 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------
    // LEDs
    // ---------------------------------------------------------------
    always_comb begin
        if (!boot_done) begin
            if (sd_boot_error)
                led = ~{3'b111, sd_error_code};
            else
                led = ~{2'b00, sd_boot_state};
        end else if (state == S_IDLE) begin
            led = all_match ? 6'b000000 : 6'b111111;
        end else begin
            led = ~{2'b01, read_idx};
        end
    end

endmodule
