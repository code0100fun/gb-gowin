// Behavioral SD card model for Verilator simulation.
//
// Emulates an SDHC card in SPI mode. Uses the system clock to detect
// SPI clock edges (avoids multi-driver issues in Verilator).
//
// Responds to: CMD0, CMD8, CMD55+ACMD41, CMD16, CMD17, CMD58.
// Sector data is stored in a flat byte array loaded by the test wrapper.
module sd_card_model #(
    parameter int NUM_SECTORS  = 8192,  // 512-byte sectors
    parameter int ACMD41_DELAY = 2      // ACMD41 attempts before ready
) (
    input  logic clk,       // system clock (for edge detection)
    input  logic sclk,      // SPI clock from master
    input  logic mosi,      // SPI data in (from master)
    output logic miso,      // SPI data out (to master)
    input  logic cs_n       // chip select (active low)
);

    // Sector storage (preloaded by test wrapper via initial block)
    logic [7:0] sector_mem [0:NUM_SECTORS*512-1];

    // --- Edge detection ---
    logic sclk_prev, cs_n_prev;
    wire  sclk_rise = sclk && !sclk_prev;
    wire  sclk_fall = !sclk && sclk_prev;
    wire  cs_deassert = cs_n && !cs_n_prev;

    // --- RX state ---
    logic [7:0] rx_shift;
    logic [2:0] rx_bit_cnt;
    logic       rx_byte_valid;  // pulse for 1 system clock cycle

    // --- TX state ---
    logic [7:0] tx_shift;
    logic [2:0] tx_bit_cnt;
    logic       tx_active;

    // --- Command assembly ---
    logic [47:0] cmd_buf;     // 6 bytes: start|index|arg[31:0]|crc
    logic [2:0]  cmd_byte_cnt;
    logic        cmd_complete; // pulse when 6th byte received

    // --- Protocol state ---
    logic        app_cmd;      // CMD55 prefix active
    int          acmd41_cnt;

    // --- Response buffer ---
    localparam int RESP_MAX = 520; // R1 + token + 512 data + 2 CRC
    logic [7:0]  resp_buf [0:RESP_MAX-1];
    int          resp_len;
    int          resp_idx;
    logic        resp_ready;    // response prepared, waiting for byte boundary
    logic        resp_pending;  // byte boundary reached, load on next sclk_fall

    // MISO output
    assign miso = cs_n ? 1'b1 : tx_shift[7];

    always_ff @(posedge clk) begin
        sclk_prev <= sclk;
        cs_n_prev <= cs_n;
        rx_byte_valid <= 1'b0;
        cmd_complete  <= 1'b0;

        // --- CS deassert: reset SPI state ---
        if (cs_deassert) begin
            rx_bit_cnt   <= 3'd0;
            tx_shift     <= 8'hFF;
            tx_active    <= 1'b0;
            cmd_byte_cnt <= 3'd0;
            resp_len     <= 0;
            resp_idx     <= 0;
            resp_ready   <= 1'b0;
            resp_pending <= 1'b0;
        end

        // --- SCLK rising edge: sample MOSI ---
        if (sclk_rise && !cs_n) begin
            rx_shift <= {rx_shift[6:0], mosi};
            if (rx_bit_cnt == 3'd7) begin
                rx_byte_valid <= 1'b1;
                rx_bit_cnt    <= 3'd0;
            end else begin
                rx_bit_cnt <= rx_bit_cnt + 3'd1;
            end
        end

        // --- SCLK falling edge: shift TX ---
        if (sclk_fall && !cs_n) begin
            if (tx_active) begin
                // Default: shift left, fill with 1
                tx_shift <= {tx_shift[6:0], 1'b1};
                if (tx_bit_cnt == 3'd7) begin
                    // Byte complete — load next or stop
                    if (resp_idx < resp_len) begin
                        // Immediately load next byte (overrides shift above)
                        tx_shift   <= resp_buf[resp_idx];
                        tx_bit_cnt <= 3'd0;
                        resp_idx   <= resp_idx + 1;
                    end else begin
                        tx_active  <= 1'b0;
                        tx_bit_cnt <= 3'd0;
                    end
                end else begin
                    tx_bit_cnt <= tx_bit_cnt + 3'd1;
                end
            end else if (resp_pending) begin
                // Byte boundary reached — load first response byte
                tx_shift     <= resp_buf[resp_idx];
                tx_active    <= 1'b1;
                tx_bit_cnt   <= 3'd0;
                resp_idx     <= resp_idx + 1;
                resp_pending <= 1'b0;
            end
        end

        // --- Byte-boundary sync for response ---
        // Convert resp_ready → resp_pending on the next rx_byte_valid,
        // ensuring the response starts at a byte boundary on MISO.
        if (rx_byte_valid && resp_ready) begin
            resp_pending <= 1'b1;
            resp_ready   <= 1'b0;
        end

        // --- Process received bytes ---
        if (rx_byte_valid && !cs_n) begin
            if (cmd_byte_cnt == 0) begin
                // Wait for start bit pattern: 01xxxxxx
                if (rx_shift[7:6] == 2'b01) begin
                    cmd_buf[47:40] <= rx_shift;
                    cmd_byte_cnt   <= 3'd1;
                end
            end else begin
                case (cmd_byte_cnt)
                    3'd1: cmd_buf[39:32] <= rx_shift;
                    3'd2: cmd_buf[31:24] <= rx_shift;
                    3'd3: cmd_buf[23:16] <= rx_shift;
                    3'd4: cmd_buf[15:8]  <= rx_shift;
                    default: ;
                endcase
                if (cmd_byte_cnt == 3'd5) begin
                    cmd_buf[7:0]  <= rx_shift;
                    cmd_complete  <= 1'b1;
                    cmd_byte_cnt  <= 3'd0;
                end else begin
                    cmd_byte_cnt <= cmd_byte_cnt + 3'd1;
                end
            end
        end

        // --- Command dispatch ---
        // Sets resp_buf/resp_len and starts Nrc delay before responding.
        // The 8-edge Nrc delay ensures the response starts byte-aligned,
        // preventing garbled bytes from mid-byte tx_shift loading.
        if (cmd_complete) begin
            automatic logic [5:0]  idx = cmd_buf[45:40];
            automatic logic [31:0] arg = cmd_buf[39:8];

            resp_idx   <= 0;
            resp_ready <= 1'b1;

            if (app_cmd) begin
                app_cmd <= 1'b0;
                if (idx == 6'd41) begin
                    // ACMD41
                    if (acmd41_cnt >= ACMD41_DELAY) begin
                        resp_buf[0] <= 8'h00; // ready
                    end else begin
                        resp_buf[0] <= 8'h01; // idle
                        acmd41_cnt  <= acmd41_cnt + 1;
                    end
                    resp_len <= 1;
                end else begin
                    // Unknown ACMD
                    resp_buf[0] <= 8'h04;
                    resp_len    <= 1;
                end
            end else begin
                case (idx)
                    6'd0: begin // CMD0 — GO_IDLE_STATE
                        acmd41_cnt  <= 0;
                        resp_buf[0] <= 8'h01;
                        resp_len    <= 1;
                    end
                    6'd8: begin // CMD8 — SEND_IF_COND (R7)
                        resp_buf[0] <= 8'h01;
                        resp_buf[1] <= 8'h00;
                        resp_buf[2] <= 8'h00;
                        resp_buf[3] <= {4'b0, arg[11:8]};
                        resp_buf[4] <= arg[7:0];
                        resp_len    <= 5;
                    end
                    6'd16: begin // CMD16 — SET_BLOCKLEN
                        resp_buf[0] <= 8'h00;
                        resp_len    <= 1;
                    end
                    6'd17: begin // CMD17 — READ_SINGLE_BLOCK
                        resp_buf[0] <= 8'h00; // R1
                        resp_buf[1] <= 8'hFE; // data token
                        for (int i = 0; i < 512; i++) begin
                            automatic int addr = arg * 512 + i;
                            if (addr < NUM_SECTORS * 512)
                                resp_buf[2 + i] <= sector_mem[addr];
                            else
                                resp_buf[2 + i] <= 8'h00;
                        end
                        resp_buf[514] <= 8'hFF; // CRC
                        resp_buf[515] <= 8'hFF;
                        resp_len      <= 516;
                    end
                    6'd55: begin // CMD55 — APP_CMD
                        app_cmd     <= 1'b1;
                        resp_buf[0] <= 8'h01;
                        resp_len    <= 1;
                    end
                    6'd58: begin // CMD58 — READ_OCR
                        resp_buf[0] <= 8'h00;
                        resp_buf[1] <= 8'hC0; // CCS=1, power up
                        resp_buf[2] <= 8'hFF;
                        resp_buf[3] <= 8'h80;
                        resp_buf[4] <= 8'h00;
                        resp_len    <= 5;
                    end
                    default: begin
                        resp_buf[0] <= 8'h04;
                        resp_len    <= 1;
                    end
                endcase
            end
        end
    end

endmodule
