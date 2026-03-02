// Game Boy joypad — JOYP register (FF00).
//
// The Game Boy uses a column/row matrix for button input:
//   P14 selects direction keys (active low write):
//     P13=Down, P12=Up, P11=Left, P10=Right
//   P15 selects action buttons (active low write):
//     P13=Start, P12=Select, P11=B, P10=A
//
// Buttons active low on read: 0 = pressed, 1 = released.
// Hardware buttons are active high: 1 = pressed (GPIO pulled to 3.3V).
//
// Includes 2-FF synchronizer and 3-sample debouncer per button.
// Fires joypad interrupt (IF bit 4) on any selected P10-P13 1→0 transition.
module joypad #(
    parameter int DEBOUNCE_CYCLES = 27000  // ~1 kHz sample rate at 27 MHz
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

    // Raw button inputs (active high from GPIO)
    // {start, select, b, a, down, up, left, right}
    input  logic [7:0] btn,

    // Interrupt
    output logic       irq
);

    // ---------------------------------------------------------------
    // 2-FF synchronizer (no reset — settles within 2 cycles)
    // ---------------------------------------------------------------
    logic [7:0] btn_sync1, btn_sync2;
    always_ff @(posedge clk) begin
        btn_sync1 <= btn;
        btn_sync2 <= btn_sync1;
    end

    // ---------------------------------------------------------------
    // Debouncer — shared sample counter + 3-bit shift register per button
    // ---------------------------------------------------------------
    localparam int CNT_WIDTH = $clog2(DEBOUNCE_CYCLES);
    logic [CNT_WIDTH-1:0] sample_cnt;
    wire sample_tick = (sample_cnt == CNT_WIDTH'(DEBOUNCE_CYCLES - 1));

    logic [2:0] btn_shift [0:7];
    logic [7:0] btn_stable;

    initial begin
        sample_cnt = '0;
        for (int i = 0; i < 8; i++) btn_shift[i] = 3'b000;
        btn_stable = 8'h00;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            sample_cnt <= '0;
            for (int i = 0; i < 8; i++) btn_shift[i] <= 3'b000;
            btn_stable <= 8'h00;
        end else begin
            if (sample_tick)
                sample_cnt <= '0;
            else
                sample_cnt <= sample_cnt + 1;

            if (sample_tick) begin
                for (int i = 0; i < 8; i++) begin
                    btn_shift[i] <= {btn_shift[i][1:0], btn_sync2[i]};
                    if ({btn_shift[i][1:0], btn_sync2[i]} == 3'b111)
                        btn_stable[i] <= 1'b1;
                    else if ({btn_shift[i][1:0], btn_sync2[i]} == 3'b000)
                        btn_stable[i] <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // JOYP register — column select (active low)
    // ---------------------------------------------------------------
    logic [1:0] reg_select;  // {P15, P14}
    initial reg_select = 2'b11;

    always_ff @(posedge clk) begin
        if (reset)
            reg_select <= 2'b11;
        else if (io_cs && io_wr && io_addr == 7'h00)
            reg_select <= io_wdata[5:4];
    end

    // ---------------------------------------------------------------
    // Button matrix read logic
    // ---------------------------------------------------------------
    wire [3:0] dpad   = btn_stable[3:0];  // {down, up, left, right}
    wire [3:0] action = btn_stable[7:4];  // {start, select, b, a}

    logic [3:0] p10_p13;
    always_comb begin
        p10_p13 = 4'b1111;  // all released (active low)
        if (!reg_select[0]) p10_p13 = p10_p13 & ~dpad;    // P14=0 → directions
        if (!reg_select[1]) p10_p13 = p10_p13 & ~action;  // P15=0 → actions
    end

    wire [7:0] joyp_read = {2'b11, reg_select, p10_p13};

    // ---------------------------------------------------------------
    // Read mux
    // ---------------------------------------------------------------
    always_comb begin
        io_rdata_valid = 1'b0;
        io_rdata = 8'h00;
        if (io_addr == 7'h00) begin
            io_rdata = joyp_read;
            io_rdata_valid = 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Joypad interrupt — any selected P10-P13 line going 1→0
    // ---------------------------------------------------------------
    logic [3:0] prev_p10_p13;
    initial begin
        prev_p10_p13 = 4'b1111;
        irq = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            prev_p10_p13 <= 4'b1111;
            irq <= 1'b0;
        end else begin
            prev_p10_p13 <= p10_p13;
            irq <= |(prev_p10_p13 & ~p10_p13);
        end
    end

endmodule
