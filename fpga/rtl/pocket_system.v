// The Pocket core logic behind the APF template (spec 5.1): the slot loader, the interact
// registers, the Radio-86RK board, the ROM disk in the PSRAM cram0 (pocket_psram), the frame banks,
// the audio, the PLL watchdog and the resets.
// core_top.v keeps the template's own parts (the bridge, the PLL instance, the pins) and only
// instantiates this module, so all of it can be simulated with a PLL stub (spec 9.6).
`default_nettype none
module pocket_system(
    input  wire        clk_74a,
    input  wire        clk_core_12288,
    input  wire        pll_locked,           // the PLL lock, asynchronous to clk_74a
    input  wire        pll_locked_s,         // the same through synch_3 in core_top
    output wire        pll_reset,            // to the PLL rst input (pocket_pll_watchdog)
    input  wire        reset_n,              // core_bridge_cmd: low until Reset Exit
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output reg  [31:0] rd_data,              // read data of 0x0000_0000-0x0000_01FF
    output wire        rd_selected,
    input  wire        status_boot_done,
    input  wire        status_setup_done,
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    output wire        dataslot_requestwrite_ack,
    output wire        dataslot_requestwrite_ok,
    input  wire        dataslot_allcomplete,
    input  wire [31:0] cont1_key,
    output wire [23:0] video_rgb,
    output wire        video_de,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_skip,
    output wire        audio_dac,
    output wire        audio_lrck,
    output wire        memory_ready,
    output wire [21:16] cram0_a,             // the PSRAM cram0 (pocket_psram): die 0, asynchronous
    inout  wire [15:0] cram0_dq,
    output wire        cram0_adv_n,
    output wire        cram0_ce0_n,
    output wire        cram0_ce1_n,
    output wire        cram0_oe_n,
    output wire        cram0_we_n,
    output wire        cram0_ub_n,
    output wire        cram0_lb_n,
    output wire        cram0_cre,
    output wire        cram0_clk
);
// The slot loader gets a power-up reset on clk_74a, not the PLL lock (spec 5.2, option A):
// clk_74a does not come from the PLL, so a lock loss changes neither assets_valid nor the
// memories, and the machine keeps running.
reg [3:0] por = 4'd0;
always @(posedge clk_74a)
    if (por != 4'hF) por <= por + 4'd1;
wire assets_reset_n = por == 4'hF;
pocket_pll_watchdog pll_watchdog(.clk(clk_74a), .locked_s(pll_locked_s), .pll_reset(pll_reset));

wire [31:0] native_frames, key_status, mode_status, interact_rd_data;
wire [15:0] byte_a;
wire [7:0] byte_d;
wire [15:0] machine_address;
wire assets_valid, monitor_we, font_we, interact_selected, warm_reset, cold_boot, sound_on, text_green, beeper;
wire romdisk_wr, romdisk_loaded, romdisk_64k, romdisk_card, psram_ready;
wire [20:0] romdisk_word;
wire [31:0] romdisk_data;
wire [22:0] romdisk_address;
wire [7:0] romdisk_byte;
wire [1:0] controls_preset, controls_escape, panel_palette;
wire [77:0] panel_state, panel_state_pixel;
wire controls_keys_on;
wire pixel_valid, pixel_data, pixel_start, pixel_end;
wire [16:0] pixel_address;
pocket_interact interact(.clk(clk_74a), .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
    .rd_data(interact_rd_data), .selected(interact_selected), .warm_reset(warm_reset), .cold_boot(cold_boot),
    .sound_on(sound_on), .green(text_green), .preset(controls_preset), .keys_on(controls_keys_on), .escape(controls_escape),
    .palette(panel_palette));
// The slot requests wait for the PSRAM (psram_ready, about 151 us after the power-up reset): the
// request is held from the loader, so its ack, and with it every bridge word of a slot, comes only
// after the controller's BCR write. pocket_psram buffers one bridge word and needs ready to write it.
// psram_ready stays high after that (the power-up reset only), so a later reload is not delayed.
pocket_slot_loader loader(.clk(clk_74a), .reset_n(assets_reset_n), .machine_quiesced(!reset_n),
    .request_write(dataslot_requestwrite && psram_ready), .request_id(dataslot_requestwrite_id),
    .request_size(dataslot_requestwrite_size),
    .request_ack(dataslot_requestwrite_ack), .request_ok(dataslot_requestwrite_ok), .allcomplete(dataslot_allcomplete),
    .bridge_wr(bridge_wr), .bridge_address(bridge_addr), .bridge_data(bridge_wr_data), .assets_valid(assets_valid),
    .monitor_we(monitor_we), .font_we(font_we), .romdisk_wr(romdisk_wr), .romdisk_word(romdisk_word),
    .romdisk_data(romdisk_data), .romdisk_loaded(romdisk_loaded), .romdisk_64k(romdisk_64k), .romdisk_card(romdisk_card),
    .byte_a(byte_a), .byte_d(byte_d));
// The ROM disk image in the PSRAM cram0. Its reset is the power-up reset only, never the core reset,
// Reset or Cold boot: each reset would wait tPU (151 us) again before the next read or write.
pocket_psram psram(.clk(clk_74a), .reset(!assets_reset_n), .ready(psram_ready),
    .wr(romdisk_wr), .wr_word(romdisk_word), .wr_data(romdisk_data),
    .rd_addr(romdisk_address), .rd_data(romdisk_byte), .rd_ready(),
    .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_adv_n(cram0_adv_n), .cram_ce0_n(cram0_ce0_n), .cram_oe_n(cram0_oe_n),
    .cram_we_n(cram0_we_n), .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n), .cram_ce1_n(cram0_ce1_n),
    .cram_cre(cram0_cre), .cram_clk(cram0_clk));
radio86rk_pocket rk86(.clk(clk_74a), .apf_reset_n(reset_n), .assets_valid(assets_valid),
    .warm_reset(warm_reset), .cold_boot(cold_boot), .sound_on(sound_on), .pad(cont1_key),
    .preset(controls_preset), .keys_on(controls_keys_on), .escape(controls_escape), .palette(panel_palette),
    .monitor_we(monitor_we), .font_we(font_we), .romdisk_loaded(romdisk_loaded), .romdisk_64k(romdisk_64k),
    .romdisk_card(romdisk_card), .romdisk_address(romdisk_address), .romdisk_data(romdisk_byte),
    .byte_a(byte_a), .byte_d(byte_d), .pixel_valid(pixel_valid), .pixel_data(pixel_data), .pixel_start(pixel_start), .pixel_end(pixel_end),
    .pixel_address(pixel_address), .beeper(beeper), .cpu_address(machine_address), .memory_ready(memory_ready),
    .native_frames(native_frames), .key_status(key_status), .mode_status(mode_status),
    .panel_state(panel_state));

// status (POC layout; 0x14, 0x1C, 0x20, 0x30, 0x38, 0x3C and 0x40 read 0) and the interact registers
assign rd_selected = bridge_addr[31:9] == 23'd0;
always @* begin
    case (bridge_addr)
        32'h00: rd_data = 32'h524B4D31;
        32'h08: rd_data = {27'd0, memory_ready, assets_valid, reset_n, status_setup_done, status_boot_done};
        32'h24: rd_data = {16'd0, machine_address};
        32'h28: rd_data = native_frames;
        32'h34: rd_data = key_status;
        32'h44: rd_data = mode_status;
        default: rd_data = interact_selected ? interact_rd_data : 32'd0;
    endcase
end

// video and audio in the PLL domain, held in reset while the lock is lost (as the POC core_top)
wire run_async = reset_n && pll_locked;
(* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] run_sync = 3'd0;
always @(posedge clk_core_12288 or negedge run_async)
    if (!run_async) run_sync <= 3'd0;
    else run_sync <= {run_sync[1:0], 1'b1};
// the K1 panel state to the pixel clock as a whole word (pocket_bus_cdc.sdc): the source side runs
// with the keyboard (core_bridge_cmd reset_n), the destination side with the video (run_sync[2])
pocket_bus_cdc #(.W(78)) panel_cdc(.src_clk(clk_74a), .src_reset_n(reset_n), .src_data(panel_state),
    .dst_clk(clk_core_12288), .dst_reset_n(run_sync[2]), .dst_data(panel_state_pixel));
pocket_frame_video video(.source_clk(clk_74a), .source_reset_n(reset_n && pll_locked_s),
    .pixel_clk(clk_core_12288), .pixel_reset_n(run_sync[2]),
    .pixel_valid(pixel_valid), .pixel_data(pixel_data), .frame_start(pixel_start), .frame_end(pixel_end),
    .pixel_address(pixel_address), .diagnostic_error(1'b0), .green(text_green),
    .panel_state(panel_state_pixel),
    .rgb(video_rgb), .de(video_de), .hs(video_hs), .vs(video_vs), .skip(video_skip),
    .audio_dac(), .audio_lrck(), .frames_completed(), .frames_dropped(), .frames_displayed());
pocket_audio audio(.mclk(clk_core_12288), .reset_n(run_sync[2]), .beeper(beeper),
    .dac(audio_dac), .lrck(audio_lrck), .debug_bclk());
endmodule
`default_nettype wire
