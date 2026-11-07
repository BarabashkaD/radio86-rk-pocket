// Native 8x8 RK keyboard coordinates. Existing active-low Karabas map:
// src/rtl/mcu/hid_parser.vhd KB_DO/SHIFTS; physical punctuation holes are
// cross-checked with rk_kbd.v and this exact monitor's FE72 decoder.
function [6:0] page_key(input fx,input [5:0] index);
    begin
        if(!fx)begin
            if(index<10)page_key=16+index;
            else if(index<36)page_key=23+index;
            else case(index)36:page_key=28;37:page_key=30;38:page_key=31;default:page_key=63;endcase
        end else if(index<16)page_key=index;
        else case(index)
            16:page_key=26;17:page_key=27;18:page_key=29;19:page_key=32;
            20:page_key=59;21:page_key=60;22:page_key=61;23:page_key=62;
            24:page_key=64;25:page_key=65;26:page_key=66;27:page_key=67;
            default:page_key=40+index;
        endcase
    end
endfunction
function [5:0] physical_key(input [6:0] key);
    begin
        if(key<64)physical_key=key[5:0];
        else if(key==67)physical_key=35; // one logical Ctrl+C / BREAK
        else if(key>=68 && key<=76)physical_key=key-51; // Shift+1..9
        else case(key)77:physical_key=26;78:physical_key=27;79:physical_key=29;default:physical_key=0;endcase
    end
endfunction
// Character returned by the hash-bound native BIOS for a single physical key.
// Matrix/control pins remain native; this function supplies UI/status/guard only.
function [6:0] native_character(input [5:0] key,input rus,input sh,input ct);
    reg [6:0] code;
    begin
        code=0;
        if(key<16)case(key)
            0:code=12;1:code=31;2:code=27;3:code=0;4:code=1;5:code=2;6:code=3;7:code=4;
            8:code=9;9:code=10;10:code=13;11:code=127;12:code=8;13:code=25;14:code=24;15:code=26;
            default:code=0;
        endcase
        else if(key==63)code=32;
        else begin
            code=32+key;
            if(code>=64)begin
                if(ct)code=code & 7'h1f;
                else if(rus ^ sh)code=code ^ 7'h20;
            end else begin
                if(sh)code=code & 7'h2f;
                if(code[3:0]>=12)code=code ^ 7'h10;
            end
        end
        native_character=code;
    end
endfunction
