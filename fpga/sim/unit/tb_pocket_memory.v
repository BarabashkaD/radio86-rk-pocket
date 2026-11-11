`timescale 1ns/1ps
`default_nettype none
// pocket_memory (one byte-wide port at bus_a, spec 4.3, 4.5 of 0.8.0): the monitor at 8000-87FF through
// the loader port; a read returns the byte at bus_a 1 clk after the address (the RAM, the monitor with
// rom); the output keeps following bus_a with mem_rd low (the 8275 takes the DMA byte after ЧТЕНИЕ has
// ended); a write once on the falling edge of cpu_wr_n below 8000; no RAM byte changed by a write
// while aen (driven by the TB on purpose), while rom (start-up: the RAM is off) or at A15; cpu_write
// one clk; the loader port wins while load_active; the RUS shadow; the clear through the loader port,
// which keeps the monitor.
module tb_pocket_memory;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset = 1'b1, cpu_wr_n = 1'b1, rom = 1'b0, aen = 1'b0, mem_rd = 1'b0;
reg [15:0] bus_a = 16'h0000;
reg [7:0] cpu_do = 8'h00;
reg load_active = 1'b0, load_we = 1'b0;
reg [15:0] load_a = 16'd0;
reg [7:0] load_d = 8'h00;
wire [7:0] mem_di;
wire cpu_write, rus_mode;
pocket_memory dut(.clk(clk), .reset(reset), .bus_a(bus_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom),
    .aen(aen), .mem_rd(mem_rd), .mem_di(mem_di), .cpu_write(cpu_write), .load_active(load_active),
    .load_we(load_we), .load_a(load_a), .load_d(load_d), .rus_mode(rus_mode));
integer i, writes = 0;
reg [7:0] old_byte;
always @(posedge clk) if (cpu_write) writes = writes + 1;
task fail(input [8*64-1:0] what);
    begin $display("ERROR: memory: %0s", what); $finish; end
endtask
// a CPU write: cpu_wr_n low for 20 clk; the data changes after the first clk
task write_cycle(input [15:0] a, input [7:0] d);
    begin
        @(negedge clk); bus_a = a; cpu_do = d; cpu_wr_n = 1'b0;
        @(negedge clk); cpu_do = ~d;
        repeat (19) @(negedge clk);
        cpu_wr_n = 1'b1; cpu_do = 8'h00; @(negedge clk);
    end
endtask
// a read with ЧТЕНИЕ active: the byte at bus_a 1 clk after the address
task read_cycle(input [15:0] a, input r, input [7:0] want);
    begin
        @(negedge clk); bus_a = a; rom = r; mem_rd = 1'b1;
        @(negedge clk); #1;
        if (mem_di !== want) fail("wrong read data");
        mem_rd = 1'b0;
    end
endtask
// mem_rd low: the output still follows bus_a 1 clk after the address
task follow(input [15:0] a, input r, input [7:0] want);
    begin
        @(negedge clk); bus_a = a; rom = r; mem_rd = 1'b0;
        @(negedge clk); #1;
        if (mem_di !== want) fail("output dropped");
        repeat (3) @(negedge clk); #1;
        if (mem_di !== want) fail("output dropped");
    end
endtask
initial begin
    repeat (2) @(negedge clk);
    if (dut.ram[16'h8000] !== 8'hFF || dut.ram[16'h87FF] !== 8'hFF) fail("the monitor area does not start at FF");
    // the monitor through the loader port, the machine in reset
    load_active = 1'b1;
    for (i = 0; i < 2048; i = i + 1) begin load_a = 16'h8000 + i; load_d = i[7:0] ^ 8'h5A; load_we = 1'b1; @(negedge clk); end
    load_we = 1'b0; load_active = 1'b0; reset = 1'b0; @(negedge clk);
    read_cycle(16'h0100, 1'b0, 8'h00);                        // the RAM starts at zero
    writes = 0; write_cycle(16'h1234, 8'hA5);
    if (writes !== 1) fail("cpu_write is not one clk per write");
    if (dut.ram[16'h1234] !== 8'hA5) fail("the RAM did not keep the first data of the write");
    read_cycle(16'h1234, 1'b0, 8'hA5);
    read_cycle(16'hE005, 1'b1, 8'h05 ^ 8'h5A);                // the monitor, E000-FFFF
    read_cycle(16'hFFFF, 1'b1, 8'hFF ^ 8'h5A);                // its last byte
    read_cycle(16'h0006, 1'b1, 8'h06 ^ 8'h5A);                // start-up: every address reads the monitor
    // ЧТЕНИЕ low: the output keeps following bus_a (RAM, monitor, the 8257's address while aen)
    follow(16'h1234, 1'b0, 8'hA5);
    follow(16'hE007, 1'b1, 8'h07 ^ 8'h5A);
    aen = 1'b1; follow(16'h1234, 1'b0, 8'hA5); aen = 1'b0;
    // a falling cpu_wr_n while aen (never on the board: the CPU is held in HOLD) writes no RAM byte
    old_byte = dut.ram[16'h2345];
    aen = 1'b1; writes = 0; write_cycle(16'h2345, old_byte ^ 8'hFF); aen = 1'b0;
    if (dut.ram[16'h2345] !== old_byte) fail("RAM changed during aen");
    // a falling cpu_wr_n below 8000 while rom (start-up: the RAM is off) writes no RAM byte
    old_byte = dut.ram[16'h3456];
    rom = 1'b1; write_cycle(16'h3456, old_byte ^ 8'hFF); rom = 1'b0;
    if (dut.ram[16'h3456] !== old_byte) fail("RAM changed during rom");
    if (dut.ram[16'h8000 + 16'h0456] !== (8'h56 ^ 8'h5A)) fail("a write during rom reached the monitor");
    writes = 0; write_cycle(16'hF805, 8'h77);                  // A15 = 1: neither the RAM nor the monitor
    if (writes !== 1 || dut.ram[16'h1234] !== 8'hA5 || dut.ram[16'h7805] !== 8'h00 || dut.ram[16'h8005] !== (8'h05 ^ 8'h5A))
        fail("a write to 8000-FFFF reached the memory");
    // the loader port wins while load_active, over a CPU write at the same time
    @(negedge clk); load_active = 1'b1; load_a = 16'h0042; load_d = 8'h99; load_we = 1'b1;
    bus_a = 16'h0043; cpu_do = 8'h66; cpu_wr_n = 1'b0;
    @(negedge clk); load_we = 1'b0; load_active = 1'b0; cpu_wr_n = 1'b1; cpu_do = 8'h00;
    if (dut.ram[16'h0042] !== 8'h99) fail("the loader write was lost");
    if (dut.ram[16'h0043] !== 8'h00) fail("a CPU write won over the loader port");
    write_cycle(16'h7606, 8'h01);
    if (!rus_mode) fail("RUS shadow not set by a write of 7606");
    write_cycle(16'h7606, 8'h00);
    if (rus_mode) fail("RUS shadow not cleared by a write of 7606");
    write_cycle(16'h7606, 8'h01);
    // the clear through the loader port: 0000-7FFF only
    @(negedge clk); reset = 1'b1; load_active = 1'b1;
    for (i = 0; i < 32768; i = i + 1) begin load_a = i; load_d = 8'h00; load_we = 1'b1; @(negedge clk); end
    load_we = 1'b0; load_active = 1'b0; reset = 1'b0;
    if (rus_mode) fail("RUS shadow not cleared by the cold clear");
    if (dut.ram[16'h1234] !== 8'h00) fail("the loader port did not clear the RAM");
    for (i = 0; i < 2048; i = i + 1)
        if (dut.ram[16'h8000 + i] !== (i[7:0] ^ 8'h5A)) fail("the clear changed the monitor");
    $display("PASS memory: monitor through the loader port, reads 1 clk after bus_a (RAM, monitor), output follows bus_a without mem_rd, write once, no write during aen, rom or at A15, loader port wins, RUS shadow, clear keeps the monitor");
    $finish;
end
endmodule
`default_nettype wire
