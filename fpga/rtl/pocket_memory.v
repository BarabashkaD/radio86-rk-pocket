// RAM 0000-7FFF and the monitor of the Radio-86RK on the Analogue Pocket: one byte-wide memory
// with one port, like the original's memory bus. Its users: the CPU; the DMA while it holds the
// bus (vid_rd: the CPU waits; rk86_machine does not step the CPU while hlda); the loader port
// while the machine is in reset (the cold clear of the RAM, the monitor from its APF slot). Index
// 0000-7FFF is the RAM, 8000-87FF the monitor, read when rk86_machine sets rom (E000-FFFF, and
// 0000-7FFF after reset until A15). cpu_ready by region (docs/integration.md of the core, section
// 6): the byte for the CPU's index 1 clk after the address; in A000-BFFF the window device's ready.
`default_nettype none
module pocket_memory(
    input  wire        clk,
    input  wire        reset,         // the machine reset
    input  wire [15:0] cpu_a,
    input  wire  [7:0] cpu_do,
    input  wire        cpu_wr_n,
    input  wire        rom,           // rk86_machine: a read from the ROM area
    input  wire [15:0] vid_a,
    input  wire        vid_rd,
    input  wire        window_ready,  // the device in A000-BFFF has the data for cpu_a
    output wire  [7:0] mem_di,
    output wire        cpu_ready,
    output wire        cpu_write,     // one clk on the falling edge of cpu_wr_n, any address
    input  wire        load_active,   // the loader owns the port (machine in reset)
    input  wire        load_we,
    input  wire [15:0] load_a,        // 0000-7FFF the RAM, 8000-87FF the monitor
    input  wire  [7:0] load_d,
    output reg         rus_mode = 1'b0 // bit 0 of the monitor workspace byte 7606 (RUS/LAT)
);
localparam integer SIZE = 34816;      // 32768 RAM + 2048 monitor
reg [7:0] ram [0:SIZE-1];
integer k;
initial for (k = 0; k < SIZE; k = k + 1) ram[k] = k < 32768 ? 8'h00 : 8'hFF;

reg prev_wr_n = 1'b1;
assign cpu_write = !reset && prev_wr_n && !cpu_wr_n;
wire ram_write = cpu_write && !cpu_a[15];
wire [15:0] cpu_index = rom ? {5'b10000, cpu_a[10:0]} : {1'b0, cpu_a[14:0]};
// a CPU write goes to the RAM at its address and wins over a DMA read (they never meet: the CPU is
// held while the DMA has the bus; the check below reports it in simulation)
wire [15:0] port_a = load_active ? load_a : ram_write ? {1'b0, cpu_a[14:0]} : vid_rd ? {1'b0, vid_a[14:0]} : cpu_index;
wire port_we = load_active ? load_we : ram_write;
wire [7:0] port_d = load_active ? load_d : cpu_do;

reg [15:0] read_a = 16'd0;            // the address registered (Quartus single-port RAM template)
always @(posedge clk) begin
    if (port_we) ram[port_a] <= port_d;
    read_a <= port_a;
end
assign mem_di = ram[read_a];

reg [15:0] cpu_tag = 16'hFFFF;        // the CPU index the byte in mem_di was read for
reg cpu_tag_ok = 1'b0;                // 0 for one clk after a write, a load or a DMA read
always @(posedge clk) begin
    prev_wr_n <= reset ? 1'b1 : cpu_wr_n;
    cpu_tag <= cpu_index;
    cpu_tag_ok <= !port_we && !load_active && !vid_rd;
end
wire window = cpu_a[15:13] == 3'd5;
wire memory = rom || !cpu_a[15];
wire hit = cpu_tag_ok && cpu_tag == cpu_index;
assign cpu_ready = (window ? window_ready : memory ? hit : 1'b1) && !vid_rd;

always @(posedge clk)
    if (port_we && port_a == 16'h7606) rus_mode <= port_d[0];
// synthesis translate_off
// A write pulse can meet only the first clk of a DMA window (a step released by a cpu_ready stall on
// the WAIT->T1 edge): legal, the CPU write wins and the DMA re-reads vid_a in the next clk (the 8275
// takes the byte at least 36 ce later). A write pulse inside a window would be a CPU step during
// vid_rd: never possible, reported as an error.
reg vid_rd_q = 1'b0;
always @(posedge clk) begin
    vid_rd_q <= vid_rd;
    if (!load_active && ram_write && vid_rd && vid_rd_q)
        $display("ERROR: pocket_memory: a CPU write inside a DMA read at %h", cpu_a);
    else if (!load_active && ram_write && vid_rd)
        $display("INFO: pocket_memory: a CPU write on the first clk of a DMA read at %h", cpu_a);
end
// synthesis translate_on
endmodule
`default_nettype wire
