// LR35902 CPU — complete instruction execution engine.
//
// Integrates the register file, ALU, and instruction decoder into an
// M-cycle state machine that fetches, decodes, and executes every base
// and CB-prefixed instruction.
//
// Memory model: combinational reads. The CPU presents mem_addr and
// mem_rd; the external memory provides mem_rdata in the same cycle.
// Each clock tick = 1 M-cycle (4 T-cycles).
//
// Architecture: The regfile write controls are combinational (always_comb)
// so that register writes take effect on the SAME clock edge that the
// state machine advances. Only internal CPU state (ir, m_cycle, w/z regs,
// mode flags) is updated in the always_ff block.
module cpu (
    input  logic        clk,
    input  logic        reset,

    // Memory bus (active every M-cycle)
    output logic [15:0] mem_addr,
    output logic        mem_rd,
    output logic        mem_wr,
    output logic [7:0]  mem_wdata,
    input  logic [7:0]  mem_rdata,

    // Debug / status outputs
    output logic        halted,
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_sp,
    output logic [7:0]  dbg_a, dbg_f,
    output logic [7:0]  dbg_b, dbg_c,
    output logic [7:0]  dbg_d, dbg_e,
    output logic [7:0]  dbg_h, dbg_l
);

    // =================================================================
    // Internal state (registered in always_ff)
    // =================================================================
    logic [7:0]  ir;          // Instruction register (latched opcode)
    logic [2:0]  m_cycle;     // Current M-cycle within instruction (0 = fetch)
    logic [7:0]  z_reg;       // Temp low byte
    logic [7:0]  w_reg;       // Temp high byte
    logic        cb_mode;     // Next fetch is a CB-prefixed instruction
    logic        halt_mode;   // CPU is halted
    logic        ime;         // Interrupt master enable
    logic        ie_delay;    // EI takes effect after next instruction

    // =================================================================
    // Sub-module wires
    // =================================================================

    // --- Register file ports ---
    logic [2:0]  rf_r8_rsel;
    logic [7:0]  rf_r8_rdata;
    logic        rf_r8_we;
    logic [2:0]  rf_r8_wsel;
    logic [7:0]  rf_r8_wdata;

    logic [1:0]  rf_r16_rsel;
    logic [15:0] rf_r16_rdata;
    logic        rf_r16_we;
    logic [1:0]  rf_r16_wsel;
    logic [15:0] rf_r16_wdata;

    logic [1:0]  rf_r16stk_rsel;
    logic [15:0] rf_r16stk_rdata;
    logic        rf_r16stk_we;
    logic [1:0]  rf_r16stk_wsel;
    logic [15:0] rf_r16stk_wdata;

    logic [3:0]  rf_flags;
    logic        rf_flags_we;
    logic [3:0]  rf_flags_wdata;

    logic [15:0] rf_sp;
    logic        rf_sp_we;
    logic [15:0] rf_sp_wdata;

    logic [15:0] rf_pc;
    logic        rf_pc_we;
    logic [15:0] rf_pc_wdata;

    logic [7:0]  rf_out_a, rf_out_f;
    logic [7:0]  rf_out_b, rf_out_c;
    logic [7:0]  rf_out_d, rf_out_e;
    logic [7:0]  rf_out_h, rf_out_l;

    regfile rf (
        .clk          (clk),
        .r8_rsel      (rf_r8_rsel),
        .r8_rdata     (rf_r8_rdata),
        .r8_we        (rf_r8_we),
        .r8_wsel      (rf_r8_wsel),
        .r8_wdata     (rf_r8_wdata),
        .r16_rsel     (rf_r16_rsel),
        .r16_rdata    (rf_r16_rdata),
        .r16_we       (rf_r16_we),
        .r16_wsel     (rf_r16_wsel),
        .r16_wdata    (rf_r16_wdata),
        .r16stk_rsel  (rf_r16stk_rsel),
        .r16stk_rdata (rf_r16stk_rdata),
        .r16stk_we    (rf_r16stk_we),
        .r16stk_wsel  (rf_r16stk_wsel),
        .r16stk_wdata (rf_r16stk_wdata),
        .flags        (rf_flags),
        .flags_we     (rf_flags_we),
        .flags_wdata  (rf_flags_wdata),
        .sp           (rf_sp),
        .sp_we        (rf_sp_we),
        .sp_wdata     (rf_sp_wdata),
        .pc           (rf_pc),
        .pc_we        (rf_pc_we),
        .pc_wdata     (rf_pc_wdata),
        .out_a        (rf_out_a),
        .out_f        (rf_out_f),
        .out_b        (rf_out_b),
        .out_c        (rf_out_c),
        .out_d        (rf_out_d),
        .out_e        (rf_out_e),
        .out_h        (rf_out_h),
        .out_l        (rf_out_l)
    );

    // --- Decoder ---
    logic [7:0]  dec_opcode;
    logic        dec_cb_prefix;
    logic        dec_cond_met;

    logic [2:0]  dec_mcycles;
    logic [2:0]  dec_r8_src;
    logic [2:0]  dec_r8_dst;
    logic [1:0]  dec_r16_idx;
    logic [1:0]  dec_cond_code;
    logic [2:0]  dec_rst_vec;
    logic [2:0]  dec_cb_bit_idx;
    logic [4:0]  dec_alu_op;
    logic        dec_is_cb_prefix;
    logic        dec_uses_hl_indirect;
    logic        dec_is_halt;
    logic        dec_is_ei;
    logic        dec_is_di;

    decoder dec (
        .opcode           (dec_opcode),
        .cb_prefix        (dec_cb_prefix),
        .cond_met         (dec_cond_met),
        .mcycles          (dec_mcycles),
        .r8_src           (dec_r8_src),
        .r8_dst           (dec_r8_dst),
        .r16_idx          (dec_r16_idx),
        .cond_code        (dec_cond_code),
        .rst_vec          (dec_rst_vec),
        .cb_bit_idx       (dec_cb_bit_idx),
        .alu_op           (dec_alu_op),
        .is_cb_prefix     (dec_is_cb_prefix),
        .uses_hl_indirect (dec_uses_hl_indirect),
        .is_halt          (dec_is_halt),
        .is_ei            (dec_is_ei),
        .is_di            (dec_is_di)
    );

    // --- ALU ---
    logic [7:0]  alu_a, alu_b;
    logic [3:0]  alu_flags_in;
    logic [4:0]  alu_op;
    logic [2:0]  alu_bit_sel;
    // verilator lint_off UNOPTFLAT
    logic [7:0]  alu_result;
    logic [3:0]  alu_flags_out;
    // verilator lint_on UNOPTFLAT

    alu alu_inst (
        .a         (alu_a),
        .b         (alu_b),
        .flags_in  (alu_flags_in),
        .op        (alu_op),
        .bit_sel   (alu_bit_sel),
        .result    (alu_result),
        .flags_out (alu_flags_out)
    );

    // =================================================================
    // Decoder input routing
    // =================================================================
    wire [7:0] active_opcode = (m_cycle == 0) ? mem_rdata : ir;

    assign dec_opcode    = active_opcode;
    assign dec_cb_prefix = cb_mode;

    // Condition evaluation
    wire cond_result = (dec_cond_code == 2'd0) ? !rf_flags[3] :  // NZ
                       (dec_cond_code == 2'd1) ?  rf_flags[3] :  // Z
                       (dec_cond_code == 2'd2) ? !rf_flags[0] :  // NC
                                                   rf_flags[0];  // C
    assign dec_cond_met = cond_result;

    // =================================================================
    // r8 value lookups (from direct outputs)
    // =================================================================
    logic [7:0] r8_src_val;
    always_comb begin
        unique case (dec_r8_src)
            3'd0: r8_src_val = rf_out_b;
            3'd1: r8_src_val = rf_out_c;
            3'd2: r8_src_val = rf_out_d;
            3'd3: r8_src_val = rf_out_e;
            3'd4: r8_src_val = rf_out_h;
            3'd5: r8_src_val = rf_out_l;
            3'd6: r8_src_val = 8'hFF;
            3'd7: r8_src_val = rf_out_a;
        endcase
    end

    logic [7:0] r8_dst_val;
    always_comb begin
        unique case (dec_r8_dst)
            3'd0: r8_dst_val = rf_out_b;
            3'd1: r8_dst_val = rf_out_c;
            3'd2: r8_dst_val = rf_out_d;
            3'd3: r8_dst_val = rf_out_e;
            3'd4: r8_dst_val = rf_out_h;
            3'd5: r8_dst_val = rf_out_l;
            3'd6: r8_dst_val = 8'hFF;
            3'd7: r8_dst_val = rf_out_a;
        endcase
    end

    wire [15:0] hl_val = {rf_out_h, rf_out_l};

    // r16 pair value from direct outputs (avoids comb loop through r16_rsel)
    logic [15:0] r16_val;
    always_comb begin
        unique case (dec_r16_idx)
            2'd0: r16_val = {rf_out_b, rf_out_c};
            2'd1: r16_val = {rf_out_d, rf_out_e};
            2'd2: r16_val = hl_val;
            2'd3: r16_val = rf_sp;
        endcase
    end

    // Debug outputs
    assign halted = halt_mode;
    assign dbg_pc = rf_pc;
    assign dbg_sp = rf_sp;
    assign dbg_a  = rf_out_a;
    assign dbg_f  = rf_out_f;
    assign dbg_b  = rf_out_b;
    assign dbg_c  = rf_out_c;
    assign dbg_d  = rf_out_d;
    assign dbg_e  = rf_out_e;
    assign dbg_h  = rf_out_h;
    assign dbg_l  = rf_out_l;

    // =================================================================
    // Combinational: memory bus + ALU routing + register writes
    // =================================================================
    // All regfile write controls are COMBINATIONAL so they take effect
    // on the same clock edge that the state machine advances.
    // verilator lint_off CASEOVERLAP
    always_comb begin
        // ----- Defaults -----
        mem_addr  = rf_pc;
        mem_rd    = 1'b0;
        mem_wr    = 1'b0;
        mem_wdata = 8'h00;

        rf_r8_rsel     = dec_r8_src;
        rf_r16_rsel    = dec_r16_idx;
        rf_r16stk_rsel = dec_r16_idx;

        alu_a        = rf_out_a;
        alu_b        = 8'h00;
        alu_flags_in = rf_flags;
        alu_op       = dec_alu_op;
        alu_bit_sel  = dec_cb_bit_idx;

        // Regfile write defaults: no writes
        rf_r8_we        = 1'b0;
        rf_r8_wsel      = 3'd0;
        rf_r8_wdata     = 8'h00;
        rf_r16_we       = 1'b0;
        rf_r16_wsel     = 2'd0;
        rf_r16_wdata    = 16'h0000;
        rf_r16stk_we    = 1'b0;
        rf_r16stk_wsel  = 2'd0;
        rf_r16stk_wdata = 16'h0000;
        rf_flags_we     = 1'b0;
        rf_flags_wdata  = 4'h0;
        rf_sp_we        = 1'b0;
        rf_sp_wdata     = 16'h0000;
        rf_pc_we        = 1'b0;
        rf_pc_wdata     = 16'h0000;

        if (reset) begin
            // During reset: set SP and PC to initial values
            rf_sp_we    = 1'b1;
            rf_sp_wdata = 16'hFFFE;
            rf_pc_we    = 1'b1;
            rf_pc_wdata = 16'h0000;
        end else if (halt_mode) begin
            // Halted: no bus activity, no writes
        end else if (m_cycle == 0) begin
            // ===========================================================
            // FETCH phase
            // ===========================================================
            mem_addr = rf_pc;
            mem_rd   = 1'b1;

            // Default: PC++ on every fetch
            rf_pc_we    = 1'b1;
            rf_pc_wdata = rf_pc + 16'd1;

            // ALU routing for single-cycle instructions
            if (cb_mode && !dec_is_cb_prefix) begin
                // CB single-cycle: register target
                alu_a = r8_src_val;
            end else begin
                casez (mem_rdata)
                    8'b10_???_???: begin
                        alu_a = rf_out_a;
                        alu_b = r8_src_val;
                    end
                    8'b00_???_100, 8'b00_???_101: begin
                        alu_a = r8_dst_val;
                    end
                    8'b00_???_111: begin
                        alu_a = rf_out_a;
                        alu_bit_sel = {2'b00, mem_rdata[4]};
                    end
                    default: ;
                endcase
            end

            // Single-cycle execution (register writes)
            if (!dec_is_cb_prefix && !dec_is_halt && !dec_is_ei && !dec_is_di
                && dec_mcycles == 3'd1) begin
                if (cb_mode) begin
                    // CB single-cycle on register
                    rf_r8_we    = (active_opcode[7:6] != 2'b01);  // Not BIT
                    rf_r8_wsel  = dec_r8_src;
                    rf_r8_wdata = alu_result;
                    rf_flags_we    = 1'b1;
                    rf_flags_wdata = alu_flags_out;
                end else begin
                    casez (active_opcode)
                        8'h00, 8'h10: begin end  // NOP, STOP

                        // LD r8, r8
                        8'b01_???_???: begin
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = dec_r8_dst;
                            rf_r8_wdata = r8_src_val;
                        end

                        // ALU A, r8
                        8'b10_???_???: begin
                            rf_r8_we    = (dec_r8_dst != 3'd7);  // Not CP
                            rf_r8_wsel  = 3'd7;  // A
                            rf_r8_wdata = alu_result;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                        end

                        // INC/DEC r8
                        8'b00_???_100, 8'b00_???_101: begin
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = dec_r8_dst;
                            rf_r8_wdata = alu_result;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                        end

                        // RLCA/RLA/RRCA/RRA/DAA/CPL/SCF/CCF
                        8'b00_???_111: begin
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = 3'd7;  // A
                            rf_r8_wdata = alu_result;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                        end

                        // JP HL
                        8'hE9: begin
                            rf_pc_we    = 1'b1;
                            rf_pc_wdata = hl_val;
                        end

                        default: ;
                    endcase
                end
            end

        end else begin
            // ===========================================================
            // EXECUTE phase (m_cycle > 0)
            // ===========================================================
            if (cb_mode) begin
                // ----- CB multi-cycle ((HL) variants) -----
                alu_a = z_reg;
                if (ir[2:0] == 3'd6) begin
                    unique case (m_cycle)
                        3'd1: begin
                            mem_addr = hl_val;
                            mem_rd   = 1'b1;
                        end
                        3'd2: begin
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                            if (ir[7:6] != 2'b01) begin
                                mem_addr  = hl_val;
                                mem_wr    = 1'b1;
                                mem_wdata = alu_result;
                            end
                        end
                        default: ;
                    endcase
                end
            end else begin
                // ----- Base multi-cycle instructions -----
                casez (ir)
                    // LD r16, u16
                    8'b00_??_0001: begin
                        if (m_cycle == 3'd1 || m_cycle == 3'd2) begin
                            mem_addr = rf_pc;
                            mem_rd   = 1'b1;
                        end
                        unique case (m_cycle)
                            3'd1: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                rf_pc_we     = 1'b1;
                                rf_pc_wdata  = rf_pc + 16'd1;
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = dec_r16_idx;
                                rf_r16_wdata = {mem_rdata, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // LD (r16mem), A
                    8'b00_??_0010: begin
                        if (m_cycle == 3'd1) begin
                            unique case (ir[5:4])
                                2'd0: mem_addr = {rf_out_b, rf_out_c};
                                2'd1: mem_addr = {rf_out_d, rf_out_e};
                                2'd2: mem_addr = hl_val;
                                2'd3: mem_addr = hl_val;
                            endcase
                            mem_wr    = 1'b1;
                            mem_wdata = rf_out_a;
                            // HL+/HL-
                            if (ir[5:4] == 2'd2) begin
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = 2'd2;
                                rf_r16_wdata = hl_val + 16'd1;
                            end else if (ir[5:4] == 2'd3) begin
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = 2'd2;
                                rf_r16_wdata = hl_val - 16'd1;
                            end
                        end
                    end

                    // INC r16
                    8'b00_??_0011: begin
                        if (m_cycle == 3'd1) begin
                            rf_r16_we    = 1'b1;
                            rf_r16_wsel  = dec_r16_idx;
                            rf_r16_wdata = r16_val + 16'd1;
                        end
                    end

                    // INC (HL)
                    8'h34: begin
                        alu_a = z_reg;
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = hl_val;
                                mem_rd   = 1'b1;
                            end
                            3'd2: begin
                                mem_addr  = hl_val;
                                mem_wr    = 1'b1;
                                mem_wdata = alu_result;
                                rf_flags_we    = 1'b1;
                                rf_flags_wdata = alu_flags_out;
                            end
                            default: ;
                        endcase
                    end

                    // DEC (HL)
                    8'h35: begin
                        alu_a = z_reg;
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = hl_val;
                                mem_rd   = 1'b1;
                            end
                            3'd2: begin
                                mem_addr  = hl_val;
                                mem_wr    = 1'b1;
                                mem_wdata = alu_result;
                                rf_flags_we    = 1'b1;
                                rf_flags_wdata = alu_flags_out;
                            end
                            default: ;
                        endcase
                    end

                    // LD (HL), u8
                    8'h36: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr  = hl_val;
                                mem_wr    = 1'b1;
                                mem_wdata = z_reg;
                            end
                            default: ;
                        endcase
                    end

                    // LD r8, u8 (not HL)
                    8'b00_???_110: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr = rf_pc;
                            mem_rd   = 1'b1;
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = dec_r8_dst;
                            rf_r8_wdata = mem_rdata;
                            rf_pc_we    = 1'b1;
                            rf_pc_wdata = rf_pc + 16'd1;
                        end
                    end

                    // ADD HL, r16
                    8'b00_??_1001: begin
                        if (m_cycle == 3'd1) begin
                            rf_r16_we    = 1'b1;
                            rf_r16_wsel  = 2'd2;  // HL
                            rf_r16_wdata = hl_val + r16_val;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = {rf_flags[3], 1'b0,
                                ({1'b0, hl_val[11:0]} + {1'b0, r16_val[11:0]}) > 13'hFFF ? 1'b1 : 1'b0,
                                ({1'b0, hl_val} + {1'b0, r16_val}) > 17'hFFFF ? 1'b1 : 1'b0};
                        end
                    end

                    // LD A, (r16mem)
                    8'b00_??_1010: begin
                        if (m_cycle == 3'd1) begin
                            unique case (ir[5:4])
                                2'd0: mem_addr = {rf_out_b, rf_out_c};
                                2'd1: mem_addr = {rf_out_d, rf_out_e};
                                2'd2: mem_addr = hl_val;
                                2'd3: mem_addr = hl_val;
                            endcase
                            mem_rd = 1'b1;
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = 3'd7;  // A
                            rf_r8_wdata = mem_rdata;
                            if (ir[5:4] == 2'd2) begin
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = 2'd2;
                                rf_r16_wdata = hl_val + 16'd1;
                            end else if (ir[5:4] == 2'd3) begin
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = 2'd2;
                                rf_r16_wdata = hl_val - 16'd1;
                            end
                        end
                    end

                    // DEC r16
                    8'b00_??_1011: begin
                        if (m_cycle == 3'd1) begin
                            rf_r16_we    = 1'b1;
                            rf_r16_wsel  = dec_r16_idx;
                            rf_r16_wdata = r16_val - 16'd1;
                        end
                    end

                    // JR i8 (unconditional)
                    8'h18: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + {{8{z_reg[7]}}, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // JR cond, i8
                    8'h20, 8'h28, 8'h30, 8'h38: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                // Only reached if cond_met (decoder gave mcycles=3)
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + {{8{z_reg[7]}}, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // LD (u16), SP
                    8'h08: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                mem_addr  = {w_reg, z_reg};
                                mem_wr    = 1'b1;
                                mem_wdata = rf_sp[7:0];
                            end
                            3'd4: begin
                                mem_addr  = {w_reg, z_reg} + 16'd1;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_sp[15:8];
                            end
                            default: ;
                        endcase
                    end

                    // LD (HL), r8
                    8'b01_110_???: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr  = hl_val;
                            mem_wr    = 1'b1;
                            mem_wdata = r8_src_val;
                        end
                    end

                    // LD r8, (HL)
                    8'b01_???_110: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr = hl_val;
                            mem_rd   = 1'b1;
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = dec_r8_dst;
                            rf_r8_wdata = mem_rdata;
                        end
                    end

                    // ALU A, (HL)
                    8'b10_???_110: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr = hl_val;
                            mem_rd   = 1'b1;
                            alu_a = rf_out_a;
                            alu_b = mem_rdata;
                            rf_r8_we    = (dec_r8_dst != 3'd7);  // Not CP
                            rf_r8_wsel  = 3'd7;  // A
                            rf_r8_wdata = alu_result;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                        end
                    end

                    // RET cond
                    8'hC0, 8'hC8, 8'hD0, 8'hD8: begin
                        unique case (m_cycle)
                            3'd1: begin end  // internal: evaluate condition
                            3'd2: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd3: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd4: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // POP r16stk
                    8'hC1, 8'hD1, 8'hE1, 8'hF1: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we        = 1'b1;
                                rf_sp_wdata     = rf_sp + 16'd1;
                                rf_r16stk_we    = 1'b1;
                                rf_r16stk_wsel  = dec_r16_idx;
                                rf_r16stk_wdata = {mem_rdata, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // JP cond, u16
                    8'hC2, 8'hCA, 8'hD2, 8'hDA: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                // Only reached if cond_met
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // JP u16
                    8'hC3: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // CALL cond, u16
                    8'hC4, 8'hCC, 8'hD4, 8'hDC: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                // Internal: decrement SP
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd4: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[15:8];
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd5: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[7:0];
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // PUSH r16stk
                    8'hC5, 8'hD5, 8'hE5, 8'hF5: begin
                        // Inline stack pair read mux
                        logic [15:0] push_val;
                        push_val = 16'h0000;
                        unique case (ir[5:4])
                            2'd0: push_val = {rf_out_b, rf_out_c};
                            2'd1: push_val = {rf_out_d, rf_out_e};
                            2'd2: push_val = {rf_out_h, rf_out_l};
                            2'd3: push_val = {rf_out_a, rf_out_f};
                        endcase
                        unique case (m_cycle)
                            3'd1: begin
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd2: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = push_val[15:8];
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd3: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = push_val[7:0];
                            end
                            default: ;
                        endcase
                    end

                    // ALU A, u8
                    8'b11_???_110: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr = rf_pc;
                            mem_rd   = 1'b1;
                            alu_a = rf_out_a;
                            alu_b = mem_rdata;
                            rf_r8_we    = (dec_r8_dst != 3'd7);  // Not CP
                            rf_r8_wsel  = 3'd7;  // A
                            rf_r8_wdata = alu_result;
                            rf_flags_we    = 1'b1;
                            rf_flags_wdata = alu_flags_out;
                            rf_pc_we    = 1'b1;
                            rf_pc_wdata = rf_pc + 16'd1;
                        end
                    end

                    // RST n
                    8'b11_???_111: begin
                        unique case (m_cycle)
                            3'd1: begin
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd2: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[15:8];
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd3: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[7:0];
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {13'd0, dec_rst_vec} << 3;
                            end
                            default: ;
                        endcase
                    end

                    // RET
                    8'hC9: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd3: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // RETI
                    8'hD9: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_sp;
                                mem_rd   = 1'b1;
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + 16'd1;
                            end
                            3'd3: begin
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // CALL u16
                    8'hCD: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd4: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[15:8];
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp - 16'd1;
                            end
                            3'd5: begin
                                mem_addr  = rf_sp;
                                mem_wr    = 1'b1;
                                mem_wdata = rf_pc[7:0];
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = {w_reg, z_reg};
                            end
                            default: ;
                        endcase
                    end

                    // LDH (FF00+u8), A
                    8'hE0: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr  = {8'hFF, z_reg};
                                mem_wr    = 1'b1;
                                mem_wdata = rf_out_a;
                            end
                            default: ;
                        endcase
                    end

                    // LDH A, (FF00+u8)
                    8'hF0: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = {8'hFF, z_reg};
                                mem_rd   = 1'b1;
                                rf_r8_we    = 1'b1;
                                rf_r8_wsel  = 3'd7;  // A
                                rf_r8_wdata = mem_rdata;
                            end
                            default: ;
                        endcase
                    end

                    // LDH (FF00+C), A
                    8'hE2: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr  = {8'hFF, rf_out_c};
                            mem_wr    = 1'b1;
                            mem_wdata = rf_out_a;
                        end
                    end

                    // LDH A, (FF00+C)
                    8'hF2: begin
                        if (m_cycle == 3'd1) begin
                            mem_addr = {8'hFF, rf_out_c};
                            mem_rd   = 1'b1;
                            rf_r8_we    = 1'b1;
                            rf_r8_wsel  = 3'd7;
                            rf_r8_wdata = mem_rdata;
                        end
                    end

                    // LD (u16), A
                    8'hEA: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                mem_addr  = {w_reg, z_reg};
                                mem_wr    = 1'b1;
                                mem_wdata = rf_out_a;
                            end
                            default: ;
                        endcase
                    end

                    // LD A, (u16)
                    8'hFA: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd3: begin
                                mem_addr = {w_reg, z_reg};
                                mem_rd   = 1'b1;
                                rf_r8_we    = 1'b1;
                                rf_r8_wsel  = 3'd7;
                                rf_r8_wdata = mem_rdata;
                            end
                            default: ;
                        endcase
                    end

                    // ADD SP, i8
                    8'hE8: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                logic [4:0]  sp_h4;
                                logic [8:0]  sp_c8;
                                sp_h4 = {1'b0, rf_sp[3:0]} + {1'b0, z_reg[3:0]};
                                sp_c8 = {1'b0, rf_sp[7:0]} + {1'b0, z_reg};
                                rf_sp_we    = 1'b1;
                                rf_sp_wdata = rf_sp + {{8{z_reg[7]}}, z_reg};
                                rf_flags_we    = 1'b1;
                                rf_flags_wdata = {1'b0, 1'b0, sp_h4[4], sp_c8[8]};
                            end
                            default: ;
                        endcase
                    end

                    // LD HL, SP+i8
                    8'hF8: begin
                        unique case (m_cycle)
                            3'd1: begin
                                mem_addr = rf_pc;
                                mem_rd   = 1'b1;
                                rf_pc_we    = 1'b1;
                                rf_pc_wdata = rf_pc + 16'd1;
                            end
                            3'd2: begin
                                logic [4:0]  hl_h4;
                                logic [8:0]  hl_c8;
                                hl_h4 = {1'b0, rf_sp[3:0]} + {1'b0, z_reg[3:0]};
                                hl_c8 = {1'b0, rf_sp[7:0]} + {1'b0, z_reg};
                                rf_r16_we    = 1'b1;
                                rf_r16_wsel  = 2'd2;
                                rf_r16_wdata = rf_sp + {{8{z_reg[7]}}, z_reg};
                                rf_flags_we    = 1'b1;
                                rf_flags_wdata = {1'b0, 1'b0, hl_h4[4], hl_c8[8]};
                            end
                            default: ;
                        endcase
                    end

                    // LD SP, HL
                    8'hF9: begin
                        if (m_cycle == 3'd1) begin
                            rf_sp_we    = 1'b1;
                            rf_sp_wdata = hl_val;
                        end
                    end

                    default: ;
                endcase
            end
        end
    end
    // verilator lint_on CASEOVERLAP

    // =================================================================
    // Sequential logic — ONLY state machine updates
    // =================================================================
    // verilator lint_off CASEOVERLAP
    always_ff @(posedge clk) begin
        if (reset) begin
            ir        <= 8'h00;
            m_cycle   <= 3'd0;
            z_reg     <= 8'h00;
            w_reg     <= 8'h00;
            cb_mode   <= 1'b0;
            halt_mode <= 1'b0;
            ime       <= 1'b0;
            ie_delay  <= 1'b0;
        end else if (halt_mode) begin
            // Stay halted
        end else begin
            // EI delay
            if (ie_delay) begin
                ime      <= 1'b1;
                ie_delay <= 1'b0;
            end

            if (m_cycle == 0) begin
                // FETCH: latch opcode
                ir <= mem_rdata;

                if (dec_is_cb_prefix) begin
                    cb_mode <= 1'b1;
                    m_cycle <= 3'd0;
                end else if (dec_is_halt) begin
                    halt_mode <= 1'b1;
                end else if (dec_is_ei) begin
                    ie_delay <= 1'b1;
                end else if (dec_is_di) begin
                    ime <= 1'b0;
                end else if (dec_mcycles == 3'd1) begin
                    // Single-cycle: already executed in comb, stay in fetch
                    m_cycle <= 3'd0;
                    if (cb_mode) cb_mode <= 1'b0;
                end else begin
                    m_cycle <= 3'd1;
                end

            end else begin
                // EXECUTE: update temps from memory reads
                if (cb_mode) begin
                    if (m_cycle == 3'd1 && ir[2:0] == 3'd6)
                        z_reg <= mem_rdata;
                end else begin
                    casez (ir)
                        // Instructions that latch mem_rdata into z/w
                        8'b00_??_0001: begin  // LD r16, u16
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'h34, 8'h35: begin  // INC/DEC (HL)
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'h36: begin  // LD (HL), u8
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'h18: begin  // JR i8
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'h20, 8'h28, 8'h30, 8'h38: begin  // JR cond
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'h08: begin  // LD (u16), SP
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hC0, 8'hC8, 8'hD0, 8'hD8: begin  // RET cond
                            if (m_cycle == 3'd2) z_reg <= mem_rdata;
                            if (m_cycle == 3'd3) w_reg <= mem_rdata;
                        end
                        8'hC1, 8'hD1, 8'hE1, 8'hF1: begin  // POP
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'hC2, 8'hCA, 8'hD2, 8'hDA: begin  // JP cond
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hC3: begin  // JP u16
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hC4, 8'hCC, 8'hD4, 8'hDC: begin  // CALL cond
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'b11_???_110: begin  // ALU A, u8
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'hC9: begin  // RET
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hD9: begin  // RETI
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                            if (m_cycle == 3'd3) ime <= 1'b1;
                        end
                        8'hCD: begin  // CALL u16
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hE0: begin  // LDH (u8), A
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'hF0: begin  // LDH A, (u8)
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'hEA: begin  // LD (u16), A
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hFA: begin  // LD A, (u16)
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                            if (m_cycle == 3'd2) w_reg <= mem_rdata;
                        end
                        8'hE8: begin  // ADD SP, i8
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        8'hF8: begin  // LD HL, SP+i8
                            if (m_cycle == 3'd1) z_reg <= mem_rdata;
                        end
                        default: ;
                    endcase
                end

                // Advance or return to fetch
                if (m_cycle == dec_mcycles - 3'd1) begin
                    m_cycle <= 3'd0;
                    if (cb_mode) cb_mode <= 1'b0;
                end else begin
                    m_cycle <= m_cycle + 3'd1;
                end
            end
        end
    end
    // verilator lint_on CASEOVERLAP

endmodule
