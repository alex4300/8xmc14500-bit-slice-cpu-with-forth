// ============================================================================
// uart_test_noreset.v — Same as uart_test.v but independent of btn_rst_n
// ============================================================================
// Uses only POR via init values on regs. If btn_rst_n is stuck or the reset
// chain is broken, this variant should still send "Hi!\n" once per second.
// ============================================================================

module uart_test_noreset (
    input  wire       clk27,
    input  wire       btn_rst_n,   // declared but ignored
    input  wire       uart_rx,     // declared but ignored
    output wire       uart_tx,
    output wire [5:0] led
);
    // No reset synchronizer. Regs start from their `initial` values on
    // configuration load. Gowin supports initial values on flip-flops.

    wire       tx_busy;
    reg        tx_start = 0;
    reg  [7:0] tx_data  = 0;

    // uart_tx gets a constant "always released" reset (always 1).
    wire rst_n_const = 1'b1;

    uart_tx #(.CLK_HZ(27_000_000), .BAUD_RATE(115200)) u_tx (
        .clk(clk27), .rst_n(rst_n_const),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(uart_tx), .tx_busy(tx_busy)
    );

    // Message characters encoded directly — no memory array.
    function [7:0] msg_char;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: msg_char = 8'h48;   // 'H'
                2'd1: msg_char = 8'h69;   // 'i'
                2'd2: msg_char = 8'h21;   // '!'
                2'd3: msg_char = 8'h0A;   // '\n'
                default: msg_char = 8'h3F; // '?'
            endcase
        end
    endfunction

    reg [25:0] delay_cnt = 0;
    reg [1:0]  msg_idx   = 0;
    reg [1:0]  state     = 0;

    always @(posedge clk27) begin
        tx_start <= 1'b0;
        case (state)
            2'd0: begin
                if (delay_cnt == 26'd27_000_000) begin
                    delay_cnt <= 0;
                    msg_idx   <= 0;
                    state     <= 1;
                end else delay_cnt <= delay_cnt + 1;
            end
            2'd1: begin
                if (!tx_busy) begin
                    tx_data  <= msg_char(msg_idx);
                    tx_start <= 1'b1;
                    state    <= 2;
                end
            end
            2'd2: begin
                if (!tx_busy) begin
                    if (msg_idx == 2'd3) state <= 0;
                    else begin
                        msg_idx <= msg_idx + 2'd1;
                        state   <= 1;
                    end
                end
            end
        endcase
    end

    // Simple LED: heartbeat on LED0, tx_start echo on LED1 (active-low LEDs).
    reg [25:0] hb = 0;
    always @(posedge clk27) hb <= hb + 1;

    reg [15:0] tx_blink = 0;
    always @(posedge clk27) begin
        if (tx_start) tx_blink <= 16'hFFFF;
        else if (tx_blink != 0) tx_blink <= tx_blink - 1;
    end

    // LED mapping (active-low on board):
    //   led[0] = heartbeat → physical LED5 blinks
    //   led[1] = tx_start activity → physical LED4 blinks per byte
    //   led[5] = "always on" marker → physical LED0 steady ON = bitstream alive
    assign led = ~{1'b1, 3'b000, (tx_blink != 0), hb[25]};
endmodule
