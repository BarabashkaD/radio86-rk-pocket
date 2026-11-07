`timescale 1ns/1ps
`default_nettype none
// pocket_pll_watchdog (spec 5.2): quiet while locked, a PULSE-clk reset after TIMEOUT clk without
// lock, retries while unlocked, stops once locked.
module tb_pll_watchdog;
reg clk = 1'b0;
always #5 clk = ~clk;
reg locked = 1'b1;
wire pll_reset;
pocket_pll_watchdog #(.TIMEOUT(100), .PULSE(4)) dut(.clk(clk), .locked_s(locked), .pll_reset(pll_reset));
integer pulses = 0, high = 0;
reg prev = 1'b0;
always @(negedge clk) begin
    if (pll_reset) high = high + 1;
    if (pll_reset && !prev) pulses = pulses + 1;
    prev = pll_reset;
end
initial begin
    repeat (500) @(negedge clk);
    if (pulses != 0) begin $display("ERROR: watchdog pulse while locked"); $finish; end
    locked = 1'b0; repeat (99) @(negedge clk);
    if (pulses != 0) begin $display("ERROR: watchdog pulse before the timeout"); $finish; end
    repeat (10) @(negedge clk);
    if (pulses != 1 || high != 4) begin $display("ERROR: watchdog pulse count %0d, %0d clk high", pulses, high); $finish; end
    repeat (200) @(negedge clk);
    if (pulses < 2) begin $display("ERROR: watchdog did not retry"); $finish; end
    locked = 1'b1; repeat (10) @(negedge clk); pulses = 0; repeat (300) @(negedge clk);
    if (pulses != 0) begin $display("ERROR: watchdog pulse after lock"); $finish; end
    $display("PASS PLL watchdog: quiet while locked, pulse after the timeout, retries, stops on lock");
    $finish;
end
endmodule
`default_nettype wire
