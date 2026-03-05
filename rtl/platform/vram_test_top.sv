// VRAM write test — CPU executes a small BSRAM ROM that writes tile data
// and a tilemap to VRAM, sets BGP/LCDC, then halts. No SDRAM involved.
//
// If the display shows horizontal black/white stripes, the CPU→VRAM→PPU→LCD
// pipeline works. If corrupted, the bug is in the CPU/bus/PPU path itself
// (not SDRAM).
module vram_test_top (
    input  logic       clk,
    input  logic       btn_s1,
    input  logic       btn_s2,
    output logic [5:0] led,

    output logic       lcd_rst,
    output logic       lcd_cs,
    output logic       lcd_dc,
    output logic       lcd_sclk,
    output logic       lcd_mosi,
    output logic       lcd_bl,

    output logic       sd_clk,
    output logic       sd_cmd,
    input  logic       sd_dat0,
    output logic       sd_dat1,
    output logic       sd_dat2,
    output logic       sd_dat3,

    input  logic       btn_right,
    input  logic       btn_left,
    input  logic       btn_up,
    input  logic       btn_down,
    input  logic       btn_a,
    input  logic       btn_b,
    input  logic       btn_select,
    input  logic       btn_start,

    output logic       uart_tx,
    input  logic       uart_rx,

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

    gb_top #(
        .ROM_SIZE     (64),
        .ROM_FILE     ("sim/data/vram_test.hex"),
        .USE_SD       (0),
        .PPU_PRESCALE (88)
    ) u_gb (
        .clk          (clk),
        .btn_s1       (btn_s1),
        .btn_s2       (btn_s2),
        .led          (led),
        .lcd_rst      (lcd_rst),
        .lcd_cs       (lcd_cs),
        .lcd_dc       (lcd_dc),
        .lcd_sclk     (lcd_sclk),
        .lcd_mosi     (lcd_mosi),
        .lcd_bl       (lcd_bl),
        .sd_clk       (sd_clk),
        .sd_cmd       (sd_cmd),
        .sd_dat0      (sd_dat0),
        .sd_dat1      (sd_dat1),
        .sd_dat2      (sd_dat2),
        .sd_dat3      (sd_dat3),
        .btn_right    (btn_right),
        .btn_left     (btn_left),
        .btn_up       (btn_up),
        .btn_down     (btn_down),
        .btn_a        (btn_a),
        .btn_b        (btn_b),
        .btn_select   (btn_select),
        .btn_start    (btn_start),
        .uart_tx      (uart_tx),
        .uart_rx      (uart_rx),
        .O_sdram_clk  (O_sdram_clk),
        .O_sdram_cke  (O_sdram_cke),
        .O_sdram_cs_n (O_sdram_cs_n),
        .O_sdram_ras_n(O_sdram_ras_n),
        .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_addr (O_sdram_addr),
        .O_sdram_ba   (O_sdram_ba),
        .O_sdram_dqm  (O_sdram_dqm),
        .IO_sdram_dq  (IO_sdram_dq)
    );

endmodule
