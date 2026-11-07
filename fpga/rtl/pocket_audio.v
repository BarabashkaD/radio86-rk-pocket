// Native Karabas BEEPER -> 48 kHz, signed 16-bit stereo I2S for APF.
// Both channels share a frame snapshot. A small DC blocker removes steady pin DC.
`default_nettype none
module pocket_audio(
    input wire mclk,reset_n,beeper,
    output reg dac,
    output wire lrck,debug_bclk
);
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] beeper_sync;
    reg [7:0] phase;
    reg signed [31:0] previous_x,highpass;
    reg signed [15:0] frame_sample;
    reg warm;
    wire signed [31:0] sample_x=beeper_sync[2] ? 32'sd1048576 : 32'sd0; // 4096 << 8
    wire signed [31:0] next_highpass=highpass-(highpass>>>8)+sample_x-previous_x;
    wire signed [31:0] next_sample=next_highpass>>>8;
    wire [4:0] slot=phase[6:2];
    assign lrck=phase[7];
    assign debug_bclk=phase[1];
    always @(posedge mclk or negedge reset_n)begin
        if(!reset_n)begin
            beeper_sync<=0;phase<=0;previous_x<=0;highpass<=0;frame_sample<=0;warm<=0;
        end else begin
            beeper_sync<={beeper_sync[1:0],beeper};
            phase<=phase+1'b1;
            if(phase==255)begin
                previous_x<=sample_x;
                if(!warm)begin warm<=1;highpass<=0;frame_sample<=0;end
                else begin
                highpass<=next_highpass;
                if(next_sample>32767)frame_sample<=16'sh7fff;
                else if(next_sample< -32768)frame_sample<=16'sh8000;
                else frame_sample<=next_sample[15:0];
                end
            end
        end
    end
    // Change serial data on MCLK's falling edge, while the derived SCLK is
    // low. Slot 0 is the I2S delay, slots 1..16 are MSB-first, 17..31 are zero.
    always @(negedge mclk or negedge reset_n)begin
        if(!reset_n)dac<=0;
        else if(phase[1:0]==0)begin
            if(slot>=1 && slot<=16)dac<=frame_sample[16-slot];
            else dac<=0;
        end
    end
endmodule
`default_nettype wire
