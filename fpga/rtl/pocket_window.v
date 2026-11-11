// The display window: the 408 x 300 part of the native raster that the Pocket shows (spec 4.5, D7, D13:
// an adaptation of the board's digital video): h_cnt X0..X0 + 407 and v_cnt 0..299 of pocket_raster, one
// native line per window line, every dot inside the window the machine's dot 1:1. Character k of a row has its six dots at
// h_cnt 6k + 6 .. 6k + 11 (pocket_raster: h_cnt 0 on the first dot after HRTC falls), so X0 = 42
// shows the text columns 6..73, as the POC frames (golden/): the monitor's home column 8 at window
// x 12. The raster's frame_start (h 0, v 0) is never a window dot, so the window makes its markers
// from an address counter: start at address 0, finish at 122399.
`default_nettype none
module pocket_window(
    input  wire        clk,
    input  wire        s_ce,           // pocket_raster ce: its outputs are valid on this clk
    input  wire        s_dot,
    input  wire        s_frame_start,
    input  wire [10:0] h_cnt,
    input  wire [10:0] v_cnt,
    output reg         valid = 1'b0,
    output reg         data = 1'b0,
    output reg         start = 1'b0,
    output reg         finish = 1'b0,
    output reg  [16:0] address = 17'd0
);
localparam [16:0] LAST = 17'd122399;
localparam [10:0] X0 = 11'd42;         // the first h_cnt of the window (fpga/sim/run_sim.py WINDOW_X0)
reg [16:0] next = 17'd0;
reg synced = 1'b0;                     // a frame start was seen: no partial first frame
wire in_window = h_cnt >= X0 && h_cnt <= X0 + 11'd407 && v_cnt <= 11'd299;   // not "inside": a SystemVerilog keyword
always @(posedge clk) begin
    valid <= 1'b0; start <= 1'b0; finish <= 1'b0;
    if (s_ce) begin
        if (s_frame_start) begin
            next <= 17'd0;
            synced <= 1'b1;
        end else if (synced && in_window && next <= LAST) begin
            valid <= 1'b1;
            data <= s_dot;
            address <= next;
            start <= next == 17'd0;
            finish <= next == LAST;
            next <= next + 17'd1;
        end
    end
end
endmodule
`default_nettype wire
