// LR35902 register file.
//
// Eight 8-bit registers (A, F, B, C, D, E, H, L), two 16-bit registers
// (SP, PC), and flag extraction from F.
//
// The register file supports:
//   - 8-bit read/write via a 3-bit register index (matching opcode encoding)
//   - 16-bit pair read/write via a 2-bit pair index
//   - Direct flag read/write
//   - SP and PC read/write
//
// Register encoding (r8, matches opcode bits):
//   000=B  001=C  010=D  011=E  100=H  101=L  110=[HL]*  111=A
//   * Index 6 is reserved for [HL] indirect — the CPU handles memory access
//     externally. The regfile returns 0xFF for reads and ignores writes to
//     index 6.
//
// 16-bit pair encoding (r16):
//   00=BC  01=DE  10=HL  11=SP
//
// Stack pair encoding (r16stk, used by PUSH/POP):
//   00=BC  01=DE  10=HL  11=AF
//
// F register: bits [3:0] are hardwired to 0.
//   Bit 7 = Z (Zero), Bit 6 = N (Subtract),
//   Bit 5 = H (Half-carry), Bit 4 = C (Carry)
module regfile (
    input  logic        clk,

    // 8-bit register access
    input  logic [2:0]  r8_rsel,      // read select
    output logic [7:0]  r8_rdata,     // read data
    input  logic        r8_we,        // write enable
    input  logic [2:0]  r8_wsel,      // write select
    input  logic [7:0]  r8_wdata,     // write data

    // 16-bit pair access (r16: BC, DE, HL, SP)
    input  logic [1:0]  r16_rsel,     // read select
    output logic [15:0] r16_rdata,    // read data
    input  logic        r16_we,       // write enable
    input  logic [1:0]  r16_wsel,     // write select
    input  logic [15:0] r16_wdata,    // write data

    // 16-bit stack pair access (r16stk: BC, DE, HL, AF)
    input  logic [1:0]  r16stk_rsel,
    output logic [15:0] r16stk_rdata,
    input  logic        r16stk_we,
    input  logic [1:0]  r16stk_wsel,
    input  logic [15:0] r16stk_wdata,

    // Flag access
    output logic [3:0]  flags,        // {Z, N, H, C}
    input  logic        flags_we,
    input  logic [3:0]  flags_wdata,  // {Z, N, H, C}

    // SP / PC
    output logic [15:0] sp,
    input  logic        sp_we,
    input  logic [15:0] sp_wdata,

    output logic [15:0] pc,
    input  logic        pc_we,
    input  logic [15:0] pc_wdata,

    // Direct register outputs (active simultaneously, no port conflicts)
    output logic [7:0]  out_a, out_f,
    output logic [7:0]  out_b, out_c,
    output logic [7:0]  out_d, out_e,
    output logic [7:0]  out_h, out_l
);

    // Storage: 8 individual registers + SP + PC
    logic [7:0] reg_a, reg_f;
    logic [7:0] reg_b, reg_c;
    logic [7:0] reg_d, reg_e;
    logic [7:0] reg_h, reg_l;
    logic [15:0] reg_sp, reg_pc;

    // Direct register outputs
    assign out_a = reg_a;
    assign out_f = reg_f;
    assign out_b = reg_b;
    assign out_c = reg_c;
    assign out_d = reg_d;
    assign out_e = reg_e;
    assign out_h = reg_h;
    assign out_l = reg_l;

    // Flag extraction — F upper nibble only, lower nibble always 0
    assign flags = reg_f[7:4];

    // SP / PC outputs
    assign sp = reg_sp;
    assign pc = reg_pc;

    // ---------------------------------------------------------------
    // 8-bit read mux (combinational)
    // ---------------------------------------------------------------
    always_comb begin
        unique case (r8_rsel)
            3'd0: r8_rdata = reg_b;
            3'd1: r8_rdata = reg_c;
            3'd2: r8_rdata = reg_d;
            3'd3: r8_rdata = reg_e;
            3'd4: r8_rdata = reg_h;
            3'd5: r8_rdata = reg_l;
            3'd6: r8_rdata = 8'hFF;  // [HL] placeholder — CPU handles this
            3'd7: r8_rdata = reg_a;
        endcase
    end

    // ---------------------------------------------------------------
    // 16-bit pair read mux (r16: BC, DE, HL, SP)
    // ---------------------------------------------------------------
    always_comb begin
        unique case (r16_rsel)
            2'd0: r16_rdata = {reg_b, reg_c};
            2'd1: r16_rdata = {reg_d, reg_e};
            2'd2: r16_rdata = {reg_h, reg_l};
            2'd3: r16_rdata = reg_sp;
        endcase
    end

    // ---------------------------------------------------------------
    // 16-bit stack pair read mux (r16stk: BC, DE, HL, AF)
    // ---------------------------------------------------------------
    always_comb begin
        unique case (r16stk_rsel)
            2'd0: r16stk_rdata = {reg_b, reg_c};
            2'd1: r16stk_rdata = {reg_d, reg_e};
            2'd2: r16stk_rdata = {reg_h, reg_l};
            2'd3: r16stk_rdata = {reg_a, reg_f};
        endcase
    end

    // ---------------------------------------------------------------
    // Write logic (synchronous)
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        // 8-bit register writes
        if (r8_we) begin
            unique case (r8_wsel)
                3'd0: reg_b <= r8_wdata;
                3'd1: reg_c <= r8_wdata;
                3'd2: reg_d <= r8_wdata;
                3'd3: reg_e <= r8_wdata;
                3'd4: reg_h <= r8_wdata;
                3'd5: reg_l <= r8_wdata;
                3'd6: ;  // [HL] — ignored
                3'd7: reg_a <= r8_wdata;
            endcase
        end

        // 16-bit pair writes (r16: BC, DE, HL, SP)
        if (r16_we) begin
            unique case (r16_wsel)
                2'd0: {reg_b, reg_c} <= r16_wdata;
                2'd1: {reg_d, reg_e} <= r16_wdata;
                2'd2: {reg_h, reg_l} <= r16_wdata;
                2'd3: reg_sp         <= r16_wdata;
            endcase
        end

        // 16-bit stack pair writes (r16stk: BC, DE, HL, AF)
        if (r16stk_we) begin
            unique case (r16stk_wsel)
                2'd0: {reg_b, reg_c} <= r16stk_wdata;
                2'd1: {reg_d, reg_e} <= r16stk_wdata;
                2'd2: {reg_h, reg_l} <= r16stk_wdata;
                2'd3: begin
                    reg_a <= r16stk_wdata[15:8];
                    reg_f <= r16stk_wdata[7:0] & 8'hF0;  // mask low nibble
                end
            endcase
        end

        // Direct flag writes
        if (flags_we)
            reg_f <= {flags_wdata, 4'b0000};

        // SP / PC writes
        if (sp_we)
            reg_sp <= sp_wdata;
        if (pc_we)
            reg_pc <= pc_wdata;
    end

endmodule
