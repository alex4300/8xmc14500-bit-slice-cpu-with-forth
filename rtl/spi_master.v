// ============================================================================
// spi_master.v — 8-bit SPI master, Mode 0, byte-at-a-time
// ============================================================================
// Full-duplex: each transaction shifts out `tx_data` while shifting in one
// byte on MISO. No CS handling — that's a separate GPIO, driven by the CPU
// via the SPI_CS MMIO register. One transaction at a time; the CPU polls
// `busy` before starting the next.
//
// SPI Mode 0: CPOL=0 (SCK idle low), CPHA=0 (sample on rising, shift on
// falling). Standard for SD-in-SPI-mode.
//
// Clock: SCK = clk / (2 * CLK_DIV). For SD init the standard mandates
// 100-400 kHz. At clk=27 MHz: CLK_DIV=64 → SCK ≈ 210 kHz (safe for init).
// ============================================================================

module spi_master #(
    parameter CLK_DIV = 64      // half-period of SCK in system cycles
)(
    input  wire        clk,
    input  wire        rst_n,

    // CPU-facing interface
    input  wire [7:0]  tx_data,
    input  wire        tx_start,      // 1-cycle pulse; starts a transaction if !busy
    output wire [7:0]  rx_data,
    output wire        busy,

    // SPI pins
    output reg         sck,
    output reg         mosi,
    input  wire        miso
);

    reg  [3:0]  bit_cnt;    // 0 = idle; otherwise remaining bit-pairs
    reg  [7:0]  shift;      // TX on shift-out, RX on shift-in
    reg  [15:0] div_cnt;    // clock-divider counter
    reg         half;       // 0 = next edge rises SCK (sample); 1 = falls (advance)

    assign busy    = (bit_cnt != 4'd0);
    assign rx_data = shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck     <= 1'b0;
            mosi    <= 1'b1;
            bit_cnt <= 4'd0;
            shift   <= 8'hFF;
            div_cnt <= 16'd0;
            half    <= 1'b0;
        end else if (!busy && tx_start) begin
            // Load: drive MSB on MOSI, arm for 8 SCK cycles, first edge is rising
            shift   <= tx_data;
            mosi    <= tx_data[7];
            sck     <= 1'b0;
            bit_cnt <= 4'd8;
            half    <= 1'b0;
            div_cnt <= CLK_DIV - 1;
        end else if (busy) begin
            if (div_cnt != 0) begin
                div_cnt <= div_cnt - 1'b1;
            end else begin
                div_cnt <= CLK_DIV - 1;
                if (half == 1'b0) begin
                    // Rising edge: SCK high, sample MISO into LSB, pushing
                    // old MSB out — shift[7] after this is the next TX bit.
                    sck   <= 1'b1;
                    shift <= {shift[6:0], miso};
                    half  <= 1'b1;
                end else begin
                    // Falling edge: SCK low, commit next TX bit to MOSI,
                    // count down. When bit_cnt reaches 0, we're done.
                    sck     <= 1'b0;
                    half    <= 1'b0;
                    bit_cnt <= bit_cnt - 1'b1;
                    if (bit_cnt == 4'd1)
                        mosi <= 1'b1;          // done → idle MOSI high
                    else
                        mosi <= shift[7];      // next bit (shifted up on rising)
                end
            end
        end
    end

endmodule
