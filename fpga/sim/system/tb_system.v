`timescale 1ns/1ps
`default_nettype none
// System testbench of the Pocket target (spec 9.4-9.7): pocket_system with the bridge and data
// slot signals driven as core_bridge_cmd drives them, and a PLL stub (clk_core_12288 and its
// lock: the scenario drops the lock, and the PLL reset of the watchdog unlocks it for 1000 clk).
// +scenario=boot|powerup|nocart|reset|relock|watchdog|menu|xonix|dpddt|tetris
// +timeout=<clk to wait for the monitor to take a key, default 4000000>
// Working directory: monitor.hex, font.hex, cartridge.hex (fpga/sim/run_sim.py); writes frame.hex.
`include "power_up.vh"
module tb_system;
defparam sys.pll_watchdog.TIMEOUT = 20000;   // 270 us here; 28 ms in the build
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
localparam [15:0] B_LEFT = 16'h0004, B_RIGHT = 16'h0008, B_A = 16'h0010, B_B = 16'h0020, B_L = 16'h0100;
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
task tap(input [15:0] b);                    // panel-only buttons: navigation, L
    begin pad = {4'h1, 12'h0, b}; repeat (8) @(negedge clk); pad = {4'h1, 28'h0}; repeat (8) @(negedge clk); end
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
task press_key(input [15:0] b);
    integer start;
    begin
        start_frame = frames;
        while (sys.rk86.mem.ram[15'h7609] !== 8'hFF) begin
            @(negedge clk);
            if (frames - start_frame > 30) fail("the monitor did not see the key release");
        end
        // 21 scans of about 2.5 ms each and the beep: about 4 frames
        pad = {4'h1, 12'h0, b}; start = key_deliveries; start_frame = frames;
        while (key_deliveries == start) begin
            @(negedge clk);
            if (frames - start_frame > 10) fail("the monitor did not take the key");
        end
        pad = {4'h1, 28'h0};
    end
endtask
function integer panel_index(input [7:0] c);
    begin
        if (c >= "0" && c <= "9") panel_index = c - "0";
        else if (c >= "A" && c <= "Z") panel_index = c - "A" + 10;
        else panel_index = 36;                                    // ","
    end
endfunction
task type_char(input [7:0] c);
    begin
        while (sys.rk86.keyboard.selection != panel_index(c)) tap(B_RIGHT);
        press_key(B_A);
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
        tap(B_L);
        if (!sys.rk86.keyboard.panel_open) fail("the panel did not open");
        type_char("R"); type_char("0"); type_char(","); type_char("1"); type_char("F"); type_char("F");
        type_char(","); type_char("0"); press_key(B_B);
        wait_ram(0, 0, 512, 20, "R0,1FF,0 did not copy the loader");
        type_char("G"); type_char("0"); press_key(B_B);
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
        tap(B_L); wait_frames(2);
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
        tap(B_L); repeat (64) @(negedge clk);
        pad = {4'h1, 12'h0, B_LEFT}; n = 0; start_frame = frames;
        while (frames < start_frame + 3) begin
            @(posedge clk);
            if (!sys.rk86.kbd_rows[2]) begin if (sys.rk86.kbd_cols[7]) fail("D-pad Left is not 7 in Digits 7-8-9-6"); n = n + 1; end
        end
        pad = {4'h1, 28'h0};
        if (n == 0) fail("TETRIS never scanned row 2");
        $display("PASS tetris: started at 3000, D-pad Left = 7 with the Digits 7-8-9-6 preset");
    end else fail("unknown scenario");
    $finish;
end
endmodule
`default_nettype wire
