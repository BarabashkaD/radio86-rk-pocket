// K1 on-screen keyboard: the panel of 67 caps, drawn in the pixel clock domain (clk_core_12288).
// A pure function of the raster position and the state, pixel-exact to scripts/k1/layout.py
// render_panel. Three stages: hit and rgb belong to the x, y given LATENCY clks earlier.
//   1: the position in the panel, the cap row r and line j (/13), the quarter q and its pixel m (/5)
//   2: the key under the quarter (k1_key_at), inside its cap or not, the column c in the cap
//   3: the label pixel, lit / selected, the palette colours
// state (one frame's latched copy): [0] open, [7:1] selected key id, [8] rus, [9] sh (SS line),
// [10] ct (US line), [11] rus_line (RUS line), [75:12] pulled matrix lines 0..63, [77:76] palette
// (0 v1.1, 1 v1.4, 2 mono; 3 is drawn as mono).
`default_nettype none
module pocket_k1_panel(
    input wire clk,reset_n,
    input wire [8:0] x,y,           // raster of pocket_frame_video; picture pixel = (x-16, y-32)
    input wire [77:0] state,
    input wire green,               // the text colour: mono draws in 00FF00 instead of FFFFFF
    output reg hit,                 // the pixel belongs to the open panel
    output reg [23:0] rgb
);
    `include "pocket_k1_layout.vh"
    `include "native_font.vh"
    localparam LATENCY=3;
    localparam [8:0] X0=9'd16+9'd62,Y0=9'd32+9'd218,PW=9'd284,PH=9'd82;
    localparam [2:0] ROWS=3'd6;
    localparam [3:0] CAP_H=4'd12,ROW_H=4'd13;
    localparam [5:0] QUARTERS=6'd56;

    wire open=state[0];
    wire [6:0] selected=state[7:1];
    wire rus=state[8],sh=state[9],ct=state[10],rus_line=state[11];
    wire [63:0] pulled=state[75:12];
    wire mono=state[77];
    wire pal=state[76];
    wire [23:0] text=green ? 24'h00ff00 : 24'hffffff;

    // stage 1: the position
    wire [8:0] lx=x-X0,ly9=y-Y0;
    wire [8:0] ax=lx-9'd2,ay=ly9-9'd2;
    wire [8:0] q_full=ax/9'd5,r_full=ay/9'd13;
    reg s1_in,s1_edge,s1_zone;
    reg [8:0] s1_lx;
    reg [5:0] s1_q;
    reg [2:0] s1_m,s1_r;
    reg [3:0] s1_j;
    always @(posedge clk) begin
        s1_in<=x>=X0 && x<X0+PW && y>=Y0 && y<Y0+PH;
        s1_edge<=lx==9'd0 || lx==PW-9'd1 || ly9==9'd0 || ly9==PH-9'd1;
        s1_zone<=lx>=9'd2 && ly9>=9'd2 && r_full<ROWS && ay%9'd13<CAP_H && q_full<QUARTERS;
        s1_lx<=lx;
        s1_q<=q_full[5:0];
        s1_m<=ax%9'd5;
        s1_r<=r_full[2:0];
        s1_j<=ay%9'd13;
    end

    // stage 2: the key and the column in its cap
    wire [6:0] id=k1_key_at(s1_r,s1_q);
    wire [6:0] key_end={1'b0,k1_x(id)}+k1_w(id);
    wire in_cap=s1_zone && {1'b0,s1_q}>={1'b0,k1_x(id)} && {1'b0,s1_q}<key_end
                && !({1'b0,s1_q}==key_end-7'd1 && s1_m==3'd4);
    reg s2_in,s2_edge,s2_cap;
    reg [6:0] s2_id;
    reg [7:0] s2_c,s2_cw;
    reg [3:0] s2_j;
    always @(posedge clk) begin
        s2_in<=s1_in;s2_edge<=s1_edge;s2_cap<=in_cap;s2_id<=id;
        s2_c<=s1_lx-k1_cap_x(id);
        s2_cw<=k1_cap_w(id);
        s2_j<=s1_j;
    end

    // stage 3: the colour
    wire [24:0] lab=k1_label(s2_id,rus,sh,ct);
    wire [1:0] font=lab[24:23],n=lab[22:21];
    wire [6:0] line=k1_line(s2_id);
    wire lit=(!line[6] && pulled[line[5:0]]) || (line==7'd64 && sh) || (line==7'd65 && ct)
             || (line==7'd66 && rus_line) || (ct && k1_lit_ctrl(s2_id,rus,sh));
    wire sel=s2_id==selected;
    wire [7:0] half={1'b0,s2_cw[7:1]};
    wire [7:0] start=font==2'd2 ? half-{5'd0,n,1'b0}+8'd1         // 4x6: mid - (4n-1)/2
                    : n==2'd1 ? half-8'd3 : half-8'd3*{6'd0,n}+8'd1; // 6x8: mid - 3, or mid - 3n + 1
    wire [8:0] gx={1'b0,s2_c}-{1'b0,start};                           // bit 8: left of the label
    wire [1:0] k=font==2'd2 ? gx[3:2] : gx<9'd6 ? 2'd0 : gx<9'd12 ? 2'd1 : 2'd2;   // the character
    wire [8:0] gx8=gx-(k==2'd1 ? 9'd6 : k==2'd2 ? 9'd12 : 9'd0);
    wire [2:0] col=font==2'd2 ? {1'b0,gx[1:0]} : gx8[2:0];                         // its column
    wire [6:0] code=k==2'd0 ? lab[20:14] : k==2'd1 ? lab[13:7] : lab[6:0];
    wire [47:0] g8=native_glyph(code)|k1_arrow_glyph(code);
    wire [23:0] g4=k1_small_glyph(code);
    wire [3:0] gy8=s2_j-4'd2,gy4=s2_j-4'd3;
    wire on8=font==2'd1 && !gx[8] && gx<{5'd0,n,2'b0}+{6'd0,n,1'b0} && s2_j>=4'd2 && s2_j<4'd10
             && g8[6'd47-(gy8[2:0]*6'd6+{3'd0,col})];
    wire on4=font==2'd2 && !gx[8] && gx<{5'd0,n,2'b0} && s2_j>=4'd3 && s2_j<4'd9
             && g4[5'd23-(gy4[2:0]*5'd4+{3'd0,col[1:0]})];
    wire right=s2_c==s2_cw-8'd1,left=s2_c==8'd0;
    // colour caps: {face, highlight, shadow, label}, lit swaps face and label
    wire [95:0] set=sel ? K1_SELECTED_SET : k1_cap_set(pal,k1_role(s2_id));
    wire [23:0] face0=set[95:72],hi0=set[71:48],shd=set[47:24],fg0=set[23:0];
    wire [23:0] face=lit ? fg0 : face0,hi=lit ? fg0 : hi0,fg_c=lit ? face0 : fg0;
    wire [23:0] bevel=s2_j==4'd0 ? (right ? shd : hi) : s2_j>=CAP_H-4'd2 ? shd
                      : left ? hi : right ? shd : face;
    // mono caps: normal = black with a text outline, lit = inverted; selected adds an inner frame
    wire outline=s2_j==4'd0 || s2_j==CAP_H-4'd1 || left || right;
    wire frame=s2_j>=4'd1 && s2_j<=CAP_H-4'd2 && s2_c>=8'd2 && s2_c<=s2_cw-8'd3
               && (s2_j==4'd1 || s2_j==CAP_H-4'd2 || s2_c==8'd2 || s2_c==s2_cw-8'd3);
    wire [23:0] fg_m=lit ? 24'h000000 : text;
    wire [23:0] base_m=sel && frame ? fg_m : lit ? text : outline ? text : 24'h000000;
    wire [47:0] board=k1_board(pal);
    wire [23:0] cap_rgb=on8 || on4 ? (mono ? fg_m : fg_c) : mono ? base_m : bevel;
    wire [23:0] board_rgb=mono ? (s2_edge ? text : 24'h000000) : (s2_edge ? board[23:0] : board[47:24]);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin hit<=0;rgb<=0;end
        else begin
            hit<=open && s2_in;
            rgb<=s2_cap ? cap_rgb : board_rgb;
        end
    end
endmodule
`default_nettype wire
