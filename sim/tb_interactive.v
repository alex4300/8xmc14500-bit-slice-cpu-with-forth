// ============================================================================
// tb_interactive.v — Interactive Terminal Emulator for mc14500_cpu
// ============================================================================
//
// Bridges the CPU's I/O ports to stdin/stdout:
//
//   Address 0xFE (read)  — Status register
//                          Bit 0: TX ready (always 1)
//                          Bit 1: RX data available (1 when char buffered)
//
//   Address 0xFF (read)  — Read received character (clears RX available)
//   Address 0xFF (write) — Send character to terminal
//
// Usage:
//   make interactive                          # default echo program
//   make interactive PROGRAM=my_prog.mem      # custom program
//   echo "Hello" | make interactive           # piped input
//
// ============================================================================

`timescale 1ns / 1ps

module tb_interactive;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter ROM_FILE        = "echo_program.mem";
    parameter RAM_FILE        = "";
    parameter STORAGE_FILE    = "";          // hex file to init storage memory
    parameter STORAGE_OUT     = "";          // hex file to write storage to on $finish (persistence)
    parameter MAX_CYCLES      = 100_000_000;
    parameter BLOCK_SIZE      = 256;         // bytes per block

    // ========================================================================
    // Signals
    // ========================================================================
    reg         clk;
    reg         rst_n;
    wire [7:0]  debug_rr;
    wire [14:0] debug_pc;
    wire        debug_flag_z;
    wire        debug_flag_c;
    wire        debug_flag_v;
    wire        debug_halted;
    wire [7:0]  io_out_data;
    wire        io_out_valid;
    reg  [7:0]  io_in_data;
    reg  [7:0]  io_status;
    wire [14:0] debug_ram_addr;
    wire [7:0]  debug_ram_wdata;
    wire        debug_ram_we;

    // Storage MMIO signals
    wire [7:0]  storage_block_lo_data;
    wire        storage_block_lo_we;
    wire [7:0]  storage_block_hi_data;
    wire        storage_block_hi_we;
    wire [7:0]  storage_data_out;
    wire        storage_data_we;
    wire        storage_data_re;
    wire [7:0]  storage_data_in;

    // ========================================================================
    // CPU
    // ========================================================================
    mc14500_cpu #(
        .ROM_DEPTH   (8192),
        .RAM_DEPTH   (32768),
        .STACK_DEPTH (32),
        .ROM_FILE    (ROM_FILE),
        .RAM_FILE    (RAM_FILE)
    ) cpu (
        .clk            (clk),
        .rst_n          (rst_n),
        .debug_rr       (debug_rr),
        .debug_pc       (debug_pc),
        .debug_flag_z   (debug_flag_z),
        .debug_flag_c   (debug_flag_c),
        .debug_flag_v   (debug_flag_v),
        .debug_halted   (debug_halted),
        .io_out_data    (io_out_data),
        .io_out_valid   (io_out_valid),
        .io_in_read     (),
        .io_in_data     (io_in_data),
        .io_status      (io_status),
        .io_stall       (1'b0),
        .gpio_out_data  (),
        .gpio_out_we    (),
        .gpio_in_data   (8'h00),
        .spi_tx_data    (),
        .spi_tx_we      (),
        .spi_rx_data    (8'hFF),
        .spi_busy       (1'b0),
        .spi_cs_data    (),
        .spi_cs_we      (),
        .storage_block_lo_data (storage_block_lo_data),
        .storage_block_lo_we   (storage_block_lo_we),
        .storage_block_hi_data (storage_block_hi_data),
        .storage_block_hi_we   (storage_block_hi_we),
        .storage_data_out      (storage_data_out),
        .storage_data_we       (storage_data_we),
        .storage_data_re       (storage_data_re),
        .storage_data_in       (storage_data_in),
        .debug_ram_addr (debug_ram_addr),
        .debug_ram_wdata(debug_ram_wdata),
        .debug_ram_we   (debug_ram_we)
    );

    // ========================================================================
    // Storage Peripheral (block-oriented "disk")
    // ========================================================================
    // 64KB total storage, 256 bytes per block = 256 blocks.
    // Auto-incrementing offset within block on each data read/write.
    // Initialized from STORAGE_FILE (hex format), if provided.
    reg [7:0]  storage_mem [0:65535];
    reg [7:0]  storage_block_lo_reg;
    reg [7:0]  storage_block_hi_reg;
    reg [7:0]  storage_offset;
    integer    si;

    initial begin
        // Clear storage
        for (si = 0; si < 65536; si = si + 1)
            storage_mem[si] = 8'h00;
        storage_block_lo_reg = 8'h00;
        storage_block_hi_reg = 8'h00;
        storage_offset       = 8'h00;
        // Load from file if provided
        if (STORAGE_FILE != "")
            $readmemh(STORAGE_FILE, storage_mem);
    end

    // Compute current full address (block * 256 + offset)
    wire [15:0] storage_addr = {storage_block_hi_reg, storage_block_lo_reg} * BLOCK_SIZE
                             + {8'h00, storage_offset};

    assign storage_data_in = storage_mem[storage_addr];

    // Sequential: handle block# writes and data R/W with auto-increment
    always @(posedge clk) begin
        if (storage_block_lo_we) begin
            storage_block_lo_reg <= storage_block_lo_data;
            storage_offset       <= 8'h00;
        end
        if (storage_block_hi_we) begin
            storage_block_hi_reg <= storage_block_hi_data;
            storage_offset       <= 8'h00;
        end
        if (storage_data_we) begin
            storage_mem[storage_addr] <= storage_data_out;
            storage_offset            <= storage_offset + 8'h01;
        end else if (storage_data_re) begin
            storage_offset <= storage_offset + 8'h01;
        end
    end


    // Clock: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // ========================================================================
    // Input FIFO — read all of stdin upfront into a buffer
    // ========================================================================
    // Icarus $fgetc is blocking, so we slurp stdin at init time.
    // For piped input this works perfectly. For interactive use,
    // pipe input line by line or use the wrapper script.
    // Input is read from a file (.uart_input) prepared by the Makefile.
    // This avoids blocking on stdin when running interactively.
    parameter INPUT_FILE = "build/.uart_input";

    reg [7:0]  input_buf [0:65535];
    integer    input_len;
    integer    input_pos;
    integer    ch;
    integer    input_fd;

    initial begin
        input_len = 0;
        input_fd = $fopen(INPUT_FILE, "r");
        if (input_fd != 0) begin
            ch = $fgetc(input_fd);
            while (ch != -1 && ch != 32'hFFFF_FFFF && input_len < 65536) begin
                input_buf[input_len] = ch[7:0];
                input_len = input_len + 1;
                ch = $fgetc(input_fd);
            end
            $fclose(input_fd);
        end
        input_pos = 0;
    end

    // ========================================================================
    // Detect when CPU reads from 0xFF (consumes the RX byte)
    // ========================================================================
    wire [3:0]  cur_opcode = cpu.microword[42:39];
    wire [15:0] cur_addr   = cpu.microword[26:11];
    wire is_read_op  = (cur_opcode >= 4'h1 && cur_opcode <= 4'h9);
    wire rx_consumed = is_read_op && (cur_addr == 16'h7FFF) && !debug_halted;

    // ========================================================================
    // RX state
    // ========================================================================
    reg       rx_has_data;
    reg [7:0] rx_byte;

    // ========================================================================
    // Main simulation
    // ========================================================================
    integer cycle_count;

    initial begin
        // ---- Banner ----
        $display("");
        $display("============================================================");
        $display("  MC14500 Interactive Emulator");
        $display("  ROM: %0s  (%0d bytes input buffered)", ROM_FILE, input_len);
        $display("============================================================");
        $display("");

        // ---- Reset ----
        rst_n       = 0;
        io_in_data  = 8'h00;
        io_status   = 8'h01;     // TX ready, RX empty
        rx_has_data = 0;
        rx_byte     = 8'h00;

        repeat (3) @(posedge clk);
        #1;                             // Release reset AFTER clock edge
        rst_n = 1;

        // ---- Run ----
        cycle_count = 0;

        while (!debug_halted && cycle_count < MAX_CYCLES) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;

            // --- TX: CPU wrote to 0xFF → emit character ---
            if (io_out_valid) begin
                $write("%c", io_out_data);
                $fflush();
            end




            // --- RX consumed: CPU read from 0xFF → clear buffer ---
            if (rx_consumed && rx_has_data) begin
                rx_has_data = 0;
                io_status   = 8'h01;   // TX ready, RX empty
            end

            // --- Feed next input byte when buffer is free ---
            // Only feed after CPU has entered poll loop (reading status at 0xFE)
            // This prevents input being consumed during the init phase
            if (!rx_has_data && input_pos < input_len
                && is_read_op && cur_addr == 16'h7FFE) begin
                rx_byte     = input_buf[input_pos];
                io_in_data  = input_buf[input_pos];
                input_pos   = input_pos + 1;
                rx_has_data = 1;
                io_status   = 8'h03;   // TX ready + RX available
            end

            // --- If all input consumed and RX empty → end simulation ---
            // (Only when using piped input; prevents infinite poll loop)
            if (input_pos >= input_len && !rx_has_data && input_len > 0) begin
                // Let CPU finish processing for a few more cycles
                // (needs enough time for find_builtin hash chain + word execution)
                repeat (4000000) begin
                    @(posedge clk);
                    #1;
                    if (io_out_valid) begin
                        $write("%c", io_out_data);
                        $fflush();
                    end
                end
                $display("");
                $display("[Emulator] Input exhausted after %0d cycles.", cycle_count);
                if (STORAGE_OUT != "") begin
                    $writememh(STORAGE_OUT, storage_mem);
                    $display("[Storage] Wrote back to %0s", STORAGE_OUT);
                end
                $finish;
            end
        end

        // ---- Done ----
        $display("");
        if (debug_halted)
            $display("[Emulator] CPU halted after %0d cycles. RR=0x%02X", cycle_count, debug_rr);
        else
            $display("[Emulator] Timeout after %0d cycles.", cycle_count);

        if (STORAGE_OUT != "") begin
            $writememh(STORAGE_OUT, storage_mem);
            $display("[Storage] Wrote back to %0s", STORAGE_OUT);
        end
        $finish;
    end

endmodule
