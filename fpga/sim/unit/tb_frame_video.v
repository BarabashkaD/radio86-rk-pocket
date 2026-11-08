`timescale 1ns/1ps
// Fast producer / slow consumer, whole-frame drops, and reset during a frame.
module tb_frame_video;
    reg source_clk=0,pixel_clk=0,source_reset_n=0,pixel_reset_n=0;
    always #6.734 source_clk=~source_clk;
    always #40.690 pixel_clk=~pixel_clk;
    reg valid=0,data=0,start=0,finish=0;
    reg [16:0] address=0;
    wire [23:0] rgb;
    wire de,hs,vs;
    wire [31:0] completed,dropped,displayed;
    pocket_frame_video dut(.source_clk(source_clk),.source_reset_n(source_reset_n),.pixel_clk(pixel_clk),.pixel_reset_n(pixel_reset_n),
        .pixel_valid(valid),.pixel_data(data),.frame_start(start),.frame_end(finish),.pixel_address(address),.diagnostic_error(1'b0),.green(1'b0),.panel_state(78'd0),
        .rgb(rgb),.de(de),.hs(hs),.vs(vs),.skip(),.audio_dac(),.audio_lrck(),
        .frames_completed(completed),.frames_dropped(dropped),.frames_displayed(displayed));
    integer frame,pixel,checked=0,pixels=0;
    reg checking=0,expected=0;
    reg previous_de=0,previous_hs=0,previous_vs=0,seen_vs=0;
    integer line_pixels=0,active_lines=0,hs_count=0,frame_pixels=0,since_hs=0,since_vs=0,line_segments=0;
    initial begin
        #11;source_reset_n=1;pixel_reset_n=1;
        for(frame=0;frame<40;frame=frame+1)begin
            for(pixel=0;pixel<122400;pixel=pixel+1)begin
                @(negedge source_clk);valid=1;data=frame[0];address=pixel;start=pixel==0;finish=pixel==122399;
                if(frame==5 && pixel==30000)begin
                    valid=0;start=0;finish=0;source_reset_n=0;pixel_reset_n=0;
                    repeat(7)@(negedge source_clk);
                    source_reset_n=1;pixel_reset_n=1;
                    pixel=122400; // abandon this partial source frame
                end
            end
            @(negedge source_clk);valid=0;start=0;finish=0;
            repeat(8)@(negedge source_clk);
        end
        wait(checked>=4);
        if(dropped<2 || displayed<4)$fatal(1,"no drop/swap coverage dropped=%0d displayed=%0d",dropped,displayed);
        $display("PASS coherent frame video: checked=%0d completed=%0d dropped=%0d displayed=%0d; reset mid-frame",checked,completed,dropped,displayed);$finish;
    end
    always @(negedge source_clk)
        if(source_reset_n && dut.write_pixel && dut.display_valid && dut.write_bank==dut.display_bank)$fatal(1,"ownership collision");
    always @(negedge pixel_clk)begin
        if(!pixel_reset_n)begin
            checking=0;pixels=0;checked=0;previous_de=0;previous_hs=0;previous_vs=0;seen_vs=0;
            line_pixels=0;active_lines=0;hs_count=0;frame_pixels=0;since_hs=0;since_vs=0;line_segments=0;
        end
        else begin
            since_hs=since_hs+1;since_vs=since_vs+1;
            if(hs && previous_hs || vs && previous_vs)$fatal(1,"multi-cycle sync pulse");
            if(vs)begin
                if(seen_vs && (active_lines!=300 || hs_count!=400 || frame_pixels!=122400))
                    $fatal(1,"transport geometry active=%0d HS=%0d pixels=%0d",active_lines,hs_count,frame_pixels);
                seen_vs=1;active_lines=0;hs_count=0;frame_pixels=0;since_vs=0;
            end
            if(hs)begin
                if(since_vs<3 || de || previous_de)$fatal(1,"HS gap contract");
                hs_count=hs_count+1;since_hs=0;line_pixels=0;line_segments=0;
            end
            if(de)begin
                if(since_hs<2)$fatal(1,"DE immediately after HS");
                line_pixels=line_pixels+1;frame_pixels=frame_pixels+1;
                if(!previous_de)begin
                    line_segments=line_segments+1;active_lines=active_lines+1;
                    if(line_segments!=1)$fatal(1,"multiple DE segments per line");
                end
            end
            if(!de && previous_de && line_pixels!=408)$fatal(1,"active line width %0d",line_pixels);
            if(vs)begin
                if(checking)begin if(pixels!=122400)$fatal(1,"frame pixels %0d",pixels);checked=checked+1;end
                checking=dut.display_valid;pixels=0;
            end
            if(checking && de)begin
                if(pixels==0)expected=rgb[0];
                if(rgb!=={24{expected}})$fatal(1,"torn frame at pixel %0d",pixels);
                pixels=pixels+1;
            end
            if(!de && rgb!==0)$fatal(1,"blanking RGB");
            previous_de=de;previous_hs=hs;previous_vs=vs;
        end
    end
    initial begin #200000000;$fatal(1,"video stress timeout");end
endmodule
