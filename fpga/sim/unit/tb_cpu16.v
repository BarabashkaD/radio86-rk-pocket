// rk86_machine16 with the CPU test program (fpga/sim/cpu16/cpu_test.asm, spec 9.1-2) in place of the
// monitor (+bios=cpu_test.hex, 2048 bytes, written by run_sim.py) on the Pocket memory: pocket_memory
// through fpga/sim/memory/tb_rk86_mem16.v (the ports of the fork's model; RAM mem.mem.ram); ce16 =
// 64 of 297 clk, reset for the first 200 ce16. Frames (spec 7): VRTC rises counted from the first VRTC
// rise after the 8275's VE rises (frame 0 starts there; VE must rise within 3 200 000 ce16); the run ends
// when the program writes A5 to 0010, within 30 frames. Checks:
//   - the program's results: 0001-0007 (phase n at 0000 + n) all 00 at the end (ERROR: cpu16: phase <n>
//     case <v>); a case number written there (neither 00 nor the FF that START writes) stops the run at once
//   - start-up (GLUE-11, GLUE-12): the program's two start-up writes (80h to 8003, 55h to 0020) seen; at
//     the clk where start-up ends the keyboard 8255 kept its reset state (port A an input) and RAM 0020 is
//     not 55
//   - INTE: one rise (EI) and one fall (DI), both inside phase 5 (phase 4's result written, phase 5's not)
//   - underrun (spec 8): armed at the second VRTC rise after the first clk with the 8257 mode A4h, until
//     phase 6 starts (the 8257 mode 80h again; at least one more VRTC rise in between, so the check spans a
//     whole frame): the 8275's underrun blank never rises (stop); before the
//     arming point it is reported as an INFO line (the monitor's order: 27h before the 8257 is enabled)
//   - Preset Counters (spec 4.4, D11, Task 8 S12): after the Load Cursor command that ends the hold of
//     phase 6's E0h, the first DMA transfer after each VRTC rise (row 0's first byte) is logged; it must
//     be 76D0 (ERROR: cpu16: E0h restart out of step), in at least 2 frames; checked until phase 6's
//     result is written (phase 7 moves the 8257 block)
//   - DMA reads by the system address (review A I2), phase 7: at every 8275 DMA byte (its WR rise with
//     DACK, the byte it latched while WR was low) whose address (bus_a while WR is low) is in E000-FFFF,
//     the byte must be the program's byte at that address (ERROR: cpu16: phase 7 DMA byte); at least
//     2048 such bytes by the end (ERROR: cpu16: phase 7: <n> DMA bytes from the program)
// The checks probe the chip instances (dut.cpu, dut.dma, dut.crt, dut.ppa) and pocket_memory; they are
// sampled at the falling edge of clk, between the enables.
`include "cpu_power_up.vh"
`default_nettype none
`timescale 1ns/1ns
module tb_cpu16;
localparam integer FRAMES = 30;
localparam integer VE_LIMIT = 3200000;          // 10 frames of 319 920 ce16
localparam integer TIME_LIMIT = 12800000;       // 40 frames: the whole run
reg clk = 1'b0; always #1 clk = ~clk;
reg [8:0] cadence = 9'd0;
wire [9:0] sum = {1'b0, cadence} + 10'd64;
wire ce16 = sum >= 10'd297;
always @(posedge clk) cadence <= ce16 ? sum - 10'd297 : sum[8:0];
integer n16 = 0;
reg reset = 1'b1;
always @(posedge clk)
    if (ce16) begin
        n16 <= n16 + 1;
        if (n16 == 199) reset <= 1'b0;          // high for the first 200 ce16
    end

//---------------- the machine and the memory
wire [15:0] cpu_a, bus_a;
wire  [7:0] cpu_do, mem_di, ppa_pa;
wire        mem_rd, cpu_wr_n, rom, startup, aen, pc0, inte, pix_ce, pix, hrtc, vrtc, ext_we_n, ext_rd_n;
wire  [9:0] font_addr;
reg   [7:0] font_data = 8'h00;
rk86_machine16 dut(.clk(clk), .ce16(ce16), .reset(reset), .cpu_a(cpu_a), .bus_a(bus_a), .cpu_do(cpu_do),
    .mem_rd(mem_rd), .cpu_wr_n(cpu_wr_n), .rom(rom), .startup(startup), .aen(aen), .mem_di(mem_di),
    .ppa_pa(ppa_pa), .kbd_cols(8'hFF), .kbd_shift(3'b111), .tape_in(1'b0), .pc0(pc0), .inte(inte),
    .font_addr(font_addr), .font_data(font_data), .pix_ce(pix_ce), .pix(pix), .hrtc(hrtc), .vrtc(vrtc),
    .ext_we_n(ext_we_n), .ext_rd_n(ext_rd_n), .ext_di(8'hFF));
tb_rk86_mem16 mem(.clk(clk), .bus_a(bus_a), .cpu_do(cpu_do), .cpu_wr_n(cpu_wr_n), .rom(rom), .aen(aen),
    .mem_rd(mem_rd), .mem_di(mem_di));

//---------------- errors
integer errors = 0;
task fail; begin
    errors = errors + 1;
    if (errors >= 20) begin $display("FATAL: cpu16: too many errors"); $finish; end
end endtask

//---------------- power-up, the program
reg [8*512-1:0] bios_file;
initial begin
    `CPU16_ZERO(dut.cpu)
    if (!$value$plusargs("bios=%s", bios_file)) begin $display("FATAL: cpu16: no +bios=<hex file>"); $finish; end
    $readmemh(bios_file, mem.bios);
    if ((^mem.bios[0]) === 1'bx || (^mem.bios[2047]) === 1'bx) begin
        $display("FATAL: cpu16: the program %0s is not 2048 bytes", bios_file); $finish; end
end

//---------------- state
reg ve_q = 1'b0, vrtc_q = 1'b0, ub_q = 1'b0, su_q = 1'b1, inte_q = 1'b0, dack2_q = 1'b1, crt_wr_q = 1'b1;
reg ve_seen = 1'b0, a4_seen = 1'b0, armed = 1'b0, boot_ur = 1'b0, p6 = 1'b0, preset_seen = 1'b0, lc_seen = 1'b0;
reg want_row0 = 1'b0, su_w_ppa = 1'b0, su_w_ram = 1'b0, finished = 1'b0, r6_marked = 1'b0;
reg cmd_sel = 1'b0, dma_sel = 1'b0, p7 = 1'b0;
reg [7:0] cmd_d = 8'h00;
reg [15:0] dma_a = 16'h0000;
integer frame = -1;                 // -1 before frame 0
integer a4_rises = 0, armed_rises = 0, su_falls = 0, inte_rises = 0, inte_falls = 0, row0_logged = 0, row0_frame = 0, k;
integer rom_dma = 0, rom_dma_bad = 0;
localparam integer ROM_DMA_MIN = 2048;

task results; begin
    $display("INFO: cpu16: results 0001-0007 %h %h %h %h %h %h %h, 0010 %h", mem.mem.ram[1], mem.mem.ram[2],
             mem.mem.ram[3], mem.mem.ram[4], mem.mem.ram[5], mem.mem.ram[6], mem.mem.ram[7], mem.mem.ram[16'h0010]);
end endtask

always @(negedge clk) if (!finished) begin
    //---------------- start-up: the program's writes are lost, the decoder is off
    if (dut.startup && !dut.cpu_wr_n) begin
        if (dut.cpu_a == 16'h8003 && dut.cpu_do == 8'h80) su_w_ppa = 1'b1;
        if (dut.cpu_a == 16'h0020 && dut.cpu_do == 8'h55) su_w_ram = 1'b1;
    end
    if (su_q && !dut.startup) begin
        su_falls = su_falls + 1;
        if (!su_w_ppa || !su_w_ram) begin
            $display("ERROR: cpu16: the start-up writes not seen (8003 %b, 0020 %b)", su_w_ppa, su_w_ram); fail;
        end
        if (dut.ppa.pa_oe !== 1'b0) begin
            $display("ERROR: cpu16: device written during start-up (8255 port A an output, ce16 %0d)", n16); fail;
        end
        if (mem.mem.ram[16'h0020] === 8'h55) begin
            $display("ERROR: cpu16: RAM written during start-up (0020 = 55, ce16 %0d)", n16); fail;
        end
    end
    su_q = dut.startup;
    //---------------- INTE: EI and DI of phase 5
    if (!inte_q && dut.inte) begin
        inte_rises = inte_rises + 1;
        if (mem.mem.ram[4] === 8'hFF || mem.mem.ram[5] !== 8'hFF) begin
            $display("ERROR: cpu16: phase 5 inte rose outside phase 5 (0004 %h, 0005 %h)", mem.mem.ram[4], mem.mem.ram[5]); fail;
        end
    end
    if (inte_q && !dut.inte) begin
        inte_falls = inte_falls + 1;
        if (mem.mem.ram[5] !== 8'hFF) begin
            $display("ERROR: cpu16: phase 5 inte fell outside phase 5 (0005 %h)", mem.mem.ram[5]); fail;
        end
    end
    inte_q = dut.inte;
    //---------------- the display enable and the frames
    if (!ve_q && dut.crt.ve) ve_seen = 1'b1;
    ve_q = dut.crt.ve;
    if (!ve_seen && n16 >= VE_LIMIT) begin
        $display("ERROR: cpu16: display never enabled (%0d ce16)", n16); fail; results; finished = 1'b1; $finish;
    end
    if (n16 >= TIME_LIMIT) begin                     // e.g. the 8275 held by Preset Counters for good
        $display("ERROR: cpu16: no end mark at 0010 in %0d ce16 (frame %0d)", n16, frame); fail; results;
        finished = 1'b1; $finish;
    end
    if (!a4_seen && dut.dma.mode == 8'hA4) a4_seen = 1'b1;
    // the 8275 commands at WR rise (as the 8275 takes them): Preset Counters and Load Cursor in phase 6
    // and the DMA bytes (DACK with WR): the address while WR is low, the byte the 8275 latched (w_d)
    if (!dut.crt.wr_n) begin
        cmd_sel = !dut.crt.cs_n && dut.crt.a0 && dut.crt.dack_n;
        cmd_d = dut.crt.d_i;
        dma_sel = !dut.crt.dack_n;
        if (dma_sel) dma_a = bus_a;
    end else if (!crt_wr_q) begin
        if (cmd_sel) begin
            if (p6 && cmd_d == 8'hE0) preset_seen = 1'b1;
            if (preset_seen && !lc_seen && cmd_d == 8'h80) lc_seen = 1'b1;
        end
        // phase 7 (review A I2): a DMA read of E000-FFFF delivers the program (the monitor ROM)
        if (dma_sel && dma_a[15:13] == 3'b111) begin
            rom_dma = rom_dma + 1;
            if (dut.crt.w_d !== mem.bios[dma_a[10:0]]) begin
                rom_dma_bad = rom_dma_bad + 1;
                if (rom_dma_bad <= 5) begin
                    $display("ERROR: cpu16: phase 7 DMA byte %h at %h, expected the program byte %h (frame %0d)",
                             dut.crt.w_d, dma_a, mem.bios[dma_a[10:0]], frame); fail;
                end
            end
        end
        cmd_sel = 1'b0; dma_sel = 1'b0;
    end
    crt_wr_q = dut.crt.wr_n;
    // phase 7 starts once phase 6's result is written (0006 from START's FF to 00; the RAM starts at 00):
    // the row 0 check of phase 6 ends there
    if (mem.mem.ram[6] === 8'hFF) r6_marked = 1'b1;
    if (!p7 && r6_marked && mem.mem.ram[6] === 8'h00) begin p7 = 1'b1; want_row0 = 1'b0; end
    // phase 6 starts with the write of 80h to the 8257 mode register
    if (a4_seen && !p6 && dut.dma.mode == 8'h80) begin
        p6 = 1'b1;
        if (!armed || armed_rises < 1) begin
            $display("ERROR: cpu16: phase 6 started before the underrun check spanned a frame (armed %b, %0d VRTC rises, frame %0d)",
                     armed, armed_rises, frame); fail;
        end
    end
    // underrun (spec 8)
    if (!ub_q && dut.crt.ublank) begin
        if (!armed) boot_ur = 1'b1;
        else if (!p6) begin
            $display("ERROR: cpu16: underrun (the 8275 blanked in frame %0d, ce16 %0d)", frame, n16); fail;
            results; finished = 1'b1; $finish;
        end
    end
    ub_q = dut.crt.ublank;
    if (!vrtc_q && dut.vrtc) begin
        if (ve_seen) frame = frame + 1;
        if (armed && !p6) armed_rises = armed_rises + 1;
        if (a4_seen && !armed) begin
            a4_rises = a4_rises + 1;
            if (a4_rises == 2) begin
                armed = 1'b1;
                $display("INFO: cpu16: underrun at boot %0d (DU before the 8257 was enabled: data sheet behaviour, spec section 8)",
                         boot_ur);
            end
        end
        if (lc_seen && !p7) begin
            if (want_row0) begin
                $display("ERROR: cpu16: E0h restart out of step (row 0 not fetched in frame %0d)", row0_frame); fail;
            end
            want_row0 = 1'b1; row0_frame = frame;
        end
        if (frame >= FRAMES) begin
            $display("ERROR: cpu16: no end mark at 0010 in %0d frames", FRAMES); fail; results;
            finished = 1'b1; $finish;
        end
    end
    vrtc_q = dut.vrtc;
    // row 0's first byte after the VRTC rise: the first DACK2 fall
    if (dack2_q && !dut.dma.dack_n[2] && want_row0) begin
        want_row0 = 1'b0; row0_logged = row0_logged + 1;
        $display("INFO: cpu16: after E0h row 0 is fetched from %h in frame %0d", dut.dma.a_o, row0_frame);
        if (dut.dma.a_o !== 16'h76D0) begin
            $display("ERROR: cpu16: E0h restart out of step (row 0 from %h in frame %0d, expected 76d0)",
                     dut.dma.a_o, row0_frame); fail;
        end
    end
    dack2_q = dut.dma.dack_n[2];
    //---------------- a failing phase stops the run at once (its case number: neither 00 nor the FF of START)
    for (k = 1; k <= 7; k = k + 1)
        if (!finished && mem.mem.ram[k] !== 8'h00 && mem.mem.ram[k] !== 8'hFF) begin
            $display("ERROR: cpu16: phase %0d case %0d (frame %0d)", k, mem.mem.ram[k], frame); fail;
            results; finished = 1'b1; $finish;
        end
    //---------------- the end mark
    if (!finished && mem.mem.ram[16'h0010] == 8'hA5) begin
        finished = 1'b1;
        for (k = 1; k <= 7; k = k + 1)
            if (mem.mem.ram[k] !== 8'h00) begin
                $display("ERROR: cpu16: phase %0d case %0d%0s", k, mem.mem.ram[k], mem.mem.ram[k] === 8'hFF ? " (not run)" : "");
                fail;
            end
        if (su_falls != 1) begin $display("ERROR: cpu16: start-up ended %0d times, expected 1", su_falls); fail; end
        if (mem.mem.ram[16'h0020] === 8'h55) begin $display("ERROR: cpu16: RAM 0020 = 55"); fail; end
        if (inte_rises != 1 || inte_falls != 1 || dut.inte !== 1'b0) begin
            $display("ERROR: cpu16: phase 5 inte: %0d rises, %0d falls, now %b (expected 1, 1, 0)",
                     inte_rises, inte_falls, dut.inte); fail;
        end
        if (!armed || !p6) begin $display("ERROR: cpu16: underrun check armed %b, phase 6 seen %b", armed, p6); fail; end
        if (!preset_seen || !lc_seen) begin
            $display("ERROR: cpu16: Preset Counters seen %b, Load Cursor seen %b", preset_seen, lc_seen); fail;
        end
        if (row0_logged < 2) begin
            $display("ERROR: cpu16: row 0 logged in %0d frames after the Load Cursor, expected at least 2", row0_logged); fail;
        end
        $display("INFO: cpu16: phase 7: %0d DMA bytes from E000-FFFF, %0d not the program byte", rom_dma, rom_dma_bad);
        if (rom_dma < ROM_DMA_MIN) begin
            $display("ERROR: cpu16: phase 7: %0d DMA bytes from the program, expected at least %0d", rom_dma, ROM_DMA_MIN); fail;
        end
        results;
        $display("INFO: cpu16: end mark in frame %0d (ce16 %0d)", frame, n16);
        if (errors == 0) $display("PASS: cpu16 (%0d frames)", frame);
        $finish;
    end
end
endmodule
`default_nettype wire
