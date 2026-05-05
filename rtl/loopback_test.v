// ============================================================================
// loopback_test.v — Pure wire-level UART loopback
// ============================================================================
// Nothing but `assign uart_tx = uart_rx` and a heartbeat LED.
// If typing in the terminal echoes back → CH340/USB/UART path is alive.
// If it doesn't → problem is on the host (wrong port, driver, permissions)
// or the dock's CH340 itself, not our design.
// ============================================================================

module loopback_test (
    input  wire       clk27,
    input  wire       btn_rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);
    // Wire-level loopback — no logic in between.
    assign uart_tx = uart_rx;

    // Heartbeat on LED0 to confirm bitstream is running.
    reg [25:0] hb = 0;
    always @(posedge clk27) hb <= hb + 1;

    // Show uart_rx level on LED1 (active-low, so LED1 lit = uart_rx low).
    // With tio idle (no typing), uart_rx should be HIGH → LED1 off.
    // When typing, brief low pulses → LED1 flickers.
    assign led = ~{4'b0000, ~uart_rx, hb[25]};
endmodule
