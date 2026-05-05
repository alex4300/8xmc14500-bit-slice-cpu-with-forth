// ============================================================================
// mc14500_fpga_test.v — FPGA CPU test WITHOUT SYNC_MEM pipeline
// ============================================================================
// Uses SYNC_MEM=0 (combinational reads) + tiny RAM (256 bytes, fits in LUTs).
// ROM is also small (64 words). Loads test_fpga.asm which just sends "Hi!".
// Purpose: verify CPU works on FPGA AT ALL, bypassing the 3-phase pipeline.
// ============================================================================

module mc14500_fpga_test (
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

    // CPU signals
    wire [7:0]  io_out_data;
    wire        io_out_valid;
    wire        io_in_read;
    wire [14:0] debug_pc;
    wire        debug_halted;
    wire        debug_rom_loaded;

    // UART TX
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

    uart_tx #(.CLK_HZ(27_000_000), .BAUD_RATE(115200)) u_tx (
        .clk(clk27), .rst_n(rst_n),
        .tx_data(tx_data), .tx_start(tx_start),
        .tx(uart_tx), .tx_busy(tx_busy)
    );

    // Bridge uses a small state machine identical in shape to uart_test.v:
    // latch tx_data on io_out_valid, then drive tx_start high until uart_tx
    // asserts tx_busy (one fewer sampling-window race mode than a 1-cycle
    // pulse). `pending` lets us remember a write that arrived while busy.
    reg       pending;
    reg [7:0] pending_data;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            tx_start     <= 1'b0;
            tx_data      <= 8'h00;
            pending      <= 1'b0;
            pending_data <= 8'h00;
        end else begin
            // Capture CPU writes into a 1-deep hold buffer.
            if (io_out_valid) begin
                pending      <= 1'b1;
                pending_data <= io_out_data;
            end

            // Drive uart_tx when it's idle and we have a byte to send.
            if (tx_start) begin
                // Hold until uart_tx acknowledges by raising busy
                if (tx_busy) tx_start <= 1'b0;
            end else if (pending && !tx_busy) begin
                tx_data  <= pending_data;
                tx_start <= 1'b1;
                pending  <= 1'b0;
            end
        end
    end

    // CPU — SYNC_MEM=0 (combinational), tiny memories (fit in LUTs)
    mc14500_cpu #(
        .ROM_DEPTH   (64),        // tiny! test_fpga.asm is ~20 instructions
        .RAM_DEPTH   (256),       // tiny! just needs address 0x00 for temp
        .STACK_DEPTH (8),
        .ROM_FILE    ("build/forth.mem"),   // we'll copy test_fpga.mem here
        .RAM_FILE    (""),
        .SYNC_MEM    (0)          // NO pipeline — combinational reads
    ) cpu (
        .clk              (clk27),
        .rst_n            (rst_n),
        .debug_rr         (),
        .debug_pc         (debug_pc),
        .debug_flag_z     (),
        .debug_flag_c     (),
        .debug_flag_v     (),
        .debug_halted     (debug_halted),
        .io_out_data      (io_out_data),
        .io_out_valid     (io_out_valid),
        .io_in_read       (io_in_read),
        .io_in_data       (8'h00),
        .io_status        ({6'b0, 1'b0, ~tx_busy}),
        .io_stall         (1'b0),
        .gpio_out_data    (),
        .gpio_out_we      (),
        .gpio_in_data     (8'h00),
        // Storage not used
        .storage_block_lo_data(), .storage_block_lo_we(),
        .storage_block_hi_data(), .storage_block_hi_we(),
        .storage_data_out(), .storage_data_we(), .storage_data_re(),
        .storage_data_in(8'h00),
        .debug_ram_addr   (),
        .debug_ram_wdata  (),
        .debug_ram_we     (),
        .debug_rom_loaded (debug_rom_loaded)
    );

    // LEDs & debug
    reg [25:0] hb;
    always @(posedge clk27) hb <= hb + 1;

    // wr_blink: extends io_out_valid (single-cycle) into ~2.4 ms pulse
    reg [15:0] wr_blink;
    always @(posedge clk27) begin
        if (io_out_valid) wr_blink <= 16'hFFFF;
        else if (wr_blink != 0) wr_blink <= wr_blink - 1;
    end

    // tx_blink: extends the bridge's tx_start pulse so we can actually see it
    reg [15:0] tx_blink;
    always @(posedge clk27) begin
        if (tx_start)           tx_blink <= 16'hFFFF;
        else if (tx_blink != 0) tx_blink <= tx_blink - 1;
    end

    // Latch io_out_data whenever the CPU fires io_out_valid — lets us read
    // the last captured byte straight off LEDs. Low 2 bits go on LED0/LED1,
    // and we replace heartbeat/halt indicators with data bits for this debug.
    reg [7:0] last_byte;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)           last_byte <= 8'h00;
        else if (io_out_valid) last_byte <= io_out_data;
    end

    // For 'U' = 0x55 = 01010101: bits[1:0] = 01  → LED1 off, LED0 on
    //                            bits[3:2] = 01  → LED3 off, LED2 on
    // I.e. an alternating 0/1/0/1 pattern on LEDs 0..3 means 'U' is being
    // sent. Anything else is a wrong byte.
    assign led = ~{
        (wr_blink != 0),       // LED5: CPU fired io_out_valid (unchanged)
        (tx_blink != 0),       // LED4: bridge latched tx_start (was ROM-loaded)
        last_byte[3],          // LED3: last-sent byte bit 3
        last_byte[2],          // LED2: last-sent byte bit 2
        last_byte[1],          // LED1: last-sent byte bit 1
        last_byte[0]           // LED0: last-sent byte bit 0
    };

endmodule
