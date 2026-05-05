// ============================================================================
// mc14500_top.v — Tang Nano 20K top-level
// ============================================================================
// Wires the CPU to:
//   - 27 MHz onboard oscillator (direct, no PLL for MVP)
//   - USB-C integrated USB-UART (115200 Baud)
//   - 6 onboard LEDs for status
//   - S1 button for user reset (active low)
//
// The CPU's UART MMIO (io_out_data/io_in_data/io_status) is connected to
// uart_tx and uart_rx modules. io_status bit [1] = rx_ready, bit [0] = tx_idle.
//
// Storage interface: optional on-chip BRAM for a small number of Forth blocks
// (not connected for initial bring-up — SD card integration comes later).
// ============================================================================

module mc14500_top (
    input  wire       clk27,        // 27 MHz onboard oscillator
    input  wire       btn_rst_n,    // S1 button (active-low reset)
    input  wire       uart_rx,      // from USB-UART (FT232 on Tang Nano)
    output wire       uart_tx,      // to   USB-UART
    output wire [5:0] led,          // 6 onboard LEDs (active low on some boards)

    // SPI master — wired to SD card on J14 (Mic Array header)
    output wire       sd_sck,
    output wire       sd_cs,
    output wire       sd_mosi,
    input  wire       sd_miso
);

    // ------------------------------------------------------------------------
    // Reset synchronizer
    // ------------------------------------------------------------------------
    // Combine power-on reset + button. Hold reset for a few cycles to let
    // BRAM initialize properly.
    reg [7:0] rst_counter = 0;
    reg       rst_n       = 0;
    always @(posedge clk27) begin
        if (!btn_rst_n) begin
            rst_counter <= 0;
            rst_n       <= 0;
        end else if (rst_counter == 8'hFF) begin
            rst_n <= 1;
        end else begin
            rst_counter <= rst_counter + 1;
        end
    end

    // ------------------------------------------------------------------------
    // CPU signals
    // ------------------------------------------------------------------------
    wire [7:0]  cpu_io_out_data;
    wire        cpu_io_out_valid;
    wire [7:0]  cpu_io_in_data;
    wire [7:0]  cpu_io_status;
    wire [7:0]  debug_rr;
    wire [14:0] debug_pc;
    wire        debug_flag_z;
    wire        debug_flag_c;
    wire        debug_flag_v;
    wire        debug_halted;
    wire        debug_rom_loaded;

    // ------------------------------------------------------------------------
    // UART TX
    // ------------------------------------------------------------------------
    wire       tx_busy;
    reg        tx_start;
    reg  [7:0] tx_data;

    uart_tx #(
        .CLK_HZ    (27_000_000),
        .BAUD_RATE (115200)
    ) u_tx (
        .clk      (clk27),
        .rst_n    (rst_n),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (uart_tx),
        .tx_busy  (tx_busy)
    );

    // TX FIFO bridge + XON/XOFF flow control injection.
    // forth.asm writes bursts of bytes without polling tx_idle — a 16-deep
    // FIFO absorbs that. On top we squeeze in single flow-control bytes
    // (XOFF/XON) out-of-band when the RX FIFO crosses high/low watermarks.
    localparam TX_FIFO_DEPTH_LOG2 = 4;   // 16 entries
    localparam TX_FIFO_DEPTH      = 1 << TX_FIFO_DEPTH_LOG2;

    reg [7:0]                   tx_fifo [0:TX_FIFO_DEPTH-1];
    reg [TX_FIFO_DEPTH_LOG2:0]  tx_wr_ptr;
    reg [TX_FIFO_DEPTH_LOG2:0]  tx_rd_ptr;
    wire tx_fifo_empty = (tx_wr_ptr == tx_rd_ptr);
    wire tx_fifo_full  = (tx_wr_ptr[TX_FIFO_DEPTH_LOG2]     != tx_rd_ptr[TX_FIFO_DEPTH_LOG2]) &&
                         (tx_wr_ptr[TX_FIFO_DEPTH_LOG2-1:0] == tx_rd_ptr[TX_FIFO_DEPTH_LOG2-1:0]);

    // ------------------------------------------------------------------------
    // UART RX + FIFO — no more overwrites on fast paste.
    // XON/XOFF: send XOFF (0x13) when FIFO fills past HIGH watermark, XON
    // (0x11) after it drains below LOW. Host terminal must use software
    // flow control (`tio -i software`, `picocom --send-cmd ...`, etc.).
    // ------------------------------------------------------------------------
    localparam RX_FIFO_DEPTH_LOG2   = 5;    // 32 entries
    localparam RX_FIFO_DEPTH        = 1 << RX_FIFO_DEPTH_LOG2;
    localparam [RX_FIFO_DEPTH_LOG2:0] RX_HIGH_WM = 6'd24;
    localparam [RX_FIFO_DEPTH_LOG2:0] RX_LOW_WM  = 6'd4;

    wire [7:0] rx_data;
    wire       rx_ready;
    reg        rx_ack;

    uart_rx #(
        .CLK_HZ    (27_000_000),
        .BAUD_RATE (115200)
    ) u_rx (
        .clk      (clk27),
        .rst_n    (rst_n),
        .rx_in    (uart_rx),
        .rx_ack   (rx_ack),
        .rx_data  (rx_data),
        .rx_ready (rx_ready)
    );

    reg [7:0]                   rx_fifo [0:RX_FIFO_DEPTH-1];
    reg [RX_FIFO_DEPTH_LOG2:0]  rx_wr_ptr;
    reg [RX_FIFO_DEPTH_LOG2:0]  rx_rd_ptr;
    wire rx_fifo_empty = (rx_wr_ptr == rx_rd_ptr);
    wire rx_fifo_full  = (rx_wr_ptr[RX_FIFO_DEPTH_LOG2]     != rx_rd_ptr[RX_FIFO_DEPTH_LOG2]) &&
                         (rx_wr_ptr[RX_FIFO_DEPTH_LOG2-1:0] == rx_rd_ptr[RX_FIFO_DEPTH_LOG2-1:0]);
    wire [RX_FIFO_DEPTH_LOG2:0] rx_count = rx_wr_ptr - rx_rd_ptr;

    wire rx_consumed;

    // Ingest: pull each received byte into the FIFO, pulse rx_ack 1 cycle
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            rx_wr_ptr <= 0;
            rx_ack    <= 1'b0;
        end else begin
            rx_ack <= 1'b0;
            if (rx_ready && !rx_ack && !rx_fifo_full) begin
                rx_fifo[rx_wr_ptr[RX_FIFO_DEPTH_LOG2-1:0]] <= rx_data;
                rx_wr_ptr <= rx_wr_ptr + 1'b1;
                rx_ack    <= 1'b1;
            end
        end
    end

    // CPU consumes from FIFO. io_in_read pulses for exactly the execute phase
    // of a `LD [0x7FFF]`, so advancing rd_ptr is 1 byte per read.
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            rx_rd_ptr <= 0;
        end else if (rx_consumed && !rx_fifo_empty) begin
            rx_rd_ptr <= rx_rd_ptr + 1'b1;
        end
    end

    assign cpu_io_in_data = rx_fifo[rx_rd_ptr[RX_FIFO_DEPTH_LOG2-1:0]];
    // io_status[1] = RX byte available, [0] = TX FIFO can accept more.
    assign cpu_io_status  = {6'b0, ~rx_fifo_empty, ~tx_fifo_full};

    // XON/XOFF controller + unified TX drainer. Flow-control bytes take
    // priority over the CPU TX FIFO so watermark signalling isn't delayed
    // by a long output burst.
    reg       xoff_sent;
    reg       fc_valid;
    reg [7:0] fc_byte;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            tx_start  <= 1'b0;
            tx_data   <= 8'h00;
            tx_wr_ptr <= 0;
            tx_rd_ptr <= 0;
            xoff_sent <= 1'b1;       // Pretend XOFF was sent so we emit
            fc_valid  <= 1'b1;       // a fresh XON immediately on reset.
            fc_byte   <= 8'h11;      // Host may have been throttled before reset.
        end else begin
            // Arm a flow-control byte on watermark crossing
            if (!fc_valid) begin
                if (!xoff_sent && rx_count >= RX_HIGH_WM) begin
                    fc_byte   <= 8'h13;   // XOFF
                    fc_valid  <= 1'b1;
                    xoff_sent <= 1'b1;
                end else if (xoff_sent && rx_count <= RX_LOW_WM) begin
                    fc_byte   <= 8'h11;   // XON
                    fc_valid  <= 1'b1;
                    xoff_sent <= 1'b0;
                end
            end

            // Enqueue CPU byte (drop if full — CPU may poll tx-can-accept)
            if (cpu_io_out_valid && !tx_fifo_full) begin
                tx_fifo[tx_wr_ptr[TX_FIFO_DEPTH_LOG2-1:0]] <= cpu_io_out_data;
                tx_wr_ptr <= tx_wr_ptr + 1'b1;
            end

            // Drain — priority to fc_byte over CPU FIFO
            if (tx_start) begin
                if (tx_busy) tx_start <= 1'b0;
            end else if (!tx_busy) begin
                if (fc_valid) begin
                    tx_data  <= fc_byte;
                    tx_start <= 1'b1;
                    fc_valid <= 1'b0;
                end else if (!tx_fifo_empty) begin
                    tx_data   <= tx_fifo[tx_rd_ptr[TX_FIFO_DEPTH_LOG2-1:0]];
                    tx_start  <= 1'b1;
                    tx_rd_ptr <= tx_rd_ptr + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Storage MMIO stubs (Phase C: BSRAM emulator removed, all blocks live
    // on SD via the ROM SD primitives).  We keep the CPU-side wires so the
    // CPU instantiation parameters stay stable, but writes are dropped and
    // reads return 0 — block_dispatch in ROM no longer hits this path.
    // ------------------------------------------------------------------------
    wire [7:0] stg_blk_lo_wdata;
    wire       stg_blk_lo_we;
    wire [7:0] stg_blk_hi_wdata;
    wire       stg_blk_hi_we;
    wire [7:0] stg_data_wdata;
    wire       stg_data_we;
    wire       stg_data_re;
    wire [7:0] stg_data_in = 8'h00;

    // ------------------------------------------------------------------------
    // CPU instance
    // ------------------------------------------------------------------------
    mc14500_cpu #(
        .ROM_DEPTH   (8192),
        .RAM_DEPTH   (32768),
        .STACK_DEPTH (32),
        .ROM_FILE    ("build/forth.mem"),
        .RAM_FILE    ("build/forth.ram"),
        .SYNC_MEM    (1)              // FPGA BRAM needs registered reads → 3 cycles/instruction
    ) cpu (
        .clk              (clk27),
        .rst_n            (rst_n),
        .debug_rr         (debug_rr),
        .debug_pc         (debug_pc),
        .debug_flag_z     (debug_flag_z),
        .debug_flag_c     (debug_flag_c),
        .debug_flag_v     (debug_flag_v),
        .debug_halted     (debug_halted),
        .io_out_data      (cpu_io_out_data),
        .io_out_valid     (cpu_io_out_valid),
        .io_in_read       (rx_consumed),
        .io_in_data       (cpu_io_in_data),
        .io_status        (cpu_io_status),
        .io_stall         (tx_fifo_full),
        .gpio_out_data    (cpu_gpio_out_data),
        .gpio_out_we      (cpu_gpio_out_we),
        .gpio_in_data     (8'h00),          // no GPIO-in wired yet

        // Storage: 8-block BRAM emulator wired below (volatile)
        .storage_block_lo_data (stg_blk_lo_wdata),
        .storage_block_lo_we   (stg_blk_lo_we),
        .storage_block_hi_data (stg_blk_hi_wdata),
        .storage_block_hi_we   (stg_blk_hi_we),
        .storage_data_out      (stg_data_wdata),
        .storage_data_we       (stg_data_we),
        .storage_data_re       (stg_data_re),
        .storage_data_in       (stg_data_in),

        // SPI master (MMIO 0x7FF0..0x7FF2)
        .spi_tx_data           (spi_tx_data),
        .spi_tx_we             (spi_tx_we),
        .spi_rx_data           (spi_rx_data),
        .spi_busy              (spi_busy),
        .spi_cs_data           (spi_cs_data),
        .spi_cs_we             (spi_cs_we),

        .debug_ram_addr        (),
        .debug_ram_wdata       (),
        .debug_ram_we          (),
        .debug_rom_loaded      (debug_rom_loaded)
    );

    // ------------------------------------------------------------------------
    // SPI Master + CS register
    // ------------------------------------------------------------------------
    // CLK_DIV=64 → SCK ≈ 27MHz / 128 ≈ 210 kHz, safely below SD init max (400 kHz).
    // After SD init we could rev this up, but for bring-up keep it simple and slow.
    // SPI_CS is an 8-bit register; bit 0 drives sd_cs directly (low = selected).
    wire [7:0] spi_tx_data;
    wire       spi_tx_we;
    wire [7:0] spi_rx_data;
    wire       spi_busy;
    wire [7:0] spi_cs_data;
    wire       spi_cs_we;

    reg  [7:0] spi_cs_reg;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)         spi_cs_reg <= 8'hFF;     // all deselected at reset
        else if (spi_cs_we) spi_cs_reg <= spi_cs_data;
    end
    assign sd_cs = spi_cs_reg[0];

    spi_master #(.CLK_DIV(64)) u_spi (
        .clk      (clk27),
        .rst_n    (rst_n),
        .tx_data  (spi_tx_data),
        .tx_start (spi_tx_we),
        .rx_data  (spi_rx_data),
        .busy     (spi_busy),
        .sck      (sd_sck),
        .mosi     (sd_mosi),
        .miso     (sd_miso)
    );

    // ------------------------------------------------------------------------
    // GPIO — Forth writes 0x7FF4 → updates gpio_out, reflected on LEDs 2..5
    // ------------------------------------------------------------------------
    wire [7:0] cpu_gpio_out_data;
    wire       cpu_gpio_out_we;
    reg  [3:0] gpio_out;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) gpio_out <= 4'd0;
        else if (cpu_gpio_out_we) gpio_out <= cpu_gpio_out_data[3:0];
    end

    // ------------------------------------------------------------------------
    // LED status
    // ------------------------------------------------------------------------
    // LED[0]: Heartbeat (slow blink ~1 Hz), proves top-level is alive
    // LED[1]: CPU running (not halted)
    // LED[2]: UART TX activity
    // LED[3]: UART RX activity
    // LED[4]: Reset is released
    // LED[5]: Zero flag (debug)
    reg [25:0] heartbeat;
    always @(posedge clk27) heartbeat <= heartbeat + 1;

    reg [15:0] tx_blink;
    reg [15:0] rx_blink;
    reg [15:0] wr_blink;  // io_out_valid activity — does CPU ever write to UART?
    always @(posedge clk27) begin
        if (tx_start)                tx_blink <= 16'hFFFF;
        else if (tx_blink != 0)      tx_blink <= tx_blink - 1;
        if (rx_ready && !rx_ack)     rx_blink <= 16'hFFFF;
        else if (rx_blink != 0)      rx_blink <= rx_blink - 1;
        if (cpu_io_out_valid)        wr_blink <= 16'hFFFF;
        else if (wr_blink != 0)      wr_blink <= wr_blink - 1;
    end

    // LED mapping — active-low on Tang Primer 20K Dock.
    // LED0 = heartbeat (debug, proves top is alive)
    // LED1 = CPU running  (debug)
    // LED2..5 = Forth-controllable via MMIO 0x7FF4 (gpio_out[0..3])
    wire [5:0] led_int = {
        gpio_out[3],             // LED5 ← GPIO bit 3
        gpio_out[2],             // LED4 ← GPIO bit 2
        gpio_out[1],             // LED3 ← GPIO bit 1
        gpio_out[0],             // LED2 ← GPIO bit 0
        !debug_halted,           // LED1: CPU running (debug)
        heartbeat[25]            // LED0: heartbeat (debug)
    };
    assign led = ~led_int;

endmodule
