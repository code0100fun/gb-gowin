// Minimal UART echo test — no CPU, no Game Boy.
// Receives bytes via UART, echoes them back, and displays the last
// received byte's lower 6 bits on the LEDs.
//
// Flash and test:
//   mise run flash -- serial_test_top
//   picocom -b 115200 /dev/ttyUSB1
//   (type characters — they echo back, LEDs show the value)
module serial_test_top (
    input  logic       clk,        // 27 MHz
    input  logic       btn_s1,     // reset
    input  logic       btn_s2,     // unused
    output logic [5:0] led,        // onboard LEDs (active low)

    output logic       uart_tx,
    input  logic       uart_rx
);

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
    // UART TX / RX
    // ---------------------------------------------------------------
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_ready;

    uart_rx u_rx (
        .clk  (clk),
        .reset(reset),
        .rx   (uart_rx),
        .data (rx_data),
        .valid(rx_valid)
    );

    uart_tx u_tx (
        .clk  (clk),
        .reset(reset),
        .data (tx_data),
        .valid(tx_valid),
        .ready(tx_ready),
        .tx   (uart_tx)
    );

    // ---------------------------------------------------------------
    // Echo logic: latch received byte, send it back when TX is free
    // ---------------------------------------------------------------
    logic [7:0] last_byte;
    logic       pending;  // a byte is waiting to be echoed

    always_ff @(posedge clk) begin
        if (reset) begin
            last_byte <= 8'd0;
            pending   <= 1'b0;
            tx_valid  <= 1'b0;
            tx_data   <= 8'd0;
        end else begin
            tx_valid <= 1'b0;

            if (rx_valid) begin
                last_byte <= rx_data;
                pending   <= 1'b1;
            end

            if (pending && tx_ready) begin
                tx_data  <= last_byte;
                tx_valid <= 1'b1;
                pending  <= 1'b0;
            end
        end
    end

    // LEDs show lower 6 bits of last received byte (active low)
    assign led = ~last_byte[5:0];

endmodule
