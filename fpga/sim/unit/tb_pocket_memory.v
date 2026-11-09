`timescale 1ns/1ps
`default_nettype none
// pocket_memory (one byte-wide port): write once on the cpu_wr_n edge, the tag after a write, A15
// writes, the monitor at 8000-87FF through the loader port and its reads (E000-FFFF and 0000-7FFF
// after reset), the window, the DMA read while vid_rd and the CPU read after it, the RUS shadow,
// and the clear through the loader port, which keeps the monitor.
module tb_pocket_memory;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1, cpu_wr_n = 1'b1, rom = 1'b0, vid_rd = 1'b0, window_ready = 1'b1;
reg [15:0] cpu_a = 16'h0000, vid_a = 16'h0000;
reg [7:0] cpu_do = 8'h00;
reg load_active = 1'b0, load_we = 1'b0;
reg [15:0] load_a = 16'd0;
reg [7:0] load_d = 8'h00;
wire [7:0] mem_di;
wire cpu_ready, cpu_write, rus_mode;
pocket_memory dut(.clk(clk), .reset(reset), .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom),
    .vid_a(vid_a), .vid_rd(vid_rd), .window_ready(window_ready), .mem_di(mem_di), .cpu_ready(cpu_ready),
    .cpu_write(cpu_write), .load_active(load_active), .load_we(load_we), .load_a(load_a), .load_d(load_d),
    .rus_mode(rus_mode));
integer i, writes = 0;
always @(posedge clk) if (cpu_write) writes = writes + 1;
task fail(input [8*64-1:0] what);
    begin $display("ERROR: %0s", what); $finish; end
endtask
// a CPU write: cpu_wr_n low for 20 clk; the data changes after the first clk
task write_cycle(input [15:0] a, input [7:0] d);
    begin
        @(negedge clk); cpu_a = a; cpu_do = d; cpu_wr_n = 1'b0;
        @(negedge clk); cpu_do = ~d;
        repeat (19) @(negedge clk);
        cpu_wr_n = 1'b1; cpu_do = 8'h00; @(negedge clk);
    end
endtask
task read_cycle(input [15:0] a, input r, input [7:0] want);
    begin
        @(negedge clk); cpu_a = a; rom = r; #1;
        if (cpu_ready) fail("ready at once after an address change");
        @(negedge clk); #1;
        if (!cpu_ready) fail("not ready 1 clk after the address");
        if (mem_di !== want) fail("wrong read data");
    end
endtask
initial begin
    repeat (2) @(negedge clk);
    if (dut.ram[16'h8000] !== 8'hFF || dut.ram[16'h87FF] !== 8'hFF) fail("the monitor area does not start at FF");
    // the monitor through the loader port, the machine in reset
    load_active = 1'b1;
    for (i = 0; i < 2048; i = i + 1) begin load_a = 16'h8000 + i; load_d = i[7:0] ^ 8'h5A; load_we = 1'b1; @(negedge clk); end
    load_we = 1'b0; load_active = 1'b0; reset = 1'b0; @(negedge clk);
    read_cycle(16'h0100, 1'b0, 8'h00);                       // the RAM starts at zero
    writes = 0; write_cycle(16'h1234, 8'hA5);
    if (writes !== 1) fail("cpu_write is not one clk per write");
    if (dut.ram[16'h1234] !== 8'hA5) fail("the RAM did not keep the first data of the write");
    // a read of the address just written waits one clk (tag invalidated)
    @(negedge clk); cpu_a = 16'h2000; cpu_do = 8'h3C; cpu_wr_n = 1'b0;
    @(negedge clk); cpu_wr_n = 1'b1; #1;
    if (cpu_ready) fail("read after write: ready in the clk after the write");
    @(negedge clk); #1;
    if (!cpu_ready || mem_di !== 8'h3C) fail("read after write: old data or not ready");
    writes = 0; write_cycle(16'hF805, 8'h77);                 // A15 = 1: neither the RAM nor the monitor
    if (writes !== 1 || dut.ram[16'h1234] !== 8'hA5 || dut.ram[16'h8005] !== (8'h05 ^ 8'h5A))
        fail("a write to 8000-FFFF reached the memory");
    read_cycle(16'hE005, 1'b1, 8'h05 ^ 8'h5A);               // the monitor, E000-FFFF
    read_cycle(16'hFFFF, 1'b1, 8'hFF ^ 8'h5A);               // its last byte
    read_cycle(16'h0006, 1'b1, 8'h06 ^ 8'h5A);               // after reset: 0000-7FFF reads the monitor
    rom = 1'b0;
    @(negedge clk); cpu_a = 16'hA001; window_ready = 1'b0; repeat (3) @(negedge clk); #1;
    if (cpu_ready) fail("window: ready without window_ready");
    window_ready = 1'b1; #1;
    if (!cpu_ready) fail("window: not ready with window_ready");
    // the DMA: while vid_rd the CPU waits and the port reads vid_a
    read_cycle(16'h0100, 1'b0, 8'h00);
    @(negedge clk); vid_a = 16'h1234; vid_rd = 1'b1; #1;
    if (cpu_ready) fail("cpu_ready during vid_rd");
    @(negedge clk); #1;
    if (mem_di !== 8'hA5 || cpu_ready) fail("DMA read data, or cpu_ready during vid_rd");
    @(negedge clk); #1;
    if (mem_di !== 8'hA5) fail("DMA read data not held");
    vid_rd = 1'b0; #1;
    if (cpu_ready) fail("CPU read after a DMA read: ready with the DMA's word");
    @(negedge clk); #1;
    if (!cpu_ready || mem_di !== 8'h00) fail("CPU read after a DMA read: wrong data or not ready");
    write_cycle(16'h7606, 8'h01);
    if (!rus_mode) fail("RUS shadow not set by a write of 7606");
    // the clear through the loader port: 0000-7FFF only
    @(negedge clk); reset = 1'b1; load_active = 1'b1;
    for (i = 0; i < 32768; i = i + 1) begin load_a = i; load_d = 8'h00; load_we = 1'b1; @(negedge clk); end
    load_we = 1'b0; load_active = 1'b0; reset = 1'b0;
    if (rus_mode) fail("RUS shadow not cleared by the cold clear");
    if (dut.ram[16'h1234] !== 8'h00) fail("the loader port did not clear the RAM");
    for (i = 0; i < 2048; i = i + 1)
        if (dut.ram[16'h8000 + i] !== (i[7:0] ^ 8'h5A)) fail("the clear changed the monitor");
    $display("PASS memory: write once, tag after write, A15 writes, monitor through the loader port and its reads, window, DMA read and the CPU after it, RUS shadow, clear keeps the monitor");
    $finish;
end
endmodule
`default_nettype wire
