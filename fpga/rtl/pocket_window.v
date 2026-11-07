// The 408 x 300 window of the native dot stream (spec 5.5): h_cnt 60..467 and the even lines
// v_cnt 0..598, as the Karabas framebuffer window and the POC capture. The stream's own
// frame_start (h 0) and frame_end (h 467, v 599) are never window dots, so the window makes
// its markers from an address counter: start at address 0, finish at 122399.
`default_nettype none
module pocket_window(
    input  wire        clk,
    input  wire        s_ce,           // rk86_video_stream ce: its outputs are valid on this clk
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
reg [16:0] next = 17'd0;
reg synced = 1'b0;                     // a frame start was seen: no partial first frame
wire in_window = h_cnt >= 11'd60 && h_cnt <= 11'd467 && v_cnt <= 11'd598 && !v_cnt[0];   // not "inside": a SystemVerilog keyword
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
