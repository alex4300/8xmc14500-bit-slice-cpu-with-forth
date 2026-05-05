// ============================================================================
// tb_cpu.v — Testbench for mc14500_cpu (8-Bit Bit-Slice CPU)
// ============================================================================
// Loads test_cpu.mem via ROM_FILE, pre-fills RAM, runs until HALT,
// and verifies results.
// ============================================================================

`timescale 1ns / 1ps

module tb_cpu;

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
    wire [14:0] debug_ram_addr;
    wire [7:0]  debug_ram_wdata;
    wire        debug_ram_we;
    reg  [7:0]  io_in_data;

    mc14500_cpu #(
        .ROM_DEPTH   (8192),
        .RAM_DEPTH   (32768),
        .STACK_DEPTH (8),
        .ROM_FILE    ("build/test_cpu.mem"),
        .RAM_FILE    ("")
    ) uut (
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
        .io_status      (8'h01),
        .io_stall       (1'b0),
        .gpio_out_data  (),
        .gpio_out_we    (),
        .gpio_in_data   (8'h00),
        // SPI not used in CPU tests — tie off
        .spi_tx_data    (),
        .spi_tx_we      (),
        .spi_rx_data    (8'hFF),
        .spi_busy       (1'b0),
        .spi_cs_data    (),
        .spi_cs_we      (),
        // Storage not used in CPU tests — tie off
        .storage_block_lo_data (),
        .storage_block_lo_we   (),
        .storage_block_hi_data (),
        .storage_block_hi_we   (),
        .storage_data_out      (),
        .storage_data_we       (),
        .storage_data_re       (),
        .storage_data_in       (8'h00),
        .debug_ram_addr (debug_ram_addr),
        .debug_ram_wdata(debug_ram_wdata),
        .debug_ram_we   (debug_ram_we)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // Test tracking
    integer pass_count = 0;
    integer fail_count = 0;

    task check_ram;
        input [15:0] addr;
        input [7:0] expected;
        input [63:0] name;
        begin
            if (uut.ram[addr] === expected) begin
                $display("  PASS  RAM[0x%02X] = 0x%02X  (%s)", addr[7:0], uut.ram[addr], name);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  RAM[0x%02X] = 0x%02X, expected 0x%02X  (%s)",
                         addr[7:0], uut.ram[addr], expected, name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer cycle_count;

    initial begin
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        $display("");
        $display("============================================================");
        $display("  MC14500 8-Bit Bit-Slice CPU — System Testbench (40-bit)");
        $display("============================================================");

        rst_n      = 0;
        io_in_data = 8'h00;

        @(posedge clk);
        @(posedge clk);

        // Pre-load RAM with test data
        uut.ram[15'h10] = 8'h25;    // Operand A: 37
        uut.ram[15'h11] = 8'h1A;    // Operand B: 26
        uut.ram[15'h12] = 8'hFF;    // For INC: 255
        uut.ram[15'h13] = 8'h50;    // For SUB: 80
        uut.ram[15'h14] = 8'h1F;    // For SUB: 31
        uut.ram[15'h15] = 8'h42;    // Marker for branch
        uut.ram[15'h42] = 8'h77;    // For IX test
        uut.ram[15'h100] = 8'hCC;   // For 15-bit IX test

        // Release reset
        @(posedge clk);
        #1;
        rst_n = 1;

        // Trace execution
        $display("");
        $display("  Cycle | PC   | RR       | Flags(Z,C,V)");
        $display("  ------+------+----------+-------------");

        cycle_count = 0;
        while (!debug_halted && cycle_count < 200) begin
            @(posedge clk);
            #1;
            cycle_count = cycle_count + 1;
            $display("  %4d  | 0x%03X | 0x%02X (%3d) |    %b,%b,%b",
                cycle_count, debug_pc, debug_rr, debug_rr,
                debug_flag_z, debug_flag_c, debug_flag_v);
        end

        $display("");
        if (debug_halted)
            $display("  CPU halted after %0d cycles.", cycle_count);
        else
            $display("  WARNING: CPU did not halt within 200 cycles!");

        $display("");
        $display("  --- Result Verification ---");
        $display("");

        // Original tests
        check_ram(15'h20, 8'h3F, "ADD     ");
        check_ram(15'h21, 8'h00, "INC_ovfl");
        check_ram(15'h22, 8'h42, "BRANCH  ");
        check_ram(15'h23, 8'h31, "SUB     ");

        // Immediate tests
        check_ram(15'h24, 8'hAB, "LD_IMM  ");
        check_ram(15'h25, 8'hB0, "ADD_IMM ");
        check_ram(15'h26, 8'h00, "AND_IMM ");
        check_ram(15'h27, 8'hFF, "SUB_IMM ");

        // Shift tests
        check_ram(15'h28, 8'h4A, "SHL     ");
        check_ram(15'h29, 8'h25, "SHR     ");
        check_ram(15'h2A, 8'h4A, "ROL     ");
        check_ram(15'h2B, 8'hA0, "ROR     ");

        // IX tests
        check_ram(15'h2C, 8'h77, "IX_LD   ");
        check_ram(15'h2D, 8'h55, "IX_STO  ");

        // 15-bit IX tests
        check_ram(15'h33, 8'hCC, "IX15_LD ");
        check_ram(15'h34, 8'hDD, "IX15_STO");

        // SP + PUSH/POP tests
        check_ram(15'h2E, 8'hAA, "SP_PEEK ");
        check_ram(15'h2F, 8'hBB, "POP_1   ");
        check_ram(15'h30, 8'hAA, "POP_2   ");
        check_ram(15'h31, 8'h9F, "SP_RST  ");

        // Indirect jump
        check_ram(15'h32, 8'hEE, "JMPI    ");

        $display("");
        $display("============================================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0)
            $display("  >>> ALL TESTS PASSED <<<");
        else
            $display("  >>> SOME TESTS FAILED <<<");
        $display("");

        #50;
        $finish;
    end

endmodule
