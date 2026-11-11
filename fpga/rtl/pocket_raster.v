// The native raster of the 16 MHz machine on the Pocket (spec 4.5, 7, D13: an adaptation of the
// board's digital video): counts dots from the falling edge of HRTC and lines from the falling edge of
// VRTC, as a monitor locks to the sync, and gives pocket_window what rk86_video_stream gave: dot strobe,
// dot, position, frame start. HRTC / VRTC are the 8275's pins, active high, not re-timed to the dots.
// A frame starts only for a plausible raster (spec 7): the frame that ended at this VRTC fall had
// FRAME_MIN..FRAME_MAX lines and every line of it LINE_MIN..LINE_MAX dots; otherwise (the 8275's
// power-up parameters, the first frame after a lock) v_cnt stays at 2047 for that frame: no window
// position, no frame start. Until the first lock, and when the syncs stop (display off, Preset
// Counters), h_cnt and v_cnt saturate at 2047. dot = pix: the 8275's VSP darkens every retrace
// position, so the dots are not gated here.
`default_nettype none
module pocket_raster(
    input  wire        clk,
    input  wire        pix_ce,
    input  wire        pix,
    input  wire        hrtc,
    input  wire        vrtc,
    output wire        ce,
    output wire        dot,
    output wire [10:0] h_cnt,
    output wire [10:0] v_cnt,
    output wire        frame_start
);
localparam [10:0] MAX = 11'h7FF;
localparam [10:0] LINE_MIN = 11'd256, LINE_MAX = 11'd1023;     // dots per line of a plausible frame
localparam [10:0] FRAME_MIN = 11'd200, FRAME_MAX = 11'd1023;   // lines of a plausible frame
reg hrtc_q = 1'b0, vrtc_q = 1'b0, vpend = 1'b0;
reg [10:0] h_r = MAX, v_r = MAX;
reg [10:0] lines = 11'd0;      // lines of the frame in progress (its line starts), saturating
reg good = 1'b0;               // every line of the frame in progress so far had LINE_MIN..LINE_MAX dots
wire hfall = hrtc_q && !hrtc;
wire vfall = vrtc_q && !vrtc;
wire vstart = hfall && (vfall || vpend);                               // the first line after VRTC falls
wire line_ok = h_r >= LINE_MIN - 11'd1 && h_r <= LINE_MAX - 11'd1;    // the line ending here: h_r + 1 dots
wire plausible = vstart && good && line_ok && lines >= FRAME_MIN && lines <= FRAME_MAX;
assign h_cnt = hfall ? 11'd0 : h_r == MAX ? MAX : h_r + 11'd1;
assign v_cnt = vstart ? (plausible ? 11'd0 : MAX)
             : h_cnt == MAX ? MAX                                     // the syncs stopped: no position
             : !hfall || v_r == MAX ? v_r : v_r + 11'd1;
always @(posedge clk)
    if (pix_ce) begin
        hrtc_q <= hrtc;
        vrtc_q <= vrtc;
        h_r <= h_cnt;
        v_r <= v_cnt;
        vpend <= hfall ? 1'b0 : vpend | vfall;
        if (vstart) begin
            lines <= 11'd1; good <= 1'b1;
        end else if (hfall) begin
            lines <= lines == MAX ? MAX : lines + 11'd1;
            good <= good && line_ok;
        end
    end
assign ce = pix_ce;
assign dot = pix;
assign frame_start = pix_ce && plausible;
endmodule
`default_nettype wire
