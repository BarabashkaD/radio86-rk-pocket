`timescale 1ns/1ps
`default_nettype none
// pocket_raster: a sync generator (line L dots, HRTC the last H dots of the line, frame F lines, VRTC V
// lines that fall at the HRTC rise of the last line, so HRTC falls H dots later) on a dot enable every 2
// clk and a random pix. The generator also is the oracle: the dot (hc, li) it is at, whether the frame
// that ended at its last frame boundary was plausible (200..1023 lines, every line 256..1023 dots, and
// a boundary before it to measure from), and whether the syncs are stopped or not yet locked.
// Everything the checker reads is registered with <= at a clk edge and read at the same edge, so it is
// the value of the dot the DUT sees. Parameters change at a frame boundary (pend), like a CRT
// reprogrammed between frames; a frame is judged by the frame before it, so the first frame of a new
// raster has a position when the frame before it was plausible.
module tb_pocket_raster;
reg clk = 1'b0;
always #5 clk = ~clk;
reg pix_ce = 1'b0, pix = 1'b0, hrtc = 1'b0, vrtc = 1'b0;
wire ce, dot, frame_start;
wire [10:0] h_cnt, v_cnt;
pocket_raster dut(.clk(clk), .pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc), .ce(ce), .dot(dot),
    .h_cnt(h_cnt), .v_cnt(v_cnt), .frame_start(frame_start));

// the raster in use, the next one (loaded at a frame boundary), want: 1 the frame of this raster is
// plausible, 0 not, 2 not stated
integer Lc = 18, Hc = 12, Fc = 2, Vc = 1, OddL = 0, OddLine = 0, want = 0;
integer nL = 18, nH = 12, nF = 2, nV = 1, nOddL = 0, nOddLine = 0, nwant = 0;
reg pend = 1'b0, stop = 1'b0, resume_go = 1'b0, resumed = 1'b0;
integer hc = 0, li = 0, nlines = 0, wraps = 0;
reg locked = 1'b0, measured = 1'b0, fr_good = 1'b1, f_ok = 1'b0, origin = 1'b0;
wire signed [31:0] leff = (li == OddLine && OddL != 0) ? OddL : Lc;
reg ok_line, plaus_n;
always @(posedge clk) begin
    pix <= $random;
    pix_ce <= ~pix_ce;
    if (pix_ce) begin
        origin <= 1'b0;
        if (stop) begin
            hrtc <= 1'b0; vrtc <= 1'b0;
            hc <= hc >= 2046 ? 2047 : hc + 1;
            if (resume_go) begin
                stop <= 1'b0; resume_go <= 1'b0; resumed <= 1'b1;
                hc <= 0; li <= Fc - 1 - Vc; locked <= 1'b0; measured <= 1'b0; fr_good <= 1'b1;
                nlines <= 0; f_ok <= 1'b0;
            end
        end else if (hc == leff - 1) begin
            hc <= 0; hrtc <= 1'b0; locked <= 1'b1;
            ok_line = leff >= 256 && leff <= 1023;
            if (li == Fc - 1) begin
                plaus_n = measured && fr_good && ok_line && nlines + 1 >= 200 && nlines + 1 <= 1023;
                if (measured && want != 2 && plaus_n != (want == 1)) begin
                    $display("ERROR: raster: TB model, plausible %0d, stated %0d", plaus_n, want);
                    $finish;
                end
                origin <= plaus_n; f_ok <= plaus_n; measured <= 1'b1; fr_good <= 1'b1;
                nlines <= 0; li <= 0; wraps <= wraps + 1;
                if (pend) begin
                    Lc <= nL; Hc <= nH; Fc <= nF; Vc <= nV; OddL <= nOddL; OddLine <= nOddLine; want <= nwant;
                    pend <= 1'b0;
                end
            end else begin
                li <= li + 1; fr_good <= fr_good && ok_line; nlines <= nlines + 1;
            end
        end else begin
            hc <= hc + 1;
            if (hc + 1 == leff - Hc) begin
                hrtc <= 1'b1;
                if (li == Fc - 1 - Vc) vrtc <= 1'b1;
                if (li == Fc - 1) vrtc <= 1'b0;
            end
        end
    end
end

// the checker: at every ce, read before the edge
integer n_ce = 0, n_one = 0, n_one_h = 0, n_start = 0, n_locked_h = 0, n_hrtc_h = 0, n_imp = 0, n_pos = 0,
        n_held = 0, n_stopline = 0, n_resume = 0, n_pos_line0 = 0;
reg [10:0] eh, ev;
task err(input [8*48-1:0] what);
begin
    $display("ERROR: raster: %0s (h %0d v %0d, expected h %0d v %0d, start %b, origin %b)",
        what, h_cnt, v_cnt, eh, ev, frame_start, origin);
    $finish;
end
endtask
always @(posedge clk) begin
    if (ce !== pix_ce) err("ce");
    if (pix_ce) begin
        eh = locked ? hc : 2047;
        ev = (!f_ok || hc == 2047 || li > 2047) ? 2047 : li;       // v_cnt saturates at 2047
        n_ce = n_ce + 1;
        if (dot !== pix) err("dot");
        if (pix) n_one = n_one + 1;
        if (pix && hrtc) n_one_h = n_one_h + 1;
        if (frame_start !== origin) begin
            if (frame_start) err("frame start on an implausible raster");
            else err("missing frame start");
        end
        if (origin) n_start = n_start + 1;
        if (h_cnt !== eh) err("h_cnt");
        if (locked) n_locked_h = n_locked_h + 1;
        if (locked && hrtc) n_hrtc_h = n_hrtc_h + 1;
        if (v_cnt !== ev) begin
            if (stop && hc == 2047) err("v_cnt held after the syncs stopped");
            else if (!f_ok) err("position on an implausible raster");
            else err("v_cnt");
        end
        if (stop && hc == 2047) n_held = n_held + 1;
        else if (stop && f_ok) n_stopline = n_stopline + 1;
        else if (!f_ok) n_imp = n_imp + 1;
        else n_pos = n_pos + 1;
        if (resumed && !f_ok) n_resume = n_resume + 1;
        if (f_ok && !stop && li == 0) n_pos_line0 = n_pos_line0 + 1;
    end
end

// the stimulus, at negedge clk
task wait_wraps(input integer n);
integer t;
begin
    t = wraps + n;
    while (wraps < t) @(negedge clk);
    repeat (4) @(negedge clk);
end
endtask
task cfg(input integer l, input integer h, input integer f, input integer v, input integer ol,
         input integer oln, input integer w);
begin
    nL = l; nH = h; nF = f; nV = v; nOddL = ol; nOddLine = oln; nwant = w; pend = 1'b1;
    while (pend) @(negedge clk);
    repeat (4) @(negedge clk);
end
endtask
task starts(input integer since, input integer exp_n, input [8*24-1:0] name);
begin
    if (n_start - since !== exp_n) begin
        $display("ERROR: raster: %0s: %0d frame starts, expected %0d", name, n_start - since, exp_n);
        $finish;
    end
end
endtask
integer s0;
initial begin
    #1000000000;
    $display("ERROR: raster: timeout");
    $finish;
end
initial begin
    @(negedge clk);
    // phase 0: the 8275's power-up raster
    wait_wraps(1500);
    starts(0, 0, "phase 0");
    // phase 1: a plausible raster; no start at the first fall (the frame before was phase 0's)
    s0 = n_start;
    cfg(516, 48, 310, 10, 0, 0, 1);
    starts(s0, 0, "phase 1 first fall");
    wait_wraps(4);
    starts(s0, 4, "phase 1");
    // phase 2: reprogrammed at a frame boundary; the frame that ended there was plausible
    s0 = n_start;
    cfg(400, 40, 200, 8, 0, 0, 1);
    wait_wraps(3);
    starts(s0, 4, "phase 2");
    // phase 2b: implausible lengths; the first fall still judges the plausible frame before it
    s0 = n_start;
    cfg(240, 48, 310, 10, 0, 0, 0);
    wait_wraps(2);
    starts(s0, 1, "phase 2b short lines");
    s0 = n_start;
    cfg(516, 48, 180, 10, 0, 0, 0);
    wait_wraps(2);
    starts(s0, 0, "phase 2b short frames");
    // phase 3: the syncs stop low at the first line of a positioned frame (v_cnt holds the line until
    // h_cnt saturates), for 2 frames
    cfg(516, 48, 310, 10, 0, 0, 1);
    wait_wraps(2);
    s0 = n_start;
    @(negedge clk);
    while (!(hc == 100 && li == 0)) @(negedge clk);
    stop = 1'b1;
    repeat (2 * 310 * 516) @(posedge pix_ce);
    starts(s0, 0, "phase 3");
    // phase 4: the syncs resume (516 x 310); the first VRTC fall only starts the measurement
    Lc = 516; Hc = 48; Fc = 310; Vc = 10; OddL = 0; OddLine = 0; want = 1;
    @(negedge clk);
    resume_go = 1'b1;
    while (stop) @(negedge clk);
    s0 = n_start;
    wait_wraps(1);
    starts(s0, 0, "phase 4 first fall");
    wait_wraps(1);
    starts(s0, 1, "phase 4 second fall");
    wait_wraps(2);
    starts(s0, 3, "phase 4");
    // phase 5: the limits, one frame of each (the frame is judged at the next fall)
    s0 = n_start;
    cfg(256, 48, 200, 10, 0, 0, 1);       // LINE_MIN, FRAME_MIN
    cfg(255, 48, 200, 10, 0, 0, 0);       // LINE_MIN - 1
    cfg(1023, 48, 200, 10, 0, 0, 1);      // LINE_MAX
    cfg(1024, 48, 200, 10, 0, 0, 0);      // LINE_MAX + 1
    cfg(256, 48, 1023, 10, 0, 0, 1);      // FRAME_MAX
    cfg(256, 48, 1024, 10, 0, 0, 0);      // FRAME_MAX + 1
    cfg(516, 48, 199, 10, 0, 0, 0);       // FRAME_MIN - 1
    cfg(516, 48, 200, 10, 0, 0, 1);       // FRAME_MIN
    cfg(516, 48, 310, 10, 255, 0, 0);     // one short line: the first, a middle, the last
    cfg(516, 48, 310, 10, 255, 100, 0);
    cfg(516, 48, 310, 10, 255, 309, 0);
    cfg(516, 48, 310, 10, 1024, 0, 0);    // one long line
    cfg(516, 48, 310, 10, 1024, 309, 0);
    cfg(516, 48, 310, 10, 256, 309, 1);   // one line at the limits
    cfg(516, 48, 310, 10, 1023, 100, 1);
    cfg(256, 48, 2248, 10, 0, 0, 0);      // more lines than the counter holds (2248 = 2048 + 200)
    cfg(516, 48, 310, 10, 0, 0, 1);
    wait_wraps(1);
    // the first change ends the phase 4 frame (1); then the frames of 256x200, 1023x200, 256x1023, 516x200,
    // 516x310 with a 256 dot line, with a 1023 dot line, and the last 516x310 (7)
    starts(s0, 8, "phase 5");
    if (n_one == 0 || n_one_h == 0 || n_hrtc_h == 0 || n_locked_h == 0 || n_imp == 0 || n_pos == 0 ||
        n_held == 0 || n_stopline == 0 || n_resume == 0 || n_pos_line0 == 0) begin
        $display("ERROR: raster: a check saw no samples (ones %0d, ones in HRTC %0d, HRTC %0d, locked %0d, implausible %0d, position %0d, held %0d, stopped line %0d, resume %0d, line 0 %0d)",
            n_one, n_one_h, n_hrtc_h, n_locked_h, n_imp, n_pos, n_held, n_stopline, n_resume, n_pos_line0);
        $finish;
    end
    $display("PASS: raster: %0d dots, %0d frame starts, %0d implausible, %0d positioned, %0d stopped", n_ce, n_start,
        n_imp, n_pos, n_held + n_stopline);
    $finish;
end
endmodule
`default_nettype wire
