// ============================================================================
// uart_tx.v — 8-N-1 UART Transmitter
// ============================================================================
// Standard UART: 1 start bit (low), 8 data bits LSB-first, 1 stop bit (high).
// Parameterizable baud divisor = CLK_HZ / BAUD_RATE.
// Handshake: assert `tx_start` for one clock along with `tx_data`, then wait
// until `tx_busy` deasserts before the next byte.
// ============================================================================

module uart_tx #(
    parameter CLK_HZ    = 27_000_000,
    parameter BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_start,     // pulse for one clock to begin TX
    output reg        tx,           // serial output
    output wire       tx_busy       // high while transmitting
);

    localparam CLKS_PER_BIT = CLK_HZ / BAUD_RATE;
    localparam CNT_W        = $clog2(CLKS_PER_BIT);

    // State
    reg [CNT_W-1:0] bit_cnt;        // clocks elapsed in current bit
    reg [3:0]       bit_idx;        // which bit we're sending (0..9)
    reg [9:0]       shift;          // {stop, data[7:0], start}
    reg             busy;

    assign tx_busy = busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx       <= 1'b1;
            busy     <= 1'b0;
            bit_cnt  <= 0;
            bit_idx  <= 0;
            shift    <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;              // idle high
            if (tx_start) begin
                // Load {stop, data[7:0], start}
                shift   <= {1'b1, tx_data, 1'b0};
                tx      <= 1'b0;     // start bit on line immediately
                busy    <= 1'b1;
                bit_idx <= 0;
                bit_cnt <= 0;
            end
        end else begin
            if (bit_cnt == CLKS_PER_BIT - 1) begin
                bit_cnt <= 0;
                // Shift out next bit
                shift   <= {1'b1, shift[9:1]};
                tx      <= shift[1];
                if (bit_idx == 9) begin
                    busy <= 1'b0;    // done (10 bits sent)
                end
                bit_idx <= bit_idx + 1;
            end else begin
                bit_cnt <= bit_cnt + 1;
            end
        end
    end

endmodule
