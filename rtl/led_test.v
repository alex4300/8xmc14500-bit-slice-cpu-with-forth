// ============================================================================
// led_test.v — Diagnose: identifies LED pin order on Tang Primer 20K Dock
// ============================================================================
// Each LED gets a different blink pattern so we can identify them.
// LED0: 1 Hz heartbeat
// LED1: 2 Hz
// LED2: 4 Hz
// LED3: 8 Hz
// LED4: 16 Hz (visibly fast)
// LED5: solid on
// Also: button presses are echoed to all LEDs (XOR), so we can find btn_rst_n
// ============================================================================

module led_test (
    input  wire       clk27,
    input  wire       btn_rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);

    reg [25:0] counter;
    always @(posedge clk27) counter <= counter + 1;

    // Different blink rates — LED0 slowest, LED4 fastest
    wire btn_pressed = ~btn_rst_n;

    assign led[0] = ~(counter[25] ^ btn_pressed);  // ~1 Hz
    assign led[1] = ~(counter[24] ^ btn_pressed);  // ~2 Hz
    assign led[2] = ~(counter[23] ^ btn_pressed);  // ~4 Hz
    assign led[3] = ~(counter[22] ^ btn_pressed);  // ~8 Hz
    assign led[4] = ~(counter[21] ^ btn_pressed);  // ~16 Hz
    assign led[5] = ~(1'b1            ^ btn_pressed); // solid on (off when pressed)

    // UART loopback test: echo back what we receive
    assign uart_tx = uart_rx;

endmodule
