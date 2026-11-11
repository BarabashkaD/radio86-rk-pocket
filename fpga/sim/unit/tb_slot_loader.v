`timescale 1ns/1ps
`default_nettype none
// pocket_slot_loader with the font and ROM disk memories (pocket_rom8) and a monitor byte model:
// the requests (ids, sizes, only while quiesced), 4 byte writes per word in byte order, any order of
// words, bytes beyond the requested size dropped, writes while running dropped, the ROM disk read
// port with its tag, the FILL of an unwritten memory, assets_valid only after allcomplete; the ROM disk up to
// 65536 bytes and romdisk_64k (the 64 KB wiring) only above 32768.
module tb_slot_loader;
reg clk = 1'b0;
always #5 clk = ~clk;
reg reset_n = 1'b0, quiesced = 1'b1, request = 1'b0, complete = 1'b0, wr = 1'b0;
reg [15:0] id = 16'd0;
reg [31:0] size = 32'd0, address = 32'd0, data = 32'd0;
reg [15:0] ra = 16'd0;
wire ack, ok, valid, monitor_we, font_we, romdisk_we, romdisk_64k;
wire [15:0] byte_a, tag, fresh_tag;
wire [7:0] byte_d, rd, fresh_rd;
pocket_slot_loader dut(.clk(clk), .reset_n(reset_n), .machine_quiesced(quiesced),
    .request_write(request), .request_id(id), .request_size(size), .request_ack(ack), .request_ok(ok),
    .allcomplete(complete), .bridge_wr(wr), .bridge_address(address), .bridge_data(data), .assets_valid(valid),
    .monitor_we(monitor_we), .font_we(font_we), .romdisk_we(romdisk_we), .romdisk_64k(romdisk_64k), .byte_a(byte_a),
    .byte_d(byte_d));
pocket_rom8 #(.AW(10), .FILL(8'h00)) font_rom(.clk(clk), .we(font_we), .wa(byte_a[9:0]), .wd(byte_d),
    .ra(10'd0), .rd(), .tag());
pocket_rom8 #(.AW(16), .FILL(8'hFF)) romdisk(.clk(clk), .we(romdisk_we), .wa(byte_a), .wd(byte_d),
    .ra(ra), .rd(rd), .tag(tag));
pocket_rom8 #(.AW(16), .FILL(8'hFF)) fresh(.clk(clk), .we(1'b0), .wa(16'd0), .wd(8'h00),
    .ra(ra), .rd(fresh_rd), .tag(fresh_tag));
reg [7:0] monitor [0:2047];
integer i;
initial for (i = 0; i < 2048; i = i + 1) monitor[i] = 8'hFF;
always @(posedge clk) if (monitor_we) monitor[byte_a[10:0]] <= byte_d;
task fail(input [8*64-1:0] what);
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
// one bridge word, then 5 idle clk (APF writes at most one word per 88 clk)
task word(input [31:0] a, input [31:0] d);
    begin @(negedge clk); address = a; data = d; wr = 1'b1; @(negedge clk); wr = 1'b0; repeat (5) @(negedge clk); end
endtask
// a byte pattern that differs between neighbouring bytes and between 256-byte pages
function [7:0] pat(input integer s, input integer n);
    pat = n * 7 + s * 61 + (n >> 8);
endfunction
function [31:0] wpat(input integer s, input integer n);   // the word of bytes n..n+3, first byte in 31:24
    wpat = {pat(s, n), pat(s, n + 1), pat(s, n + 2), pat(s, n + 3)};
endfunction
initial begin
    repeat (3) @(negedge clk); reset_n = 1'b1; @(negedge clk);
    // refused: an unknown slot, sizes above the ranges
    slot(3, 4, 1'b0); slot(0, 2049, 1'b0); slot(1, 1025, 1'b0); slot(2, 65537, 1'b0);
    if (romdisk_64k !== 1'b0) fail("romdisk_64k without a ROM disk");
    // the ROM disk size picks the wiring: above 32768 bytes the 64 KB one
    slot(2, 32256, 1'b1); if (romdisk_64k !== 1'b0) fail("romdisk_64k at 32256 bytes");
    slot(2, 32769, 1'b1); if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 32769 bytes");
    slot(2, 32768, 1'b1); if (romdisk_64k !== 1'b0) fail("romdisk_64k at 32768 bytes");
    // the ROM disk: 65536 bytes, the words in descending order, one written twice
    slot(2, 65536, 1'b1); if (romdisk_64k !== 1'b1) fail("romdisk_64k not set at 65536 bytes");
    for (i = 16383; i >= 0; i = i - 1) begin
        word(32'h2200_0000 + 4 * i, wpat(2, 4 * i));
        if (i == 12) word(32'h2200_0000 + 4 * i, wpat(2, 4 * i));
    end
    // the font: 1022 bytes asked for, 256 words written: bytes 1022 and 1023 keep the fill 00
    slot(1, 1022, 1'b1);
    for (i = 0; i < 256; i = i + 1) word(32'h2100_0000 + 4 * i, wpat(1, 4 * i));
    // the monitor: 2048 bytes, then a word at 0x800, beyond the size: dropped (else it wraps onto 0-3)
    slot(0, 2048, 1'b1);
    for (i = 0; i < 512; i = i + 1) word(32'h2000_0000 + 4 * i, wpat(0, 4 * i));
    word(32'h2000_0800, 32'h11223344);
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
    for (i = 0; i < 65536; i = i + 1)
        if (romdisk.mem[i] !== pat(2, i)) begin $display("ERROR: ROM disk byte %0h is %h", i, romdisk.mem[i]); $finish; end
    // the read port: data and tag 1 clk after the address; an unwritten memory reads its FILL
    for (i = 0; i < 65536; i = i + 97) begin
        @(negedge clk); ra = i; @(negedge clk);
        if (tag !== i[15:0] || rd !== pat(2, i)) fail("ROM disk read port: data or tag");
        if (fresh_tag !== i[15:0] || fresh_rd !== 8'hFF) fail("an unwritten ROM disk does not read FF");
    end
    // the machine running: requests refused, bridge words dropped
    quiesced = 1'b0;
    slot(1, 1024, 1'b0);
    word(32'h2100_0000, 32'hDEADBEEF);
    if (font_rom.mem[0] !== pat(1, 0)) fail("a write while running reached the font");
    $display("PASS slot_loader: requests and sizes, the 64 KB ROM disk and its wiring flag, 4 byte writes per word in order, any word order, size limit, writes while running dropped, read port and tag, FILL, assets_valid");
    $finish;
end
endmodule
`default_nettype wire
