// Game Boy serial port — SB and SC registers (FF01-FF02).
//
// Minimal implementation for single-player games that probe serial.
// Internal clock mode only — no external link cable support.
//
// SB (FF01): 8-bit shift register. During transfer, shifts out MSB-first
//   and shifts in 1s (no link partner), ending as 0xFF.
//
// SC (FF02): Serial control.
//   Bit 7: Transfer start/in-progress (1=active, auto-clears on complete)
//   Bit 0: Clock select (0=external, 1=internal 8192 Hz)
//   Bits 6-1: Unused, read as 1.
//
// Transfer timing: internal clock = 8192 Hz = 128 M-cycles/bit.
//   Full transfer = 8 bits * 128 = 1024 M-cycles.
//
// Interrupt: IF bit 3 pulses when transfer completes.
module serial #(
    parameter int CLOCKS_PER_BIT = 128  // 8192 Hz at 1 M-cycle/clk
) (
    input  logic       clk,
    input  logic       reset,

    // I/O bus
    input  logic       io_cs,
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,
    output logic       io_rdata_valid,

    // Interrupt
    output logic       irq,

    // Debug
    output logic [7:0] dbg_sb,
    output logic [7:0] dbg_sc
);

    // ---------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------
    logic [7:0] sb_reg;
    logic       sc_transfer;  // SC bit 7
    logic       sc_clock;     // SC bit 0

    logic [2:0]  bit_cnt;
    logic [$clog2(CLOCKS_PER_BIT)-1:0] clk_cnt;
    logic        transferring;

    // Debug outputs
    assign dbg_sb = sb_reg;
    assign dbg_sc = {sc_transfer, 6'b111111, sc_clock};

    // ---------------------------------------------------------------
    // Read mux
    // ---------------------------------------------------------------
    always_comb begin
        io_rdata_valid = 1'b0;
        io_rdata = 8'h00;
        unique case (io_addr)
            7'h01: begin
                io_rdata = sb_reg;
                io_rdata_valid = 1'b1;
            end
            7'h02: begin
                io_rdata = {sc_transfer, 6'b111111, sc_clock};
                io_rdata_valid = 1'b1;
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------
    // Sequential logic
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            sb_reg       <= 8'h00;
            sc_transfer  <= 1'b0;
            sc_clock     <= 1'b0;
            bit_cnt      <= 3'd0;
            clk_cnt      <= '0;
            transferring <= 1'b0;
            irq          <= 1'b0;
        end else begin
            irq <= 1'b0;  // default: clear pulse

            // Transfer shift logic
            if (transferring) begin
                if (clk_cnt == 0) begin
                    // Shift SB: MSB out, 1 in (no link partner)
                    sb_reg <= {sb_reg[6:0], 1'b1};

                    if (bit_cnt == 3'd7) begin
                        // Transfer complete
                        transferring <= 1'b0;
                        sc_transfer  <= 1'b0;
                        irq          <= 1'b1;
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                        clk_cnt <= CLOCKS_PER_BIT[$clog2(CLOCKS_PER_BIT)-1:0] - 1;
                    end
                end else begin
                    clk_cnt <= clk_cnt - 1;
                end
            end

            // Register writes (I/O bus writes can happen during transfer)
            if (io_cs && io_wr) begin
                case (io_addr)
                    7'h01: sb_reg <= io_wdata;
                    7'h02: begin
                        sc_clock <= io_wdata[0];
                        if (io_wdata[7] && io_wdata[0] && !transferring) begin
                            // Start internal-clock transfer
                            sc_transfer  <= 1'b1;
                            transferring <= 1'b1;
                            bit_cnt      <= 3'd0;
                            clk_cnt      <= CLOCKS_PER_BIT[$clog2(CLOCKS_PER_BIT)-1:0] - 1;
                        end else begin
                            sc_transfer <= io_wdata[7];
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
