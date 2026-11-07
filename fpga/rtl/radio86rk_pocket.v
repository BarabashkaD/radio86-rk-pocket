// The Radio-86RK board of the Analogue Pocket around the board-neutral machine of the Karabas
// core (rk86_machine, rk86_video, rk86_video_stream; docs/integration.md of the core), in one
// clock domain, clk_74a (spec 5.1-5.6). Starts from the core's src/rk86_candidate.v.
`default_nettype none
module radio86rk_pocket(
    input  wire        clk,               // clk_74a
    input  wire        apf_reset_n,       // core_bridge_cmd reset_n: low until Reset Exit
    input  wire        assets_valid,
    input  wire        cartridge_valid,
    input  wire        warm_reset,        // one clk: interact Reset (RAM kept)
    input  wire        cold_boot,         // one clk: interact Cold boot (RAM cleared)
    input  wire        sound_on,
    input  wire [31:0] pad,               // cont1_key
    input  wire  [1:0] preset,
    input  wire        keys_on,
    input  wire  [1:0] escape,
    output wire [10:0] monitor_address,
    input  wire  [7:0] monitor_data,
    input  wire [10:0] monitor_tag,
    output wire  [9:0] font_address,
    input  wire  [7:0] font_data,
    output wire [14:0] cartridge_address,
    input  wire [14:0] cartridge_tag,
    input  wire  [7:0] cartridge_data,
    output wire        pixel_valid,
    output wire        pixel_data,
    output wire        pixel_start,
    output wire        pixel_end,
    output wire [16:0] pixel_address,
    output wire        beeper,
    output wire [15:0] cpu_address,
    output wire        memory_ready,
    output reg  [31:0] native_frames = 32'd0,
    output wire [31:0] key_status,        // bridge 0x34 (POC layout)
    output wire [31:0] mode_status        // bridge 0x44: {dock, ctrl, shift, rus, fx}
);
//--------- the clock enable: 160 of 297 clk, 40 M ce/s on average (docs/integration.md 2) -----
reg [8:0] cadence = 9'd0;
wire [9:0] cadence_sum = {1'b0, cadence} + 10'd160;
wire ce_next = cadence_sum >= 10'd297;
reg ce = 1'b0;
always @(posedge clk) begin
    cadence <= ce_next ? cadence_sum - 10'd297 : cadence_sum[8:0];
    ce <= ce_next;
end

//--------- the cold clear: first boot and Cold boot (spec 5.2) --------------
wire clear_active, clear_we, clear_done;
wire [14:0] clear_a;
wire [7:0] clear_d;
pocket_cold_clear clear(.clk(clk), .start(cold_boot || (assets_valid && !clear_done)), .active(clear_active),
    .we(clear_we), .a(clear_a), .d(clear_d), .done(clear_done));
assign memory_ready = clear_done && !clear_active;

//--------- the machine reset: every source is a clk register; held 15 ce (integration.md 3) ----
wire run = apf_reset_n && assets_valid && memory_ready && !warm_reset;
reg [3:0] rst_cnt = 4'd0;
always @(posedge clk)
    if (!run) rst_cnt <= 4'd0;
    else if (ce && rst_cnt != 4'hF) rst_cnt <= rst_cnt + 4'd1;
wire reset = rst_cnt != 4'hF;

//--------- the machine --------------
wire [15:0] cpu_a, vid_a;
wire [7:0] cpu_do, mem_di, kbd_rows, kbd_cols, ext_di;
wire [2:0] kbd_shift;
wire cpu_rd, cpu_wr_n, rom, startup, vid_rd, cpu_ready, pc0, inte, ext_we_n;
wire cce, hrtc, vrtc, lten, vsp, rvv, hilight, irq;
wire [3:0] line;
wire [6:0] ochar;
wire [1:0] lattr, gattr;
rk86_machine machine(.clk(clk), .ce(ce), .reset(reset), .cpu_ready(cpu_ready),
    .cce(cce), .hrtc(hrtc), .vrtc(vrtc),
    .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_rd(cpu_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup),
    .vid_a(vid_a), .vid_rd(vid_rd), .mem_di(mem_di),
    .ppa_pa(kbd_rows), .kbd_cols(kbd_cols), .kbd_shift(kbd_shift), .tape_in(1'b1),
    .pc0(pc0), .inte(inte),
    .line(line), .ochar(ochar), .lten(lten), .vsp(vsp), .rvv(rvv), .hilight(hilight),
    .lattr(lattr), .gattr(gattr), .irq(irq), .ext_we_n(ext_we_n), .ext_di(ext_di));
assign cpu_address = cpu_a;

//--------- memory and the ROM disk window --------------
wire cart_ready, cpu_write, rus_mode;
pocket_memory mem(.clk(clk), .reset(reset), .cpu_a(cpu_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom),
    .vid_a(vid_a), .vid_rd(vid_rd), .window_ready(cart_ready), .mem_di(mem_di), .cpu_ready(cpu_ready),
    .cpu_write(cpu_write), .rom_addr(monitor_address), .rom_data(monitor_data), .rom_tag(monitor_tag),
    .load_active(clear_active), .load_we(clear_we), .load_a(clear_a), .load_d(clear_d), .rus_mode(rus_mode));
pocket_cart_ppi cart(.clk(clk), .reset(reset), .write_strobe(cpu_write && cpu_a[15:13] == 3'd5),
    .register_address(cpu_a[1:0]), .write_data(cpu_do), .read_data(ext_di), .rom_valid(cartridge_valid),
    .rom_address(cartridge_address), .rom_tag(cartridge_tag), .rom_data(cartridge_data), .read_ready(cart_ready));

//--------- keyboard --------------
wire [69:0] button_map;
wire [7:0] pad_cols;
wire [2:0] pad_mods;
wire panel_open, fx_page, shift_pending, ctrl_pending, key_valid, armed, dock_keyboard;
wire [5:0] selection;
wire [6:0] key_ascii;
pocket_remap remap(.preset(preset), .keys_on(keys_on), .escape(escape), .map(button_map));
pocket_keyboard keyboard(.clk(clk), .reset_n(apf_reset_n), .enable(assets_valid && memory_ready), .pad(pad),
    .rows(kbd_rows), .map(button_map), .russian_mode(rus_mode), .columns(pad_cols), .modifiers(pad_mods),
    .panel_open(panel_open), .fx_page(fx_page), .selection(selection), .shift_pending(shift_pending),
    .ctrl_pending(ctrl_pending), .key_valid(key_valid), .key_ascii(key_ascii), .armed(armed),
    .dock_keyboard(dock_keyboard));
// the second matrix source, the Dock USB keyboard, is reserved (spec 10): no key pressed
wire [7:0] hid_cols = 8'hFF;
wire [2:0] hid_mods = 3'b111;
assign kbd_cols = pad_cols & hid_cols;
assign kbd_shift = pad_mods & hid_mods;
assign key_status = {15'd0, armed, key_valid, panel_open, selection, key_ascii, 1'b0};
assign mode_status = {27'd0, dock_keyboard, ctrl_pending, shift_pending, rus_mode, fx_page};

//--------- the native video, the window, the on-screen keyboard --------------
wire pix_ce, pix;
wire [10:0] h_cnt, v_cnt;
rk86_video native_video(.clk(clk), .ce(ce), .line(line), .ichar(ochar), .vsp(vsp), .lten(lten), .rvv(rvv),
    .cce(cce), .hrtc(hrtc), .vrtc(vrtc), .font_addr(font_address), .font_data(font_data),
    .pix_ce(pix_ce), .pix(pix), .h_cnt(h_cnt), .v_cnt(v_cnt));
wire s_ce, s_de, s_dot, s_hs, s_vs, s_ls, s_fs, s_le, s_fe;
rk86_video_stream stream(.pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc), .h_cnt(h_cnt), .v_cnt(v_cnt),
    .ce(s_ce), .de(s_de), .dot(s_dot), .hs(s_hs), .vs(s_vs),
    .line_start(s_ls), .frame_start(s_fs), .line_end(s_le), .frame_end(s_fe));
wire w_valid, w_data, w_start, w_end;
wire [16:0] w_address;
pocket_window window(.clk(clk), .s_ce(s_ce), .s_dot(s_dot), .s_frame_start(s_fs), .h_cnt(h_cnt), .v_cnt(v_cnt),
    .valid(w_valid), .data(w_data), .start(w_start), .finish(w_end), .address(w_address));
pocket_keyboard_overlay overlay(.clk(clk), .reset_n(apf_reset_n), .panel_open(panel_open), .fx_page(fx_page),
    .russian_mode(rus_mode), .shift_pending(shift_pending), .ctrl_pending(ctrl_pending), .selection(selection),
    .pixel_valid(w_valid), .pixel_data(w_data), .frame_start(w_start), .frame_end(w_end), .pixel_address(w_address),
    .out_valid(pixel_valid), .out_data(pixel_data), .out_start(pixel_start), .out_end(pixel_end),
    .out_address(pixel_address));
always @(posedge clk)
    if (s_ce && s_fs) native_frames <= native_frames + 32'd1;

//--------- the beeper: the Karabas BEEPER source pc0 ^ inte, registered (spec 3) --------------
reg beeper_level = 1'b0;
always @(posedge clk)
    beeper_level <= reset ? 1'b0 : sound_on && (pc0 ^ inte);
assign beeper = beeper_level;
endmodule
`default_nettype wire
