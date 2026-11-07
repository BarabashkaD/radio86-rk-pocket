`timescale 1ns/1ps
module tb_native_audio;
    reg clk=0,reset_n=0,beeper=0;
    always #40.690104167 clk=~clk;
    wire dac,lrck,bclk;
    pocket_audio dut(.mclk(clk),.reset_n(reset_n),.beeper(beeper),.dac(dac),.lrck(lrck),.debug_bclk(bclk));
    integer cycles=0,last_lr=0,frames=0,positive=0,negative=0,peak=0,samples,j;
    reg [15:0] assembling=0,left_word=0;
    integer value;
    always @(posedge clk)cycles=cycles+1;
    always @(negedge reset_n)last_lr=0;
    always @(posedge lrck)if(reset_n)begin
        if(last_lr!=0 && cycles-last_lr!=256)$fatal(1,"48k frame ratio %0d",cycles-last_lr);
        last_lr=cycles;
    end
    always @(posedge bclk)if(reset_n)begin
        if(dut.phase[6:2]>=1 && dut.phase[6:2]<=16)begin
            assembling[16-dut.phase[6:2]]=dac;
            if(dut.phase[6:2]==16)begin
                if(!lrck)left_word=assembling;
                else begin
                    if(assembling!==left_word)$fatal(1,"stereo frame tore %h %h",left_word,assembling);
                    value=$signed(assembling);$fwrite(samples,"%0d\n",value);frames=frames+1;
                    if(value>0)positive=positive+1;
                    if(value<0)negative=negative+1;
                    if(value<0)value=-value;
                    if(value>peak)peak=value;
                end
            end
        end else if(dac!==0)$fatal(1,"I2S delay/padding bit not zero slot=%0d",dut.phase[6:2]);
    end
    task wait_frames(input integer count);
        integer target;
        begin target=frames+count;wait(frames>=target);end
    endtask
    initial begin
        samples=$fopen("audio-samples.txt","w");
        repeat(5)@(negedge clk);reset_n=1;
        wait_frames(8);if(peak!=0)$fatal(1,"idle source not silent");
        beeper=1;wait_frames(3000);if(dut.frame_sample!==0)$fatal(1,"DC source did not decay to silence");
        for(j=0;j<200;j=j+1)begin beeper=0;wait_frames(24);beeper=1;wait_frames(24);end
        if(positive<100 || negative<100 || peak<1000 || peak>8192)$fatal(1,"tone waveform missing/bad gain pos=%d neg=%d peak=%d",positive,negative,peak);
        reset_n=0;repeat(5)@(negedge clk);reset_n=1;wait_frames(8);
        if(dut.frame_sample!==0)$fatal(1,"warm reset introduced DC click");
        $display("PASS native audio: 48k ratio, 16-bit signed stereo, I2S one-bit delay/padding, 1k tone, DC removal, reset silence; frames=%0d peak=%0d",frames,peak);
        $fclose(samples);$finish;
    end
endmodule
