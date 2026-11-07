`timescale 1ns/1ps
`default_nettype none
// pocket_remap + pocket_keyboard (spec 5.6): every Keys x Keys on x Escape combination on the 10 buttons, with the
// matrix checked row by row and the modifier lines; the panel switches the mapping off; the
// Dock keyboard type gives no key.
module tb_pocket_keyboard;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset_n = 1'b0;
reg [31:0] pad = {4'h1, 28'h0};
reg [7:0] rows = 8'hFF;
reg [1:0] preset = 2'd0;
reg keys_on = 1'b0;
reg [1:0] escape = 2'd0;
wire [69:0] map;
wire [7:0] columns;
wire [2:0] modifiers;
wire panel_open, fx_page, sp, cp, kv, armed, dock;
wire [5:0] selection;
wire [6:0] ascii;
pocket_remap remap(.preset(preset), .keys_on(keys_on), .escape(escape), .map(map));
pocket_keyboard dut(.clk(clk), .reset_n(reset_n), .enable(1'b1), .pad(pad), .rows(rows), .map(map),
    .russian_mode(1'b0), .columns(columns), .modifiers(modifiers), .panel_open(panel_open), .fx_page(fx_page),
    .selection(selection), .shift_pending(sp), .ctrl_pending(cp), .key_valid(kv), .key_ascii(ascii),
    .armed(armed), .dock_keyboard(dock));
reg [6:0] dir [0:15];                       // [keys*4 + Up, Down, Left, Right]
reg [6:0] want [0:9];
// the table of spec 5.6, written out by hand: the code of button b for Keys k, Keys on o, Escape e
task set_want(input integer k, input integer o, input integer e);
    integer i;
    begin
        for (i = 0; i < 4; i = i + 1) want[i] = dir[k*4 + i];                   // D-pad: Up Down Left Right
        want[4] = 63; want[5] = 10; want[6] = 11; want[7] = 57;                 // A B X Y: Space VK ZB Y
        if (o == 1) begin
            want[6] = dir[k*4 + 0]; want[5] = dir[k*4 + 1]; want[7] = dir[k*4 + 2]; want[4] = dir[k*4 + 3];
            want[3] = 63; want[1] = 10; want[0] = 11; want[2] = 57;
        end
        want[8] = e == 1 ? 2 : 10;                                              // Start
        want[9] = e == 0 ? 2 : 10;                                              // Select
    end
endtask
function [15:0] bit_of(input integer b);
    bit_of = b == 8 ? 16'h8000 : b == 9 ? 16'h4000 : (16'h0001 << b);
endfunction
task fail(input [8*64-1:0] what, input integer p, input integer b, input integer c);
    begin $display("ERROR: %0s: combination %0d button %0d code %0d columns %b modifiers %b", what, p, b, c, columns, modifiers); $finish; end
endtask
task set_buttons(input [15:0] b);
    begin @(negedge clk); pad = {4'h1, 12'h0, b}; @(negedge clk); end
endtask
task check_code(input integer p, input integer b, input [6:0] c);
    integer r;
    begin
        set_buttons(bit_of(b));
        if (c < 64) begin
            for (r = 0; r < 8; r = r + 1) begin
                rows = ~(8'h01 << r); #1;
                if (r == c[5:3] ? columns !== ~(8'h01 << c[2:0]) : columns !== 8'hFF) fail("matrix", p, b, c);
            end
        end else begin
            rows = 8'h00; #1;
            if (columns !== 8'hFF) fail("a modifier or none gave a matrix key", p, b, c);
            if ((c == 64 && modifiers !== 3'b110) || (c == 65 && modifiers !== 3'b101) ||
                (c == 66 && modifiers !== 3'b011) || (c == 127 && modifiers !== 3'b111)) fail("modifier line", p, b, c);
        end
        rows = 8'hFF;
        set_buttons(16'h0000);
    end
endtask
integer p, b, o, e;
initial begin
    // Up Down Left Right of the four Keys: Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD
    preset = 2'd1; #1;                      // an event on the inputs of the combinational map at time 0
    dir[0] = 13; dir[1] = 15; dir[2] = 12; dir[3] = 14;
    dir[4] = 24; dir[5] = 22; dir[6] = 23; dir[7] = 25;
    dir[8] = 24; dir[9] = 18; dir[10] = 20; dir[11] = 22;
    dir[12] = 55; dir[13] = 51; dir[14] = 33; dir[15] = 36;
    repeat (3) @(negedge clk); reset_n = 1'b1; repeat (3) @(negedge clk);
    if (!armed) begin $display("ERROR: not armed"); $finish; end
    for (p = 0; p < 4; p = p + 1)
        for (o = 0; o < 2; o = o + 1)
            for (e = 0; e < 3; e = e + 1) begin
                preset = p; keys_on = o; escape = e;
                set_want(p, o, e);
                for (b = 0; b < 10; b = b + 1) check_code(p*6 + o*3 + e, b, want[b]);
            end    preset = 2'd0; keys_on = 1'b0; escape = 2'd0;
    set_buttons(16'h0100); set_buttons(16'h0000); repeat (2) @(negedge clk);   // L: the panel
    if (!panel_open) begin $display("ERROR: the panel did not open"); $finish; end
    set_buttons(16'h0001); rows = 8'h00; #1;
    if (columns !== 8'hFF) begin $display("ERROR: with the panel open D-pad Up gave a key"); $finish; end
    rows = 8'hFF; set_buttons(16'h0000);
    set_buttons(16'h0010); rows = 8'h00; #1;                                      // A: the selected key
    if (columns === 8'hFF) begin $display("ERROR: panel A typed nothing"); $finish; end
    rows = 8'hFF; set_buttons(16'h0000);
    @(negedge clk); pad = {4'h4, 12'h0, 16'h0010}; rows = 8'h00; #1;               // Dock keyboard type
    if (!dock || columns !== 8'hFF) begin $display("ERROR: Dock keyboard type not ignored"); $finish; end
    $display("PASS keyboard: 24 Keys x Keys on x Escape combinations on 10 buttons, matrix rows, modifiers, panel, Dock type ignored");
    $finish;
end
endmodule
`default_nettype wire
