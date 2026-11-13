// The Radio-86RK board of the Analogue Pocket around rk86_machine16, the machine with the original
// 16 MHz timing (the core's src/rtl/rk86_16, spec 0.8.0), in one clock domain, clk_74a: the 16 MHz
// clock enable, the reset, the memory, the font, the ROM disk device, the keyboard, the native raster
// (pocket_raster) and the 408 x 300 display window (pocket_window), the beeper. The ROM disk image
// itself is in the PSRAM (pocket_psram in pocket_system): romdisk_address out, romdisk_data back.
`default_nettype none
module radio86rk_pocket(
    input  wire        clk,               // clk_74a
    input  wire        apf_reset_n,       // core_bridge_cmd reset_n: low until Reset Exit
    input  wire        assets_valid,
    input  wire        warm_reset,        // one clk: interact Reset (RAM kept)
    input  wire        cold_boot,         // one clk: interact Cold boot (RAM cleared)
    input  wire        sound_on,
    input  wire [31:0] pad,               // cont1_key
    input  wire  [1:0] preset,
    input  wire        keys_on,
    input  wire  [1:0] escape,
    input  wire  [1:0] palette,           // Keyboard colours (interact 0x118)
    input  wire        monitor_we,        // pocket_slot_loader: a monitor byte at byte_a[10:0]
    input  wire        font_we,           // a font byte at byte_a[9:0]
    input  wire        romdisk_loaded,    // pocket_slot_loader: a ROM disk image was accepted
    input  wire        romdisk_64k,       // the ROM disk image is above 32 KB: a 64 KB ROM
    input  wire        romdisk_card,      // the ROM disk image is above 64 KB: the J6 bank card
    output wire [22:0] romdisk_address,   // the ROM disk byte address A22-A0, to pocket_psram
    input  wire  [7:0] romdisk_data,      // its byte from pocket_psram
    input  wire [15:0] byte_a,
    input  wire  [7:0] byte_d,
    output wire        pixel_valid,
    output wire        pixel_data,
    output wire        pixel_start,
    output wire        pixel_end,
    output wire [16:0] pixel_address,
    output wire        beeper,
    output wire [15:0] cpu_address,
    output wire        memory_ready,
    output reg  [31:0] native_frames = 32'd0,
    output wire [31:0] key_status,        // bridge 0x34: {panel_open, selection[6:0]}
    output wire [31:0] mode_status,       // bridge 0x44: {dock, shift latch, RUS, Ctrl, Shift lines, rus_mode}
    output wire [77:0] panel_state        // the K1 panel state (pocket_k1_panel), clk domain
);
//--------- the clock enable: 64 of 297 clk_74a: 16 MHz on average (spec 4.5) -----
reg [8:0] cadence = 9'd0;
wire [9:0] cadence_sum = {1'b0, cadence} + 10'd64;
wire ce_next = cadence_sum >= 10'd297;
reg ce16 = 1'b0;
always @(posedge clk) begin
    cadence <= ce_next ? cadence_sum - 10'd297 : cadence_sum[8:0];
    ce16 <= ce_next;
end

//--------- the cold clear: first boot and Cold boot (spec 5.2), only after the slots ----------
wire clear_active, clear_we, clear_done;
wire [14:0] clear_a;
wire [7:0] clear_d;
pocket_cold_clear clear(.clk(clk), .start(assets_valid && (cold_boot || !clear_done)), .active(clear_active),
    .we(clear_we), .a(clear_a), .d(clear_d), .done(clear_done));
assign memory_ready = clear_done && !clear_active;
// the loader port of pocket_memory: the monitor bytes of the slot loader until assets_valid, then
// the cold clear of 0000-7FFF (the machine is in reset in both)
wire load_active = clear_active || !assets_valid;
wire load_we = clear_active ? clear_we : monitor_we;
wire [15:0] load_a = clear_active ? {1'b0, clear_a} : {5'b10000, byte_a[10:0]};
wire [7:0] load_d = clear_active ? clear_d : byte_d;

//--------- the machine reset: every source is a clk register; held 144 ce16 (spec 4.2) ----
wire run = apf_reset_n && assets_valid && memory_ready && !warm_reset;
reg [7:0] rst_cnt = 8'd0;
always @(posedge clk)
    if (!run) rst_cnt <= 8'd0;
    else if (ce16 && rst_cnt != 8'd144) rst_cnt <= rst_cnt + 8'd1;
wire reset = rst_cnt != 8'd144;

//--------- the machine --------------
wire [15:0] bus_a;
wire [7:0] cpu_do, mem_di, kbd_rows, kbd_cols, ext_di;
wire [2:0] kbd_shift;
wire mem_rd, cpu_wr_n, rom, startup, aen, pc0, inte, ext_we_n, ext_rd_n;
wire pix_ce, pix, hrtc, vrtc;
wire [15:0] machine_cpu_a;
wire [9:0] font_address;
wire [7:0] font_data;
rk86_machine16 machine(.clk(clk), .ce16(ce16), .reset(reset), .cpu_a(machine_cpu_a),
    .bus_a(bus_a), .cpu_do(cpu_do), .mem_rd(mem_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup), .aen(aen),
    .mem_di(mem_di), .ppa_pa(kbd_rows), .kbd_cols(kbd_cols), .kbd_shift(kbd_shift), .tape_in(1'b1),
    .pc0(pc0), .inte(inte), .font_addr(font_address), .font_data(font_data),
    .pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc), .ext_we_n(ext_we_n), .ext_rd_n(ext_rd_n), .ext_di(ext_di));
assign cpu_address = machine_cpu_a;   // status register: the CPU's address, as before

//--------- memory, the font, the ROM disk in the A000-BFFF block (second 8255) --------------
wire cpu_write, rus_mode;
pocket_memory mem(.clk(clk), .reset(reset), .bus_a(bus_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom),
    .aen(aen), .mem_rd(mem_rd), .mem_di(mem_di), .cpu_write(cpu_write), .load_active(load_active),
    .load_we(load_we), .load_a(load_a), .load_d(load_d), .rus_mode(rus_mode));
pocket_rom8 #(.AW(10), .FILL(8'h00)) font_rom(.clk(clk), .we(font_we), .wa(byte_a[9:0]), .wd(byte_d),
    .ra(font_address), .rd(font_data), .tag());
// the A000-BFFF block (second 8255; the machine's "window": ext_rd_n, ext_we_n, ext_di). The decoder looks
// only at A15-A13 and gates ext_rd_n / ext_we_n, so CS is tied active. The 8255's pins A1, A0 pick one of
// its 4 registers; they take address lines A1, A0 of bus_a (the CPU's address, the 8257's during DMA), so
// the registers repeat every 4 bytes. The ROM disk is in the PSRAM: without an image (romdisk_loaded low)
// port A reads FF; beyond the end of a shorter image it reads whatever the PSRAM holds there.
// The card follows the image size: up to 32 KB a 32 KB ROM (A15 not wired: 8000-FFFF mirror 0000-7FFF),
// up to 64 KB a 64 KB ROM (PC7 = A15), above 64 KB the J6 bank card (a bank latch loaded when port C goes
// to 7F with PC7 falling). The machine reset keeps the bank; power-up, a slot load and Cold boot clear it.
pocket_cart_ppi cart(.clk(clk), .reset(reset), .card_reset(!apf_reset_n || cold_boot), .cs_n(1'b0),
    .rd_n(ext_rd_n), .wr_n(ext_we_n), .wide(romdisk_64k), .card(romdisk_card), .loaded(romdisk_loaded), .a(bus_a[1:0]), .d_i(cpu_do), .d_o(ext_di),
    .rom_address(romdisk_address), .rom_data(romdisk_data));

//--------- keyboard --------------
wire [69:0] button_map;
wire [7:0] pad_cols;
wire [2:0] pad_mods;
wire panel_open, shift_line, ctrl_line, rus_line, shift_latch, dock_keyboard;
wire [6:0] selection;
wire [63:0] pulled;
pocket_remap remap(.preset(preset), .keys_on(keys_on), .escape(escape), .map(button_map));
pocket_keyboard keyboard(.clk(clk), .reset_n(apf_reset_n), .enable(assets_valid && memory_ready),
    .clear_latch(warm_reset || cold_boot), .pad(pad),
    .rows(kbd_rows), .map(button_map), .russian_mode(rus_mode), .columns(pad_cols), .modifiers(pad_mods),
    .panel_open(panel_open), .selection(selection), .pulled(pulled), .shift_line(shift_line),
    .ctrl_line(ctrl_line), .rus_line(rus_line), .shift_latch(shift_latch), .dock_keyboard(dock_keyboard));
// the second matrix source, the Dock USB keyboard, is reserved (spec 10): no key pressed
wire [7:0] hid_cols = 8'hFF;
wire [2:0] hid_mods = 3'b111;
assign kbd_cols = pad_cols & hid_cols;
assign kbd_shift = pad_mods & hid_mods;
assign key_status = {24'd0, panel_open, selection};
assign mode_status = {26'd0, dock_keyboard, shift_latch, rus_line, ctrl_line, shift_line, rus_mode};
// the K1 panel state bus (task-2 layout): {palette, pulled, rus_line, ct, sh, rus, selection, open},
// held and crossed to the pixel clock in pocket_system (pocket_bus_cdc)
assign panel_state = {palette, pulled, rus_line, ctrl_line, shift_line, rus_mode, selection, panel_open};

//--------- the native raster and the display window (the K1 panel is drawn in pocket_frame_video) ----------
wire [10:0] h_cnt, v_cnt;
wire s_ce, s_dot, s_fs;
pocket_raster raster(.clk(clk), .pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc),
    .ce(s_ce), .dot(s_dot), .h_cnt(h_cnt), .v_cnt(v_cnt), .frame_start(s_fs));
pocket_window window(.clk(clk), .s_ce(s_ce), .s_dot(s_dot), .s_frame_start(s_fs), .h_cnt(h_cnt), .v_cnt(v_cnt),
    .valid(pixel_valid), .data(pixel_data), .start(pixel_start), .finish(pixel_end), .address(pixel_address));
always @(posedge clk)
    if (s_ce && s_fs) native_frames <= native_frames + 32'd1;

//--------- the beeper: INTE only, registered, as on the Радио 1986 board (D9.1) and Kiselev 1.4 (U16C);
// was pc0 ^ inte, the replica's choice (spec 4.5). pc0 is the tape output, unused on the Pocket.
reg beeper_level = 1'b0;
always @(posedge clk)
    beeper_level <= reset ? 1'b0 : sound_on && inte;
assign beeper = beeper_level;
endmodule
`default_nettype wire
