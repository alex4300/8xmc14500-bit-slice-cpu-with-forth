// ============================================================================
// storage_bram.v — 8-block (2KB) BRAM storage emulator for Forth blocks
// ============================================================================
// Isolated into its own module with `keep_hierarchy` so yosys's opt_merge
// pass can't flatten it into the CPU and blow up consolidating the big
// ROM mux tree together with storage logic.
// ============================================================================

module storage_bram (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] blk_lo_wdata,
    input  wire       blk_lo_we,
    input  wire [7:0] blk_hi_wdata,       // currently unused (8 blocks)
    input  wire       blk_hi_we,
    input  wire [7:0] data_wdata,
    input  wire       data_we,
    input  wire       data_re,
    output wire [7:0] data_rdata
);

    localparam ADDR_BITS = 11;   // 8 blocks × 256 bytes = 2048

    (* ram_style = "block", syn_ramstyle = "block_ram" *)
    reg [7:0] stg_ram [0:(1 << ADDR_BITS) - 1];

    reg [2:0] blk;
    reg [7:0] offset;
    reg [7:0] data_r;

    integer i;
    initial begin
        for (i = 0; i < (1 << ADDR_BITS); i = i + 1)
            stg_ram[i] = 8'h00;
        `ifdef FPGA_INLINE_INIT
            `include "build/storage_init.vh"
        `else
        `ifdef FPGA_BUILD
            $readstg_ramh("build/storage.hex", stg_ram);
        `endif
        `endif
    end

    wire [ADDR_BITS-1:0] addr = {blk, offset};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk    <= 3'd0;
            offset <= 8'd0;
        end else begin
            if (blk_lo_we) begin
                blk    <= blk_lo_wdata[2:0];
                offset <= 8'd0;
            end else if (blk_hi_we) begin
                offset <= 8'd0;
            end else if (data_we) begin
                stg_ram[addr] <= data_wdata;
                offset    <= offset + 1'b1;
            end else if (data_re) begin
                offset    <= offset + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        data_r <= stg_ram[addr];
    end

    assign data_rdata = data_r;

endmodule

// Rename the storage init variable to match the inline include expectation.
// The include references `stg_ram[N]` — which matches our local register name.
