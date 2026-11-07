`default_nettype none
// The Pocket buttons as the native Radio-86RK keyboard (spec 5.6). With the panel open (L): the
// on-screen keyboard of POC 0.4.0 (pocket_key_defs.vh, pocket_keyboard_overlay.v). With the panel
// closed: each of 10 buttons gives the 7-bit key code of map (pocket_remap.v). Outputs: the
// matrix columns for the rows of PPI port A, the modifier lines {RUS, Ctrl, Shift}, active low.
module pocket_keyboard(
    input wire clk,reset_n,enable,
    input wire [31:0] pad,
    input wire [7:0] rows,
    input wire [69:0] map,
    input wire russian_mode,
    output reg [7:0] columns,
    output wire [2:0] modifiers,
    output reg panel_open,fx_page,
    output reg [5:0] selection,
    output reg shift_pending,ctrl_pending,
    output wire key_valid,
    output wire [6:0] key_ascii,
    output reg armed,
    output wire dock_keyboard           // controller type 0x4: recognized, not used yet (spec 10)
);
    `include "pocket_key_defs.vh"
    wire supported=pad[31:28]>=1 && pad[31:28]<=3;
    assign dock_keyboard=pad[31:28]==4'h4;
    wire [15:0] buttons=pad[15:0];
    reg [15:0] previous;
    wire [15:0] press=buttons & ~previous;
    wire typing=|buttons[7:4];
    reg held;
    reg [6:0] held_key;
    reg held_shift,held_ctrl;
    wire permitted=reset_n && enable && supported && armed && !buttons[8];
    wire normal=permitted && !buttons[9] && !previous[9] && !(panel_open && buttons[15]);
    wire closed=normal && !panel_open;
    wire real_key=held_key<64 || held_key>=67;
    wire primary=normal && panel_open && held && typing && real_key;
    // the mapped buttons in the order of map: Up, Down, Left, Right, A, B, X, Y, Start, Select
    wire [9:0] mapped={buttons[14],buttons[15],buttons[7:0]};
    reg map_shift,map_ctrl,map_rus;
    reg [6:0] code;
    integer i;
    wire shift_on=shift_pending || (primary && held_shift) || map_shift;
    wire ctrl_on=ctrl_pending || (primary && held_ctrl) || map_ctrl;
    wire rus_on=permitted && (buttons[9] || (panel_open && held && typing && held_key==66) || map_rus);
    wire [5:0] physical=physical_key(held_key);
    assign key_valid=primary;
    assign key_ascii=native_character(physical,russian_mode,shift_on,ctrl_on);
    assign modifiers=permitted ? {!rus_on,!ctrl_on,!shift_on} : 3'b111;
    always @* begin
        columns=8'hff;map_shift=0;map_ctrl=0;map_rus=0;code=7'd127;
        if(primary && !rows[physical[5:3]])columns[physical[2:0]]=0;
        if(closed)for(i=0;i<10;i=i+1)if(mapped[i])begin
            code=map[7*i +: 7];
            if(code<7'd64)begin if(!rows[code[5:3]])columns[code[2:0]]=0;end
            else if(code==7'd64)map_shift=1;
            else if(code==7'd65)map_ctrl=1;
            else if(code==7'd66)map_rus=1;
        end
    end
    reg [6:0] chosen;
    always @* chosen=page_key(fx_page,selection);
    always @(posedge clk)begin
        if(!reset_n || !enable)begin
            previous<=0;held<=0;held_key<=0;held_shift<=0;held_ctrl<=0;
            armed<=0;panel_open<=0;fx_page<=0;selection<=13;shift_pending<=0;ctrl_pending<=0;
        end else if(!supported)begin
            previous<=0;held<=0;armed<=0;shift_pending<=0;ctrl_pending<=0;
        end else begin
            previous<=buttons;
            if(!armed)begin held<=0;if(buttons==0)armed<=1;end
            else if(press[8])begin
                panel_open<=!panel_open;held<=0;armed<=0;shift_pending<=0;ctrl_pending<=0;
            end else if(buttons[9])begin held<=0;shift_pending<=0;ctrl_pending<=0;end
            else if(previous[9])begin held<=0;armed<=buttons==0;end
            else if(panel_open && press[15])begin fx_page<=!fx_page;held<=0;armed<=0;end
            else if(held)begin
                if(!typing)begin
                    held<=0;
                    if(real_key || held_key==66)begin shift_pending<=0;ctrl_pending<=0;end
                end
            end else if(panel_open && |press[7:4])begin
                held<=1;held_shift<=0;held_ctrl<=0;
                if(press[4])begin
                    held_key<=chosen;
                    if(chosen==64)shift_pending<=!shift_pending;
                    if(chosen==65)ctrl_pending<=!ctrl_pending;
                    if(chosen==67)held_ctrl<=1;
                    if(chosen>=68)held_shift<=1;
                end else if(press[5])held_key<=10;
                else if(press[6])held_key<=11;
                else held_key<=63;
            end else if(panel_open && !typing)begin
                if(press[2] && !buttons[3])selection<=selection==0 ? 39 : selection-1'b1;
                else if(press[3] && !buttons[2])selection<=selection==39 ? 0 : selection+1'b1;
                else if(press[0] && !buttons[1])selection<=selection<10 ? selection+30 : selection-10;
                else if(press[1] && !buttons[0])selection<=selection>=30 ? selection-30 : selection+10;
            end
        end
    end
endmodule
`default_nettype wire
