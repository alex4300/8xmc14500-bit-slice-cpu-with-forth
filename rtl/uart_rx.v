// ============================================================================
// uart_rx.v — 8-N-1 UART Receiver with 1-byte buffer
// ============================================================================
// Samples the incoming line at CLKS_PER_BIT / 2 offsets (mid-bit sampling).
// Double-registers rx_in for metastability.
// After a full byte arrives, `rx_ready` goes high and stays high until
// `rx_ack` is pulsed (CPU reads the byte). If a new byte arrives before
// ack, it overwrites the buffer (no flow control).
// ============================================================================

module uart_rx #(
    parameter CLK_HZ    = 27_000_000,
    parameter BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_in,        // serial input
    input  wire       rx_ack,       // pulse: byte consumed, clear ready
    output reg  [7:0] rx_data,      // received byte (valid when rx_ready)
    output reg        rx_ready      // high when a new byte is in rx_data
);

    localparam CLKS_PER_BIT = CLK_HZ / BAUD_RATE;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;
    localparam CNT_W        = $clog2(CLKS_PER_BIT);

    // Double-register input for metastability
    reg rx_meta;
    reg rx_sync;
    always @(posedge clk) begin
        rx_meta <= rx_in;
        rx_sync <= rx_meta;
    end

    // FSM
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]      state;
    reg [CNT_W-1:0] cnt;
    reg [3:0]      bit_idx;
    reg [7:0]      shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            cnt      <= 0;
            bit_idx  <= 0;
            shift    <= 8'h00;
            rx_data  <= 8'h00;
            rx_ready <= 1'b0;
        end else begin
            if (rx_ack) rx_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (rx_sync == 1'b0) begin
                        // Start bit detected → wait half bit to center
                        state <= S_START;
                        cnt   <= 0;
                    end
                end
                S_START: begin
                    if (cnt == HALF_BIT - 1) begin
                        // Middle of start bit — confirm still low
                        if (rx_sync == 1'b0) begin
                            cnt     <= 0;
                            state   <= S_DATA;
                            bit_idx <= 0;
                        end else begin
                            state <= S_IDLE;   // glitch
                        end
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
                S_DATA: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt        <= 0;
                        shift      <= {rx_sync, shift[7:1]};  // LSB first
                        if (bit_idx == 7) begin
                            state <= S_STOP;
                        end
                        bit_idx    <= bit_idx + 1;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
                S_STOP: begin
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt      <= 0;
                        state    <= S_IDLE;
                        // Commit byte (overwrites any previous unread byte)
                        rx_data  <= shift;
                        rx_ready <= 1'b1;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule
