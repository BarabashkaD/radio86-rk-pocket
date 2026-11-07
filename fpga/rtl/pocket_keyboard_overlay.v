`default_nettype none
module pocket_keyboard_overlay(
    input wire clk,reset_n,panel_open,fx_page,russian_mode,shift_pending,ctrl_pending,
    input wire [5:0] selection,
    input wire pixel_valid,pixel_data,frame_start,frame_end,
    input wire [16:0] pixel_address,
    output reg out_valid,out_data,out_start,out_end,
    output reg [16:0] out_address
);
    `include "pocket_key_defs.vh"
    `include "native_font.vh"
    reg [8:0] x,y;
    reg visible,fx,rus,sh,ct;
    reg [5:0] selected;
    reg [3:0] grid_col,grid_dy;
    reg [4:0] grid_dx;
    reg [1:0] grid_row;
    reg [5:0] header_col;
    reg [2:0] header_dx;
    reg base,draw,inverse;
    reg [6:0] letter;
    reg [5:0] bit_index,index1,index2;
    reg v1,v2,start1,start2,end1,end2,base1,base2,draw1,draw2,inverse1,inverse2;
    reg [16:0] address1,address2;
    reg [6:0] letter1;
    reg [47:0] bits2;
    reg [5:0] index;
    reg [1:0] part;
    reg [2:0] dot;
    reg [3:0] glyph_line;
    localparam [8*28-1:0] HEADER0="L:BACK A:KEY B:ENT X:BS Y:SP";
    localparam [8*15-1:0] HEADER1="R:LANG ST:PAGE ";
    function [6:0] caption(input special,input [5:0] position,input [1:0] piece,input language,input shifted);
        reg [6:0] key,code;
        reg [23:0] label_text;
        begin
            key=page_key(special,position);label_text="   ";code=0;
            case(key)
                0:label_text="HM ";1:label_text="CLR";2:label_text="ESC";
                3:label_text="F1 ";4:label_text="F2 ";5:label_text="F3 ";6:label_text="F4 ";7:label_text="F5 ";
                8:label_text="TAB";9:label_text="LF ";10:label_text="ENT";11:label_text="BS ";
                12:label_text="LT ";13:label_text="UP ";14:label_text="RT ";15:label_text="DN ";
                63:label_text="SP ";64:label_text="SHF";65:label_text="CTL";66:label_text="R/L";67:label_text="BRK";
                default:begin
                    code=native_character(physical_key(key),language,shifted || key>=68,1'b0);
                    label_text={8'h20,1'b0,code,8'h20};
                end
            endcase
            case(piece)0:caption=label_text[22:16];1:caption=label_text[14:8];default:caption=label_text[6:0];endcase
        end
    endfunction
    function [6:0] heading(input line,input [5:0] position,input special,input language,input shifted,input control_on);
        begin
            heading=32;
            if(!line)begin if(position<28)heading=HEADER0[(27-position)*8+:8];end
            else if(position<15)heading=HEADER1[(14-position)*8+:8];
            else case(position)
                15:heading=language ? "R" : "L";16:heading=language ? "U" : "A";17:heading=language ? "S" : "T";
                19:heading=special ? "F" : "A";20:heading=special ? "X" : "B";21:heading=special ? " " : "C";
                23:heading="S";24:heading=":";25:heading=shifted ? "*" : "-";
                27:heading="C";28:heading=":";29:heading=control_on ? "*" : "-";
                default:heading=32;
            endcase
        end
    endfunction
    always @* begin
        base=pixel_data;draw=0;inverse=0;letter=32;bit_index=0;index=0;part=0;dot=0;glyph_line=0;
        if(!frame_start && visible && x>=80 && x<328 && y>=224 && y<298)begin
            base=x==80 || x==327 || y==224 || y==297;
            if(x>=84 && x<324 && y>=248 && y<296)begin
                index={4'b0,grid_row}*6'd10+{2'b0,grid_col};
                inverse=index==selected || (fx && ((index==24 && sh)||(index==25 && ct)));
                base=inverse;
                if(grid_dx>=2 && grid_dx<8)begin part=0;dot=grid_dx-2;draw=1;end
                else if(grid_dx>=9 && grid_dx<15)begin part=1;dot=grid_dx-9;draw=1;end
                else if(grid_dx>=16 && grid_dx<22)begin part=2;dot=grid_dx-16;draw=1;end
                if(grid_dy<2 || grid_dy>=10)draw=0;
                letter=caption(fx,index,part,rus,sh);
                glyph_line=grid_dy-4'd2;
                if(draw)bit_index=6'd47-(glyph_line*6'd6+{3'b0,dot});
            end
            if(x>=84 && x<324 && ((y>=228 && y<236)||(y>=238 && y<246)))begin
                letter=heading(y>=238,header_col,fx,rus,sh,ct);draw=1;inverse=0;
                glyph_line=y>=9'd238 ? y-9'd238 : y-9'd228;
                bit_index=6'd47-(glyph_line*6'd6+{3'b0,header_dx});
            end
        end
    end
    always @(posedge clk)begin
        if(!reset_n)begin
            x<=0;y<=0;visible<=0;fx<=0;rus<=0;sh<=0;ct<=0;selected<=13;
            grid_col<=0;grid_dx<=0;grid_row<=0;grid_dy<=0;header_col<=0;header_dx<=0;
            v1<=0;v2<=0;out_valid<=0;start1<=0;start2<=0;out_start<=0;end1<=0;end2<=0;out_end<=0;
            address1<=0;address2<=0;out_address<=0;base1<=0;base2<=0;draw1<=0;draw2<=0;inverse1<=0;inverse2<=0;
            letter1<=0;bits2<=0;index1<=0;index2<=0;out_data<=0;
        end else begin
            if(frame_start)begin visible<=panel_open;fx<=fx_page;rus<=russian_mode;sh<=shift_pending;ct<=ctrl_pending;selected<=selection;end
            v1<=pixel_valid;start1<=frame_start && pixel_valid;end1<=frame_end && pixel_valid;
            address1<=pixel_address;base1<=base;draw1<=draw;inverse1<=inverse;letter1<=letter;index1<=bit_index;
            v2<=v1;start2<=start1;end2<=end1;address2<=address1;base2<=base1;draw2<=draw1;inverse2<=inverse1;bits2<=native_glyph(letter1);index2<=index1;
            out_valid<=v2;out_start<=start2;out_end<=end2;out_address<=address2;out_data<=draw2 ? bits2[index2]^inverse2 : base2;
            if(pixel_valid)begin
                if(frame_start)begin x<=1;y<=0;grid_col<=0;grid_dx<=0;grid_row<=0;grid_dy<=0;header_col<=0;header_dx<=0;end
                else begin
                    if(x==407)begin x<=0;y<=y==299 ? 0 : y+1'b1;end else x<=x+1'b1;
                    if(x<84 || x>=324)begin grid_col<=0;grid_dx<=0;header_col<=0;header_dx<=0;end
                    else begin
                        if(grid_dx==23)begin grid_dx<=0;grid_col<=grid_col+1'b1;end else grid_dx<=grid_dx+1'b1;
                        if(header_dx==5)begin header_dx<=0;header_col<=header_col+1'b1;end else header_dx<=header_dx+1'b1;
                    end
                    if(x==407)begin
                        if(y<248 || y>=295)begin grid_row<=0;grid_dy<=0;end
                        else if(grid_dy==11)begin grid_dy<=0;grid_row<=grid_row+1'b1;end else grid_dy<=grid_dy+1'b1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
