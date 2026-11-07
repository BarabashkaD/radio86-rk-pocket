`timescale 1ns/1ps
module tb_native_keyboard_overlay;
    reg clk=0,reset_n=0,open=0,fx=0,rus=0,sh=0,ct=0;
    reg [5:0] selection=11;
    reg valid=0,data=0,start=0,finish=0;
    reg [16:0] address=0;
    wire ov,od,os,oe;
    wire [16:0] oa;
    reg frame[0:122399];
    reg [7:0] font[0:1023];
    integer count=0,starts=0,ends=0,i,c,y,x;
    reg [47:0] glyph;
    always #5 clk=~clk;
    pocket_keyboard_overlay dut(.clk(clk),.reset_n(reset_n),.panel_open(open),.fx_page(fx),.russian_mode(rus),
        .shift_pending(sh),.ctrl_pending(ct),.selection(selection),.pixel_valid(valid),.pixel_data(data),
        .frame_start(start),.frame_end(finish),.pixel_address(address),.out_valid(ov),.out_data(od),
        .out_start(os),.out_end(oe),.out_address(oa));
    always @(negedge clk)if(ov)begin
        if(oa!==count || (^od===1'bx))$fatal(1,"native overlay stream count=%0d addr=%h data=%b",count,oa,od);
        frame[oa]=od;count=count+1;
        if(os)begin starts=starts+1;if(oa!=0)$fatal(1,"bad first marker");end
        if(oe)begin ends=ends+1;if(oa!=122399)$fatal(1,"bad last marker");end
    end
    task send_frame(input checkered,input mid_change);
        integer p,xx,yy;
        reg expected;
        begin
            count=0;starts=0;ends=0;
            for(p=0;p<122400;p=p+1)begin
                @(negedge clk);valid=1;address=p;data=checkered ? p[0]^p[9] : 0;start=p==0;finish=p==122399;
                if(mid_change && p==1000)begin rus=1;selection=3;end
            end
            @(negedge clk);valid=0;start=0;finish=0;repeat(5)@(negedge clk);
            if(count!=122400 || starts!=1 || ends!=1)$fatal(1,"native frame alignment %0d/%0d/%0d",count,starts,ends);
            for(p=0;p<122400;p=p+1)begin
                xx=p%408;yy=p/408;expected=checkered ? p[0]^p[9] : 0;
                if((!open || xx<80 || xx>=328 || yy<224 || yy>=298) && frame[p]!==expected)$fatal(1,"native overlay changed outside canvas box");
            end
        end
    endtask
    task expect_glyph(input integer left,input integer top,input [6:0] code,input inverted);
        integer gx,gy;
        begin
            for(gy=0;gy<8;gy=gy+1)for(gx=0;gx<6;gx=gx+1)
                if(frame[(top+gy)*408+left+gx] !== (font[code*8+gy][5-gx]^inverted))
                    $fatal(1,"native glyph %h pixel %0d,%0d",code,left+gx,top+gy);
        end
    endtask
    initial begin
        $readmemh("font.hex",font);
        for(c=0;c<128;c=c+1)begin
            glyph=dut.native_glyph(c);
            for(y=0;y<8;y=y+1)for(x=0;x<6;x=x+1)
                if(glyph[47-y*6-x]!==font[c*8+y][5-x])$fatal(1,"native font bit order %h",c);
        end
        repeat(3)@(negedge clk);reset_n=1;
        send_frame(1,0);
        open=1;rus=0;selection=11;send_frame(0,1);
        expect_glyph(117,262,7'h42,1); // selected B stays LAT despite mid-frame RUS.
        expect_glyph(84,228,"L",0);expect_glyph(174,238,"L",0);
        $writememh("native-lat-frame.hex",frame);
        selection=11;send_frame(0,0);expect_glyph(117,262,7'h62,1);expect_glyph(174,238,"R",0);
        $writememh("native-rus-frame.hex",frame);
        fx=1;selection=19;sh=0;ct=1;send_frame(0,0);
        expect_glyph(309,262,7'h60,1);expect_glyph(158,250,"F",0);expect_glyph(165,250,"1",0);
        expect_glyph(198,238,"F",0);expect_glyph(258,238,"*",0);
        $writememh("native-fx-frame.hex",frame);
        open=0;send_frame(1,0);
        $display("PASS native overlay: 612000 pixels, all128 native glyphs, LAT/RUS and FX captions, frame-latched state, unchanged closed/outside canvas, 3-stage stream markers");$finish;
    end
endmodule
