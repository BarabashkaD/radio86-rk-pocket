`timescale 1ns/1ps
`default_nettype none
// pocket_interact (spec 5.7): defaults without reset, read-back, the three Controls registers, the
// ignored out-of-range writes, one-clk actions, the full address decode.
module tb_pocket_interact;
reg clk = 1'b0;
always #5 clk = ~clk;
reg wr = 1'b0;
reg [31:0] a = 32'd0, d = 32'd0;
wire [31:0] rd;
wire sel, warm, cold, sound, green;
wire [1:0] preset, escape;
wire keys_on;
pocket_interact dut(.clk(clk), .bridge_wr(wr), .bridge_addr(a), .bridge_wr_data(d), .rd_data(rd), .selected(sel),
    .warm_reset(warm), .cold_boot(cold), .sound_on(sound), .green(green), .preset(preset), .keys_on(keys_on), .escape(escape));
integer i, warm_count = 0, cold_count = 0;
always @(negedge clk) begin if (warm) warm_count = warm_count + 1; if (cold) cold_count = cold_count + 1; end
task write(input [31:0] addr, input [31:0] value);
    begin @(negedge clk); a = addr; d = value; wr = 1'b1; @(negedge clk); wr = 1'b0; end
endtask
task expect_read(input [31:0] addr, input [31:0] want);
    begin
        @(negedge clk); a = addr; #1;
        if (!sel || rd !== want) begin $display("ERROR: read %h = %h, expected %h", addr, rd, want); $finish; end
    end
endtask
initial begin
    expect_read(32'h104, 1); expect_read(32'h108, 0); expect_read(32'h10C, 0); expect_read(32'h110, 0); expect_read(32'h114, 0);
    write(32'h104, 0); write(32'h108, 1);
    expect_read(32'h104, 0); expect_read(32'h108, 1);
    for (i = 0; i < 4; i = i + 1) begin write(32'h10C, i); expect_read(32'h10C, i); end
    for (i = 0; i < 2; i = i + 1) begin write(32'h110, i); expect_read(32'h110, i); end
    for (i = 0; i < 3; i = i + 1) begin write(32'h114, i); expect_read(32'h114, i); end
    if (preset !== 2'd3 || keys_on !== 1'b1 || escape !== 2'd2) begin $display("ERROR: outputs %0d %0d %0d", preset, keys_on, escape); $finish; end
    // out-of-range writes are ignored (the registers keep 3, 1, 2)
    write(32'h10C, 4); write(32'h10C, 7); write(32'h10C, 32'h8000_0003);
    write(32'h110, 2); write(32'h110, 3); write(32'h110, 32'h0000_0100);
    write(32'h114, 3); write(32'h114, 4); write(32'h114, 32'h0000_0102);
    expect_read(32'h10C, 3); expect_read(32'h110, 1); expect_read(32'h114, 2);
    if (preset !== 2'd3 || keys_on !== 1'b1 || escape !== 2'd2) begin $display("ERROR: outputs after bad writes %0d %0d %0d", preset, keys_on, escape); $finish; end
    // the old per-button registers are reserved: they read 0 and take no write
    for (i = 6; i <= 17; i = i + 1) begin write(32'h100 + 4*i, 5); expect_read(32'h100 + 4*i, 0); end
    expect_read(32'h10C, 3); expect_read(32'h110, 1); expect_read(32'h114, 2);
    // the other registers are unaffected by the Controls writes
    expect_read(32'h104, 0); expect_read(32'h108, 1);    write(32'h100, 1); repeat (2) @(negedge clk); write(32'h100, 2); repeat (2) @(negedge clk);
    if (warm_count !== 1 || cold_count !== 1) begin $display("ERROR: actions warm %0d cold %0d", warm_count, cold_count); $finish; end
    expect_read(32'h100, 0); expect_read(32'h118, 0); expect_read(32'h140, 0); expect_read(32'h144, 0);
    @(negedge clk); a = 32'h0000_0200; #1;
    if (sel) begin $display("ERROR: 0x200 selected"); $finish; end
    a = 32'h0001_0104; #1;
    if (sel) begin $display("ERROR: 0x10104 selected (address not fully decoded)"); $finish; end
    $display("PASS interact: defaults, read-back, Keys / Keys on / Escape, ignored out-of-range writes, reserved 0x118-0x144, actions, full decode");
    $finish;
end
endmodule
`default_nettype wire
