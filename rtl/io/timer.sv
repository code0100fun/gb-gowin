// Game Boy timer — DIV, TIMA, TMA, TAC registers.
//
// DIV (FF04): upper byte of a free-running 16-bit counter that
//   increments every M-cycle. Writing any value resets it to zero.
//
// TIMA (FF05): timer counter, clocked by a selected bit of the
//   DIV counter. Overflows from 0xFF → reloads from TMA and fires IRQ.
//
// TMA (FF06): modulo — value loaded into TIMA on overflow.
//
// TAC (FF07): timer control.
//   Bit 2   = enable
//   Bits 1:0 = clock select (which DIV bit clocks TIMA)
//
// Clock select table (1 clock = 1 M-cycle = 4 T-cycles):
//   TAC[1:0]  DIV bit   M-cycles/tick   Frequency
//     00        7         256             4096 Hz
//     01        1           4           262144 Hz
//     10        3          16            65536 Hz
//     11        5          64            16384 Hz
module timer (
    input  logic       clk,
    input  logic       reset,

    // I/O bus
    input  logic       io_cs,
    input  logic [6:0] io_addr,
    input  logic       io_wr,
    input  logic [7:0] io_wdata,
    output logic [7:0] io_rdata,
    output logic       io_rdata_valid, // high when address is ours (04-07)

    // Interrupt
    output logic       irq,            // one-cycle pulse on TIMA overflow

    // Debug
    output logic [15:0] dbg_div_ctr,
    output logic [7:0]  dbg_tima,
    output logic [7:0]  dbg_tma,
    output logic [7:0]  dbg_tac
);

    // ---------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------
    logic [15:0] div_ctr;
    logic [7:0]  tima;
    logic [7:0]  tma;
    logic [2:0]  tac;
    logic        prev_bit;  // previous value of the selected DIV bit

    initial begin
        div_ctr  = 16'h0000;
        tima     = 8'h00;
        tma      = 8'h00;
        tac      = 3'b000;
        prev_bit = 1'b0;
    end

    // ---------------------------------------------------------------
    // Clock select mux
    // ---------------------------------------------------------------
    logic selected_bit;
    always_comb begin
        unique case (tac[1:0])
            2'b00: selected_bit = div_ctr[7];
            2'b01: selected_bit = div_ctr[1];
            2'b10: selected_bit = div_ctr[3];
            2'b11: selected_bit = div_ctr[5];
        endcase
    end

    // Falling edge of (enable AND selected_bit)
    wire tick_bit = tac[2] & selected_bit;
    wire tima_tick = prev_bit & ~tick_bit;

    // ---------------------------------------------------------------
    // Read mux
    // ---------------------------------------------------------------
    always_comb begin
        io_rdata_valid = 1'b0;
        io_rdata = 8'h00;
        unique case (io_addr)
            7'h04: begin io_rdata = div_ctr[15:8];       io_rdata_valid = 1'b1; end
            7'h05: begin io_rdata = tima;                 io_rdata_valid = 1'b1; end
            7'h06: begin io_rdata = tma;                  io_rdata_valid = 1'b1; end
            7'h07: begin io_rdata = {5'b11111, tac};      io_rdata_valid = 1'b1; end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------
    // Sequential logic
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            div_ctr  <= 16'h0000;
            tima     <= 8'h00;
            tma      <= 8'h00;
            tac      <= 3'b000;
            prev_bit <= 1'b0;
            irq      <= 1'b0;
        end else begin
            // Default: clear IRQ pulse
            irq <= 1'b0;

            // DIV always increments
            div_ctr <= div_ctr + 16'd1;

            // Track the selected bit for falling-edge detection
            prev_bit <= tick_bit;

            // TIMA increment on falling edge
            if (tima_tick) begin
                if (tima == 8'hFF) begin
                    tima <= tma;   // overflow → reload from TMA
                    irq  <= 1'b1;
                end else begin
                    tima <= tima + 8'd1;
                end
            end

            // I/O writes (override above defaults when active)
            if (io_cs && io_wr) begin
                unique case (io_addr)
                    7'h04: begin
                        div_ctr  <= 16'h0000;
                        prev_bit <= 1'b0;
                    end
                    7'h05: tima <= io_wdata;
                    7'h06: tma  <= io_wdata;
                    7'h07: tac  <= io_wdata[2:0];
                    default: ;
                endcase
            end
        end
    end

    // Debug
    assign dbg_div_ctr = div_ctr;
    assign dbg_tima    = tima;
    assign dbg_tma     = tma;
    assign dbg_tac     = {5'b0, tac};

endmodule
