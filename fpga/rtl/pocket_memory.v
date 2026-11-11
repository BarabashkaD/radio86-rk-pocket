// RAM 0000-7FFF and the monitor of the Radio-86RK on the Analogue Pocket: one byte-wide memory
// with one port, as the original's memory bus (spec 4.3, 4.5 of 0.8.0). The address is bus_a of
// rk86_machine16: the CPU's, or the 8257's while its AEN is high; the loader port owns it while
// the machine is in reset (the cold clear of the RAM, the monitor from its APF slot). Index
// 0000-7FFF is the RAM, 8000-87FF the monitor, read when rom (E000-FFFF, and every address during
// start-up, when the RAM is off and takes no write). mem_di is the byte at bus_a 1 clk after the
// address, whatever mem_rd is. A DMA read is decoded like a CPU read, as on the board: the 8275 takes the
// byte of the device at the 8257's address (this memory for RAM and monitor) at WR↑, 5 ce16 after ЧТЕНИЕ.
`default_nettype none
module pocket_memory(
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] bus_a,
    input  wire  [7:0] cpu_do,
    input  wire        cpu_wr_n,
    input  wire        rom,
    input  wire        aen,
    input  wire        mem_rd,        // ЧТЕНИЕ: not used for the read (see above); the port of tb_rk86_mem16
    output wire  [7:0] mem_di,
    output wire        cpu_write,     // one clk on the falling edge of cpu_wr_n, any address
    input  wire        load_active,
    input  wire        load_we,
    input  wire [15:0] load_a,
    input  wire  [7:0] load_d,
    output reg         rus_mode = 1'b0
);
localparam integer SIZE = 34816;
reg [7:0] ram [0:SIZE-1];
integer k;
initial for (k = 0; k < SIZE; k = k + 1) ram[k] = k < 32768 ? 8'h00 : 8'hFF;
reg prev_wr_n = 1'b1;
assign cpu_write = !reset && prev_wr_n && !cpu_wr_n;
wire ram_write = cpu_write && !aen && !rom && !bus_a[15];
wire [15:0] index = rom ? {5'b10000, bus_a[10:0]} : {1'b0, bus_a[14:0]};
wire [15:0] port_a = load_active ? load_a : ram_write ? {1'b0, bus_a[14:0]} : index;
wire port_we = load_active ? load_we : ram_write;
wire [7:0] port_d = load_active ? load_d : cpu_do;
reg [15:0] read_a = 16'd0;
always @(posedge clk) begin
    if (port_we) ram[port_a] <= port_d;
    read_a <= port_a;
    prev_wr_n <= reset ? 1'b1 : cpu_wr_n;
    if (port_we && port_a == 16'h7606) rus_mode <= port_d[0];
end
assign mem_di = ram[read_a];
endmodule
`default_nettype wire
