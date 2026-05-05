// Synthesis wrapper: CPU with small ROM/RAM for readable schematic
module mc14500_cpu_synth (
    input  wire        clk,
    input  wire        rst_n,
    output wire [7:0]  debug_rr,
    output wire [7:0]  debug_pc,
    output wire        debug_flag_z,
    output wire        debug_flag_c,
    output wire        debug_flag_v,
    output wire        debug_halted,
    output wire [7:0]  io_out_data,
    output wire        io_out_valid,
    input  wire [7:0]  io_in_data,
    output wire [7:0]  debug_ram_addr,
    output wire [7:0]  debug_ram_wdata,
    output wire        debug_ram_we
);

    mc14500_cpu #(
        .ROM_DEPTH   (4),
        .RAM_DEPTH   (4),
        .STACK_DEPTH (4),
        .ROM_FILE    ("")
    ) u_cpu (
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
        .io_in_data     (io_in_data),
        .debug_ram_addr (debug_ram_addr),
        .debug_ram_wdata(debug_ram_wdata),
        .debug_ram_we   (debug_ram_we)
    );

endmodule
