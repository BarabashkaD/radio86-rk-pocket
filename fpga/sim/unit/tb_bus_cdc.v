`timescale 1ns/1ps
`default_nettype none
// pocket_bus_cdc: two unrelated clocks (74.25 and 12.288 MHz), random source values at random
// intervals. Each source value is {seq, f(seq)}, so a torn or invented value fails the check.
// Checks: the destination shows only source values, in source order (0 only after a reset); it
// copies a held value only when that value has been stable for 2 destination periods (what makes
// the copy safe in hardware, where zero-delay RTL cannot tear a word); the last value arrives,
// also after a destination reset in the middle of the run (a PLL lock loss).
module tb_bus_cdc;
localparam W = 32;
localparam real SRC_HALF = 6.734, DST_HALF = 40.690;
reg src_clk = 1'b0, dst_clk = 1'b0;
always #(SRC_HALF) src_clk = ~src_clk;
initial begin #3.3; forever #(DST_HALF) dst_clk = ~dst_clk; end
reg src_reset_n = 1'b0, dst_reset_n = 1'b0;
reg [W-1:0] src_data = {W{1'b0}};
wire [W-1:0] dst_data;
pocket_bus_cdc #(.W(W)) dut(.src_clk(src_clk), .src_reset_n(src_reset_n), .src_data(src_data),
    .dst_clk(dst_clk), .dst_reset_n(dst_reset_n), .dst_data(dst_data));
function [W-1:0] value(input [15:0] seq);
    reg [15:0] h;
    begin h = seq * 16'h9E37; value = {seq, h ^ 16'h5A5A ^ {h[7:0], h[15:8]}}; end
endfunction
integer updates = 0, last_seq = 0, seq = 0, k;
realtime held_t = 0.0;
always @(dut.held) held_t = $realtime;
reg [W-1:0] prev_dst = {W{1'b0}};
always @(posedge dst_clk) begin
    #0.1;
    if (dst_data !== prev_dst) begin
        if (dst_data === {W{1'b0}}) begin
            if (dst_reset_n) begin $display("ERROR: destination went to 0 without a reset"); $finish; end
        end else begin
            if (dst_data !== value(dst_data[31:16])) begin $display("ERROR: destination shows %h, not a source value", dst_data); $finish; end
            if (dst_data[31:16] <= last_seq) begin $display("ERROR: destination seq %0d after %0d", dst_data[31:16], last_seq); $finish; end
            if ($realtime - 0.1 - held_t < 4.0 * DST_HALF) begin
                $display("ERROR: copied a held value %0.1f ns after it changed", $realtime - 0.1 - held_t); $finish;
            end
            last_seq = dst_data[31:16]; updates = updates + 1;
        end
        prev_dst = dst_data;
    end
end
always @(negedge dst_reset_n) begin #0.1; prev_dst = dst_data; end
task run_values(input integer count);
    integer gap;
    begin
        for (k = 0; k < count; k = k + 1) begin
            gap = $urandom % 4 == 0 ? 1 : 1 + $urandom % 60;
            repeat (gap) @(negedge src_clk);
            seq = seq + 1; src_data = value(seq[15:0]);
        end
    end
endtask
task expect_last;
    integer guard;
    begin
        guard = 0;
        while (dst_data !== src_data && guard < 100) begin @(posedge dst_clk); guard = guard + 1; end
        if (dst_data !== src_data) begin $display("ERROR: the last value %h did not arrive (%h)", src_data, dst_data); $finish; end
    end
endtask
initial begin
    repeat (5) @(negedge src_clk); src_reset_n = 1'b1;
    repeat (2) @(negedge dst_clk); dst_reset_n = 1'b1;
    run_values(3000); expect_last;
    // a destination reset (lock loss) while values keep coming
    fork
        run_values(1000);
        begin repeat (200) @(negedge dst_clk); dst_reset_n = 1'b0; repeat (30) @(negedge dst_clk); dst_reset_n = 1'b1; end
    join
    expect_last;
    if (updates < 500) begin $display("ERROR: only %0d destination updates", updates); $finish; end
    $display("PASS bus cdc: %0d source values, %0d destination updates, only whole source values in order, last value arrives, destination reset", seq, updates);
    $finish;
end
endmodule
`default_nettype wire
