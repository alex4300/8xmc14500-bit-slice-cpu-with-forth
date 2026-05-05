// ============================================================================
// tb_fpga_test.v — Simulates the exact fpga_test.v FPGA-top with the
// test_uart_simple.asm program, sampling the uart_tx output as a real
// UART receiver would.
// ============================================================================
// This tests whether the RTL (CPU + bridge + uart_tx) produces clean UART
// frames. If sim shows correct 'U' bytes and the FPGA doesn't, the bug is
// synth-specific (yosys/Gowin). If sim also misbehaves, we have an RTL bug
// and a reproducible case.
// ============================================================================

`define FPGA_INLINE_INIT
`define FPGA_BUILD

module tb_fpga_test;

    reg  clk27 = 0;
    reg  btn_rst_n = 0;
    wire uart_rx = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    // 27 MHz clock
    always #18.5 clk27 = ~clk27;   // ~27.027 MHz

    mc14500_fpga_test dut (
        .clk27(clk27),
        .btn_rst_n(btn_rst_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led(led)
    );

    // ------------------------------------------------------------------
    // UART RX model (115200 baud, 8-N-1) — samples uart_tx pin and
    // reconstructs bytes. Prints them as hex + char.
    // ------------------------------------------------------------------
    localparam integer CLK_HZ    = 27_000_000;
    localparam integer BAUD      = 115200;
    localparam integer CLKS_BIT  = CLK_HZ / BAUD;          // 234
    localparam integer HALF_BIT  = CLKS_BIT / 2;

    reg       uart_rx_prev = 1'b1;
    integer   state      = 0;     // 0 idle, 1 sampling
    integer   bit_cnt    = 0;
    integer   bit_idx    = 0;
    reg [7:0] rx_shift   = 0;
    integer   byte_count = 0;

    always @(posedge clk27) begin
        case (state)
            0: begin
                // Look for falling edge = start bit
                if (uart_rx_prev == 1'b1 && uart_tx == 1'b0) begin
                    state   <= 1;
                    bit_cnt <= 0;
                    bit_idx <= 0;
                end
            end
            1: begin
                bit_cnt <= bit_cnt + 1;
                // Sample in middle of each bit. First sample at HALF_BIT into
                // start bit → bit_idx 0..9 (start + 8 data + stop).
                if (bit_cnt == HALF_BIT + bit_idx * CLKS_BIT) begin
                    if (bit_idx >= 1 && bit_idx <= 8) begin
                        rx_shift[bit_idx - 1] <= uart_tx;
                    end
                    if (bit_idx == 9) begin
                        // Stop bit should be 1
                        byte_count = byte_count + 1;
                        $display("[%0t] RX byte #%0d: 0x%02x %s  (stop=%b)",
                                 $time, byte_count, rx_shift,
                                 (rx_shift >= 32 && rx_shift < 127) ? rx_shift : "?",
                                 uart_tx);
                        state <= 0;
                    end
                    bit_idx <= bit_idx + 1;
                end
            end
        endcase
        uart_rx_prev <= uart_tx;
    end

    // ------------------------------------------------------------------
    // Also log io_out_valid events and tx_start events for timing context.
    // ------------------------------------------------------------------
    integer io_count = 0;
    integer tx_count = 0;
    always @(posedge clk27) begin
        if (dut.io_out_valid) begin
            io_count = io_count + 1;
            $display("[%0t] io_out_valid #%0d  io_out_data=0x%02x",
                     $time, io_count, dut.io_out_data);
        end
        if (dut.tx_start) begin
            tx_count = tx_count + 1;
            $display("[%0t] tx_start #%0d     tx_data=0x%02x  busy=%b",
                     $time, tx_count, dut.tx_data, dut.tx_busy);
        end
    end

    // ------------------------------------------------------------------
    // Stimulus: release reset, run long enough to see several bytes.
    // test_uart_simple.asm sends one byte per ~65k * 5 = 327k cycles ≈ 12 ms.
    // Run 40 ms sim time = a handful of bytes.
    // ------------------------------------------------------------------
    initial begin
        $dumpfile("build/tb_fpga_test.vcd");
        $dumpvars(0, tb_fpga_test);

        btn_rst_n = 0;
        #500 btn_rst_n = 1;

        // Run ~40 ms of sim time
        #40_000_000;

        $display("");
        $display("==== Summary ====");
        $display("io_out_valid pulses: %0d", io_count);
        $display("tx_start pulses:     %0d", tx_count);
        $display("UART bytes received: %0d", byte_count);
        $finish;
    end

endmodule
