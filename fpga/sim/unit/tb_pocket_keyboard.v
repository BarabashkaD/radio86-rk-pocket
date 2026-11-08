`timescale 1ns/1ps
`default_nettype none
// pocket_remap + pocket_keyboard (K1): the panel-closed mapping (every Keys x Keys on x Escape
// combination on the 10 buttons, matrix rows, modifiers), L tap / hold, the delayed US, R, the
// L+R chord, the panel buttons, MIN_HOLD, navigation over the 67 keys with auto-repeat, the
// selection on reopen, the controller type. Small timings: 1 ms = 100 clk.
module tb_pocket_keyboard;
localparam integer MS = 100, TAP = 20, CHORD = 6, RUS_MIN = 6, HOLD = 8, DELAY = 16, REPEAT = 4;
localparam [15:0] UP = 16'h0001, DOWN = 16'h0002, LEFT = 16'h0004, RIGHT = 16'h0008, A = 16'h0010,
                  B = 16'h0020, X = 16'h0040, Y = 16'h0080, L = 16'h0100, R = 16'h0200,
                  SELECT = 16'h4000, START = 16'h8000;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset_n = 1'b0, enable = 1'b1, clear_latch = 1'b0;
reg [3:0] ptype = 4'h1;
reg [15:0] btn = 16'h0000;
wire [31:0] pad = {ptype, 12'h0, btn};
reg [7:0] rows = 8'hFF;
reg [1:0] preset = 2'd0;
reg keys_on = 1'b0;
reg [1:0] escape = 2'd0;
wire [69:0] map;
wire [7:0] columns;
wire [2:0] modifiers;
wire panel_open, shift_line, ctrl_line, rus_line, shift_latch, dock;
wire [6:0] selection;
wire [63:0] pulled;
pocket_remap remap(.preset(preset), .keys_on(keys_on), .escape(escape), .map(map));
pocket_keyboard #(.CLK_HZ(MS * 1000), .TAP_MS(TAP), .CHORD_MS(CHORD), .RUS_MIN_MS(RUS_MIN), .MIN_HOLD_MS(HOLD),
    .REPEAT_DELAY_MS(DELAY), .REPEAT_MS(REPEAT)) dut(
    .clk(clk), .reset_n(reset_n), .enable(enable), .clear_latch(clear_latch), .pad(pad), .rows(rows), .map(map),
    .russian_mode(1'b0), .columns(columns), .modifiers(modifiers), .panel_open(panel_open), .selection(selection),
    .pulled(pulled), .shift_line(shift_line), .ctrl_line(ctrl_line), .rus_line(rus_line), .shift_latch(shift_latch),
    .dock_keyboard(dock));
reg saw_rus = 1'b0, saw_ctrl = 1'b0;
always @(posedge clk) begin
    if (rus_line) saw_rus <= 1'b1;
    if (ctrl_line) saw_ctrl <= 1'b1;
end
task fail(input [8*80-1:0] what);
    begin
        $display("ERROR: %0s: pulled %h shift %b ctrl %b rus %b latch %b panel %b selection %0d", what, pulled,
                 shift_line, ctrl_line, rus_line, shift_latch, panel_open, selection);
        $finish;
    end
endtask
task chk(input ok, input [8*80-1:0] what);
    if (!ok) fail(what);
endtask
task clocks(input integer n);
    repeat (n) @(negedge clk);
endtask
task ms(input integer n);
    clocks(n * MS);
endtask
task down(input [15:0] b);
    begin @(negedge clk); btn = btn | b; clocks(3); end
endtask
task up(input [15:0] b);
    begin @(negedge clk); btn = btn & ~b; clocks(3); end
endtask
task idle(input [8*80-1:0] what);          // release everything, let every pull end
    begin
        up(16'hFFFF); ms(HOLD + RUS_MIN + 3);
        chk(pulled === 64'd0 && modifiers === {2'b11, !shift_latch} && columns === 8'hFF, what);
    end
endtask
task matrix(input [6:0] k, input [8*80-1:0] what);  // exactly key k, row by row
    integer r;
    begin
        if (pulled !== (64'd1 << k)) fail(what);
        for (r = 0; r < 8; r = r + 1) begin
            rows = ~(8'h01 << r); #1;
            if (r == k[5:3] ? columns !== ~(8'h01 << k[2:0]) : columns !== 8'hFF) fail(what);
        end
        rows = 8'hFF;
    end
endtask
task tap_l;
    begin down(L); ms(2); up(L); end
endtask
task chord_lr;                              // L then R, both released
    begin down(L); ms(2); down(R); ms(2); up(L | R); clocks(3); end
endtask
task step(input [15:0] b, input [6:0] want, input [8*80-1:0] what);
    begin down(b); up(b); chk(selection === want, what); end
endtask
// the panel-closed mapping: the table of spec 5.6, written out by hand
reg [6:0] dir [0:15];                       // [keys*4 + Up, Down, Left, Right]
reg [6:0] want [0:9];
task set_want(input integer k, input integer o, input integer e);
    integer i;
    begin
        for (i = 0; i < 4; i = i + 1) want[i] = dir[k*4 + i];
        want[4] = 63; want[5] = 10; want[6] = 11; want[7] = 57;                 // A B X Y: Space VK ZB Y
        if (o == 1) begin
            want[6] = dir[k*4 + 0]; want[5] = dir[k*4 + 1]; want[7] = dir[k*4 + 2]; want[4] = dir[k*4 + 3];
            want[3] = 63; want[1] = 10; want[0] = 11; want[2] = 57;
        end
        want[8] = e == 1 ? 2 : 10;                                              // Start
        want[9] = e == 0 ? 2 : 10;                                              // Select
    end
endtask
function [15:0] bit_of(input integer n);
    bit_of = n == 8 ? START : n == 9 ? SELECT : (16'h0001 << n);
endfunction
integer p, b, o, e;
task check_code(input [6:0] c);
    begin
        down(bit_of(b));
        if (c < 64) matrix(c, "matrix");
        else begin
            rows = 8'h00; #1;
            if (columns !== 8'hFF || pulled !== 64'd0) fail("a modifier gave a matrix key");
            if ((c == 64 && modifiers !== 3'b110) || (c == 65 && modifiers !== 3'b101) ||
                (c == 66 && modifiers !== 3'b011)) fail("modifier line");
            rows = 8'hFF;
        end
        up(bit_of(b)); ms(HOLD + 2);
        chk(pulled === 64'd0 && modifiers === 3'b111, "matrix: the pull did not end");
    end
endtask
initial begin
    preset = 2'd1; #1;                      // an event on the inputs of the combinational map at time 0
    dir[0] = 13; dir[1] = 15; dir[2] = 12; dir[3] = 14;
    dir[4] = 24; dir[5] = 22; dir[6] = 23; dir[7] = 25;
    dir[8] = 24; dir[9] = 18; dir[10] = 20; dir[11] = 22;
    dir[12] = 55; dir[13] = 51; dir[14] = 33; dir[15] = 36;
    clocks(3); reset_n = 1'b1; clocks(3);
    chk(pulled === 64'd0 && modifiers === 3'b111 && !panel_open && selection === 7'd28, "idle after reset");

    //--- panel closed: the mapping ---
    for (p = 0; p < 4; p = p + 1)
        for (o = 0; o < 2; o = o + 1)
            for (e = 0; e < 3; e = e + 1) begin
                preset = p; keys_on = o; escape = e;
                set_want(p, o, e);
                for (b = 0; b < 10; b = b + 1) check_code(want[b]);
            end
    preset = 2'd3; keys_on = 1'b0; escape = 2'd0;                               // WASD, Select = AR2, Start = VK
    down(SELECT); chk(pulled === 64'd1 << 2, "closed: Select is not its mapped key");
    down(LEFT); chk(pulled === (64'd1 << 2 | 64'd1 << 33) && selection === 7'd28, "closed: Select+Left is not mapped");
    down(START); chk(pulled === (64'd1 << 2 | 64'd1 << 33 | 64'd1 << 10), "closed: Start is not its mapped key");
    idle("closed: Select, Left, Start");
    preset = 2'd0;

    //--- L: tap, hold, clear ---
    down(L); chk(ctrl_line && modifiers === 3'b101, "L down: no US at once");
    ms(2); up(L); chk(shift_latch && shift_line && !ctrl_line && modifiers === 3'b110, "L tap: no Shift latch");
    tap_l; chk(!shift_latch && !shift_line, "second L tap: the latch stays");
    down(L); ms(TAP + 3); chk(ctrl_line && !shift_line, "L held: not US only");
    up(L); chk(!shift_latch && !ctrl_line, "L held past TAP toggled the latch");
    tap_l; chk(shift_latch, "L tap: no latch before clear_latch");
    @(negedge clk) clear_latch = 1'b1; @(negedge clk) clear_latch = 1'b0; clocks(2);
    chk(!shift_latch && !shift_line, "clear_latch did not clear the latch");

    //--- R alone ---
    saw_rus = 1'b0;
    down(R); ms(CHORD - 2); chk(!saw_rus, "R: RUS before the chord window");
    ms(4); chk(rus_line && modifiers === 3'b011, "R: no RUS after the chord window");
    ms(10); chk(rus_line, "R held: RUS ended");
    up(R); ms(RUS_MIN - 1); chk(rus_line, "R: RUS shorter than RUS_MIN after the release");
    ms(3); chk(!rus_line, "R: RUS longer than RUS_MIN after the release");
    saw_rus = 1'b0;
    down(R); ms(1); up(R); ms(CHORD - 3); chk(!saw_rus, "R tap: RUS before the chord window");
    ms(3); chk(rus_line, "R tap: no RUS at the window end");
    ms(RUS_MIN + 3); chk(!rus_line, "R tap: RUS did not end");
    idle("after R");

    //--- the chord opens the panel: L then R ---
    saw_rus = 1'b0; saw_ctrl = 1'b0;
    down(L); ms(2); down(R); chk(panel_open, "chord L,R: the panel did not open");
    chk(!ctrl_line, "chord L,R: US after the chord");
    chk(selection === 7'd28, "first open: the selection is not on G");
    ms(CHORD + RUS_MIN + 4); chk(!saw_rus, "chord: RUS");
    up(L | R); chk(!shift_latch, "chord L,R: toggled the latch");
    chk(!rus_line && !ctrl_line, "chord L,R: a modifier after the release");

    //--- panel open: B, MIN_HOLD, A Y X Start, Select + D-pad ---
    down(B); matrix(39, "B on G: not line 39 in row 4");
    chk(selection === 7'd28, "B moved the selection");
    idle("B on G");
    @(negedge clk) btn = B; @(negedge clk) btn = 16'h0000;                     // a 1-clock B tap
    ms(HOLD - 1); chk(pulled === 64'd1 << 39, "MIN_HOLD: a 1-clock B tap ended early");
    ms(3); chk(pulled === 64'd0, "MIN_HOLD: the B tap did not end");
    down(A); chk(pulled === 64'd1 << 63, "panel A: not Space"); idle("A");
    down(Y); chk(pulled === 64'd1 << 11, "panel Y: not ZB"); idle("Y");
    down(X); chk(pulled === 64'd1 << 10, "panel X: not VK"); idle("X");
    down(START); chk(pulled === 64'd1 << 2, "panel Start: not AR2"); idle("Start");
    down(SELECT); chk(pulled === 64'd0, "panel Select alone pulled a line");
    down(UP); chk(pulled === 64'd1 << 13 && selection === 7'd28, "Select+Up: not the up arrow");
    up(UP); down(DOWN); chk(pulled[15] && selection === 7'd28, "Select+Down: not the down arrow");
    up(DOWN); down(LEFT); chk(pulled[12] && selection === 7'd28, "Select+Left: not the left arrow");
    up(LEFT); down(RIGHT); chk(pulled[14] && selection === 7'd28, "Select+Right: not the right arrow");
    idle("Select + D-pad");
    down(B | A | X); chk(pulled === (64'd1 << 39 | 64'd1 << 63 | 64'd1 << 10), "B+A+X: the lines do not add up");
    idle("B+A+X");

    //--- L with keys (panel open, G selected) ---
    down(L); chk(ctrl_line, "L held: no US at once");
    down(B); chk(ctrl_line && pulled === 64'd1 << 39, "L held + B: not US + key");
    up(B); ms(HOLD + 2); up(L); chk(!shift_latch && !ctrl_line, "L held + B toggled the latch");
    down(B); ms(1); down(L); ms(3); chk(!ctrl_line, "delayed Ctrl: US at once with a key held");
    up(B); ms(HOLD); chk(ctrl_line && pulled === 64'd0, "delayed Ctrl: no US after the key release");
    ms(TAP); up(L); chk(!shift_latch && !ctrl_line, "delayed Ctrl: L held past TAP toggled");
    down(B); ms(1); down(L); ms(TAP - 3); chk(!ctrl_line, "delayed Ctrl: US before TAP with the key held");
    ms(5); chk(ctrl_line && pulled === 64'd1 << 39, "delayed Ctrl: no US at TAP with the key held");
    idle("delayed Ctrl at TAP"); chk(!shift_latch, "delayed Ctrl: L held past TAP toggled");
    saw_ctrl = 1'b0;
    down(B); ms(1); down(L); ms(3); up(L); chk(!saw_ctrl, "delayed Ctrl: an L tap with a key held sent US");
    chk(shift_latch, "an L tap with a key held: no latch");
    idle("L tap with a key held"); tap_l; chk(!shift_latch, "the latch did not clear");

    //--- navigation (xq: the remembered column) ---
    step(DOWN, 41, "G down: not O");
    step(DOWN, 54, "down: not row 4 under G");
    step(DOWN, 63, "down: not Space");
    step(DOWN, 5, "down from Space: not F5 (wrap to row 0)");
    step(UP, 63, "up from row 0: not Space (wrap to row 5)");
    step(UP, 54, "up from Space: not the key under G");
    step(UP, 41, "up: not O");
    step(UP, 28, "up: not G");
    step(DOWN, 41, "down: not O"); step(DOWN, 54, "down: not row 4"); step(DOWN, 63, "down: not Space");
    step(RIGHT, 64, "Space right: not the left arrow");
    step(UP, 58, "up from the left arrow: not the key under it");
    step(DOWN, 64, "down: not back on the left arrow");
    step(LEFT, 63, "left: not Space");
    step(LEFT, 62, "left: not SS");
    down(B); chk(shift_line && pulled === 64'd0 && modifiers === 3'b110, "B on SS: not the Shift line");
    idle("B on SS"); chk(!shift_latch, "B on SS toggled the latch");
    step(UP, 48, "SS up: not Q");
    step(DOWN, 62, "Q down: not SS");
    step(LEFT, 61, "left: not US");
    down(B); chk(ctrl_line && pulled === 64'd0 && modifiers === 3'b101, "B on US: not the Ctrl line"); idle("B on US");
    step(LEFT, 66, "left from US: no wrap to the right arrow");
    step(RIGHT, 61, "right from the right arrow: no wrap to US");
    step(UP, 47, "US up: not RUS/LAT");
    down(B); chk(rus_line && pulled === 64'd0 && modifiers === 3'b011, "B on RUS/LAT: not the RUS line"); idle("B on RUS");
    step(UP, 35, "up: not F"); step(UP, 22, "up: not J"); step(UP, 8, "up: not row 1 key 8");
    step(UP, 0, "up: not AR2");
    step(LEFT, 7, "left from AR2: no wrap to STR");
    step(RIGHT, 0, "right from STR: no wrap to AR2");
    step(DOWN, 8, "down: not row 1 key 8");
    down(RIGHT); ms(DELAY + 3 * REPEAT + 2 - 1); up(RIGHT);                    // held 30 ms: 1 + 4 moves
    chk(selection === 7'd13, "auto-repeat: not 5 moves in 30 ms");
    ms(DELAY); chk(selection === 7'd13, "auto-repeat after the release");
    down(RIGHT); ms(DELAY - 2); up(RIGHT); chk(selection === 7'd14, "auto-repeat before the delay");

    //--- the chord closes the panel: R then L; then nothing until both are released ---
    saw_rus = 1'b0; saw_ctrl = 1'b0;
    down(R); ms(2); down(L); chk(!panel_open, "chord R,L: the panel did not close");
    up(R); ms(TAP + 3); chk(!saw_ctrl, "after a chord L gave US");
    down(R); ms(CHORD + 3); chk(!saw_rus, "chord: RUS (after a chord R gave RUS)");
    chk(!panel_open, "after a chord R and L toggled the panel");
    up(L | R); chk(!shift_latch, "after a chord the release toggled the latch");
    ms(RUS_MIN + 3); chk(!saw_rus && !saw_ctrl, "chord R,L: a modifier");
    tap_l; chk(shift_latch, "an L tap after a chord: no latch"); tap_l;
    chord_lr; chk(panel_open && selection === 7'd47, "reopen: the selection is not on the last key pressed");
    down(UP); chk(pulled === 64'd0, "panel D-pad: pulled a line"); idle("panel D-pad");
    chk(selection === 7'd35, "panel D-pad up: not F");

    //--- controller type, enable, reset: no pulls, panel closed, latch cleared ---
    tap_l; down(A); chk(shift_latch && panel_open && pulled[63], "before the type change");
    ptype = 4'h4; clocks(3);
    chk(dock && pulled === 64'd0 && modifiers === 3'b111 && !panel_open && !shift_latch, "Dock type not ignored");
    ptype = 4'h1; ms(HOLD + 2); chk(pulled === 64'd0, "a button held over the type change pulled");
    up(A); down(A); chk(pulled === 64'd1 << 63, "A after re-arming: no Space");
    enable = 1'b0; clocks(2); chk(pulled === 64'd0 && modifiers === 3'b111, "enable low: a pull");
    enable = 1'b1; up(A); down(B); chk(pulled === 64'd1 << 10 && selection === 7'd28, "after enable: not the closed B map");
    idle("after enable");
    $display("PASS keyboard K1: mapping (24 combinations x 10 buttons), L tap/hold/delayed US, R, chord, panel buttons, MIN_HOLD, navigation, auto-repeat, reopen, controller type");
    $finish;
end
endmodule
`default_nettype wire
