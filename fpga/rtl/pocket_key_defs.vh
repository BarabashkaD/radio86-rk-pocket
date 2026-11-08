// Character returned by the hash-bound native BIOS for a single physical key: the monitor's
// decoder at FE72 step by step (rus = byte 7606 nonzero, sh / ct = the SS / US lines low).
// Checked for all 512 cases against an 8080 run of the ROM (scripts/tests/test_k1_layout.py).
// Test model only: no RTL includes this file; the pins stay native.
function [6:0] native_character(input [5:0] key,input rus,input sh,input ct);
    reg [6:0] code;
    begin
        code=0;
        if(key<16)case(key) // tables FEEA / FEE2
            0:code=12;1:code=31;2:code=27;3:code=0;4:code=1;5:code=2;6:code=3;7:code=4;
            8:code=9;9:code=10;10:code=13;11:code=127;12:code=8;13:code=25;14:code=24;15:code=26;
            default:code=0;
        endcase
        else if(key==63)code=32;
        else code=32+key;
        if(key>=16 && key!=63 || key==11)begin // FF06: codes from 40h, and the row 2-7 keys
            if(code>=64)begin
                if(ct)code=code & 7'h1f; // Ctrl first: no RUS, no Shift
                else begin
                    if(rus)code=code | 7'h20; // RUS: 40h-5Fh -> 60h-7Fh
                    if(sh)code=code ^ 7'h20;  // Shift: the other alphabet (7Fh -> 5Fh)
                end
            end else begin
                if(sh && !ct)code=code & 7'h2f; // Ctrl cancels Shift on digits / punctuation
                if(code[3:0]>=12)code=code ^ 7'h10;
            end
        end
        native_character=code;
    end
endfunction
