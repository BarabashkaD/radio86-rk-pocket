// Dual-clock ping-pong frames. One outstanding ownership token; whole-frame drops.
`default_nettype none
module pocket_frame_video(
    input wire source_clk,source_reset_n,pixel_clk,pixel_reset_n,
    input wire pixel_valid,pixel_data,frame_start,frame_end,
    input wire [16:0] pixel_address,
    input wire diagnostic_error,green,
    input wire [77:0] panel_state,      // K1 panel state, pixel_clk domain (pocket_k1_panel.v)
    output reg [23:0] rgb,
    output reg de,hs,vs,
    output wire skip,audio_dac,audio_lrck,
    output reg [31:0] frames_completed,frames_dropped,frames_displayed
);
    reg frame0[0:122399];
    reg frame1[0:122399];
    reg write_bank,writing,pending,request_token,ack_token;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] ack_sync,request_sync;
    wire accept_start=frame_start && !pending;
    wire write_pixel=pixel_valid && (writing || accept_start);
    always @(posedge source_clk) begin
        if(write_pixel && source_reset_n) begin
            if(write_bank) frame1[pixel_address]<=pixel_data;
            else frame0[pixel_address]<=pixel_data;
        end
    end
    always @(posedge source_clk or negedge source_reset_n) begin
        if(!source_reset_n) begin
            write_bank<=0;writing<=0;pending<=0;request_token<=0;ack_sync<=0;
            frames_completed<=0;frames_dropped<=0;
        end else begin
            ack_sync<={ack_sync[1:0],ack_token};
            if(pending && ack_sync[2]==request_token) begin pending<=0;write_bank<=!write_bank;end
            if(frame_start) begin
                writing<=!pending;
                if(pending)frames_dropped<=frames_dropped+1'b1;
            end
            if(frame_end && write_pixel) begin
                writing<=0;pending<=1;request_token<=!request_token;frames_completed<=frames_completed+1'b1;
            end
        end
    end
    reg display_bank,display_valid;
    reg [8:0] x,y;
    reg [16:0] read_address;
    reg q0,q1,de_d,hs_d,vs_d;
    reg [7:0] audio_phase;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] error_sync;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] green_sync;
    wire active=x>=16 && x<424 && y>=32 && y<332;
    assign skip=0;assign audio_dac=0;assign audio_lrck=audio_phase[7];
    always @(posedge pixel_clk) begin
        q0<=frame0[read_address];q1<=frame1[read_address];
    end
    always @* read_address=active ? ((y-9'd32)*17'd408+(x-9'd16)) : 17'd0;
    // The K1 panel draws over the picture (and over the error colour). Its hit / rgb come 3 clks
    // after x, y (pocket_k1_panel LATENCY); the picture path, 1 clk after x, y at de_d, is delayed
    // by D = 3 - 1 more clks, so hs / vs / de / rgb keep their timing relative to each other.
    localparam D=2;
    reg [77:0] frame_state;                 // panel_state of this frame: latched at x == 0 && y == 0
    reg [D-1:0] de_p,hs_p,vs_p,dot_p,error_p,green_p;
    wire panel_hit;
    wire [23:0] panel_rgb;
    pocket_k1_panel panel(.clk(pixel_clk),.reset_n(pixel_reset_n),.x(x),.y(y),.state(frame_state),
        .green(green_sync[2]),.hit(panel_hit),.rgb(panel_rgb));
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if(!pixel_reset_n) begin
            request_sync<=0;ack_token<=0;display_bank<=1;display_valid<=0;
            x<=0;y<=0;de_d<=0;hs_d<=0;vs_d<=0;rgb<=0;de<=0;hs<=0;vs<=0;
            audio_phase<=0;error_sync<=0;green_sync<=0;frames_displayed<=0;
            frame_state<=0;de_p<=0;hs_p<=0;vs_p<=0;dot_p<=0;error_p<=0;green_p<=0;
        end else begin
            request_sync<={request_sync[1:0],request_token};
            error_sync<={error_sync[1:0],diagnostic_error};
            green_sync<={green_sync[1:0],green};
            audio_phase<=audio_phase+1'b1;
            if(x==511)begin x<=0;y<=y==399 ? 0 : y+1'b1;end else x<=x+1'b1;
            if(x==0 && y==0 && request_sync[2]!=ack_token) begin
                display_bank<=!display_bank;display_valid<=1;ack_token<=request_sync[2];
                frames_displayed<=frames_displayed+1'b1;
            end
            if(x==0 && y==0)frame_state<=panel_state;
            de_d<=active;hs_d<=x==3;vs_d<=x==0 && y==0;
            de_p<={de_p[D-2:0],de_d};hs_p<={hs_p[D-2:0],hs_d};vs_p<={vs_p[D-2:0],vs_d};
            dot_p<={dot_p[D-2:0],display_valid && (display_bank ? q1 : q0)};
            error_p<={error_p[D-2:0],error_sync[2]};green_p<={green_p[D-2:0],green_sync[2]};
            de<=de_p[D-1];hs<=hs_p[D-1];vs<=vs_p[D-1];
            rgb<=0;
            if(de_p[D-1]) begin
                if(panel_hit)rgb<=panel_rgb;
                else if(error_p[D-1])rgb<=24'h600000;
                else if(dot_p[D-1])rgb<=green_p[D-1] ? 24'h00ff00 : 24'hffffff;
            end
        end
    end
endmodule
`default_nettype wire
