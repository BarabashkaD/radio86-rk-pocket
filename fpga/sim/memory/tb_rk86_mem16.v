// The memory model of the fork's machine16 testbench built from pocket_memory (spec 9.1-6 of 0.8.0):
//   python -B <core>/src/sim/machine16/run_machine16_sim.py machine16
//       --mem <repo>/fpga/sim/memory/tb_rk86_mem16.v <repo>/fpga/rtl/pocket_memory.v
// (absolute paths; fpga/sim/run_core_machine.py builds that command). The ports of the fork's
// tb_rk86_mem16. The testbench fills bios at time 0 ($readmemh); the monitor is copied into the
// 8000-87FF of pocket_memory after #1. pocket_memory keeps its own RAM, which starts at zero; no
// loader, no reset. The time unit of the fork's testbench (1 ns): #1 is the first clk edge, in reset.
`timescale 1ns/1ns
`default_nettype none
module tb_rk86_mem16(
    input  wire        clk,
    input  wire [15:0] bus_a,
    input  wire  [7:0] cpu_do,
    input  wire        cpu_wr_n,
    input  wire        rom,
    input  wire        aen,
    input  wire        mem_rd,
    output wire  [7:0] mem_di
);
reg [7:0] bios [0:2047];
integer k;
initial begin
    #1;
    for (k = 0; k < 2048; k = k + 1) mem.ram[32768 + k] = bios[k];
end
pocket_memory mem(.clk(clk), .reset(1'b0), .bus_a(bus_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom),
    .aen(aen), .mem_rd(mem_rd), .mem_di(mem_di), .cpu_write(), .load_active(1'b0), .load_we(1'b0),
    .load_a(16'd0), .load_d(8'd0), .rus_mode());
endmodule
`default_nettype wire
