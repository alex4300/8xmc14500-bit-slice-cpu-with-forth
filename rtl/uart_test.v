// ============================================================================
// uart_test.v — Pure UART TX test, no CPU involved
// ============================================================================
// Sends "Hi!\n" once per second via uart_tx module.
// Tests that uart_tx.v actually works on FPGA hardware.
// ============================================================================

module uart_test (
    input  wire       clk27,
    input  wire       btn_rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [5:0] led
);

    // Reset sync
    reg [7:0] rst_cnt = 0;
    reg       rst_n   = 0;
    always @(posedge clk27) begin
        if (!btn_rst_n) begin rst_cnt <= 0; rst_n <= 0; end
        else if (rst_cnt == 8'hFF) rst_n <= 1;
        else rst_cnt <= rst_cnt + 1;
    end

    // UART TX instance
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

    uart_tx #(.CLK_HZ(27_000_000), .BAUD_RATE(115200)) u_tx (
        .clk(clk27), .rst_n(rst_n),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(uart_tx), .tx_busy(tx_busy)
    );

    // Message: "Hi!\n" = {0x48, 0x69, 0x21, 0x0A}
    reg [7:0] msg [0:3];
    initial begin
        msg[0] = 8'h48;  // H
        msg[1] = 8'h69;  // i
        msg[2] = 8'h21;  // !
        msg[3] = 8'h0A;  // newline
    end

    // State machine: send 4 bytes, then wait ~1 second, repeat
    reg [25:0] delay_cnt;
    reg [2:0]  msg_idx;
    reg [1:0]  state;   // 0=idle/delay, 1=send, 2=wait_tx_done

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state     <= 0;
            msg_idx   <= 0;
            delay_cnt <= 0;
            tx_start  <= 0;
            tx_data   <= 0;
        end else begin
            tx_start <= 0;

            case (state)
                2'd0: begin // delay
                    if (delay_cnt == 26'd27_000_000) begin
                        delay_cnt <= 0;
                        msg_idx   <= 0;
                        state     <= 1;
                    end else begin
                        delay_cnt <= delay_cnt + 1;
                    end
                end
                2'd1: begin // start send
                    if (!tx_busy) begin
                        tx_data  <= msg[msg_idx];
                        tx_start <= 1;
                        state    <= 2;
                    end
                end
                2'd2: begin // wait for tx done
                    if (!tx_busy) begin
                        if (msg_idx == 3) begin
                            state <= 0;  // back to delay
                        end else begin
                            msg_idx <= msg_idx + 1;
                            state   <= 1;  // next char
                        end
                    end
                end
                default: state <= 0;
            endcase
        end
    end

    // --- BRAM init test: read forth.mem and show first word on LEDs ---
    reg [47:0] bram_test [0:7];
    initial $readmemh("build/forth.mem", bram_test);

    // bram_test[0] should be the JMP init instruction (non-zero).
    // LED5 = bram_ok (1 if ROM has data, 0 if $readmemh failed)
    // LED4..1 = low 4 bits of bram_test[0]
    // LED0 = heartbeat
    reg [25:0] hb;
    always @(posedge clk27) hb <= hb + 1;
    wire bram_ok = (bram_test[0] != 48'h0);
    assign led = ~{bram_ok, bram_test[0][3:0], hb[25]};

endmodule
