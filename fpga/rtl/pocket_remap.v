// The key codes of the 10 mapped buttons (spec 5.6): Keys (the four direction keys), Keys on
// (which buttons carry the direction keys and which the action keys) and Escape (which of Start
// and Select sends AR2). Button i (0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 X, 7 Y, 8 Start,
// 9 Select) is map[7*i+6:7*i]; a code is 0..63 = matrix row*8+col, 64 Shift (SS), 65 Ctrl (US),
// 66 RUS/LAT, 127 none. Matrix positions: docs/integration.md section 8 of the core.
`default_nettype none
module pocket_remap(
    input  wire  [1:0] preset,          // Keys: 0 Cursor, 1 Digits 7-8-9-6, 2 Digits 8-4-6-2, 3 WASD
    input  wire        keys_on,         // Keys on: 0 D-pad, 1 A B X Y
    input  wire  [1:0] escape,          // Escape: 0 Select, 1 Start, 2 None (both send VK)
    output reg  [69:0] map
);
localparam [6:0] SPACE = 7'd63, VK = 7'd10, ZB = 7'd11, KEY_Y = 7'd57, AR2 = 7'd2;
reg [6:0] up, down, left, right, start, select;
always @* begin
    case (preset)
        2'd1:    begin up = 7'd24; down = 7'd22; left = 7'd23; right = 7'd25; end   // 8 6 7 9
        2'd2:    begin up = 7'd24; down = 7'd18; left = 7'd20; right = 7'd22; end   // 8 2 4 6
        2'd3:    begin up = 7'd55; down = 7'd51; left = 7'd33; right = 7'd36; end   // W S A D
        default: begin up = 7'd13; down = 7'd15; left = 7'd12; right = 7'd14; end   // cursor keys
    endcase
    start  = escape == 2'd1 ? AR2 : VK;
    select = escape == 2'd0 ? AR2 : VK;
    // {Select, Start, Y, X, B, A, Right, Left, Down, Up}
    if (keys_on) map = {select, start, left, up, down, right, SPACE, KEY_Y, VK, ZB};
    else         map = {select, start, KEY_Y, ZB, VK, SPACE, right, left, down, up};
end
endmodule
`default_nettype wire
