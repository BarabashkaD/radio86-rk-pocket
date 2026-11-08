`timescale 1ns/1ps
`default_nettype none
// System testbench of the Pocket target (spec 9.4-9.7): pocket_system with the bridge and data
// slot signals driven as core_bridge_cmd drives them, and a PLL stub (clk_core_12288 and its
// lock: the scenario drops the lock, and the PLL reset of the watchdog unlocks it for 1000 clk).
// +scenario=boot|powerup|nocart|reset|relock|watchdog|menu|xonix|dpddt|tetris|k1|k1_panel
// +timeout=<clk to wait for the monitor to take a key, default 4000000>
// Working directory: monitor.hex, font.hex, cartridge.hex (fpga/sim/run_sim.py); writes frame.hex;
// k1 writes k1_<n>.hex (the RGB output of one displayed frame, 408 x 300, one RRGGBB per pixel)
// and k1.log (STEP lines and, per capture, "STATE <n> <panel state hex> <green> <what>", the state
// pocket_frame_video latched for that frame; scripts/k1/check_frames.py renders the model for it).
// k1_panel (run_sim.py test system_k1_panel, CI): the panel without the monitor, 3 captures (palettes 0, 1, 2).
// The keyboard timings run on a 10x shorter base: pocket_keyboard CLK_HZ = 7425000, so each of its
// millisecond parameters (TAP_MS, CHORD_MS, ...) lasts a tenth of its time in the build.
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
wire ack, ok, rd_selected, memory_ready, asset_error, de, hs, vs, skip, dac, lrck;
wire [31:0] rd_data;
wire [23:0] rgb;
pocket_system sys(.clk_74a(clk), .clk_core_12288(clk_av), .pll_locked(pll_locked), .pll_locked_s(lock_sync[2]),
    .pll_reset(pll_reset), .reset_n(reset_n), .bridge_wr(wr), .bridge_addr(address), .bridge_wr_data(data),
    .rd_data(rd_data), .rd_selected(rd_selected), .status_boot_done(lock_sync[2]), .status_setup_done(1'b0),
    .dataslot_requestwrite(request), .dataslot_requestwrite_id(id), .dataslot_requestwrite_size(size),
    .dataslot_requestwrite_ack(ack), .dataslot_requestwrite_ok(ok), .dataslot_allcomplete(complete),
    .cont1_key(pad), .video_rgb(rgb), .video_de(de), .video_hs(hs), .video_vs(vs), .video_skip(skip),
    .audio_dac(dac), .audio_lrck(lrck), .memory_ready(memory_ready), .asset_error(asset_error));

reg [7:0] monitor [0:2047];
reg [7:0] font [0:1023];
reg [7:0] cart [0:32255];
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
    prev_kbd_read <= sys.rk86.cpu_rd && sys.rk86.cpu_a == 16'h8001;
    if (sys.rk86.cpu_rd && sys.rk86.cpu_a == 16'h8001 && !prev_kbd_read) kbd_reads = kbd_reads + 1;
end
// during a PLL lock loss the machine must never be reset and the assets must stay valid
reg guard_lock = 1'b0;
always @(posedge clk)
    if (guard_lock && (sys.rk86.reset || !sys.assets_valid)) begin
        $display("ERROR: PLL lock loss reached the machine: reset %b, assets_valid %b", sys.rk86.reset, sys.assets_valid);
        $finish;
    end
reg [8*16-1:0] scenario;
integer timeout, i, guard, n, start_frame;
localparam [15:0] B_UP = 16'h0001, B_DOWN = 16'h0002, B_LEFT = 16'h0004, B_RIGHT = 16'h0008, B_A = 16'h0010,
                  B_B = 16'h0020, B_L = 16'h0100, B_R = 16'h0200;
localparam [6:0] KEY_VK = 7'd10, NO_KEY = 7'd127;    // matrix key ВК; no key
// the second keyboard input: tb_key (a matrix key 0..63, or NO_KEY) pulls its column while its row is scanned
reg [6:0] tb_key = NO_KEY;
wire [7:0] tb_hid_cols = tb_key < 7'd64 && !sys.rk86.kbd_rows[tb_key[5:3]] ? ~(8'd1 << tb_key[2:0]) : 8'hFF;
wire [2:0] tb_hid_mods = 3'b111;
wire [31:0] frames = sys.native_frames;

task fail(input [8*64-1:0] what);
    begin $display("ERROR: %0s (frame %0d, cpu %h)", what, frames, sys.rk86.cpu_a); $finish; end
endtask
task bridge_write(input [31:0] a, input [31:0] d);
    begin @(negedge clk); address = a; data = d; wr = 1'b1; @(negedge clk); wr = 1'b0; repeat (4) @(negedge clk); end
endtask
task slot(input [15:0] slot_id, input [31:0] bytes);
    begin
        @(negedge clk); id = slot_id; size = bytes; request = 1'b1; guard = 0;
        while (!ack && guard < 20000) begin @(negedge clk); guard = guard + 1; end
        if (!ack || !ok) fail("slot refused");
        request = 1'b0; repeat (3) @(negedge clk);
    end
endtask
task load(input with_cart);
    begin
        repeat (20) @(negedge clk);              // the power-up reset of the asset stores
        slot(0, 2048);
        for (i = 0; i < 512; i = i + 1) bridge_write(32'h2000_0000 + 4*i, {monitor[4*i], monitor[4*i+1], monitor[4*i+2], monitor[4*i+3]});
        slot(1, 1024);
        for (i = 0; i < 256; i = i + 1) bridge_write(32'h2100_0000 + 4*i, {font[4*i], font[4*i+1], font[4*i+2], font[4*i+3]});
        if (with_cart) begin
            slot(2, 32256);
            for (i = 0; i < 8064; i = i + 1) bridge_write(32'h2200_0000 + 4*i, {cart[4*i], cart[4*i+1], cart[4*i+2], cart[4*i+3]});
        end
        complete = 1'b1; guard = 0;
        while (!sys.assets_valid && !asset_error && guard < 200000) begin @(negedge clk); guard = guard + 1; end
        if (!sys.assets_valid || asset_error) fail("assets not valid");
    end
endtask
task wait_fetch(input [15:0] a, input integer max_frames, input [8*40-1:0] what);
    begin
        start_frame = frames;
        while (!(sys.rk86.cpu_a == a && sys.rk86.cpu_rd)) begin
            @(posedge clk);
            if (frames - start_frame > max_frames) fail(what);
        end
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
    if (sys.rk86.cpu_write && sys.rk86.cpu_a == 16'h7605 && sys.rk86.cpu_do == 8'hFF) key_deliveries = key_deliveries + 1;
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
            if (frames - start_frame > 30) fail("the monitor did not see the key release");
        end
    end
endtask
task press_key(input [6:0] k);                // a matrix key on the second keyboard input
    integer start;
    begin
        wait_key_release;
        // 21 scans of about 2.5 ms each and the beep: about 4 frames
        tb_key = k; start = key_deliveries; start_frame = frames;
        while (key_deliveries == start) begin
            @(negedge clk);
            if (frames - start_frame > 10) fail("the monitor did not take the key");
        end
        tb_key = NO_KEY;
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
            if (frames - start_frame > 10) fail("the monitor did not take the panel key");
        end
        pad = {4'h1, 28'h0};
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
    end
endtask
task boot(input with_cart, input [1:0] boot_preset);
    begin
        load(with_cart);
        bridge_write(32'h10C, boot_preset);       // a persisted value, written before Reset Exit
        reset_n = 1'b1;
        wait_fetch(16'hFE63, 20, "no keyboard loop");
    end
endtask
task to_menu;
    begin
        type_char("R"); type_char("0"); type_char(","); type_char("1"); type_char("F"); type_char("F");
        type_char(","); type_char("0"); press_key(KEY_VK);
        wait_ram(0, 0, 512, 20, "R0,1FF,0 did not copy the loader");
        type_char("G"); type_char("0"); press_key(KEY_VK);
        wait_fetch(16'h741C, 30, "no ROM disk menu");
    end
endtask
task capture;
    begin capture_go = 1'b1; wait (capture_done); $writememh("frame.hex", frame); capture_go = 1'b0; capture_done = 1'b0; end
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
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 4000000;
    $readmemh("monitor.hex", monitor); $readmemh("font.hex", font); $readmemh("cartridge.hex", cart);
    // as the core's TBs: no interrupt source, and the write/read holds start at 0
    force sys.rk86.machine.cpu_int = 1'b0;
    force sys.rk86.hid_cols = tb_hid_cols; force sys.rk86.hid_mods = tb_hid_mods;
    sys.rk86.machine.dma_we_q = 1'b0; sys.rk86.machine.crt_we_q = 1'b0; sys.rk86.machine.crt_rd_q = 1'b0;
    if (scenario == "powerup") begin `RANDOM_UP(sys.rk86.machine, sys.rk86.native_video) end
    else begin `ZERO_UP(sys.rk86.machine, sys.rk86.native_video) end
    if (scenario == "boot" || scenario == "powerup") begin
        load(1'b1);
        bridge_write(32'h10C, 1); bridge_write(32'h104, 0);   // persisted, while reset_n is low
        reset_n = 1'b1; repeat (4) @(negedge clk);
        if (sys.controls_preset !== 2'd1 || sys.sound_on !== 1'b0) fail("persisted interact values lost at Reset Exit");
        bridge_write(32'h10C, 0); bridge_write(32'h104, 1);
        wait_fetch(16'hFE63, 20, "no keyboard loop");
        capture;
        $display("PASS %0s: assets, persisted interact values, keyboard loop at FE63, frame.hex", scenario);
    end else if (scenario == "nocart") begin
        boot(1'b0, 2'd0);
        if (sys.cartridge_valid || asset_error) fail("no ROM disk: cartridge_valid or error");
        if (sys.rk86.ext_di !== 8'hFF) fail("no ROM disk: the window does not read FF");
        $display("PASS nocart: monitor without ROM disk, A000-BFFF reads FF");
    end else if (scenario == "reset") begin
        boot(1'b1, 2'd0);
        for (i = 0; i < 256; i = i + 1) sys.rk86.mem.ram[16'h1000 + i] = i[7:0] ^ 8'h3C;
        bridge_write(32'h100, 1);
        if (!sys.rk86.reset) fail("Reset did not reset the machine");
        wait (!sys.rk86.reset);
        wait_fetch(16'hFE63, 20, "no keyboard loop after Reset");
        for (i = 0; i < 256; i = i + 1) if (sys.rk86.mem.ram[16'h1000 + i] !== (i[7:0] ^ 8'h3C)) fail("Reset changed the RAM");
        bridge_write(32'h100, 2);
        wait (sys.rk86.clear_active); wait (!sys.rk86.clear_active);
        wait_fetch(16'hFE63, 20, "no keyboard loop after Cold boot");
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
        wait_fetch(16'hFE63, 2, "the machine stopped after a lock loss");
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
        wait_fetch(16'hFE63, 2, "the machine stopped after the watchdog");
        $display("PASS watchdog: PLL reset after the timeout, relock, machine and assets kept, video restarted");
    end else if (scenario == "menu") begin
        boot(1'b1, 2'd0); to_menu;
        wait_frames(2);
        capture;
        $display("PASS menu: R0,1FF,0 copied the loader, G0 reached the ROM disk menu, frame.hex");
    end else if (scenario == "xonix") begin
        boot(1'b1, 2'd0); to_menu; type_char("4");
        wait_fetch(16'h0000, 60, "XONIX did not start at 0000");
        check_ram(0, 21760, 2816, "XONIX image differs at its start");
        n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin @(posedge clk); if (sys.rk86.cpu_rd && sys.rk86.cpu_a < 16'h0B00) n = n + 1; end
        if (n < 1000) fail("XONIX does not run");
        $display("PASS xonix: copied to 0000, started there and running");
    end else if (scenario == "dpddt") begin
        boot(1'b1, 2'd0); to_menu; type_char("3");
        wait_ram(16'h6400, 16896, 256, 30, "DP/DDT was not loaded at 6400");
        wait_frames(10);
        bridge_write(32'h100, 1); wait (!sys.rk86.reset);
        wait_fetch(16'hFE63, 20, "no keyboard loop after Reset from DP/DDT");
        $display("PASS dpddt: DP/DDT loaded at 6400 as on the real machine, Reset recovered");
    end else if (scenario == "tetris") begin
        boot(1'b1, 2'd1); to_menu; type_char("6");
        wait_fetch(16'h3000, 60, "TETRIS did not start at 3000");
        check_ram(12288, 30624, 1632, "TETRIS image differs at its start");
        repeat (64) @(negedge clk);
        pad = {4'h1, 12'h0, B_LEFT}; n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin
            @(posedge clk);
            if (!sys.rk86.kbd_rows[2]) begin if (sys.rk86.kbd_cols[7]) fail("D-pad Left is not 7 in Digits 7-8-9-6"); n = n + 1; end
        end
        pad = {4'h1, 28'h0};
        if (n == 0) fail("TETRIS never scanned row 2");
        $display("PASS tetris: started at 3000, D-pad Left = 7 with the Digits 7-8-9-6 preset");
    end else if (scenario == "k1") begin
        k1_log = $fopen("k1.log", "w");
        if (k1_line(K1_G) != 7'd39 || k1_line(K1_R) != 7'd50 || k1_line(K1_K) != 7'd43 || k1_line(K1_8) != 7'd24)
            fail("the K1 key ids of this TB do not match pocket_k1_layout.vh");
        boot(1'b0, 2'd0);
        k1_step("keyboard loop FE63, no ROM disk; L+R");
        wait_prompt(5); wait_vs(2);              // the prompt in a displayed frame
        open_panel; wait_vs(2);
        capture_k1(k1_state(K1_G, 0, 0, 0, 64'd0, 2'd0), "LAT, selection G, palette 0 (v1.1)");
        k1_step("RK typed through the panel");
        panel_press(K1_R); panel_press(K1_K);
        wait_screen("RK", 2, 5, "RK typed through the panel is not on the screen");
        select_key(K1_8);
        wait_frames(3);                          // RK in a completed, displayed frame
        panel_hold(K1_8); wait_vs(1);            // the held key in the latched state of the next frame
        capture_k1(k1_state(K1_8, 0, 0, 0, 64'd1 << 24, 2'd0), "B held on 8 (lit), RK on the screen");
        panel_release;
        wait_screen("RK8", 3, 5, "RK8 is not on the screen");
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
        wait_fetch(16'hFE51, 10, "R: the monitor did not take RUS (FE51)");
        pad = {4'h1, 28'h0}; start_frame = frames;
        while (sys.rk86.mem.ram[15'h7606] === rus_byte) begin
            @(negedge clk);
            if (frames - start_frame > 5) fail("R did not switch the monitor to RUS");
        end
        repeat (8) @(negedge clk);
        if (!sys.rk86.rus_mode) fail("R: 7606 changed, but rus_mode is not RUS");
        start_frame = frames;
        while (sys.rk86.keyboard.rus_line) begin
            @(negedge clk);
            if (frames - start_frame > 2) fail("the RUS line stays pulled after R");
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
        // CI (run_sim.py test system_k1_panel): the keyboard is enabled by assets_valid and
        // memory_ready, not by the monitor, so the panel opens right after the assets and the cold
        // clear while the monitor boots underneath. Checks the chord, the panel in the real output
        // (bus CDC, frame latch, overlay) for the palettes 0, 1, 2, the Shift latch and the Ctrl
        // line; not the typing, B lit or RUS (full k1). Risk: the captures fall in native frames
        // of about 3-9, while the monitor initialises its workspace (FE63 in frame 7); the RUS bit
        // of the state is rus_mode (RAM 7606 bit 0), so a monitor write of 7606 with bit 0 set in
        // that time would fail a capture (not seen; the STATE line of k1.log then shows rus = 1).
        k1_log = $fopen("k1.log", "w");
        if (k1_line(K1_G) != 7'd39 || k1_line(K1_R) != 7'd50 || k1_line(K1_K) != 7'd43 || k1_line(K1_8) != 7'd24)
            fail("the K1 key ids of this TB do not match pocket_k1_layout.vh");
        load(1'b0);
        bridge_write(32'h10C, 2'd0);              // a persisted value, written before Reset Exit
        reset_n = 1'b1;
        wait_frames(2);                           // written frames in both frame banks
        k1_step("assets, no ROM disk, 2 frames; L+R");
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
        $display("PASS k1_panel: panel opened without the monitor, Shift latch and Ctrl, %0d RGB captures", captures);
    end else fail("unknown scenario");
    $finish;
end
endmodule
`default_nettype wire
