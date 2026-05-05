// ============================================================================
// tb_bench.v — Benchmark cycle counter for MC14500 CPU
// ============================================================================
// Runs a benchmark .mem file and measures cycles between labeled sections.
// Uses generic marker detection: measures cycles between PC hitting
// specific addresses (configurable via parameters).
//
// Usage:
//   iverilog -o tb_bench.vvp tb_bench.v mc14500_cpu.v mc14500_slice.v
//   vvp tb_bench.vvp                    (uses default ROM_FILE)
//   Or override: -Ptb_bench.ROM_FILE=\"bench_forth.mem\"
// ============================================================================

`timescale 1ns / 1ps

module tb_bench;

    parameter ROM_FILE   = "bench.mem";

    // Benchmark marker addresses — set via -P overrides or defaults
    parameter MUL_START  = 11'h000;
    parameter MUL_END    = 11'h000;
    parameter FIB_START  = 11'h000;
    parameter FIB_END    = 11'h000;
    parameter FILL_START = 11'h000;
    parameter FILL_END   = 11'h000;

    reg         clk;
    reg         rst_n;
    wire [7:0]  debug_rr;
    wire [14:0] debug_pc;
    wire        debug_flag_z, debug_flag_c, debug_flag_v, debug_halted;
    wire [7:0]  io_out_data;
    wire        io_out_valid;
    wire [14:0] debug_ram_addr;
    wire [7:0]  debug_ram_wdata;
    wire        debug_ram_we;

    mc14500_cpu #(
        .ROM_DEPTH(2048), .RAM_DEPTH(32768), .STACK_DEPTH(8),
        .ROM_FILE(ROM_FILE),
        .RAM_FILE("")
    ) cpu (
        .clk(clk), .rst_n(rst_n),
        .debug_rr(debug_rr), .debug_pc(debug_pc),
        .debug_flag_z(debug_flag_z), .debug_flag_c(debug_flag_c),
        .debug_flag_v(debug_flag_v), .debug_halted(debug_halted),
        .io_out_data(io_out_data), .io_out_valid(io_out_valid), .io_in_read(),
        .io_in_data(8'h00), .io_status(8'h01), .io_stall(1'b0),
        .gpio_out_data(), .gpio_out_we(), .gpio_in_data(8'h00),
        .spi_tx_data(), .spi_tx_we(), .spi_rx_data(8'hFF),
        .spi_busy(1'b0), .spi_cs_data(), .spi_cs_we(),
        .storage_block_lo_data(), .storage_block_lo_we(),
        .storage_block_hi_data(), .storage_block_hi_we(),
        .storage_data_out(), .storage_data_we(), .storage_data_re(),
        .storage_data_in(8'h00),
        .debug_ram_addr(debug_ram_addr), .debug_ram_wdata(debug_ram_wdata),
        .debug_ram_we(debug_ram_we)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer total_cycles;
    integer mul_start_cyc, mul_cycles;
    integer fib_start_cyc, fib_cycles;
    integer fill_start_cyc, fill_cycles;
    reg mul_running, fib_running, fill_running;

    initial begin
        rst_n = 0;
        mul_running = 0; fib_running = 0; fill_running = 0;
        mul_cycles = 0; fib_cycles = 0; fill_cycles = 0;
        repeat (3) @(posedge clk);
        #1;
        rst_n = 1;
        total_cycles = 0;

        while (!debug_halted && total_cycles < 100000) begin
            @(posedge clk);
            #1;
            total_cycles = total_cycles + 1;

            if (debug_pc == MUL_START && !mul_running && MUL_START != 0) begin
                mul_start_cyc = total_cycles; mul_running = 1;
            end
            if (debug_pc == MUL_END && mul_running) begin
                mul_cycles = total_cycles - mul_start_cyc; mul_running = 0;
            end
            if (debug_pc == FIB_START && !fib_running && FIB_START != 0) begin
                fib_start_cyc = total_cycles; fib_running = 1;
            end
            if (debug_pc == FIB_END && fib_running) begin
                fib_cycles = total_cycles - fib_start_cyc; fib_running = 0;
            end
            if (debug_pc == FILL_START && !fill_running && FILL_START != 0) begin
                fill_start_cyc = total_cycles; fill_running = 1;
            end
            if (debug_pc == FILL_END && fill_running) begin
                fill_cycles = total_cycles - fill_start_cyc; fill_running = 0;
            end

            if (io_out_valid)
                $write("%c", io_out_data);
        end

        $display("");
        $display("");
        $display("============================================================");
        $display("  Benchmark: %0s", ROM_FILE);
        $display("============================================================");
        if (mul_cycles > 0)
            $display("  MUL  13*7     : %4d cycles", mul_cycles);
        if (fib_cycles > 0)
            $display("  FIB  fib(10)  : %4d cycles", fib_cycles);
        if (fill_cycles > 0)
            $display("  FILL 32 bytes : %4d cycles", fill_cycles);
        $display("  Total         : %4d cycles", total_cycles);
        $display("============================================================");
        $display("");

        $finish;
    end
endmodule
