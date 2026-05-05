// ============================================================================
// mc14500_cpu.v — 8-Bit CPU from eight 1-Bit Slices
// ============================================================================
//
// This module chains eight mc14500_slice instances into a complete 8-bit
// processor with:
//   - 8-bit ALU with carry chain
//   - Flags: Zero, Carry, Overflow
//   - Microcode-driven control (external ROM provides microwords)
//   - 8-bit data bus to RAM
//   - Simple branch logic (unconditional, on zero, on carry)
//   - Hardware stack for subroutine support (configurable depth)
//
// ============================================================================
//
// Microword Format (41 bits):
//
//   [40:37]  opcode      — ALU operation for all slices (4 bits)
//   [36]     we          — Write enable: store ALU result to RAM
//   [35]     use_carry   — 1: carry_in[0] = carry_flag, 0: carry_in[0] = 0
//   [34:33]  jmp_mode    — 00: next, 01: jump, 10: jump if zero,
//                          11: jump if carry
//   [32]     call        — 1: push return address before jumping
//   [31]     ret         — 1: pop return address (overrides jmp)
//   [30]     halt        — 1: stop execution
//   [29]     imm         — 1: immediate mode (ram_addr field = literal value)
//   [28]     shift       — 1: shift/rotate operation (data from neighbor slices)
//   [27]     shift_dir   — when shift=1: 0=left, 1=right
//                          when shift=0: 0=normal, 1=SP-indexed mode
//   [26]     ix_mode     — when [27]=0: IX-indexed (addr = ram_addr + IX)
//                          when [27]=1 (SP mode): 0=peek, 1=auto (PUSH/POP)
//   [25]     jmp_ind     — 1: indirect jump (target from RR, not jmp_target)
//   [24:10]  ram_addr    — RAM address (15 bits → 32KB), or immediate value
//   [9:0]    jmp_target  — Microcode jump target (10 bits → 1024 words)
//
// ============================================================================

module mc14500_cpu #(
    parameter ROM_DEPTH   = 8192,  // Microcode ROM size (words, 15-bit PC)
    parameter RAM_DEPTH   = 32768, // Data RAM size (bytes), 15-bit address
    parameter STACK_DEPTH = 16,    // Hardware call stack depth
    parameter ROM_FILE    = "",    // Path to microcode .mem file
    parameter RAM_FILE    = "",    // Path to RAM init .mem file (optional)
    parameter SYNC_MEM    = 0      // 0 = comb memory (sim), 1 = sync BRAM (FPGA)
) (
    input  wire        clk,
    input  wire        rst_n,

    // Debug / observation ports
    output wire [7:0]  debug_rr,       // Result Register (all 8 bits)
    output wire [14:0] debug_pc,       // Program Counter (15-bit, 32K addressable)
    output wire        debug_flag_z,   // Zero flag
    output wire        debug_flag_c,   // Carry flag
    output wire        debug_flag_v,   // Overflow flag
    output wire        debug_halted,   // CPU halted

    // External I/O
    //   0x7FFF = data register (read/write characters)
    //   0x7FFE = status register (read-only, directly from io_status)
    output wire [7:0]  io_out_data,
    output wire        io_out_valid,    // CPU writes to UART data register
    output wire        io_in_read,      // CPU reads from UART data register (consume byte)
    input  wire [7:0]  io_in_data,
    input  wire [7:0]  io_status,      // Status byte mapped at addr 0x7FFE
    input  wire        io_stall,       // High: freeze CPU in current phase (backpressure)

    // GPIO — memory-mapped at 0x7FF4 (output), 0x7FF5 (input)
    output wire [7:0]  gpio_out_data,
    output wire        gpio_out_we,
    input  wire [7:0]  gpio_in_data,

    // SPI master — memory-mapped at 0x7FF0..0x7FF2
    //   0x7FF0 = SPI_DATA   (W: start TX with byte; R: last RX byte)
    //   0x7FF1 = SPI_STATUS (R: bit 0 = busy)
    //   0x7FF2 = SPI_CS     (W: chip-select bits, 1=deselect, 0=select)
    output wire [7:0]  spi_tx_data,
    output wire        spi_tx_we,
    input  wire [7:0]  spi_rx_data,
    input  wire        spi_busy,
    output wire [7:0]  spi_cs_data,
    output wire        spi_cs_we,

    // External storage interface (block-oriented "disk")
    //   0x7FF8 = block# low byte (write)
    //   0x7FF9 = block# high byte (write)
    //   0x7FFA = block data byte (R/W, auto-increments offset within block)
    output wire [7:0]  storage_block_lo_data,
    output wire        storage_block_lo_we,
    output wire [7:0]  storage_block_hi_data,
    output wire        storage_block_hi_we,
    output wire [7:0]  storage_data_out,
    output wire        storage_data_we,
    output wire        storage_data_re,
    input  wire [7:0]  storage_data_in,

    // RAM observation (active during writes)
    output wire [14:0] debug_ram_addr,
    output wire [7:0]  debug_ram_wdata,
    output wire        debug_ram_we,

    // ROM diagnostic — high if ROM[0] has been populated (non-zero microword).
    // Zero microword = NOP, so at reset this also indicates whether $readmemh
    // (or the inline init) actually wrote anything into the ROM array.
    output wire        debug_rom_loaded
);

    // ========================================================================
    // Microcode ROM (48-bit microword, 11-bit PC → 2048 words)
    // ========================================================================
    reg [47:0] rom [0:ROM_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < ROM_DEPTH; i = i + 1)
            rom[i] = 48'h000000000000;
        `ifdef FPGA_INLINE_INIT
            `include "build/forth_init.vh"
        `else
        `ifdef FPGA_BUILD
            $readmemh("build/forth.mem", rom);
        `else
            if (ROM_FILE != "")
                $readmemh(ROM_FILE, rom);
        `endif
        `endif
    end

    // ========================================================================
    // Data RAM
    // ========================================================================
    reg [7:0] ram [0:RAM_DEPTH-1];

    integer j;
    initial begin
        for (j = 0; j < RAM_DEPTH; j = j + 1)
            ram[j] = 8'h00;
        // Use $readmemh on every path. The old comment that "$readmemh
        // silently drops data on Gowin/yosys" appeared to be paranoia
        // carried over from the 48-bit-wide ROM; for the byte-wide RAM
        // yosys 0.64 does pick the file up cleanly.  Inline ram[X]=…
        // assignments scaled badly when the boot text was packed in here
        // (Phase B) — yosys created one init port per assignment and the
        // resulting BRAM init was incomplete in the bitstream.
        `ifdef FPGA_BUILD
            $readmemh("build/forth.ram", ram);
        `else
            if (RAM_FILE != "")
                $readmemh(RAM_FILE, ram);
        `endif
    end

    // (Phase D: boot_text BRAM removed — blocks_core.fth lives on the SD
    // card, the user loads it on demand via `0 100 0 110 THRU` or similar.
    // ROM only carries the Forth kernel + dict-init code; everything above
    // that comes from SD.)

    // ========================================================================
    // Program Counter & Control
    // ========================================================================
    reg [14:0] pc;
    reg        halted;
    reg        carry_flag;     // Latched carry from last arithmetic op

    // Hardware stack for CALL/RET
    localparam SP_WIDTH = $clog2(STACK_DEPTH);
    reg [14:0]           stack [0:STACK_DEPTH-1];
    reg [SP_WIDTH-1:0]   sp;       // Stack pointer (log2 of STACK_DEPTH)

    // Index Register (IX) — memory-mapped at 0xFD (lo) and 0xFB (hi)
    // Full 15-bit IX = {ix_hi, ix} for unified memory addressing
    reg [7:0]  ix;             // IX low byte (0x7FFD)
    reg [6:0]  ix_hi;          // IX high 7 bits (0x7FFB)

    // Data Stack Pointer (SP) — memory-mapped at 0xFC, stack grows downward
    reg [7:0]  sp_data;

    // ========================================================================
    // FPGA BRAM pipeline (SYNC_MEM=1: 3-phase execution for sync BRAM reads)
    // ========================================================================
    // phase 0: ROM read → microword_r latches at end of phase
    // phase 1: RAM read (using eff_addr from microword_r) → ram_data_r latches
    // phase 2: execute — both memory regs valid, update CPU state at end
    // cpu_en: high only during execute phase (or always for sim mode).
    reg  [1:0] phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase <= 2'd0;
        else if (!halted && !io_stall) phase <= (phase == 2'd2) ? 2'd0 : (phase + 2'd1);
    end
    wire cpu_en = SYNC_MEM ? (phase == 2'd2 && !io_stall) : !io_stall;

    // ========================================================================
    // Microword Decode
    // ========================================================================
    reg  [47:0] microword_r;
    wire [47:0] microword;
    always @(posedge clk) begin
        if (!SYNC_MEM || phase == 2'd0)
            microword_r <= rom[pc];
    end
    assign microword = SYNC_MEM ? microword_r : rom[pc];

    // 48-bit microword layout — see doc/MICROWORD.md for full reference.
    // [47:43] reserved for future use (Return-Stack-Mode, Interrupt, STC, ...)
    wire [3:0]  opcode     = microword[42:39];
    wire        we         = microword[38];
    wire        use_carry  = microword[37];
    wire [1:0]  jmp_mode   = microword[36:35];
    wire        is_call    = microword[34];
    wire        is_ret     = microword[33];
    wire        is_halt    = microword[32];
    wire        imm_mode   = microword[31];
    wire        is_shift   = microword[30];
    wire        raw_bit27  = microword[29];        // shift_dir / sp_mode (context)
    wire        raw_bit26  = microword[28];        // ix_mode / sp_auto   (context)
    wire        jmp_ind    = microword[27];
    wire [15:0] ram_addr   = microword[26:11];     // 16-bit, eff_addr uses low 15
    wire [14:0] jmp_target = {microword[47:44], microword[10:0]};  // 15-bit PC target (0..0x7FFF)

    // Derived addressing modes (bit [26] and [25] are context-dependent)
    wire        shift_right = raw_bit27;                       // when shift=1
    wire        sp_mode     = !is_shift && raw_bit27;          // SP-indexed
    wire        sp_auto     = sp_mode && raw_bit26;            // SP + auto inc/dec
    wire        ix_mode     = !is_shift && !raw_bit27 && raw_bit26;  // IX-indexed

    // ========================================================================
    // Effective Address
    // ========================================================================
    // For PUSH (sp_auto + write): SP decrements FIRST, then we use new SP.
    // This is handled in the sequential block; here we use sp_data directly.
    // The pre-decremented value is computed combinationally for the store address.
    wire [7:0]  sp_predec  = sp_data - 8'h01;
    wire        is_push    = sp_auto && we;      // STO with sp_auto = PUSH
    wire        is_pop     = sp_auto && !we;     // LD/etc with sp_auto = POP

    // Note: ram_addr is 16 bits in the microword but eff_addr is 15-bit (32KB RAM).
    // ram_addr[15] is reserved for future 64KB-RAM activation and currently ignored.
    wire [14:0] sp_eff     = is_push ? (ram_addr[14:0] + {7'h00, sp_predec}) :
                                       (ram_addr[14:0] + {7'h00, sp_data});

    wire [14:0] eff_addr   = ix_mode ? (ram_addr[14:0] + {ix_hi, ix}) :
                              sp_mode ? sp_eff                        :
                              ram_addr[14:0];

    // ========================================================================
    // Data Bus — Immediate, I/O, registers, or RAM
    // ========================================================================
    // Registered RAM read (for SYNC_MEM=1, FPGA BRAM)
    reg  [7:0] ram_data_r;
    wire [7:0] ram_read = SYNC_MEM ? ram_data_r : ram[eff_addr];
    always @(posedge clk) begin
        if (!SYNC_MEM || phase == 2'd1)
            ram_data_r <= ram[eff_addr];
    end

    wire [7:0] data_from_ram = imm_mode               ? ram_addr[7:0] : // Immediate
                               (eff_addr == 15'h7FFF) ? io_in_data    :
                               (eff_addr == 15'h7FFE) ? io_status     :
                               (eff_addr == 15'h7FFD) ? ix            :
                               (eff_addr == 15'h7FFC) ? sp_data       :
                               (eff_addr == 15'h7FFB) ? {1'b0, ix_hi} :
                               (eff_addr == 15'h7FFA) ? storage_data_in :
                               (eff_addr == 15'h7FF5) ? gpio_in_data :
                               (eff_addr == 15'h7FF1) ? {7'b0, spi_busy} :
                               (eff_addr == 15'h7FF0) ? spi_rx_data :
                               // 0x7FF4 / 0x7FF2 are write-only (readback
                               // would create a combinational loop)
                               ram_read;

    // ========================================================================
    // Shift Data Routing
    // ========================================================================
    // For shift/rotate: each slice gets its neighbor's RR bit instead of RAM data.
    // Slices are unchanged — they just see different data_in.
    //
    //   SHL: slice[n] ← slice[n-1].rr, slice[0] ← 0 or carry
    //   SHR: slice[n] ← slice[n+1].rr, slice[7] ← 0 or carry
    //   ROL/ROR: same but carry_flag feeds the vacant bit
    //
    // The bit that "falls off" becomes the new carry flag.

    wire [7:0] slice_rr;         // forward-declared for shift routing
    wire       shift_in_bit = use_carry ? carry_flag : 1'b0;

    wire [7:0] shift_data;
    assign shift_data[0] = shift_right ? slice_rr[1] : shift_in_bit;
    assign shift_data[1] = shift_right ? slice_rr[2] : slice_rr[0];
    assign shift_data[2] = shift_right ? slice_rr[3] : slice_rr[1];
    assign shift_data[3] = shift_right ? slice_rr[4] : slice_rr[2];
    assign shift_data[4] = shift_right ? slice_rr[5] : slice_rr[3];
    assign shift_data[5] = shift_right ? slice_rr[6] : slice_rr[4];
    assign shift_data[6] = shift_right ? slice_rr[7] : slice_rr[5];
    assign shift_data[7] = shift_right ? shift_in_bit : slice_rr[6];

    // Bit that shifts out → becomes carry
    wire shift_carry_out = shift_right ? slice_rr[0] : slice_rr[7];

    // Final data input to slices: shift data or normal data
    wire [7:0] slice_data_in = is_shift ? shift_data : data_from_ram;

    // Force opcode to LD (0x1) during shift so slices load from data_in
    // Force NOP during non-execute phases so RR doesn't change multiple times per instruction
    wire [3:0] slice_opcode_raw = is_shift ? 4'h1 : opcode;
    wire [3:0] slice_opcode     = cpu_en ? slice_opcode_raw : 4'h0;

    // ========================================================================
    // Slice Instantiation — Eight 1-Bit Slices with Carry Chain
    // ========================================================================
    wire [7:0] slice_data_out;
    wire [8:0] carry_chain;    // 9 bits: carry_chain[0] = carry in to bit 0

    // Carry input for bit 0: either 0 or the latched carry flag
    // For INC: set carry_in[0]=1 to increment by 1
    // For DEC: set carry_in[0]=1 to decrement by 1
    wire carry_seed;
    assign carry_seed = (opcode == 4'hA || opcode == 4'hB)
                      ? 1'b1                         // INC/DEC: seed with 1
                      : (use_carry ? carry_flag : 1'b0);

    assign carry_chain[0] = carry_seed;

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : slice
            mc14500_slice u_slice (
                .clk       (clk),
                .rst_n     (rst_n),
                .opcode    (slice_opcode),
                .data_in   (slice_data_in[g]),
                .carry_in  (carry_chain[g]),
                .data_out  (slice_data_out[g]),
                .carry_out (carry_chain[g+1]),
                .rr_out    (slice_rr[g])
            );
        end
    endgenerate

    // ========================================================================
    // Flags
    // ========================================================================
    wire flag_zero  = (slice_rr == 8'h00);
    wire flag_carry = carry_chain[8];

    // Overflow: XOR of carry into and out of MSB (signed overflow)
    wire flag_overflow = carry_chain[7] ^ carry_chain[8];

    // Determine if current operation is arithmetic (updates carry flag)
    wire is_arithmetic = (opcode == 4'h8) || (opcode == 4'h9) ||
                         (opcode == 4'hA) || (opcode == 4'hB);

    // ========================================================================
    // RAM Write (using effective address for indexed mode)
    // ========================================================================
    wire is_storage_addr = (eff_addr >= 15'h7FF8) && (eff_addr <= 15'h7FFA);
    wire is_gpio_addr    = (eff_addr == 15'h7FF4) || (eff_addr == 15'h7FF5);
    wire is_spi_addr     = (eff_addr >= 15'h7FF0) && (eff_addr <= 15'h7FF2);
    wire is_special_addr = (eff_addr >= 15'h7FFB) || is_storage_addr || is_gpio_addr || is_spi_addr;
    // All write-enables gated by cpu_en — critical for SYNC_MEM=1 where
    // microword is only valid during the execute phase.
    wire ram_write_en = we && !halted && !is_special_addr && !imm_mode && cpu_en;
    wire io_write_en  = we && !halted && (eff_addr == 15'h7FFF) && !imm_mode && cpu_en;
    wire ix_write_en  = we && !halted && (eff_addr == 15'h7FFD) && !imm_mode && cpu_en;
    wire ix_hi_write_en = we && !halted && (eff_addr == 15'h7FFB) && !imm_mode && cpu_en;
    wire sp_write_en  = we && !halted && (eff_addr == 15'h7FFC) && !imm_mode && !sp_mode && cpu_en;

    // --- Storage MMIO (external block-oriented "disk") ---
    assign storage_block_lo_we = we && !halted && (eff_addr == 15'h7FF8) && !imm_mode && cpu_en;
    assign storage_block_hi_we = we && !halted && (eff_addr == 15'h7FF9) && !imm_mode && cpu_en;
    assign storage_data_we     = we && !halted && (eff_addr == 15'h7FFA) && !imm_mode && cpu_en;
    assign storage_data_re     = !we && !halted && (eff_addr == 15'h7FFA) && cpu_en;
    assign gpio_out_we         = we && !halted && (eff_addr == 15'h7FF4) && !imm_mode && cpu_en;
    assign gpio_out_data       = slice_data_out;
    assign storage_block_lo_data = slice_data_out;
    assign storage_block_hi_data = slice_data_out;
    assign storage_data_out      = slice_data_out;

    // --- SPI master MMIO ---
    assign spi_tx_we   = we && !halted && (eff_addr == 15'h7FF0) && !imm_mode && cpu_en;
    assign spi_cs_we   = we && !halted && (eff_addr == 15'h7FF2) && !imm_mode && cpu_en;
    assign spi_tx_data = slice_data_out;
    assign spi_cs_data = slice_data_out;

    always @(posedge clk) begin
        if (ram_write_en)
            ram[eff_addr] <= slice_data_out;
    end

    // ========================================================================
    // Branch Logic
    // ========================================================================
    wire do_jump;
    assign do_jump = (jmp_mode == 2'b01)                     ||  // Unconditional
                     (jmp_mode == 2'b10 && flag_zero)         ||  // Jump if zero
                     (jmp_mode == 2'b11 && carry_flag);           // Jump if carry

    // ========================================================================
    // Sequential Control — PC, Flags, Stack, Halt
    // ========================================================================
    // IX register — write from data bus or reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ix <= 8'h00;
        else if (ix_write_en && cpu_en)
            ix <= slice_data_out;
    end

    // IX_HI register — upper 7 bits of 15-bit index
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ix_hi <= 7'h00;
        else if (ix_hi_write_en && cpu_en)
            ix_hi <= slice_data_out[6:0];
    end

    // SP register — auto-decrement on PUSH, auto-increment on POP, or direct write
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sp_data <= 8'h00;
        else if (!halted && cpu_en) begin
            if (is_push)
                sp_data <= sp_predec;           // PUSH: SP--
            else if (is_pop)
                sp_data <= sp_data + 8'h01;     // POP: SP++
            else if (sp_write_en)
                sp_data <= slice_data_out;      // Direct: STO [0xFC]
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc         <= 15'h0000;
            carry_flag <= 1'b0;
            halted     <= 1'b0;
            sp         <= {SP_WIDTH{1'b0}};
        end
        else if (!halted && cpu_en) begin
            // --- Update carry flag on arithmetic or shift operations ---
            if (is_arithmetic)
                carry_flag <= flag_carry;
            else if (is_shift)
                carry_flag <= shift_carry_out;

            // --- Halt ---
            if (is_halt) begin
                halted <= 1'b1;
            end
            // --- Return from subroutine ---
            else if (is_ret && sp != {SP_WIDTH{1'b0}}) begin
                pc <= stack[sp - 1];
                sp <= sp - 1;
            end
            // --- Call subroutine (push return addr, then jump) ---
            else if (do_jump && is_call) begin
                stack[sp] <= pc + 15'h0001;
                sp        <= sp + 1;
                pc        <= jmp_ind ? {7'b0, slice_rr} : jmp_target;
            end
            // --- Simple jump (direct or indirect via RR) ---
            else if (do_jump) begin
                pc <= jmp_ind ? {7'b0, slice_rr} : jmp_target;
            end
            // --- Normal: advance to next instruction ---
            else begin
                pc <= pc + 15'h0001;
            end
        end
    end

    // ========================================================================
    // Debug / Observation Outputs
    // ========================================================================
    assign debug_rr       = slice_rr;
    assign debug_pc       = pc;
    assign debug_flag_z   = flag_zero;
    assign debug_flag_c   = carry_flag;
    assign debug_flag_v   = flag_overflow;
    assign debug_halted   = halted;
    assign io_out_data    = slice_data_out;
    assign io_out_valid   = io_write_en;
    assign io_in_read     = !we && !halted && (eff_addr == 15'h7FFF) && cpu_en;
    assign debug_ram_addr = eff_addr;
    assign debug_ram_wdata= slice_data_out;
    assign debug_ram_we   = ram_write_en;
    assign debug_rom_loaded = |rom[0];

endmodule
