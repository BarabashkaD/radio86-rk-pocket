`default_nettype none
// The Pocket buttons as the Radio-86RK keyboard lines (K1). Every active
// source pulls its line low and the sources add up, as on the real keyboard; the monitor decodes.
// The 64 matrix lines (key k = row*8+col) give the columns for the rows of PPI port A; the lines
// 64 SS (Shift), 65 US (Ctrl), 66 RUS/LAT give modifiers = {rus, ctrl, shift}, active low.
// - Ten slots, one per mapped button (map order: Up, Down, Left, Right, A, B, X, Y, Start, Select):
//   a press latches the slot's line, which it pulls while the button is held and at least
//   MIN_HOLD_MS from the press. Panel closed: the line of map (pocket_remap). Panel open: A Space,
//   B the selected key's line (k1_line), X VK, Y ZB, Start AR2, Select + D-pad the arrows; the
//   D-pad alone moves the selection (auto-repeat), Select alone pulls nothing.
// - L: a tap (released within TAP_MS, no other button pressed meanwhile) toggles the Shift latch;
//   held, it pulls US at once, or, when a matrix key is already pulled at the L press, after
//   TAP_MS or when no matrix key is pulled any more.
// - R: RUS from CHORD_MS after the press (if no chord), while held, and RUS_MIN_MS after the
//   release (a tap shorter than the window still gives RUS_MIN_MS from the window end).
// - L+R: the second pressed while the first is held and within CHORD_MS of its press toggles the
//   panel; L and R then do nothing until both are released.
// Timings count a shared 1 ms tick: a window of T ms is T ticks (it ends T-1..T ms after its
// start), a minimum of T ms is T+1 ticks (at least T ms). Timing parameters: 0..1022 ms.
module pocket_keyboard #(
    parameter integer CLK_HZ = 74250000,
    parameter integer TAP_MS = 250,
    parameter integer CHORD_MS = 60,
    parameter integer RUS_MIN_MS = 60,
    parameter integer MIN_HOLD_MS = 80,
    parameter integer REPEAT_DELAY_MS = 400,
    parameter integer REPEAT_MS = 100
)(
    input  wire        clk,
    input  wire        reset_n,         // APF reset
    input  wire        enable,
    input  wire        clear_latch,     // one clk: interact Reset or Cold boot
    input  wire [31:0] pad,             // cont1_key
    input  wire  [7:0] rows,            // PPI port A, active low
    input  wire [69:0] map,             // pocket_remap: the panel-closed lines of the 10 buttons
    input  wire        russian_mode,    // not used here (the panel labels use it)
    output reg   [7:0] columns,         // active low
    output wire  [2:0] modifiers,       // {rus, ctrl, shift}, active low
    output reg         panel_open,
    output reg   [6:0] selection,       // K1 key id
    output wire [63:0] pulled,          // the matrix lines pulled now, independent of rows
    output wire        shift_line,      // 1 = SS pulled
    output wire        ctrl_line,       // 1 = US pulled
    output wire        rus_line,        // 1 = RUS/LAT pulled
    output reg         shift_latch,
    output wire        dock_keyboard    // controller type 0x4: recognized, not used yet (spec 10)
);
`include "pocket_k1_layout.vh"
localparam integer MS_CLKS = CLK_HZ / 1000;
localparam [9:0] TAP_T = TAP_MS, CHORD_T = CHORD_MS, RUS_MIN_T = RUS_MIN_MS + 1,
                 HOLD_T = MIN_HOLD_MS + 1, DELAY_T = REPEAT_DELAY_MS, REPEAT_T = REPEAT_MS;
localparam [6:0] NONE = 7'd127, KEY_G = 7'd28;

//--------- the 1 ms tick --------------
reg [19:0] prescale = 20'd0;
wire tick = prescale == MS_CLKS - 1;
always @(posedge clk) prescale <= tick ? 20'd0 : prescale + 20'd1;

//--------- buttons --------------
wire supported = pad[31:28] >= 4'd1 && pad[31:28] <= 4'd3;
assign dock_keyboard = pad[31:28] == 4'h4;
wire permitted = reset_n && enable && supported;
wire [15:0] buttons = pad[15:0];
reg [15:0] previous = 16'd0;
reg armed = 1'b0;                       // after a reset, presses count once every button was released
wire [15:0] press = armed ? buttons & ~previous : 16'd0;
wire [9:0] slot_held = {buttons[14], buttons[15], buttons[7:0]};
wire [9:0] slot_press = {press[14], press[15], press[7:0]};
wire select_held = buttons[14];

//--------- the slots: the line a press latches --------------
reg [69:0] new_lines;
integer i, j;
always @* begin
    if (!panel_open) new_lines = map;
    else new_lines = {NONE, 7'd2, 7'd11, 7'd10, k1_line(selection), 7'd63,          // Select Start Y X B A
                      select_held ? {7'd14, 7'd12, 7'd15, 7'd13} : {4{NONE}}};       // Right Left Down Up
end
reg [9:0] slot_on;                     // no initial value: the first reset clk is an event for the always @* below
reg [69:0] slot_lines = {10{NONE}};
reg [99:0] slot_ms = 100'd0;            // ticks since the press, up to HOLD_T
always @(posedge clk)
    for (i = 0; i < 10; i = i + 1)
        if (!permitted) slot_on[i] <= 1'b0;
        else if (slot_press[i]) begin
            slot_lines[7*i +: 7] <= new_lines[7*i +: 7];
            slot_on[i] <= new_lines[7*i +: 7] < 7'd67;
            slot_ms[10*i +: 10] <= 10'd0;
        end else if (slot_on[i]) begin
            if (tick && slot_ms[10*i +: 10] != HOLD_T) slot_ms[10*i +: 10] <= slot_ms[10*i +: 10] + 10'd1;
            if (!slot_held[i] && slot_ms[10*i +: 10] >= HOLD_T) slot_on[i] <= 1'b0;
        end
reg [63:0] slot_matrix;
reg slot_shift, slot_ctrl, slot_rus;
reg [6:0] code;
always @* begin
    slot_matrix = 64'd0; slot_shift = 1'b0; slot_ctrl = 1'b0; slot_rus = 1'b0; code = NONE;
    for (j = 0; j < 10; j = j + 1) if (slot_on[j]) begin
        code = slot_lines[7*j +: 7];
        if (code < 7'd64) slot_matrix[code[5:0]] = 1'b1;
        else if (code == 7'd64) slot_shift = 1'b1;
        else if (code == 7'd65) slot_ctrl = 1'b1;
        else if (code == 7'd66) slot_rus = 1'b1;
    end
end
wire key_held = |slot_matrix;

//--------- L, R, the chord, the panel, navigation --------------
reg l_on = 1'b0, l_tap = 1'b0, ctrl_wait = 1'b0;    // L held (not in a chord), still a tap, US delayed
reg r_on = 1'b0, r_pend = 1'b0, rus_on = 1'b0;      // R held (not in a chord), RUS window running, RUS pulled
reg lock = 1'b0;                                    // after a chord until L and R are both released
reg [9:0] l_ms = 10'd0, r_ms = 10'd0, rus_ms = 10'd0;
reg [6:0] last_key = KEY_G;
reg [5:0] col_xq = 6'd0;                            // the remembered column, quarter units
reg nav_on = 1'b0, nav_repeat = 1'b0;
reg [1:0] nav_dir = 2'd0;                           // 0 Up, 1 Down, 2 Left, 3 Right
reg [9:0] nav_ms = 10'd0;
wire l_fresh = l_on && buttons[8] && l_ms < CHORD_T;
wire r_fresh = r_on && buttons[9] && r_ms < CHORD_T;
wire chord = !lock && ((press[8] && (press[9] || r_fresh)) || (press[9] && l_fresh));
wire [2:0] sel_row = k1_row(selection);
wire [6:0] go_left = selection == k1_row_first(sel_row) ? k1_row_last(sel_row) : selection - 7'd1;
wire [6:0] go_right = selection == k1_row_last(sel_row) ? k1_row_first(sel_row) : selection + 7'd1;
wire [6:0] go_up = k1_key_at(sel_row == 3'd0 ? 3'd5 : sel_row - 3'd1, col_xq);
wire [6:0] go_down = k1_key_at(sel_row == 3'd5 ? 3'd0 : sel_row + 3'd1, col_xq);
wire [3:0] dpad_press = press[3:0];
wire [1:0] press_dir = dpad_press[0] ? 2'd0 : dpad_press[1] ? 2'd1 : dpad_press[2] ? 2'd2 : 2'd3;
task move(input [1:0] dir);
    case (dir)
        2'd0: selection <= go_up;
        2'd1: selection <= go_down;
        2'd2: begin selection <= go_left; col_xq <= k1_centre(go_left); end
        default: begin selection <= go_right; col_xq <= k1_centre(go_right); end
    endcase
endtask
always @(posedge clk) begin
    if (!permitted) begin
        previous <= 16'd0; armed <= 1'b0; panel_open <= 1'b0; shift_latch <= 1'b0;
        l_on <= 1'b0; l_tap <= 1'b0; ctrl_wait <= 1'b0; r_on <= 1'b0; r_pend <= 1'b0; rus_on <= 1'b0;
        lock <= 1'b0; nav_on <= 1'b0;
        if (!reset_n || !enable) begin last_key <= KEY_G; selection <= KEY_G; end
    end else begin
        previous <= buttons;
        if (!armed && buttons == 16'd0) armed <= 1'b1;
        if (tick && !(&l_ms)) l_ms <= l_ms + 10'd1;
        if (tick && !(&r_ms)) r_ms <= r_ms + 10'd1;
        // L
        if (press[8] && !lock) begin
            l_on <= 1'b1; l_tap <= 1'b1; l_ms <= 10'd0; ctrl_wait <= key_held;
        end else if (l_on) begin
            if (!buttons[8]) begin
                l_on <= 1'b0; ctrl_wait <= 1'b0;
                if (l_tap && l_ms < TAP_T) shift_latch <= !shift_latch;
            end else begin
                if (|(press & ~16'h0100)) l_tap <= 1'b0;
                if (ctrl_wait && (!key_held || l_ms >= TAP_T)) ctrl_wait <= 1'b0;
            end
        end
        // R
        if (press[9] && !lock) begin
            r_on <= 1'b1; r_pend <= 1'b1; r_ms <= 10'd0;
        end else begin
            if (r_on && !buttons[9]) r_on <= 1'b0;
            if (r_pend && r_ms >= CHORD_T) begin r_pend <= 1'b0; rus_on <= 1'b1; rus_ms <= 10'd0; end
        end
        if (rus_on && !(r_pend && r_ms >= CHORD_T)) begin
            if (r_on && buttons[9]) rus_ms <= 10'd0;
            else begin
                if (tick && rus_ms != RUS_MIN_T) rus_ms <= rus_ms + 10'd1;
                if (rus_ms >= RUS_MIN_T) rus_on <= 1'b0;
            end
        end
        // navigation
        if (panel_open && press[5]) last_key <= selection;
        if (!panel_open || select_held) nav_on <= 1'b0;
        else if (|dpad_press) begin
            move(press_dir); nav_on <= 1'b1; nav_dir <= press_dir; nav_ms <= 10'd0; nav_repeat <= 1'b0;
        end else if (nav_on) begin
            if (!buttons[nav_dir]) nav_on <= 1'b0;
            else if (tick) begin
                if (nav_ms + 10'd1 >= (nav_repeat ? REPEAT_T : DELAY_T)) begin
                    move(nav_dir); nav_ms <= 10'd0; nav_repeat <= 1'b1;
                end else nav_ms <= nav_ms + 10'd1;
            end
        end
        // the chord (wins over the L and R presses above)
        if (lock && !buttons[8] && !buttons[9]) lock <= 1'b0;
        if (chord) begin
            lock <= 1'b1; l_on <= 1'b0; l_tap <= 1'b0; ctrl_wait <= 1'b0; r_on <= 1'b0; r_pend <= 1'b0;
            panel_open <= !panel_open; nav_on <= 1'b0;
            if (!panel_open) begin selection <= last_key; col_xq <= k1_centre(last_key); end
        end
        if (clear_latch) shift_latch <= 1'b0;
    end
end

//--------- the lines --------------
assign pulled = permitted ? slot_matrix : 64'd0;
assign shift_line = permitted && (shift_latch || slot_shift);
assign ctrl_line = permitted && ((l_on && !ctrl_wait) || slot_ctrl);
assign rus_line = permitted && (rus_on || slot_rus);
assign modifiers = {!rus_line, !ctrl_line, !shift_line};
integer r;
always @* begin
    columns = 8'hFF;
    for (r = 0; r < 8; r = r + 1) if (!rows[r]) columns = columns & ~pulled[8*r +: 8];
end
endmodule
`default_nettype wire
