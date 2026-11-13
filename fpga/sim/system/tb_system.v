`timescale 1ns/1ps
`default_nettype none
// System testbench of the Pocket target (spec 9.4-9.7): pocket_system with the bridge and data
// slot signals driven as core_bridge_cmd drives them, and a PLL stub (clk_core_12288 and its
// lock: the scenario drops the lock, and the PLL reset of the watchdog unlocks it for 1000 clk).
// +scenario=boot|powerup|nocart|reset|relock|watchdog|menu|menu64|card|xonix|game|dpddt|tetris|keytap|k1|k1_panel
// The machine is rk86_machine16 (16 MHz, 50 Hz native frames); compile with -I <core>/src/sim/machine16
// (cpu_power_up.vh, included by power_up.vh).
// The ROM disk is in the PSRAM: psram_model (fpga/sim/memory, AW = 16: 128 KB, FF-filled) on the cram0
// pins of pocket_system; psram_byte(i) reads ROM disk byte i from it (the packed mapping of
// pocket_psram). Every slot word goes at APF's rate (slot_write: one bridge word per 88 clk), and none
// before the controller is ready (its BCR write, 151 us after the power-up reset): pocket_system holds
// the slot requests until then, and slot and slot_write check it.
// Working directory: monitor.hex, font.hex, cartridge.hex (fpga/sim/run_sim.py); writes frame.hex and
// cursor.txt (the cursor cell for frame_compare.py --cursor); +cart_size=N: the ROM disk slot size
// (default 32256, Kiselev's image; menu64: 65536, game disk 2; card: 131072, the card image of the card
// menu and disk 2, with +card_keywait=N: the card menu's key wait); game also reads cartridge2.hex (a 64 KB
// game disk) and reloads the ROM disk slot with it while the core runs, as the Pocket menu does;
// k1 writes k1_<n>.hex (the RGB output of one displayed frame, 408 x 300, one RRGGBB per pixel)
// and k1.log (STEP lines and, per capture, "STATE <n> <panel state hex> <green> <what>", the state
// pocket_frame_video latched for that frame; scripts/k1/check_frames.py renders the model for it).
// k1_panel (run_sim.py test system_k1_panel, CI): the panel with the machine frozen (ce16 held low), 3
// captures (palettes 0, 1, 2).
// The keyboard timings run on a 10x shorter base: pocket_keyboard CLK_HZ = 7425000, so each of its
// millisecond parameters (TAP_MS, CHORD_MS, ...) lasts a tenth of its time in the build (keytap
// forces its tick back to real milliseconds).
// The ROM disk scenarios type through the reserved second keyboard input (hid_cols / hid_mods of
// radio86rk_pocket, forced here from kbd_rows: a TB key is a real matrix key), not through the panel.
`include "power_up.vh"
module tb_system;
`include "pocket_k1_layout.vh"               // k1_row / k1_line of the K1 key ids
defparam sys.pll_watchdog.TIMEOUT = 20000;   // 270 us here; 28 ms in the build
defparam sys.rk86.keyboard.CLK_HZ = 7425000; // the keyboard's milliseconds 10x shorter (header)
reg clk = 1'b0, clk_av = 1'b0;
always #6.734 clk = ~clk;                    // clk_74a, 74.25 MHz
always #40.690 clk_av = ~clk_av;             // clk_core_12288 of the PLL
reg tb_lock = 1'b1;                          // the scenario's lock
reg stub_down = 1'b0;                        // the PLL in reset or locking again after it
integer relock_cnt = 0;
wire pll_reset;
always @(posedge clk) begin
    if (pll_reset) begin stub_down <= 1'b1; relock_cnt <= 1000; end
    else if (relock_cnt != 0) relock_cnt <= relock_cnt - 1;
    else stub_down <= 1'b0;
end
wire pll_locked = tb_lock && !stub_down;
reg [2:0] lock_sync = 3'b000;                // as synch_3 in core_top
always @(posedge clk) lock_sync <= {lock_sync[1:0], pll_locked};
reg reset_n = 1'b0, request = 1'b0, complete = 1'b0, wr = 1'b0;
reg [15:0] id = 16'd0;
reg [31:0] size = 32'd0, address = 32'd0, data = 32'd0;
reg [31:0] pad = {4'h1, 28'h0};
wire ack, ok, rd_selected, memory_ready, de, hs, vs, skip, dac, lrck;
wire [31:0] rd_data;
wire [23:0] rgb;
wire [21:16] cram0_a;
wire [15:0] cram0_dq;
wire cram0_adv_n, cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n, cram0_ub_n, cram0_lb_n, cram0_cre, cram0_clk;
pocket_system sys(.clk_74a(clk), .clk_core_12288(clk_av), .pll_locked(pll_locked), .pll_locked_s(lock_sync[2]),
    .pll_reset(pll_reset), .reset_n(reset_n), .bridge_wr(wr), .bridge_addr(address), .bridge_wr_data(data),
    .rd_data(rd_data), .rd_selected(rd_selected), .status_boot_done(lock_sync[2]), .status_setup_done(1'b0),
    .dataslot_requestwrite(request), .dataslot_requestwrite_id(id), .dataslot_requestwrite_size(size),
    .dataslot_requestwrite_ack(ack), .dataslot_requestwrite_ok(ok), .dataslot_allcomplete(complete),
    .cont1_key(pad), .video_rgb(rgb), .video_de(de), .video_hs(hs), .video_vs(vs), .video_skip(skip),
    .audio_dac(dac), .audio_lrck(lrck), .memory_ready(memory_ready),
    .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_adv_n(cram0_adv_n), .cram0_ce0_n(cram0_ce0_n),
    .cram0_ce1_n(cram0_ce1_n), .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n),
    .cram0_lb_n(cram0_lb_n), .cram0_cre(cram0_cre), .cram0_clk(cram0_clk));
// the PSRAM die 0 of cram0, 128 KB (AW = 16; card: banks 0 and 1): an access beyond it is an ERROR, never aliased
psram_model #(.AW(16)) psram(.a(cram0_a), .dq(cram0_dq), .adv_n(cram0_adv_n), .ce0_n(cram0_ce0_n),
    .ce1_n(cram0_ce1_n), .oe_n(cram0_oe_n), .we_n(cram0_we_n), .ub_n(cram0_ub_n), .lb_n(cram0_lb_n),
    .cre(cram0_cre), .clk(cram0_clk));
// ROM disk byte i in the PSRAM: word i / 2, D7-D0 for an even i, D15-D8 for an odd one
function [7:0] psram_byte(input integer i);
    reg [15:0] w;
    begin
        w = psram.mem[i >> 1];
        psram_byte = i[0] ? w[15:8] : w[7:0];
    end
endfunction

reg [7:0] monitor [0:2047];
reg [7:0] font [0:1023];
reg [7:0] cart [0:131071];           // cartridge.hex: the image, FF-padded to 64 KB, or the 128 KB card image (run_sim.py)
integer cart_size;                      // +cart_size: the ROM disk slot size (default Kiselev's 32256)
integer card_keywait;                   // card: +card_keywait, the card menu's key wait (card.json keywait)
reg [7:0] cart2 [0:65535];           // game: cartridge2.hex, the 64 KB game disk loaded by the reload
integer cart2_size = 65536;
reg frame [0:122399];
reg capture_go = 1'b0, capturing = 1'b0, capture_done = 1'b0;
always @(posedge clk)
    if (capture_go && !capture_done && sys.pixel_valid) begin
        if (sys.pixel_start) capturing <= 1'b1;
        if (sys.pixel_start || capturing) begin
            frame[sys.pixel_address] <= sys.pixel_data;
            if (sys.pixel_end) begin capturing <= 1'b0; capture_done <= 1'b1; end
        end
    end
// K1: the RGB output of one displayed frame. From a video_vs, video_rgb is taken while video_de
// (408 x 300 pixels, row by row), with the panel state pocket_frame_video latched for the frame
// (at x == 0, y == 0, 3 clk before vs). vs_count counts the displayed frames (the vs pulses).
reg [23:0] rgb_frame [0:122399];
reg rgb_go = 1'b0, rgb_on = 1'b0, rgb_done = 1'b0;
reg [77:0] rgb_state = 78'd0;
reg rgb_green = 1'b0;
integer rgb_count = 0, vs_count = 0;
always @(posedge clk_av) begin
    if (vs) vs_count = vs_count + 1;
    if (rgb_go && !rgb_done) begin
        if (vs) begin
            if (rgb_on) begin $display("ERROR: RGB capture: vs after %0d pixels", rgb_count); $finish; end
            rgb_on <= 1'b1; rgb_count <= 0; rgb_state <= sys.video.frame_state; rgb_green <= sys.video.green_sync[2];
        end else if (rgb_on && de) begin
            rgb_frame[rgb_count] <= rgb;
            rgb_count <= rgb_count + 1;
            if (rgb_count == 122399) begin rgb_on <= 1'b0; rgb_done <= 1'b1; end
        end
    end
end
// keyboard reads of the CPU (PPI port B, 8001): the monitor's scans
integer kbd_reads = 0;
reg prev_kbd_read = 1'b0;
always @(posedge clk) begin
    prev_kbd_read <= sys.rk86.machine.cpu_dbin && sys.rk86.machine.cpu_a == 16'h8001;
    if (sys.rk86.machine.cpu_dbin && sys.rk86.machine.cpu_a == 16'h8001 && !prev_kbd_read) kbd_reads = kbd_reads + 1;
end
// during a PLL lock loss the machine must never be reset and the assets must stay valid
reg guard_lock = 1'b0;
always @(posedge clk)
    if (guard_lock && (sys.rk86.reset || !sys.assets_valid)) begin
        $display("ERROR: PLL lock loss reached the machine: reset %b, assets_valid %b", sys.rk86.reset, sys.assets_valid);
        $finish;
    end
reg [8*16-1:0] scenario;
integer i, guard, n, start_frame;
integer game_key, game_ram, game_rom, game_len;
localparam [15:0] B_UP = 16'h0001, B_DOWN = 16'h0002, B_LEFT = 16'h0004, B_RIGHT = 16'h0008, B_A = 16'h0010,
                  B_B = 16'h0020, B_L = 16'h0100, B_R = 16'h0200;
localparam [6:0] KEY_VK = 7'd10, NO_KEY = 7'd127;    // matrix key ВК; no key
// the second keyboard input: tb_key (a matrix key 0..63, or NO_KEY) pulls its column while its row is scanned
reg [6:0] tb_key = NO_KEY;
wire [7:0] tb_hid_cols = tb_key < 7'd64 && !sys.rk86.kbd_rows[tb_key[5:3]] ? ~(8'd1 << tb_key[2:0]) : 8'hFF;
wire [2:0] tb_hid_mods = 3'b111;
wire [31:0] frames = sys.native_frames;
// Hang limits of the waits, in native frames (50 Hz). They catch hangs, not speed: each is about 1.5
// times the frames measured on the 16 MHz machine (the remote runs of 2026-11-11) plus 3, and every
// wait prints an INFO line with the frames it used (vvp.log), so a run shows how close it came.
localparam integer FE63_FRAMES = 15;  // FE63 after the boot, a Reset or a Cold boot: frame 6-8 measured
localparam integer LOOP_FRAMES = 5;   // FE63 again while the monitor is in its keyboard loop: within 1
localparam integer KEY_FRAMES = 8;    // a key delivered, or its release seen: 2-3 frames per key (k1)
localparam integer ECHO_FRAMES = 5;   // the echo of a delivered key, RUS after the R release: within 1
localparam integer MENU_FRAMES = 50;  // G0 to the ROM disk menu (741C): not measured alone; at most 30
                                      // frames of the menu run's 58 (boot 8, 13 keys, the R copy)
// A program copied from the ROM disk: TETRIS (1632 bytes) started about 11 frames after its key, about
// 150 bytes a frame; the limit takes 100 bytes a frame (1.5 times slower) plus 10 frames for the key and
// the start.
function integer copy_frames(input integer bytes);
    copy_frames = bytes / 100 + 10;
endfunction
// native_frames counts pocket_raster's frame starts, which come only for plausible frames: before the
// monitor programs the CRT no frame is counted, so a frame-based wait would never end on a hang there.
// Fallback: out of reset, a frame start at least every 3 200 000 ce16 (10 frames of 319 920 ce16, as
// the fork's VE_LIMIT; the boot's first frame start comes about 2 frames after the reset).
localparam integer NO_FRAME_CE16 = 3200000;
integer no_frame_ce16 = 0;
reg [31:0] last_frames = 32'd0;
always @(posedge clk) begin
    if (sys.rk86.reset || frames != last_frames) no_frame_ce16 <= 0;
    else if (sys.rk86.ce16) no_frame_ce16 <= no_frame_ce16 + 1;
    last_frames <= frames;
    if (no_frame_ce16 >= NO_FRAME_CE16) begin
        $display("FATAL: tb_system: no plausible frame within 10 frames of ce16 (frame %0d, cpu %h)",
                 frames, sys.rk86.machine.cpu_a);
        $finish;
    end
end
// The native frame period: the ce16 between two frame starts with no machine reset between them must
// be 516 x 310 dots of 2 ce16 = 319 920 (boot and powerup want at least two such periods; the 8275
// Reset of the monitor's second video init gives one other period).
localparam integer FRAME_CE16 = 319920;
integer period_ce16 = 0, periods_ok = 0, periods_other = 0;
reg period_on = 1'b0;
always @(posedge clk)
    if (sys.rk86.reset) begin period_on <= 1'b0; period_ce16 <= 0; end
    else if (frames != last_frames) begin
        if (period_on) begin
            if (period_ce16 + sys.rk86.ce16 == FRAME_CE16) periods_ok <= periods_ok + 1;
            else periods_other <= periods_other + 1;
        end
        period_on <= 1'b1; period_ce16 <= 0;
    end else if (sys.rk86.ce16) period_ce16 <= period_ce16 + 1;
task info_wait(input [8*48-1:0] what, input integer used, input integer limit);
    $display("INFO: %0s: %0d frames (limit %0d)", what, used, limit);
endtask
// The beeper (spec 4.5): INTE only, registered: at every clk from the first release of the machine
// reset, beeper equals the previous clk's !reset && sound_on && inte.
reg beeper_armed = 1'b0, beeper_exp = 1'b0;
always @(posedge clk) begin
    beeper_exp <= !sys.rk86.reset && sys.sound_on && sys.rk86.inte;
    if (!sys.rk86.reset) beeper_armed <= 1'b1;
end
always @(negedge clk)
    if (beeper_armed && sys.rk86.beeper !== beeper_exp) fail("beeper does not follow INTE");
// The cursor (frame_compare.py --cursor): after a CPU write of 80h (Load Cursor) to the 8275's
// command port (C001), the next two writes to its parameter port (C000) are the column and the row.
reg [1:0] cursor_params = 2'd0;
reg [7:0] cursor_col = 8'd0, cursor_row = 8'd0;
reg cursor_known = 1'b0;
always @(posedge clk)
    if (sys.rk86.cpu_write && sys.rk86.machine.cpu_a[15:13] == 3'b110) begin
        if (sys.rk86.machine.cpu_a[0]) cursor_params <= sys.rk86.cpu_do == 8'h80 ? 2'd2 : 2'd0;
        else if (cursor_params == 2'd2) begin cursor_col <= sys.rk86.cpu_do; cursor_params <= 2'd1; end
        else if (cursor_params == 2'd1) begin cursor_row <= sys.rk86.cpu_do; cursor_params <= 2'd0; cursor_known <= 1'b1; end
    end

task fail(input [8*64-1:0] what);
    begin $display("ERROR: %0s (frame %0d, cpu %h)", what, frames, sys.rk86.machine.cpu_a); $finish; end
endtask
task bridge_write(input [31:0] a, input [31:0] d);
    begin @(negedge clk); address = a; data = d; wr = 1'b1; @(negedge clk); wr = 1'b0; repeat (4) @(negedge clk); end
endtask
// A slot request as core_bridge_cmd makes it: held until the ack. The first one after the power-up
// waits there for the PSRAM controller (pocket_system holds the requests until psram_ready, about
// 11 200 clk): an ack before ready is an ERROR.
task slot(input [15:0] slot_id, input [31:0] bytes);
    begin
        @(negedge clk); id = slot_id; size = bytes; request = 1'b1; guard = 0;
        while (!ack && guard < 20000) begin @(negedge clk); guard = guard + 1; end
        if (!ack || !ok) fail("slot refused");
        if (!sys.psram_ready) fail("a slot request taken before the PSRAM controller is ready");
        request = 1'b0; repeat (3) @(negedge clk);
    end
endtask
// a slot word at APF's rate (at most one bridge word per 88 clk, fpga/apf/io_bridge_peripheral.v):
// bridge_write (6 clk) and 82 clk idle; pocket_psram buffers one ROM disk word and writes it in 26 clk
task slot_write(input [31:0] a, input [31:0] d);
    begin
        if (!sys.psram_ready) fail("a slot word before the PSRAM controller is ready");
        bridge_write(a, d); repeat (82) @(negedge clk);
    end
endtask
task load(input with_cart);
    begin
        repeat (20) @(negedge clk);              // the power-up reset of the slot loader
        slot(0, 2048);                           // waits for psram_ready (pocket_system)
        $display("INFO: PSRAM controller ready, first slot request taken at %0t ps", $time);
        for (i = 0; i < 512; i = i + 1) slot_write(32'h2000_0000 + 4*i, {monitor[4*i], monitor[4*i+1], monitor[4*i+2], monitor[4*i+3]});
        slot(1, 1024);
        for (i = 0; i < 256; i = i + 1) slot_write(32'h2100_0000 + 4*i, {font[4*i], font[4*i+1], font[4*i+2], font[4*i+3]});
        if (with_cart) begin
            slot(2, cart_size);
            for (i = 0; i < cart_size / 4; i = i + 1) slot_write(32'h2200_0000 + 4*i, {cart[4*i], cart[4*i+1], cart[4*i+2], cart[4*i+3]});
        end
        complete = 1'b1; guard = 0;
        while (!sys.assets_valid && guard < 200000) begin @(negedge clk); guard = guard + 1; end
        if (!sys.assets_valid) fail("assets not valid");
        for (i = 0; i < 2048; i = i + 1) if (sys.rk86.mem.ram[32768 + i] !== monitor[i]) fail("the monitor is not in the memory at 8000");
        for (i = 0; i < 1024; i = i + 1) if (sys.rk86.font_rom.mem[i] !== font[i]) fail("the font is not loaded");
        if (with_cart) for (i = 0; i < cart_size; i = i + 1) if (psram_byte(i) !== cart[i]) fail("the ROM disk is not in the PSRAM");
    end
endtask
// a ROM disk reload from the Pocket menu (data.json slot 2, parameters 75): the core held in reset
// (core_bridge_cmd reset_n low), slot 2 requested with the new size and written, then Reset Exit;
// the RAM is kept (no cold clear), the machine restarts to the monitor. cart2 becomes the image the
// RAM checks compare with.
task reload_slot2;
    begin
        @(negedge clk) reset_n = 1'b0; repeat (20) @(negedge clk);
        slot(2, cart2_size);
        for (i = 0; i < cart2_size / 4; i = i + 1)
            slot_write(32'h2200_0000 + 4*i, {cart2[4*i], cart2[4*i+1], cart2[4*i+2], cart2[4*i+3]});
        for (i = 0; i < cart2_size; i = i + 1) if (psram_byte(i) !== cart2[i]) fail("reload: the ROM disk is not the new image");
        for (i = 0; i < 65536; i = i + 1) cart[i] = cart2[i];
        reset_n = 1'b1;
        wait_fetch(16'hFE63, FE63_FRAMES, "reload: no keyboard loop after the restart");
    end
endtask
task wait_fetch(input [15:0] a, input integer max_frames, input [8*40-1:0] what);
    reg [8*48-1:0] label;
    begin
        start_frame = frames;
        while (!(sys.rk86.machine.cpu_a == a && sys.rk86.machine.cpu_dbin)) begin
            @(posedge clk);
            if (frames - start_frame > max_frames) fail(what);
        end
        $sformat(label, "fetch %h at frame %0d", a, frames);
        info_wait(label, frames - start_frame, max_frames);
    end
endtask
task wait_frames(input integer count);
    begin start_frame = frames; wait (frames >= start_frame + count); end
endtask
task check_ram(input integer ram_at, input integer cart_at, input integer len, input [8*40-1:0] what);
    integer k;
    begin
        for (k = 0; k < len; k = k + 1)
            if (sys.rk86.mem.ram[ram_at + k] !== cart[cart_at + k]) fail(what);
    end
endtask
task wait_ram(input integer ram_at, input integer cart_at, input integer len, input integer max_frames, input [8*40-1:0] what);
    integer k, same;
    begin
        start_frame = frames; same = 0;
        while (!same) begin
            same = 1;
            for (k = 0; k < len; k = k + 1) if (sys.rk86.mem.ram[ram_at + k] !== cart[cart_at + k]) same = 0;
            if (!same) begin
                if (frames - start_frame > max_frames) fail(what);
                n = frames; wait (frames != n);
            end
        end
        info_wait("RAM image", frames - start_frame, max_frames);
    end
endtask
task tap(input [15:0] b);                    // a short press (an L tap toggles the Shift latch)
    begin pad = {4'h1, 12'h0, b}; repeat (8) @(negedge clk); pad = {4'h1, 28'h0}; repeat (8) @(negedge clk); end
endtask
// The panel chord (00-global.md, L+R): L, then R while L is held (well inside CHORD_MS), both released.
task chord;
    begin
        pad = {4'h1, 12'h0, B_L}; repeat (8) @(negedge clk);
        pad = {4'h1, 12'h0, B_L | B_R}; repeat (8) @(negedge clk);
        pad = {4'h1, 28'h0}; repeat (8) @(negedge clk);
    end
endtask
task open_panel;
    begin
        if (sys.rk86.keyboard.panel_open) fail("open_panel: the panel is already open");
        chord;
        if (!sys.rk86.keyboard.panel_open) fail("the panel did not open");
    end
endtask
task close_panel;
    begin
        if (!sys.rk86.keyboard.panel_open) fail("close_panel: the panel is not open");
        chord;
        if (sys.rk86.keyboard.panel_open) fail("the panel did not close");
    end
endtask
// The monitor delivers a key when its status routine FE01 has seen it on 21 scans: it writes FF
// to 7605 (FE63 then clears it and returns 7609). Each delivery is counted here.
integer key_deliveries = 0;
always @(posedge clk)
    if (sys.rk86.cpu_write && sys.rk86.machine.cpu_a == 16'h7605 && sys.rk86.cpu_do == 8'hFF) key_deliveries = key_deliveries + 1;
// A key for the monitor (as the POC's tests/pocket/tb_pocket_machine.v, which holds the key until
// it lands in the line buffer): first wait until the monitor has seen the previous key released
// (its cached key 7609 = FF; else a repeated key, as the second F of 1FF, waits for the
// autorepeat), then hold until the monitor has delivered the key, then release. The release is
// not awaited here: after ВК the monitor runs the command and scans the keys only after it.
task wait_key_release;
    begin
        start_frame = frames;
        while (sys.rk86.mem.ram[15'h7609] !== 8'hFF) begin
            @(negedge clk);
            if (frames - start_frame > KEY_FRAMES) fail("the monitor did not see the key release");
        end
    end
endtask
task press_key(input [6:0] k);                // a matrix key on the second keyboard input
    integer start;
    reg [8*48-1:0] label;
    begin
        wait_key_release;
        // the monitor delivers the key after 21 scans that saw it (keytap measures the time from a
        // press; k1: 2-3 native frames a key)
        tb_key = k; start = key_deliveries; start_frame = frames;
        while (key_deliveries == start) begin
            @(negedge clk);
            if (frames - start_frame > KEY_FRAMES) fail("the monitor did not take the key");
        end
        tb_key = NO_KEY;
        $sformat(label, "key %0d delivered", k);
        info_wait(label, frames - start_frame, KEY_FRAMES);
    end
endtask
// the matrix key of a character typed without Shift in LAT: digits and capitals print 32 + k, "," is 28
function [6:0] matrix_key(input [7:0] c);
    begin
        if (c == ",") matrix_key = 7'd28;
        else matrix_key = c - 8'd32;
    end
endfunction
task type_char(input [7:0] c);
    begin press_key(matrix_key(c)); end
endtask

// --- K1 (scenario k1): typing through the panel, the RGB captures ---
localparam [6:0] K1_G = 7'd28, K1_R = 7'd40, K1_K = 7'd25, K1_8 = 7'd16;    // key ids (00-global.md)
integer k1_log, captures = 0, hold_start;
reg [7:0] rus_byte;
task k1_step(input [8*48-1:0] what);
    begin
        $display("STEP %0s (frame %0d, %0t)", what, frames, $time);
        $fdisplay(k1_log, "STEP %0s (frame %0d)", what, frames); $fflush(k1_log);
    end
endtask
task wait_vs(input integer count);           // count displayed frames (vs pulses), bounded
    integer v, clks;
    begin
        v = vs_count; clks = 0;
        while (vs_count < v + count) begin
            @(posedge clk_av); clks = clks + 1;
            if (clks > (count + 1) * 204800) fail("no displayed frames");
        end
    end
endtask
// the open panel's expected state bus (Task 2 layout), RUS line not pulled
function [77:0] k1_state(input [6:0] sel, input rus, input sh, input ct, input [63:0] pulled, input [1:0] pal);
    k1_state = {pal, pulled, 1'b0, ct, sh, rus, sel, 1'b1};
endfunction
// one displayed frame to k1_<n>.hex, its latched panel state to k1.log; the state must be want
task capture_k1(input [77:0] want, input [8*48-1:0] what);
    integer v, clks;
    reg [8*16-1:0] name;
    begin
        captures = captures + 1; v = vs_count; rgb_go = 1'b1;
        clks = 0;
        while (!rgb_done) begin
            @(posedge clk_av); clks = clks + 1;
            if (vs_count > v + 3 || clks > 5 * 204800) fail("RGB capture: no complete displayed frame");
        end
        rgb_go = 1'b0;
        $sformat(name, "k1_%0d.hex", captures);
        $writememh(name, rgb_frame);
        $display("STATE %0d %h %0d %0s", captures, rgb_state, rgb_green, what);
        $fdisplay(k1_log, "STATE %0d %h %0d %0s", captures, rgb_state, rgb_green, what); $fflush(k1_log);
        if (rgb_state !== want) begin
            $display("ERROR: capture %0d: panel state %h, expected %h", captures, rgb_state, want); $finish;
        end
        rgb_done = 1'b0;
    end
endtask
// D-pad taps: Down / Up until the row is the key's row, then Right until the selection is the key
task select_key(input [6:0] id);
    integer steps;
    begin
        steps = 0;
        while (k1_row(sys.rk86.keyboard.selection) != k1_row(id)) begin
            tap(k1_row(id) > k1_row(sys.rk86.keyboard.selection) ? B_DOWN : B_UP);
            steps = steps + 1;
            if (steps > 6) fail("select_key: the row was not reached");
        end
        steps = 0;
        while (sys.rk86.keyboard.selection != id) begin
            tap(B_RIGHT); steps = steps + 1;
            if (steps > 14) fail("select_key: the key was not reached");
        end
    end
endtask
// press_key's handshake through the panel: after the monitor saw the last key released, hold B on
// the selected key (panel_hold), until the monitor has delivered it (panel_release)
task panel_hold(input [6:0] id);
    begin
        select_key(id); wait_key_release;
        hold_start = key_deliveries; pad = {4'h1, 12'h0, B_B}; repeat (8) @(negedge clk);
        if (sys.rk86.keyboard.pulled !== (64'd1 << k1_line(id))) fail("B does not pull the selected key's line");
    end
endtask
task panel_release;
    begin
        start_frame = frames;
        while (key_deliveries == hold_start) begin
            @(negedge clk);
            if (frames - start_frame > KEY_FRAMES) fail("the monitor did not take the panel key");
        end
        pad = {4'h1, 28'h0};
        info_wait("panel key delivered", frames - start_frame, KEY_FRAMES);
    end
endtask
task panel_press(input [6:0] id);
    begin panel_hold(id); panel_release; end
endtask
// the typed text in the monitor's line buffer (7633, F8EE) and on the screen (RAM 76D0-7FF3)
// followed by a blank cell (00, as the monitor clears the screen at FDA3, or 20): nothing typed
// after it. On a failure the RAM 7600-7FF3 goes to k1_screen.hex.
task wait_screen(input [8*4-1:0] text, input integer len, input integer max_frames, input [8*48-1:0] what);
    integer a, k, found;
    begin
        start_frame = frames; found = 0;
        while (!found) begin
            for (a = 16'h76D0; a + len < 16'h7FF4 && !found; a = a + 1) begin
                found = sys.rk86.mem.ram[a + len] === 8'h00 || sys.rk86.mem.ram[a + len] === 8'h20;
                for (k = 0; k < len; k = k + 1) if (sys.rk86.mem.ram[a + k] !== text[8*(len-1-k) +: 8]) found = 0;
            end
            for (k = 0; k < len; k = k + 1) if (sys.rk86.mem.ram[16'h7633 + k] !== text[8*(len-1-k) +: 8]) found = 0;
            if (!found) begin
                if (frames - start_frame > max_frames) begin
                    $writememh("k1_screen.hex", sys.rk86.mem.ram, 16'h7600, 16'h7FF3);
                    fail(what);
                end
                n = frames; wait (frames != n);
            end
        end
        info_wait("text on the screen", frames - start_frame, max_frames);
    end
endtask
// the prompt "-->" (2D 2D 3E) on the screen RAM 76D0-7FF3, bounded in frames
task wait_prompt(input integer max_frames);
    integer a, found;
    begin
        start_frame = frames; found = 0;
        while (!found) begin
            for (a = 16'h76D0; a + 3 < 16'h7FF4 && !found; a = a + 1)
                found = sys.rk86.mem.ram[a] === 8'h2D && sys.rk86.mem.ram[a + 1] === 8'h2D && sys.rk86.mem.ram[a + 2] === 8'h3E;
            if (!found) begin
                if (frames - start_frame > max_frames) fail("the prompt --> is not on the screen");
                n = frames; wait (frames != n);
            end
        end
        info_wait("prompt on the screen", frames - start_frame, max_frames);
    end
endtask
task boot(input with_cart, input [1:0] boot_preset);
    begin
        load(with_cart);
        bridge_write(32'h10C, boot_preset);       // a persisted value, written before Reset Exit
        reset_n = 1'b1;
        wait_fetch(16'hFE63, FE63_FRAMES, "no keyboard loop");
    end
endtask
// R0,1FF,0 (RAM 0000-01FF = image 0000-01FF), then G0
task r_g0;
    begin
        type_char("R"); type_char("0"); type_char(","); type_char("1"); type_char("F"); type_char("F");
        type_char(","); type_char("0"); press_key(KEY_VK);
        wait_ram(0, 0, 512, copy_frames(512), "R0,1FF,0 did not copy the loader");
        type_char("G"); type_char("0"); press_key(KEY_VK);
    end
endtask
task to_menu;
    begin
        r_g0;
        wait_fetch(16'h741C, MENU_FRAMES, "no ROM disk menu");
    end
endtask
// XONIX by menu key 4 of Kiselev's ROM disk: ROM 5500-5FFF copied to 0000, started there and running
task run_xonix;
    begin
        type_char("4");
        wait_fetch(16'h0000, copy_frames(2816), "XONIX did not start at 0000");
        check_ram(0, 21760, 2816, "XONIX image differs at its start");
        n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin @(posedge clk); if (sys.rk86.machine.cpu_dbin && sys.rk86.machine.cpu_a < 16'h0B00) n = n + 1; end
        if (n < 1000) fail("XONIX does not run");
    end
endtask
// frame.hex, and cursor.txt ("<col> <row>", the last Load Cursor) when the monitor has set the cursor
task capture;
    integer f;
    begin
        capture_go = 1'b1; wait (capture_done); $writememh("frame.hex", frame); capture_go = 1'b0; capture_done = 1'b0;
        if (cursor_known) begin
            f = $fopen("cursor.txt", "w"); $fdisplay(f, "%0d %0d", cursor_col, cursor_row); $fclose(f);
        end
    end
endtask
// keytap: pocket_keyboard on real milliseconds (its 1 ms tick forced to one clk in 74 250, so
// MIN_HOLD_MS lasts its build time); a button tap with the panel closed must reach the monitor.
localparam integer MS_CLK = 74250;
localparam integer TAP_HOLD_MS = 80;         // the build's MIN_HOLD_MS (pocket_keyboard.v)
reg ms_tick = 1'b0;
integer ms_cnt = 0;
always @(posedge clk) begin
    ms_tick <= ms_cnt == MS_CLK - 1;
    ms_cnt <= ms_cnt == MS_CLK - 1 ? 0 : ms_cnt + 1;
end
// the button b held hold_ms (then released); the monitor must deliver its key within KEY_FRAMES of
// the press; the time from the press to the delivery goes to an INFO line
task button_tap(input [15:0] b, input integer hold_ms, input [8*48-1:0] what);
    integer start, clks;
    reg got;
    realtime t0, dt;
    begin
        wait_key_release;
        start = key_deliveries; start_frame = frames; clks = 0; got = 1'b0;
        @(negedge clk); pad = {4'h1, 12'h0, b}; t0 = $realtime;
        while (!got || clks < hold_ms * MS_CLK) begin
            @(negedge clk); clks = clks + 1;
            if (clks == hold_ms * MS_CLK) pad = {4'h1, 28'h0};
            if (!got && key_deliveries != start) begin got = 1'b1; dt = $realtime - t0; end
            if (frames - start_frame > KEY_FRAMES) fail(what);
        end
        $display("INFO: keytap: button %h held %0d ms: the monitor delivered the key %0.2f ms after the press",
                 b, hold_ms, dt / 1.0e6);
    end
endtask
// nocart: the ROM disk 8255 driven by the TB with the machine frozen (its ports forced), strobes held
// 4 clk as in tb_cart_ppi.v
reg cart_rd_n = 1'b1, cart_wr_n = 1'b1;
reg [1:0] cart_a = 2'd0;
reg [7:0] cart_d = 8'h00, cart_v;
task cart_wr(input [1:0] ad, input [7:0] dd);
    begin
        @(negedge clk) begin cart_a = ad; cart_d = dd; end
        @(negedge clk) cart_wr_n = 1'b0;
        repeat (4) @(negedge clk); cart_wr_n = 1'b1;
        repeat (3) @(negedge clk);
    end
endtask
task cart_rd(input [1:0] ad);
    begin
        @(negedge clk) cart_a = ad;
        @(negedge clk) cart_rd_n = 1'b0;
        repeat (4) @(negedge clk); cart_v = sys.rk86.ext_di; cart_rd_n = 1'b1;
        repeat (3) @(negedge clk);
    end
endtask
task lock_loss(input integer clks);          // the lock drops for clks and comes back by itself
    begin
        guard_lock = 1'b1;
        tb_lock = 1'b0; repeat (clks) @(negedge clk);
        if (sys.run_sync[2]) fail("video and audio not held in reset without lock");
        tb_lock = 1'b1;
    end
endtask
task video_resumes;
    begin
        guard = 0;
        while (!sys.run_sync[2] && guard < 100000) begin @(negedge clk); guard = guard + 1; end
        if (!sys.run_sync[2]) fail("video and audio did not leave reset after relock");
        n = sys.video.frames_displayed; guard = 0;
        while (sys.video.frames_displayed < n + 2 && guard < 20000000) begin @(negedge clk); guard = guard + 1; end
        if (sys.video.frames_displayed < n + 2) fail("no frames displayed after relock");
    end
endtask

initial begin
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "boot";
    if (!$value$plusargs("cart_size=%d", cart_size)) cart_size = 32256;
    if (cart_size % 4 != 0 || cart_size > 131072) fail("cart_size: a multiple of 4, at most 131072");
    $readmemh("monitor.hex", monitor); $readmemh("font.hex", font);
    // cartridge.hex: 65536 entries, or 131072 for the card image (run_sim.py): the range as written
    $readmemh("cartridge.hex", cart, 0, cart_size > 65536 ? 131071 : 65535);
    if (scenario == "game") $readmemh("cartridge2.hex", cart2);
    force sys.rk86.hid_cols = tb_hid_cols; force sys.rk86.hid_mods = tb_hid_mods;
    `ZERO_UP(sys.rk86.machine)
    if (scenario == "powerup") begin
        #1;                                      // after the RTL's initial blocks (k580vt57 ad / tr), before the first clk
        `RANDOM_UP(sys.rk86.machine)
    end
    if (scenario == "boot" || scenario == "powerup") begin
        load(1'b1);
        bridge_write(32'h10C, 1); bridge_write(32'h104, 0);   // persisted, while reset_n is low
        reset_n = 1'b1; repeat (4) @(negedge clk);
        if (sys.controls_preset !== 2'd1 || sys.sound_on !== 1'b0) fail("persisted interact values lost at Reset Exit");
        bridge_write(32'h10C, 0); bridge_write(32'h104, 1);
        wait_fetch(16'hFE63, FE63_FRAMES, "no keyboard loop");
        capture;
        $display("INFO: native frame periods of %0d ce16: %0d, other: %0d", FRAME_CE16, periods_ok, periods_other);
        if (periods_ok < 2) fail("native frame period: fewer than 2 periods of 319920 ce16");
        $display("PASS %0s: assets, persisted interact values, keyboard loop at FE63, frame period, frame.hex", scenario);
    end else if (scenario == "nocart") begin
        // no image: port A reads FF (loaded low), whatever the PSRAM holds
        boot(1'b0, 2'd0);
        if (sys.rk86.romdisk_loaded !== 1'b0) fail("nocart: romdisk_loaded with no ROM disk slot");
        // A ROM disk read as the monitor's FA68 does it (the loader's copy, R0,1FF,0): control word
        // 90h to A003, the address to A001 (low) and A002 (high), then A000. The address is the first
        // one above 0000 where the image (cartridge.hex, not loaded) is not FF, and the PSRAM is given
        // that byte there by hierarchy, so only loaded = 0 makes the read FF. The machine is frozen
        // first (ce16 held low; the monitor waits in its keyboard loop and never reads A000-BFFF) and
        // the 8255's bus ports are forced. The controller holds the word of the reset address 7FFFh, so
        // it reads the changed word when the address is written.
        n = 1;
        while (n < 32256 && cart[n] === 8'hFF) n = n + 1;
        if (n == 32256) fail("nocart: cartridge.hex is FF after 0000");
        force sys.rk86.ce16 = 1'b0;
        psram.mem[n >> 1] = n[0] ? {cart[n], 8'hFF} : {8'hFF, cart[n]};
        force sys.rk86.cart.rd_n = cart_rd_n; force sys.rk86.cart.wr_n = cart_wr_n;
        force sys.rk86.cart.a = cart_a; force sys.rk86.cart.d_i = cart_d;
        cart_wr(2'd3, 8'h90);
        if (sys.rk86.cart.pc_pin[7] !== 1'b0) fail("nocart: PC7 not low after 90h (mode set: port C 00)");
        cart_wr(2'd1, n[7:0]); cart_wr(2'd2, n[15:8]);
        if (sys.rk86.romdisk_address !== {8'd0, n[14:0]}) fail("nocart: the ROM disk address is not the written one");
        guard = 0;
        while (!sys.psram.rd_ready && guard < 100) begin @(negedge clk); guard = guard + 1; end
        if (!sys.psram.rd_ready || sys.psram.rd_data !== cart[n]) fail("nocart: the PSRAM byte at the address is not the image byte");
        cart_rd(2'd0);
        if (cart_v !== 8'hFF) fail("no image: port A does not read FF (loaded low)");
        $display("PASS nocart: no image: port A reads FF (loaded low); after 90h and the address %h, A000 reads FF, the PSRAM holds %h there",
                 n[14:0], cart[n]);
    end else if (scenario == "reset") begin
        boot(1'b1, 2'd0);
        for (i = 0; i < 256; i = i + 1) sys.rk86.mem.ram[16'h1000 + i] = i[7:0] ^ 8'h3C;
        bridge_write(32'h100, 1);
        if (!sys.rk86.reset) fail("Reset did not reset the machine");
        wait (!sys.rk86.reset);
        wait_fetch(16'hFE63, FE63_FRAMES, "no keyboard loop after Reset");
        for (i = 0; i < 256; i = i + 1) if (sys.rk86.mem.ram[16'h1000 + i] !== (i[7:0] ^ 8'h3C)) fail("Reset changed the RAM");
        bridge_write(32'h100, 2);
        wait (sys.rk86.clear_active); wait (!sys.rk86.clear_active);
        wait_fetch(16'hFE63, FE63_FRAMES, "no keyboard loop after Cold boot");
        for (i = 0; i < 256; i = i + 1) if (sys.rk86.mem.ram[16'h1000 + i] !== 8'h00) fail("Cold boot left the RAM");
        $display("PASS reset: Reset keeps the RAM, Cold boot clears it, both reach FE63");
    end else if (scenario == "relock") begin
        boot(1'b1, 2'd0);
        video_resumes;
        for (i = 0; i < 256; i = i + 1) sys.rk86.mem.ram[16'h1000 + i] = i[7:0] ^ 8'h5A;
        lock_loss(10000);                        // shorter than the watchdog timeout
        if (pll_reset) fail("the watchdog fired on a short lock loss");
        video_resumes;
        guard_lock = 1'b0;
        for (i = 0; i < 256; i = i + 1) if (sys.rk86.mem.ram[16'h1000 + i] !== (i[7:0] ^ 8'h5A)) fail("a lock loss changed the RAM");
        wait_fetch(16'hFE63, LOOP_FRAMES, "the machine stopped after a lock loss");
        $display("PASS relock: lock lost and back by itself; machine, assets and RAM kept; video and audio restarted");
    end else if (scenario == "watchdog") begin
        boot(1'b1, 2'd0);
        video_resumes;
        guard_lock = 1'b1;
        tb_lock = 1'b0;                          // lost, and does not come back by itself
        guard = 0;
        while (!pll_reset && guard < 100000) begin @(negedge clk); guard = guard + 1; end
        if (!pll_reset) fail("the watchdog did not reset the PLL");
        tb_lock = 1'b1;                          // the PLL reset brings it back (stub: 1000 clk later)
        video_resumes;
        guard_lock = 1'b0;
        wait_fetch(16'hFE63, LOOP_FRAMES, "the machine stopped after the watchdog");
        $display("PASS watchdog: PLL reset after the timeout, relock, machine and assets kept, video restarted");
    end else if (scenario == "menu") begin
        boot(1'b1, 2'd0);
        if (sys.rk86.romdisk_64k !== 1'b0) fail("menu: Kiselev's 32256-byte image, the 64 KB wiring chosen");
        to_menu;
        wait_frames(2);
        capture;
        $display("PASS menu: R0,1FF,0 copied the loader, G0 reached the ROM disk menu, frame.hex");
    end else if (scenario == "menu64") begin
        // the 64 KB regression through the PSRAM: game disk 2 (+cart_size=65536) in the ROM disk slot;
        // to_menu: RAM 0000-01FF = image 0000-01FF after R0,1FF,0, then G0 to the games loader's GETCH
        // call at 741C (as in Kiselev's loader)
        boot(1'b1, 2'd0);
        if (sys.rk86.romdisk_64k !== 1'b1 || sys.rk86.romdisk_card !== 1'b0) fail("menu64: a 65536-byte image, not the 64 KB wiring");
        to_menu;
        $display("PASS menu64: 64 KB game disk through the PSRAM, R0,1FF,0 copied the loader, G0 reached the menu");
    end else if (scenario == "card") begin
        // the J6 bank card (+cart_size=131072): bank 0 the card menu (scripts/romdisk/card.py), bank 1 game
        // disk 2. R0,1FF,0 and G0 start the card menu (7400-75FF, its key wait at +card_keywait); key 0
        // selects bank 1 (SELBK: PC7 falls to port C 7F), copies its 0000-01FF to 0000 and jumps there:
        // disk 2's own loader relocates to 7400 and reaches its GETCH call at 741C. Then Core Settings
        // Reset keeps the bank, Cold boot clears it (card_reset).
        if (!$value$plusargs("card_keywait=%d", card_keywait)) fail("card: no +card_keywait");
        if (card_keywait < 16'h7400 || card_keywait > 16'h75FF || card_keywait == 16'h741C)
            fail("card: +card_keywait not in 7400-75FF, or 741C");
        boot(1'b1, 2'd0);
        if (sys.rk86.romdisk_card !== 1'b1 || sys.rk86.romdisk_64k !== 1'b1) fail("card: a 131072-byte image, not the card wiring");
        if (sys.rk86.cart.bank !== 7'd0) fail("card: bank not 0 after the slot load");
        r_g0;                                        // RAM 0000-01FF = the card menu, then G0
        wait_fetch(card_keywait[15:0], MENU_FRAMES, "no card menu");
        if (sys.rk86.cart.bank !== 7'd0) fail("card: bank not 0 in the card menu");
        type_char("0");
        start_frame = frames;
        while (sys.rk86.cart.bank !== 7'd1) begin
            @(posedge clk);
            if (frames - start_frame > MENU_FRAMES) fail("card: key 0 did not select bank 1");
        end
        info_wait("bank 1 selected", frames - start_frame, MENU_FRAMES);
        wait_fetch(16'h0000, copy_frames(512), "card: disk 2's loader not started at 0000");
        wait_fetch(16'h741C, MENU_FRAMES, "no menu of disk 2");
        check_ram(0, 65536, 512, "disk 2 loader not in 0000-01FF");
        check_ram(16'h7400, 65536, 512, "disk 2 loader not in 7400-75FF");
        if (sys.rk86.cart.bank !== 7'd1) fail("card: bank not 1 in the menu of disk 2");
        $display("INFO: card: card menu, key 0, bank 1, the menu of disk 2 at frame %0d", frames);
        bridge_write(32'h100, 1);                    // Core Settings > Reset (the machine reset)
        if (!sys.rk86.reset) fail("card: Reset did not reset the machine");
        wait (!sys.rk86.reset);
        wait_fetch(16'hFE63, FE63_FRAMES, "card: no keyboard loop after Reset");
        if (sys.rk86.cart.bank !== 7'd1) fail("card: Reset changed the bank");
        bridge_write(32'h100, 2);                    // Core Settings > Cold boot (card_reset)
        wait (sys.rk86.clear_active); wait (!sys.rk86.clear_active);
        wait_fetch(16'hFE63, FE63_FRAMES, "card: no keyboard loop after Cold boot");
        if (sys.rk86.cart.bank !== 7'd0) fail("card: Cold boot did not clear the bank");
        $display("PASS card: card menu, key 0, bank 1, the menu of disk 2; Reset keeps the bank, Cold boot clears it");
    end else if (scenario == "xonix") begin
        boot(1'b1, 2'd0);
        if (sys.rk86.romdisk_64k !== 1'b0) fail("xonix: Kiselev's 32256-byte image, the 64 KB wiring chosen");
        to_menu;                         // checkpoint 1: the loader copied by R0,1FF,0, G0 reached the menu
        wait_frames(2);
        capture;                         // checkpoint 2: frame.hex (run_sim.py compares it with rom-disk-menu.hex)
        $display("INFO: xonix: the ROM disk menu reached, frame.hex written");
        run_xonix;                       // checkpoint 3: XONIX by key 4 copied to 0000, started there and running
        $display("PASS xonix: the ROM disk menu (frame.hex), then XONIX by key 4 copied to 0000, started there and running");
    end else if (scenario == "dpddt") begin
        boot(1'b1, 2'd0); to_menu; type_char("3");
        wait_ram(16'h6400, 16896, 256, copy_frames(256), "DP/DDT was not loaded at 6400");
        wait_frames(10);
        bridge_write(32'h100, 1); wait (!sys.rk86.reset);
        wait_fetch(16'hFE63, FE63_FRAMES, "no keyboard loop after Reset from DP/DDT");
        $display("PASS dpddt: DP/DDT loaded at 6400 as on the real machine, Reset recovered");
    end else if (scenario == "tetris") begin
        boot(1'b1, 2'd1); to_menu; type_char("6");
        wait_fetch(16'h3000, copy_frames(1632), "TETRIS did not start at 3000");
        check_ram(12288, 30624, 1632, "TETRIS image differs at its start");
        capture;                          // frame.hex: the screen right after TETRIS started
        $display("INFO: tetris: frame.hex captured at native frame %0d", frames);
        repeat (64) @(negedge clk);
        pad = {4'h1, 12'h0, B_LEFT};
        repeat (1000) @(negedge clk);     // the press reaches the matrix (input sync, remap) before the check
        n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin
            @(posedge clk);
            if (!sys.rk86.kbd_rows[2]) begin if (sys.rk86.kbd_cols[7]) fail("D-pad Left is not 7 in Digits 7-8-9-6"); n = n + 1; end
        end
        pad = {4'h1, 28'h0};
        if (n == 0) fail("TETRIS never scanned row 2");
        $display("PASS tetris: started at 3000, D-pad Left = 7 with the Digits 7-8-9-6 preset");
    end else if (scenario == "game") begin
        if (!$value$plusargs("game_key=%d", game_key) || !$value$plusargs("game_ram=%d", game_ram) ||
            !$value$plusargs("game_rom=%d", game_rom) || !$value$plusargs("game_len=%d", game_len)) fail("game: plusargs");
        if (game_rom < 32768) fail("game: the entry is not above 8000h (the ROM A15 line untested)");
        boot(1'b1, 2'd0);                          // checkpoint 1: Kiselev's image, the 32 KB wiring
        if (sys.rk86.romdisk_64k !== 1'b0) fail("game: Kiselev's 32256-byte image, the 64 KB wiring chosen");
        sys.rk86.mem.ram[16'h5000] = 8'h5A;          // a marker the reload must keep (RAM kept)
        reload_slot2;                                // checkpoint 2: the reload, the 64 KB wiring, the RAM kept
        if (sys.rk86.romdisk_64k !== 1'b1) fail("game: reload of a 64 KB image, the 64 KB wiring not chosen");
        if (sys.rk86.mem.ram[16'h5000] !== 8'h5A) fail("game: the RAM was not kept by the ROM disk reload");
        $display("INFO: game: ROM disk reloaded with the 64 KB disk, the 64 KB wiring chosen, the RAM kept, monitor at FE63");
        to_menu; type_char(game_key[7:0]);           // checkpoint 3: the menu, then the game from above 8000h
        wait_fetch(game_ram[15:0], copy_frames(game_len), "the game did not start at its load address");
        check_ram(game_ram, game_rom, game_len, "the game image differs at its start");
        n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin
            @(posedge clk);
            if (sys.rk86.machine.cpu_dbin && sys.rk86.machine.cpu_a >= game_ram && sys.rk86.machine.cpu_a < game_ram + game_len) n = n + 1;
        end
        if (n < 1000) fail("the game does not run");
        $display("PASS game: Kiselev's image (32 KB wiring), reloaded with the 64 KB disk (64 KB wiring, RAM kept), menu key %0s, copied to %h, started there and running", game_key[7:0], game_ram[15:0]);
    end else if (scenario == "keytap") begin
        // Key tap timing at the 16 MHz machine (pocket_keyboard holds a tapped key MIN_HOLD_MS, a value
        // from the 1.43 MHz machine): with Keys = Digits 7-8-9-6, a D-pad Left held exactly 80 ms (7)
        // and a D-pad Up held 1 ms (8, held on by pocket_keyboard for MIN_HOLD_MS) must both reach the
        // monitor: delivered, and 78 in its line buffer (7633) and on the screen. The keyboard runs
        // on real milliseconds here (ms_tick), not on the 10x shorter base of the other scenarios.
        boot(1'b0, 2'd1);
        wait_prompt(ECHO_FRAMES);
        force sys.rk86.keyboard.tick = ms_tick;
        button_tap(B_LEFT, TAP_HOLD_MS, "keytap: the 80 ms tap did not reach the monitor");
        wait_screen("7", 1, ECHO_FRAMES, "keytap: 7 (the 80 ms tap) is not in the line buffer");
        button_tap(B_UP, 1, "keytap: the 1 ms tap did not reach the monitor");
        wait_screen("78", 2, ECHO_FRAMES, "keytap: 8 (the 1 ms tap) is not in the line buffer");
        $display("PASS keytap: a tap of %0d ms and one of 1 ms reached the monitor (78 in the line buffer)", TAP_HOLD_MS);
    end else if (scenario == "k1") begin
        k1_log = $fopen("k1.log", "w");
        if (k1_line(K1_G) != 7'd39 || k1_line(K1_R) != 7'd50 || k1_line(K1_K) != 7'd43 || k1_line(K1_8) != 7'd24)
            fail("the K1 key ids of this TB do not match pocket_k1_layout.vh");
        boot(1'b0, 2'd0);
        k1_step("keyboard loop FE63, no ROM disk; L+R");
        wait_prompt(ECHO_FRAMES); wait_vs(2);    // the prompt in a displayed frame
        open_panel; wait_vs(2);
        capture_k1(k1_state(K1_G, 0, 0, 0, 64'd0, 2'd0), "LAT, selection G, palette 0 (v1.1)");
        k1_step("RK typed through the panel");
        panel_press(K1_R); panel_press(K1_K);
        wait_screen("RK", 2, ECHO_FRAMES, "RK typed through the panel is not on the screen");
        select_key(K1_8);
        wait_frames(3);                          // RK in a completed, displayed frame
        panel_hold(K1_8); wait_vs(1);            // the held key in the latched state of the next frame
        capture_k1(k1_state(K1_8, 0, 0, 0, 64'd1 << 24, 2'd0), "B held on 8 (lit), RK on the screen");
        panel_release;
        wait_screen("RK8", 3, ECHO_FRAMES, "RK8 is not on the screen");
        wait_vs(2);                              // RK8 in a displayed frame (capture 3 follows)
        k1_step("L tap: Shift latched");
        tap(B_L);
        if (!sys.rk86.keyboard.shift_latch) fail("the L tap did not latch Shift");
        wait_vs(2);
        capture_k1(k1_state(K1_8, 0, 1, 0, 64'd0, 2'd0), "LAT, Shift latched");
        k1_step("L tap (unlatch); R held: RUS");
        tap(B_L);
        if (sys.rk86.keyboard.shift_latch) fail("the second L tap did not clear the Shift latch");
        wait_key_release;
        // FE01 takes РУС after 21 scans, then waits at FE51 for its release and only then inverts
        // 7606: R is held until the monitor waits there, then released
        rus_byte = sys.rk86.mem.ram[15'h7606];
        pad = {4'h1, 12'h0, B_R};
        wait_fetch(16'hFE51, KEY_FRAMES, "R: the monitor did not take RUS (FE51)");
        pad = {4'h1, 28'h0}; start_frame = frames;
        while (sys.rk86.mem.ram[15'h7606] === rus_byte) begin
            @(negedge clk);
            if (frames - start_frame > ECHO_FRAMES) fail("R did not switch the monitor to RUS");
        end
        repeat (8) @(negedge clk);
        if (!sys.rk86.rus_mode) fail("R: 7606 changed, but rus_mode is not RUS");
        start_frame = frames;
        while (sys.rk86.keyboard.rus_line) begin
            @(negedge clk);
            if (frames - start_frame > ECHO_FRAMES) fail("the RUS line stays pulled after R");
        end
        wait_vs(2);
        capture_k1(k1_state(K1_8, 1, 0, 0, 64'd0, 2'd0), "RUS");
        k1_step("L held past the tap window: Ctrl");
        pad = {4'h1, 12'h0, B_L}; wait_vs(2);
        if (!sys.rk86.keyboard.ctrl_line) fail("L held does not pull the Ctrl line");
        capture_k1(k1_state(K1_8, 1, 0, 1, 64'd0, 2'd0), "RUS, L held: Ctrl");
        pad = {4'h1, 28'h0}; repeat (8) @(negedge clk);
        if (sys.rk86.keyboard.shift_latch || sys.rk86.keyboard.ctrl_line) fail("L held: Shift toggled or Ctrl kept after the release");
        k1_step("palettes 1 and 2");
        bridge_write(32'h118, 1); wait_vs(2);
        capture_k1(k1_state(K1_8, 1, 0, 0, 64'd0, 2'd1), "RUS, palette 1 (v1.4)");
        bridge_write(32'h118, 2); wait_vs(2);
        capture_k1(k1_state(K1_8, 1, 0, 0, 64'd0, 2'd2), "RUS, palette 2 (mono)");
        close_panel;
        $fclose(k1_log);
        $display("PASS k1: panel opened, RK8 typed through it, %0d RGB captures (k1_<n>.hex, k1.log)", captures);
    end else if (scenario == "k1_panel") begin
        // CI (run_sim.py test system_k1_panel): the panel without the machine. The keyboard is
        // enabled by assets_valid and memory_ready (the slot loader and the cold clear run on clk),
        // not by the CPU, and pocket_frame_video draws the panel whether a frame bank is valid or
        // not; check_frames.py compares only the panel rectangle. So ce16 is held low from the
        // start: the machine stays in reset (the CPU, the 8275 and the 8257 stand still), no native
        // frame comes, and the waits count displayed 60 Hz frames (wait_vs). The RUS bit of the
        // state is rus_mode, the 7606 bit 0 the cold clear writes as 0 and no CPU write changes.
        // Checks the chord, the panel in the real output (bus CDC, frame latch, overlay) for the
        // palettes 0, 1, 2, the Shift latch and the Ctrl line; not the typing, B lit or RUS (full k1).
        k1_log = $fopen("k1.log", "w");
        if (k1_line(K1_G) != 7'd39 || k1_line(K1_R) != 7'd50 || k1_line(K1_K) != 7'd43 || k1_line(K1_8) != 7'd24)
            fail("the K1 key ids of this TB do not match pocket_k1_layout.vh");
        force sys.rk86.ce16 = 1'b0;               // the machine frozen
        load(1'b0);
        bridge_write(32'h10C, 2'd0);              // a persisted value, written before Reset Exit
        reset_n = 1'b1;
        guard = 0;
        while (!memory_ready && guard < 100000) begin @(negedge clk); guard = guard + 1; end
        if (!memory_ready) fail("k1_panel: no memory_ready after the cold clear");
        wait_vs(2);                               // the video out of reset, the panel state crossed
        if (!sys.rk86.reset || sys.rk86.rus_mode) fail("k1_panel: the machine not held in reset, or RUS");
        k1_step("assets, no ROM disk, cold clear, machine frozen; L+R");
        open_panel; wait_vs(1);
        capture_k1(k1_state(K1_G, 0, 0, 0, 64'd0, 2'd0), "LAT, selection G, palette 0 (v1.1)");
        k1_step("L tap: Shift latched; L tap; L held: Ctrl");
        tap(B_L);
        if (!sys.rk86.keyboard.shift_latch) fail("the L tap did not latch Shift");
        tap(B_L);
        if (sys.rk86.keyboard.shift_latch) fail("the second L tap did not clear the Shift latch");
        // L held for wait_vs(3): at least 2 whole displayed frames (2 x 16.7 ms = 33 ms) after the
        // press, past the tap window (TAP_MS 250 with CLK_HZ 7425000: 25 ms here); wait_vs(2) can
        // end after 16.7 ms, and the release would then toggle the Shift latch.
        pad = {4'h1, 12'h0, B_L}; wait_vs(3);
        if (!sys.rk86.keyboard.ctrl_line) fail("L held does not pull the Ctrl line");
        pad = {4'h1, 28'h0}; repeat (8) @(negedge clk);
        if (sys.rk86.keyboard.shift_latch || sys.rk86.keyboard.ctrl_line) fail("L held: Shift toggled or Ctrl kept after the release");
        k1_step("palettes 1 and 2");
        bridge_write(32'h118, 1); wait_vs(1);
        capture_k1(k1_state(K1_G, 0, 0, 0, 64'd0, 2'd1), "LAT, palette 1 (v1.4)");
        bridge_write(32'h118, 2); wait_vs(1);
        capture_k1(k1_state(K1_G, 0, 0, 0, 64'd0, 2'd2), "LAT, palette 2 (mono)");
        close_panel;
        $fclose(k1_log);
        $display("PASS k1_panel: panel opened with the machine frozen, Shift latch and Ctrl, %0d RGB captures", captures);
    end else fail("unknown scenario");
    $finish;
end
endmodule
`default_nettype wire
