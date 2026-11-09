`timescale 1ns/1ps
`default_nettype none
// pocket_cold_clear driving the loader port of pocket_memory (spec 5.2, 5.4): idle before start,
// we for exactly 32768 clks, every RAM byte and the RUS shadow cleared, the monitor area kept, a
// second clear, and a start during a clear that does not restart it.
module tb_cold_clear;
reg clk = 1'b0;
always #5 clk = ~clk;
reg start = 1'b0;
reg reset = 1'b0;
reg cpu_wr_n = 1'b1;
reg [15:0] cpu_a = 16'h0000;
reg [7:0] cpu_do = 8'h00;
wire active, we, done;
wire [14:0] a;
wire [7:0] d;
wire [7:0] mem_di;
wire cpu_ready, cpu_write, rus_mode;
pocket_cold_clear clear(.clk(clk), .start(start), .active(active), .we(we), .a(a), .d(d), .done(done));
pocket_memory dut_mem(.clk(clk), .reset(reset), .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(1'b0),
    .vid_a(16'h0000), .vid_rd(1'b0), .window_ready(1'b1), .mem_di(mem_di), .cpu_ready(cpu_ready),
    .cpu_write(cpu_write), .load_active(active), .load_we(we), .load_a({1'b0, a}), .load_d(d), .rus_mode(rus_mode));
integer i, wcount = 0;
always @(posedge clk) if (we) wcount = wcount + 1;
task fail(input [8*64-1:0] what);
    begin $display("ERROR: %0s", what); $finish; end
endtask
task fill_ram;
    begin
        for (i = 0; i < 32768; i = i + 1) dut_mem.ram[i] = (i[7:0] ^ 8'hA5) | 8'h01;
    end
endtask
task check_zero;
    begin
        for (i = 0; i < 32768; i = i + 1)
            if (dut_mem.ram[i] !== 8'h00) begin
                $display("ERROR: RAM byte %0h is %0h after the clear", i, dut_mem.ram[i]);
                $finish;
            end
        for (i = 32768; i < 34816; i = i + 1)
            if (dut_mem.ram[i] !== 8'hFF) fail("the clear wrote the monitor area");
    end
endtask
// one-clk start pulse; the signals are checked on the negedge after the next posedge
task pulse_start;
    begin @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0; end
endtask
task wait_idle;
    begin
        while (active) @(negedge clk);
        @(negedge clk);
    end
endtask
initial begin
    repeat (3) @(negedge clk);
    if (done !== 1'b0) fail("done before the first clear");
    if (active !== 1'b0) fail("active before start");
    fill_ram;
    // the RUS shadow set by a CPU write of 7606 (reset low)
    cpu_a = 16'h7606; cpu_do = 8'h01; cpu_wr_n = 1'b0;
    repeat (2) @(negedge clk);
    cpu_wr_n = 1'b1; cpu_do = 8'h00; @(negedge clk);
    if (rus_mode !== 1'b1) fail("RUS shadow not set before the clear");
    if (dut_mem.ram[15'h7606] !== 8'h01) fail("the CPU write of 7606 did not reach the RAM");
    fill_ram; dut_mem.ram[15'h7606] = 8'h01;
    repeat (3) @(negedge clk);
    if (active !== 1'b0 || done !== 1'b0) fail("active or done moved without start");
    // the first clear, the machine in reset
    reset = 1'b1; wcount = 0;
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
    if (active !== 1'b1) fail("active did not rise the clk after start");
    if (done !== 1'b0) fail("done set while the first clear runs");
    wait_idle;
    if (wcount !== 32768) fail("clear: we count is not 32768");
    if (done !== 1'b1) fail("done not set after the clear");
    check_zero;
    if (rus_mode !== 1'b0) fail("RUS shadow not cleared by the clear");
    repeat (5) @(negedge clk);
    if (done !== 1'b1 || active !== 1'b0 || wcount !== 32768) fail("done dropped or the clear went on after the end");
    // a second clear from idle
    fill_ram; wcount = 0;
    pulse_start;
    if (active !== 1'b1) fail("second clear: active did not rise");
    wait_idle;
    if (wcount !== 32768) fail("second clear: we count is not 32768");
    if (done !== 1'b1) fail("second clear: done dropped");
    check_zero;
    // a start during a clear does not restart it
    fill_ram; wcount = 0;
    pulse_start;
    repeat (1000) @(negedge clk);
    pulse_start;
    repeat (20000) @(negedge clk);
    pulse_start;
    wait_idle;
    if (wcount !== 32768) fail("start during a clear: we count is not 32768");
    if (done !== 1'b1) fail("start during a clear: done dropped");
    check_zero;
    $display("PASS cold_clear: idle before start, 32768 we clks per clear, all RAM bytes and the RUS shadow zero, monitor area kept, second clear, start during a clear ignored");
    $finish;
end
endmodule
`default_nettype wire
