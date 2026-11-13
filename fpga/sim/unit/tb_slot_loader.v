`timescale 1ns/1ps
`default_nettype none
// pocket_slot_loader with the PSRAM controller (pocket_psram) on the PSRAM model (psram_model, the whole
// die: AW = 22, FILL 0: unwritten words are X), the font memory (pocket_rom8) and a monitor byte model,
// at the clk_74a rate; bridge words 88 clk apart (APF's maximum rate). Checks, in order:
// - requests: ids, sizes (the ROM disk up to 8388608 bytes), only while quiesced; romdisk_loaded 0
//   before any accepted ROM disk request (a refused one included), 1 after;
// - the wiring flags: 32256 and 32768 bytes: romdisk_64k 0, romdisk_card 0; 32769 and 65536: romdisk_64k
//   1, romdisk_card 0 (a 64 KB image stays in the 64 KB wiring); 65537 and 8388608: both 1;
// - the ROM disk at 8 MB (after the controller's start-up): words at byte offsets 0, 4 << k (k = 0..20)
//   and 7FFFFCh, then the block 0000h-0FFFh in descending order (one word twice); each bridge word as
//   two PSRAM words (the even ROM byte in D7-D0), one romdisk_wr per accepted word;
// - the size limit: 1000 bytes, a word at 996 written, the word at 1000 dropped;
// - a shorter image (32256 bytes) after the 8 MB one: the new bytes in 0000h-0FFFh, the old tail kept;
// - the monitor and the font: 4 byte writes per word in byte order, bytes beyond the size dropped; the
//   font read port and its tag; assets_valid only after allcomplete;
// - the machine running: requests refused, font and ROM disk words dropped.
// The PSRAM model stops the simulation at its first timing or protocol ERROR.
module tb_slot_loader;
reg clk = 1'b0;
always #6.734 clk = ~clk;                  // 74.25 MHz
reg reset_n = 1'b0, quiesced = 1'b1, request = 1'b0, complete = 1'b0, wr = 1'b0;
reg [15:0] id = 16'd0;
reg [31:0] size = 32'd0, address = 32'd0, data = 32'd0;
reg [9:0] fra = 10'd0;
reg [22:0] rd_addr = 23'd0;
wire ack, ok, valid, monitor_we, font_we, romdisk_wr, romdisk_loaded, romdisk_64k, romdisk_card;
wire [20:0] romdisk_word;
wire [31:0] romdisk_data;
wire [15:0] byte_a;
wire [7:0] byte_d, frd, rd_data;
wire [9:0] ftag;
wire psram_ready, rd_ready;
wire [21:16] cram_a;
wire [15:0] cram_dq;
wire cram_adv_n, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n, cram_cre, cram_clk;
pocket_slot_loader dut(.clk(clk), .reset_n(reset_n), .machine_quiesced(quiesced),
    .request_write(request), .request_id(id), .request_size(size), .request_ack(ack), .request_ok(ok),
    .allcomplete(complete), .bridge_wr(wr), .bridge_address(address), .bridge_data(data), .assets_valid(valid),
    .monitor_we(monitor_we), .font_we(font_we), .romdisk_wr(romdisk_wr), .romdisk_word(romdisk_word),
    .romdisk_data(romdisk_data), .romdisk_loaded(romdisk_loaded), .romdisk_64k(romdisk_64k),
    .romdisk_card(romdisk_card), .byte_a(byte_a), .byte_d(byte_d));
pocket_psram ctrl(.clk(clk), .reset(!reset_n), .ready(psram_ready), .wr(romdisk_wr), .wr_word(romdisk_word),
    .wr_data(romdisk_data), .rd_addr(rd_addr), .rd_data(rd_data), .rd_ready(rd_ready), .cram_a(cram_a),
    .cram_dq(cram_dq), .cram_adv_n(cram_adv_n), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n),
    .cram_cre(cram_cre), .cram_clk(cram_clk));
psram_model #(.FILL(1'b0)) psram(.a(cram_a), .dq(cram_dq), .adv_n(cram_adv_n), .ce0_n(cram_ce0_n),
    .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram_ub_n), .lb_n(cram_lb_n), .cre(cram_cre),
    .clk(cram_clk));
pocket_rom8 #(.AW(10), .FILL(8'h00)) font_rom(.clk(clk), .we(font_we), .wa(byte_a[9:0]), .wd(byte_d),
    .ra(fra), .rd(frd), .tag(ftag));
reg [7:0] monitor [0:2047];
integer i, n, wr_count = 0;
initial for (i = 0; i < 2048; i = i + 1) monitor[i] = 8'hFF;
always @(posedge clk) if (monitor_we) monitor[byte_a[10:0]] <= byte_d;
always @(posedge clk) if (romdisk_wr) wr_count = wr_count + 1;
reg rom_phase = 1'b0;                      // only ROM disk words are sent
always @(posedge clk)
    if (rom_phase && (monitor_we || font_we)) begin
        $display("ERROR: a ROM disk word wrote the monitor or the font"); $finish;
    end

task fail(input [8*72-1:0] what);
    begin $display("ERROR: %0s", what); $finish; end
endtask
task slot(input [15:0] slot_id, input [31:0] bytes, input accepted);
    integer guard;
    begin
        @(negedge clk); id = slot_id; size = bytes; request = 1'b1; guard = 0;
        while (!ack && guard < 100) begin @(negedge clk); guard = guard + 1; end
        if (!ack || ok !== accepted) begin
            $display("ERROR: slot %0d size %0d: ok %b, expected %b", slot_id, bytes, ok, accepted); $finish;
        end
        request = 1'b0; @(negedge clk);
        if (ack) fail("ack held after the request ended");
    end
endtask
// one bridge word; the next one 88 clk later
task word(input [31:0] a, input [31:0] d);
    begin @(negedge clk); address = a; data = d; wr = 1'b1; @(negedge clk); wr = 1'b0; repeat (86) @(negedge clk); end
endtask
// a byte pattern that differs between neighbouring bytes and between 256-byte pages
function [7:0] pat(input integer s, input integer n);
    pat = n * 7 + s * 61 + (n >> 8);
endfunction
function [31:0] wpat(input integer s, input integer n);   // the word of bytes n..n+3, first byte in 31:24
    wpat = {pat(s, n), pat(s, n + 1), pat(s, n + 2), pat(s, n + 3)};
endfunction
// the two PSRAM words of the bridge word at ROM byte offset off: bytes off, off+1 in word off/2 (the
// even byte in D7-D0), off+2, off+3 in word off/2 + 1
task check_rom(input [22:0] off, input [31:0] d);
    reg [21:0] w;
    begin
        w = {off[22:2], 1'b0};
        if (psram.mem[w] !== {d[23:16], d[31:24]}) begin
            $display("ERROR: ROM disk word %h is %h, expected %h", w, psram.mem[w], {d[23:16], d[31:24]}); $finish;
        end
        w = {off[22:2], 1'b1};
        if (psram.mem[w] !== {d[7:0], d[15:8]}) begin
            $display("ERROR: ROM disk word %h is %h, expected %h", w, psram.mem[w], {d[7:0], d[15:8]}); $finish;
        end
    end
endtask
// the same comparison with the caller's message
task check_kept(input [22:0] off, input [31:0] d, input [8*72-1:0] what);
    begin
        if (psram.mem[{off[22:2], 1'b0}] !== {d[23:16], d[31:24]} || psram.mem[{off[22:2], 1'b1}] !== {d[7:0], d[15:8]}) begin
            $display("ERROR: %0s: ROM disk bytes %h are %h %h", what, off, psram.mem[{off[22:2], 1'b0}],
                psram.mem[{off[22:2], 1'b1}]);
            $finish;
        end
    end
endtask

reg [22:0] offs [0:22];
initial begin
    offs[0] = 23'd0;
    for (i = 0; i <= 20; i = i + 1) offs[i + 1] = 23'd4 << i;
    offs[22] = 23'h7FFFFC;

    repeat (3) @(negedge clk); reset_n = 1'b1; @(negedge clk);
    if (romdisk_loaded !== 1'b0 || romdisk_64k !== 1'b0 || romdisk_card !== 1'b0) fail("ROM disk flags without a ROM disk");
    // refused: an unknown slot, sizes above the ranges
    slot(3, 4, 1'b0); slot(0, 2049, 1'b0); slot(1, 1025, 1'b0); slot(2, 8388609, 1'b0);
    if (romdisk_loaded !== 1'b0) fail("romdisk_loaded after a refused ROM disk request");
    slot(2, 8388608, 1'b1);
    if (romdisk_loaded !== 1'b1) fail("romdisk_loaded not set after an accepted ROM disk request");
    // the ROM disk size picks the wiring: above 32768 bytes the 64 KB one, above 65536 the card
    slot(2, 32256, 1'b1);
    if (romdisk_64k !== 1'b0) fail("romdisk_64k at 32256 bytes");
    if (romdisk_card !== 1'b0) fail("romdisk_card at 32256 bytes");
    slot(2, 32769, 1'b1);
    if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 32769 bytes");
    if (romdisk_card !== 1'b0) fail("romdisk_card at 32769 bytes");
    slot(2, 32768, 1'b1);
    if (romdisk_64k !== 1'b0) fail("romdisk_64k at 32768 bytes");
    if (romdisk_card !== 1'b0) fail("romdisk_card at 32768 bytes");
    slot(2, 65537, 1'b1);
    if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 65537 bytes");
    if (romdisk_card !== 1'b1) fail("romdisk_card not set at 65537 bytes");
    slot(2, 65536, 1'b1);
    if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 65536 bytes");
    if (romdisk_card !== 1'b0) fail("romdisk_card at 65536 bytes");
    slot(2, 8388608, 1'b1);
    if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 8388608 bytes");
    if (romdisk_card !== 1'b1) fail("romdisk_card not set at 8388608 bytes");
    if (romdisk_loaded !== 1'b1) fail("romdisk_loaded not set after an accepted ROM disk request");

    // the controller's start-up (BCR write) before the first ROM disk word
    n = 0;
    while (psram_ready !== 1'b1) begin
        @(negedge clk); n = n + 1;
        if (n > 11300) fail("the PSRAM controller not ready");
    end
    if (wr_count != 0) fail("romdisk_wr without a ROM disk word");

    // the ROM disk at 8 MB: single words at 23-bit offsets, then 0000h-0FFFh descending, one word twice
    rom_phase = 1'b1;
    for (i = 0; i < 23; i = i + 1) word(32'h2200_0000 + offs[i], wpat(2, offs[i]));
    for (i = 1023; i >= 0; i = i - 1) begin
        word(32'h2200_0000 + 4 * i, wpat(2, 4 * i));
        if (i == 12) word(32'h2200_0000 + 4 * i, wpat(2, 4 * i));
    end
    for (i = 0; i < 23; i = i + 1) check_rom(offs[i], wpat(2, offs[i]));
    for (i = 0; i < 1024; i = i + 1) check_rom(4 * i, wpat(2, 4 * i));
    if (wr_count != 23 + 1025) begin
        $display("ERROR: %0d romdisk_wr clk for %0d ROM disk words", wr_count, 23 + 1025); $finish;
    end

    // the size limit: 1000 bytes; the word at 996 written, the word at 1000 dropped
    slot(2, 1000, 1'b1);
    if (romdisk_loaded !== 1'b1 || romdisk_64k !== 1'b0 || romdisk_card !== 1'b0) fail("ROM disk flags at 1000 bytes");
    word(32'h2200_0000 + 996, wpat(4, 996));
    word(32'h2200_0000 + 1000, wpat(4, 1000));
    check_rom(996, wpat(4, 996));
    check_kept(1000, wpat(2, 1000), "a ROM disk word at the size written");

    // a shorter image after the 8 MB one: the new bytes win, the old tail stays
    slot(2, 32256, 1'b1);
    for (i = 0; i < 1024; i = i + 1) word(32'h2200_0000 + 4 * i, wpat(3, 4 * i));
    for (i = 0; i < 1024; i = i + 1) check_rom(4 * i, wpat(3, 4 * i));
    for (i = 0; i < 23; i = i + 1)
        if (offs[i] >= 23'h1000) check_kept(offs[i], wpat(2, offs[i]), "a shorter image changed the old tail");
    if (wr_count != 23 + 1025 + 1 + 1024) begin
        $display("ERROR: %0d romdisk_wr clk for %0d ROM disk words", wr_count, 23 + 1025 + 1 + 1024); $finish;
    end
    rom_phase = 1'b0;

    // the font: 1022 bytes asked for, 256 words written: bytes 1022 and 1023 keep the fill 00
    slot(1, 1022, 1'b1);
    for (i = 0; i < 256; i = i + 1) word(32'h2100_0000 + 4 * i, wpat(1, 4 * i));
    // the monitor: 2048 bytes, then a word at 0x800, beyond the size: dropped (else it wraps onto 0-3)
    slot(0, 2048, 1'b1);
    for (i = 0; i < 512; i = i + 1) word(32'h2000_0000 + 4 * i, wpat(0, 4 * i));
    word(32'h2000_0800, 32'h11223344);
    if (wr_count != 23 + 1025 + 1 + 1024) fail("romdisk_wr for a monitor or font word");
    if (valid) fail("assets_valid before allcomplete");
    @(negedge clk); complete = 1'b1; repeat (2) @(negedge clk);
    if (!valid) fail("assets_valid not set after allcomplete");
    complete = 1'b0; repeat (3) @(negedge clk);
    if (!valid) fail("assets_valid dropped with allcomplete");
    if (font_rom.mem[1022] !== 8'h00 || font_rom.mem[1023] !== 8'h00) fail("byte beyond the size written");
    if (monitor[0] !== pat(0, 0) || monitor[1] !== pat(0, 1) || monitor[2] !== pat(0, 2) || monitor[3] !== pat(0, 3))
        fail("byte order: bits 31:24 are the first byte");
    for (i = 0; i < 2048; i = i + 1)
        if (monitor[i] !== pat(0, i)) begin $display("ERROR: monitor byte %0h is %h", i, monitor[i]); $finish; end
    for (i = 0; i < 1022; i = i + 1)
        if (font_rom.mem[i] !== pat(1, i)) begin $display("ERROR: font byte %0h is %h", i, font_rom.mem[i]); $finish; end
    // the font read port: data and tag 1 clk after the address
    for (i = 0; i < 1024; i = i + 7) begin
        @(negedge clk); fra = i; @(negedge clk);
        if (ftag !== i[9:0] || frd !== (i < 1022 ? pat(1, i) : 8'h00)) fail("font read port: data or tag");
    end

    // the machine running: requests refused, font and ROM disk words dropped
    quiesced = 1'b0;
    slot(1, 1024, 1'b0);
    slot(2, 4, 1'b0);
    word(32'h2100_0000, 32'hDEADBEEF);
    if (font_rom.mem[0] !== pat(1, 0)) fail("a write while running reached the font");
    word(32'h2200_0000, 32'hDEADBEEF);
    if (wr_count != 23 + 1025 + 1 + 1024) fail("a write while running reached the ROM disk");
    check_kept(0, wpat(3, 0), "a write while running reached the ROM disk");
    $display("PASS slot_loader: requests and sizes up to 8 MB, romdisk_64k and romdisk_card, ROM disk words at 23-bit offsets as 2 PSRAM words, size limit, shorter reload keeps the tail, monitor and font bytes, writes while running dropped, font read port, assets_valid");
    $finish;
end
endmodule
`default_nettype wire
