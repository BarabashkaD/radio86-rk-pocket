// The memory model of the core's machine testbench built from pocket_memory (spec 9.2):
//   python -B cores/karabas-go-core-rk86/src/sim/machine/run_machine_sim.py --mem fpga/sim/memory/tb_rk86_mem.v
// SYNC 1: pocket_memory with the monitor copied into its 8000-87FF at the first clk edge (the
// testbench fills bios at time 0); the stall generator holds the CPU's reads (slow).
// SYNC 0: the Karabas model of the REF build, as in the core's tb_rk86_mem.v.
// The testbench writes bios and ram; pocket_memory keeps its own RAM, which starts at zero.
`default_nettype none
module tb_rk86_mem(
    input  wire        clk,
    input  wire [15:0] cpu_a,
    input  wire  [7:0] cpu_do,
    input  wire        cpu_wr_n,
    input  wire        rom,
    input  wire [15:0] vid_a,
    input  wire        vid_rd,
    input  wire        slow,
    input  wire  [7:0] junk,
    output wire  [7:0] mem_di,
    output wire        cpu_ready
);
parameter SYNC = 1;
reg [7:0] ram [0:32767];
reg [7:0] bios [0:2047];
generate
    if (SYNC) begin : g_pocket
        wire pocket_ready;
        reg copied = 1'b0;
        integer k;
        always @(posedge clk)
            if (!copied) begin
                for (k = 0; k < 2048; k = k + 1) mem.ram[32768 + k] = bios[k];
                copied = 1'b1;
            end
        // the stall generator holds the port: a step waits wherever slow is high
        assign cpu_ready = pocket_ready && !slow;
        pocket_memory mem(.clk(clk), .reset(1'b0), .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n),
            .rom(rom), .vid_a(vid_a), .vid_rd(vid_rd), .window_ready(1'b1), .mem_di(mem_di),
            .cpu_ready(pocket_ready), .cpu_write(), .load_active(1'b0), .load_we(1'b0), .load_a(16'd0),
            .load_d(8'd0), .rus_mode());
    end else begin : g_comb
        always @(posedge clk)
            if (!vid_rd && !cpu_wr_n && !cpu_a[15])
                ram[cpu_a[14:0]] <= cpu_do;
        assign mem_di = vid_rd ? ram[vid_a[14:0]] : rom ? bios[cpu_a[10:0]] : ram[cpu_a[14:0]];
        assign cpu_ready = 1'b1;
    end
endgenerate
endmodule
`default_nettype wire
