// RAM 0000-7FFF and the monitor ROM port of the Radio-86RK on the Analogue Pocket (spec 5.4):
// a CPU read/write port with an address tag, a DMA read port with explicit write forwarding,
// the monitor through a tagged port of pocket_boot_assets, and cpu_ready by region
// (docs/integration.md of the core, section 6).
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
    output wire [10:0] rom_addr,      // monitor: data and tag one clk or more after the address
    input  wire  [7:0] rom_data,
    input  wire [10:0] rom_tag,
    input  wire        load_active,   // the loader owns the RAM write port (machine in reset)
    input  wire        load_we,
    input  wire [14:0] load_a,
    input  wire  [7:0] load_d,
    output reg         rus_mode = 1'b0 // bit 0 of the monitor workspace byte 7606 (RUS/LAT)
);
reg [7:0] ram [0:32767];
integer k;
initial for (k = 0; k < 32768; k = k + 1) ram[k] = 8'h00;

reg prev_wr_n = 1'b1;
assign cpu_write = !reset && prev_wr_n && !cpu_wr_n;
wire ram_write = cpu_write && !cpu_a[15];
wire [14:0] port_a = load_active ? load_a : cpu_a[14:0];
wire port_we = load_active ? load_we : ram_write;
wire [7:0] port_d = load_active ? load_d : cpu_do;

reg [7:0] cpu_q = 8'h00;
reg [15:0] cpu_tag = 16'hFFFF;        // {rom, cpu_a[14:0]} that cpu_q was read for
reg cpu_tag_ok = 1'b0;                // 0 for one clk after a write through the port
always @(posedge clk) begin
    cpu_q <= ram[port_a];
    if (port_we) ram[port_a] <= port_d;
end
always @(posedge clk) begin
    prev_wr_n <= reset ? 1'b1 : cpu_wr_n;
    cpu_tag <= {rom, cpu_a[14:0]};
    cpu_tag_ok <= !port_we && !load_active;
end

reg [7:0] dma_raw = 8'h00, fwd_data = 8'h00;
reg fwd = 1'b0;
always @(posedge clk)
    dma_raw <= ram[vid_a[14:0]];
always @(posedge clk) begin
    fwd <= port_we && port_a == vid_a[14:0];
    fwd_data <= port_d;
end
wire [7:0] dma_q = fwd ? fwd_data : dma_raw;

assign rom_addr = cpu_a[10:0];
wire window = cpu_a[15:13] == 3'd5;
wire memory = rom || !cpu_a[15];
wire ram_hit = cpu_tag_ok && cpu_tag == {1'b0, cpu_a[14:0]};
wire rom_hit = rom_tag == cpu_a[10:0];
assign cpu_ready = (window ? window_ready : memory ? (rom ? rom_hit : ram_hit) : 1'b1) && !vid_rd;
assign mem_di = vid_rd ? dma_q : rom ? rom_data : cpu_q;

always @(posedge clk)
    if (port_we && port_a == 15'h7606) rus_mode <= port_d[0];
endmodule
`default_nettype wire
