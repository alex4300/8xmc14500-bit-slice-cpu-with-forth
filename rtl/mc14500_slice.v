// ============================================================================
// mc14500_slice.v — 1-Bit ALU Slice (inspired by MC14500 ICU)
// ============================================================================
//
// A single 1-bit processing element. Eight of these chained together
// form an 8-bit CPU with a custom instruction set.
//
// Key differences from the original MC14500B:
//   - Added carry_in / carry_out for arithmetic (ADD, SUB)
//   - Opcodes extended for arithmetic alongside original logic ops
//   - IEN/OEN moved to top-level control (microcode handles this)
//   - data_in and data_out are separate paths (no bidirectional bus)
//
// The opcode is shared across all slices (SIMD-style), but each slice
// operates on its own bit of the data word.
//
// ============================================================================

module mc14500_slice (
    input  wire        clk,
    input  wire        rst_n,      // Active-low reset
    input  wire [3:0]  opcode,     // ALU operation (shared across all slices)
    input  wire        data_in,    // Input data bit (from RAM/IO)
    input  wire        carry_in,   // Carry/borrow from adjacent slice
    output wire        data_out,   // Output data bit (to RAM/IO)
    output wire        carry_out,  // Carry/borrow to adjacent slice
    output wire        rr_out      // Current Result Register value
);

    // ========================================================================
    // Opcode Definitions
    // ========================================================================
    //
    // Logic operations (carry chain not used):
    localparam OP_NOP  = 4'h0;    // No operation — RR unchanged
    localparam OP_LD   = 4'h1;    // Load:     RR <= data_in
    localparam OP_LDC  = 4'h2;    // Load complement: RR <= ~data_in
    localparam OP_AND  = 4'h3;    // AND:      RR <= RR & data_in
    localparam OP_ANDC = 4'h4;    // AND compl: RR <= RR & ~data_in
    localparam OP_OR   = 4'h5;    // OR:       RR <= RR | data_in
    localparam OP_ORC  = 4'h6;    // OR compl: RR <= RR | ~data_in
    localparam OP_XOR  = 4'h7;    // XOR:      RR <= RR ^ data_in
    //
    // Arithmetic operations (carry chain active):
    localparam OP_ADD  = 4'h8;    // Add:  {Cout, RR} <= RR + data_in + Cin
    localparam OP_SUB  = 4'h9;    // Sub:  {Cout, RR} <= RR - data_in - Cin
    localparam OP_INC  = 4'hA;    // Inc:  {Cout, RR} <= RR + Cin (data ignored)
    localparam OP_DEC  = 4'hB;    // Dec:  {Cout, RR} <= RR - Cin (data ignored)
    //
    // Data movement / store operations (RR not modified):
    localparam OP_STO  = 4'hC;    // Store: data_out <= RR
    localparam OP_STOC = 4'hD;    // Store complement: data_out <= ~RR
    //
    // Register control:
    localparam OP_SET  = 4'hE;    // Set:   RR <= 1
    localparam OP_CLR  = 4'hF;    // Clear: RR <= 0

    // ========================================================================
    // Result Register
    // ========================================================================
    reg rr;

    // ========================================================================
    // ALU — Combinational Logic
    // ========================================================================
    reg alu_result;
    reg alu_carry;

    always @(*) begin
        // Defaults: hold current value, no carry
        alu_result = rr;
        alu_carry  = 1'b0;

        case (opcode)
            // --- Logic operations ---
            OP_NOP:  begin alu_result = rr;            alu_carry = 1'b0;    end
            OP_LD:   begin alu_result = data_in;       alu_carry = 1'b0;    end
            OP_LDC:  begin alu_result = ~data_in;      alu_carry = 1'b0;    end
            OP_AND:  begin alu_result = rr & data_in;  alu_carry = 1'b0;    end
            OP_ANDC: begin alu_result = rr & ~data_in; alu_carry = 1'b0;    end
            OP_OR:   begin alu_result = rr | data_in;  alu_carry = 1'b0;    end
            OP_ORC:  begin alu_result = rr | ~data_in; alu_carry = 1'b0;    end
            OP_XOR:  begin alu_result = rr ^ data_in;  alu_carry = 1'b0;    end

            // --- Arithmetic operations (carry chain) ---
            OP_ADD:  {alu_carry, alu_result} = rr + data_in + carry_in;
            OP_SUB:  {alu_carry, alu_result} = rr - data_in - carry_in;
            OP_INC:  {alu_carry, alu_result} = rr + carry_in;
            OP_DEC:  {alu_carry, alu_result} = rr - carry_in;

            // --- Store operations (RR unchanged) ---
            OP_STO:  begin alu_result = rr;            alu_carry = 1'b0;    end
            OP_STOC: begin alu_result = rr;            alu_carry = 1'b0;    end

            // --- Register control ---
            OP_SET:  begin alu_result = 1'b1;          alu_carry = 1'b0;    end
            OP_CLR:  begin alu_result = 1'b0;          alu_carry = 1'b0;    end
        endcase
    end

    // ========================================================================
    // Result Register — Sequential Update
    // ========================================================================
    //
    // STO and STOC only drive data_out, they don't modify RR.
    // All other operations update RR with the ALU result.

    wire rr_write_en = (opcode != OP_STO) && (opcode != OP_STOC);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rr <= 1'b0;
        else if (rr_write_en)
            rr <= alu_result;
    end

    // ========================================================================
    // Output Assignments
    // ========================================================================
    assign data_out  = (opcode == OP_STOC) ? ~rr : rr;
    assign carry_out = alu_carry;
    assign rr_out    = rr;

endmodule
