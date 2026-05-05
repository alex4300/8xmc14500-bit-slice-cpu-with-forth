// ============================================================================
// tb_slice.v — Testbench for mc14500_slice
// ============================================================================
//
// Verifies all 16 operations of a single 1-bit ALU slice.
//
// TIMING: carry_out is combinational (reflects current RR + inputs).
//   We sample it BEFORE the clock edge commits the new RR value.
//   rr_out is sampled AFTER the clock edge.
//
// ============================================================================

`timescale 1ns / 1ps

module tb_slice;

    reg        clk;
    reg        rst_n;
    reg  [3:0] opcode;
    reg        data_in;
    reg        carry_in;
    wire       data_out;
    wire       carry_out;
    wire       rr_out;

    mc14500_slice uut (
        .clk(clk), .rst_n(rst_n), .opcode(opcode),
        .data_in(data_in), .carry_in(carry_in),
        .data_out(data_out), .carry_out(carry_out), .rr_out(rr_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // Apply inputs, sample carry before clock, check RR after clock
    task apply_and_check;
        input [3:0]  t_op;
        input        t_din;
        input        t_cin;
        input        exp_rr;
        input        exp_cout;
        input [63:0] name;
        reg          sampled_cout;
        begin
            opcode = t_op; data_in = t_din; carry_in = t_cin;
            #2;
            sampled_cout = carry_out;
            @(posedge clk); #1;
            if (rr_out !== exp_rr || sampled_cout !== exp_cout) begin
                $display("FAIL %s: RR=%b (exp %b), Cout=%b (exp %b)",
                         name, rr_out, exp_rr, sampled_cout, exp_cout);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS %s: RR=%b, Cout=%b", name, rr_out, sampled_cout);
                pass_count = pass_count + 1;
            end
        end
    endtask

    // Apply and wait (no check)
    task apply;
        input [3:0] t_op; input t_din; input t_cin;
        begin
            opcode = t_op; data_in = t_din; carry_in = t_cin;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $dumpfile("tb_slice.vcd");
        $dumpvars(0, tb_slice);

        $display("");
        $display("============================================================");
        $display("  MC14500 Slice — Single Bit ALU Verification");
        $display("============================================================");

        rst_n = 0; opcode = 0; data_in = 0; carry_in = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;

        $display("  After reset: RR=%b", rr_out);
        $display("");
        $display("--- Logic Operations ---");

        apply_and_check(4'h1, 1, 0,  1, 0, "LD_1    ");
        apply_and_check(4'h1, 0, 0,  0, 0, "LD_0    ");
        apply_and_check(4'h2, 1, 0,  0, 0, "LDC_1   ");
        apply_and_check(4'h2, 0, 0,  1, 0, "LDC_0   ");

        apply(4'hE, 0, 0);  // SET
        apply_and_check(4'h3, 1, 0,  1, 0, "AND_1&1 ");
        apply(4'hE, 0, 0);
        apply_and_check(4'h3, 0, 0,  0, 0, "AND_1&0 ");
        apply(4'hE, 0, 0);
        apply_and_check(4'h4, 0, 0,  1, 0, "ANDC_0  ");
        apply(4'hE, 0, 0);
        apply_and_check(4'h4, 1, 0,  0, 0, "ANDC_1  ");

        apply(4'hF, 0, 0);  // CLR
        apply_and_check(4'h5, 1, 0,  1, 0, "OR_0|1  ");
        apply(4'hF, 0, 0);
        apply_and_check(4'h5, 0, 0,  0, 0, "OR_0|0  ");
        apply(4'hF, 0, 0);
        apply_and_check(4'h6, 0, 0,  1, 0, "ORC_0   ");

        apply(4'hE, 0, 0);
        apply_and_check(4'h7, 1, 0,  0, 0, "XOR_1^1 ");
        apply(4'hF, 0, 0);
        apply_and_check(4'h7, 1, 0,  1, 0, "XOR_0^1 ");

        $display("");
        $display("--- Arithmetic Operations (Full Adder Truth Table) ---");

        // ADD: all 8 combinations of RR, data_in, carry_in
        apply(4'hF, 0, 0);  // CLR → RR=0
        apply_and_check(4'h8, 0, 0,  0, 0, "ADD_000 ");  // 0+0+0=0,C=0

        apply(4'hF, 0, 0);
        apply_and_check(4'h8, 0, 1,  1, 0, "ADD_001 ");  // 0+0+1=1,C=0

        apply(4'hF, 0, 0);
        apply_and_check(4'h8, 1, 0,  1, 0, "ADD_010 ");  // 0+1+0=1,C=0

        apply(4'hF, 0, 0);
        apply_and_check(4'h8, 1, 1,  0, 1, "ADD_011 ");  // 0+1+1=0,C=1

        apply(4'hE, 0, 0);  // SET → RR=1
        apply_and_check(4'h8, 0, 0,  1, 0, "ADD_100 ");  // 1+0+0=1,C=0

        apply(4'hE, 0, 0);
        apply_and_check(4'h8, 0, 1,  0, 1, "ADD_101 ");  // 1+0+1=0,C=1

        apply(4'hE, 0, 0);
        apply_and_check(4'h8, 1, 0,  0, 1, "ADD_110 ");  // 1+1+0=0,C=1

        apply(4'hE, 0, 0);
        apply_and_check(4'h8, 1, 1,  1, 1, "ADD_111 ");  // 1+1+1=1,C=1

        $display("");
        $display("--- SUB / INC / DEC ---");

        apply(4'hE, 0, 0);  // SET → RR=1
        apply_and_check(4'h9, 1, 0,  0, 0, "SUB_1-1 ");  // 1-1-0=0,C=0

        apply(4'hF, 0, 0);  // CLR
        apply_and_check(4'h9, 1, 0,  1, 1, "SUB_0-1 ");  // 0-1-0=1,C=1(borrow)

        apply(4'hE, 0, 0);
        apply_and_check(4'h9, 0, 0,  1, 0, "SUB_1-0 ");  // 1-0-0=1,C=0

        apply(4'hF, 0, 0);
        apply_and_check(4'hA, 0, 1,  1, 0, "INC_0+1 ");  // 0+1=1,C=0

        apply(4'hE, 0, 0);
        apply_and_check(4'hA, 0, 1,  0, 1, "INC_1+1 ");  // 1+1=0,C=1

        apply(4'hE, 0, 0);
        apply_and_check(4'hB, 0, 1,  0, 0, "DEC_1-1 ");  // 1-1=0,C=0

        apply(4'hF, 0, 0);
        apply_and_check(4'hB, 0, 1,  1, 1, "DEC_0-1 ");  // 0-1=1,C=1(borrow)

        $display("");
        $display("--- Store (RR must not change) ---");

        apply(4'hE, 0, 0);  // SET → RR=1
        opcode = 4'hC; data_in = 0; carry_in = 0; #2;
        if (data_out === 1'b1) begin
            $display("PASS STO     : data_out=%b", data_out);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL STO     : data_out=%b (exp 1)", data_out);
            fail_count = fail_count + 1;
        end
        @(posedge clk); #1;

        opcode = 4'hD; #2;
        if (data_out === 1'b0) begin
            $display("PASS STOC    : data_out=%b", data_out);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL STOC    : data_out=%b (exp 0)", data_out);
            fail_count = fail_count + 1;
        end
        @(posedge clk); #1;

        // RR should still be 1 after two store operations
        if (rr_out === 1'b1) begin
            $display("PASS RR_KEPT : RR=%b (unchanged after STO/STOC)", rr_out);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL RR_KEPT : RR=%b (should still be 1)", rr_out);
            fail_count = fail_count + 1;
        end

        $display("");
        $display("--- SET / CLR ---");
        apply_and_check(4'hF, 0, 0,  0, 0, "CLR     ");
        apply_and_check(4'hE, 0, 0,  1, 0, "SET     ");

        $display("");
        $display("============================================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");
        if (fail_count == 0)
            $display("  >>> ALL TESTS PASSED <<<");
        else
            $display("  >>> SOME TESTS FAILED <<<");
        $display("");

        #20;
        $finish;
    end

endmodule
