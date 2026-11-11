`timescale 1ns/1ps
`default_nettype none
// pocket_window: h_cnt 42..449 and v_cnt 0..299 (one native line per window line) of a 516 x 310
// raster (pocket_raster's lengths) with a dot every third clk; the address runs 0..122399, start at 0
// and finish at 122399 in each frame.
module tb_pocket_window;
localparam integer X0 = 42;            // the window's first h_cnt (pocket_window X0)
reg clk = 1'b0;
always #5 clk = ~clk;
reg [10:0] h = 11'd0, v = 11'd0;
reg s_ce = 1'b0;
reg [1:0] div = 2'd0;
wire s_fs = h == 11'd0 && v == 11'd0;
wire s_dot = h[0] ^ v[1] ^ h[3];
wire valid, data, start, finish;
wire [16:0] address;
pocket_window dut(.clk(clk), .s_ce(s_ce), .s_dot(s_dot), .s_frame_start(s_fs), .h_cnt(h), .v_cnt(v),
    .valid(valid), .data(data), .start(start), .finish(finish), .address(address));
always @(posedge clk) begin
    div <= div == 2'd2 ? 2'd0 : div + 2'd1;
    s_ce <= div == 2'd1;
    if (s_ce) begin
        if (h == 11'd515) begin h <= 11'd0; v <= v == 11'd309 ? 11'd0 : v + 11'd1; end
        else h <= h + 11'd1;
    end
end
integer frames = 0, count = 0, eh, ev;
always @(negedge clk)
    if (valid) begin
        eh = X0 + address % 408; ev = address / 408;
        if (address != count) begin $display("ERROR: address %0d, expected %0d", address, count); $finish; end
        if (data !== (eh[0] ^ ev[1] ^ eh[3])) begin $display("ERROR: dot at %0d", address); $finish; end
        if (start !== (address == 0) || finish !== (address == 122399)) begin $display("ERROR: markers at %0d", address); $finish; end
        count = count + 1;
        if (finish) begin frames = frames + 1; count = 0; end
    end
initial begin
    wait (frames == 2);
    $display("PASS window: 2 frames of 122400 dots, addresses, data, start and finish markers");
    $finish;
end
endmodule
`default_nettype wire
