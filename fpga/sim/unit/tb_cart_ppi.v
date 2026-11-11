`timescale 1ns/1ps
`default_nettype none
// pocket_cart_ppi, the ROM disk glue around the fork's k580vv55. Kiselev's 32 KB wiring (wide 0): after reset every
// pin an input (the ROM address 7FFF, port A FF); the monitor's FA68 sequence (control word 90h, SHLD
// A001h, LDA A000h) reads the ROM byte at HL; PC7 high (bit set / reset 0Fh) turns the ROM off (port A
// FF, the address kept), PC7 low (0Eh) turns it on again; a byte at an address written 1 clk before the
// read; every one of the 32768 addresses; the directions of the full 8255 (port C upper an input: the
// ROM off; port C lower or port B an input: those address pins high; port A an output: its latch);
// reset again. The 64 KB wiring (wide 1): after reset the address FFFF; PC7 is ROM A15 and no longer turns the
// ROM off; every one of the 65536 addresses; port C upper an input: A15 high, the ROM on; port A an output: its
// latch. CS / RD / WR strobes held 4 clk, as in the fork's tb_vv55.v.
module tb_cart_ppi;
reg clk = 1'b0, reset = 1'b1, cs_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1, wide = 1'b0;
reg [1:0] a = 2'd0;
reg [7:0] d_i = 8'h00, rom_data = 8'h00;
wire [7:0] d_o;
wire [15:0] rom_address;
always #5 clk = ~clk;
function [7:0] pattern(input [15:0] address);
    pattern = (address * 37) ^ address[15:8] ^ 8'hA5;
endfunction
always @(posedge clk) rom_data <= pattern(rom_address);    // the ROM data follows the address every clk
pocket_cart_ppi dut(.clk(clk), .reset(reset), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .wide(wide), .a(a), .d_i(d_i), .d_o(d_o),
    .rom_address(rom_address), .rom_data(rom_data));
integer errors = 0, i;
reg [7:0] v;
task chk(input ok, input [8*64-1:0] what);
    begin
        if (!ok) begin $display("ERROR: cart_ppi: %0s at %0t", what, $time); errors = errors + 1; end
        if (errors >= 20) begin $display("FATAL: cart_ppi: too many errors"); $finish; end
    end
endtask
task wr(input [1:0] ad, input [7:0] dd);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = ad; d_i = dd; end
        @(negedge clk) wr_n = 1'b0;
        repeat (4) @(negedge clk); wr_n = 1'b1;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
task rd(input [1:0] ad, output [7:0] dd);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = ad; end
        @(negedge clk) rd_n = 1'b0;
        repeat (4) @(negedge clk); dd = d_o; rd_n = 1'b1;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
// a port B write and a port A read that starts 1 clk after its WR↑ (CS held)
task wr_b_rd_a(input [7:0] dd, output [7:0] q);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = 2'd1; d_i = dd; end
        @(negedge clk) wr_n = 1'b0;
        repeat (4) @(negedge clk); wr_n = 1'b1;
        @(negedge clk) begin a = 2'd0; rd_n = 1'b0; end
        repeat (4) @(negedge clk); q = d_o; rd_n = 1'b1;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
initial begin
    repeat (4) @(negedge clk); reset = 1'b0; repeat (2) @(negedge clk);
    // reset: every pin an input, high
    chk(rom_address === 16'h7FFF, "reset: rom address not 7FFF");
    rd(2'd0, v); chk(v === 8'hFF, "reset: port A not FF");
    // the monitor's FA68: MVI A,90h; STA A003h; SHLD A001h (HL = 1234h); LDA A000h
    wr(2'd3, 8'h90);
    chk(rom_address === 16'h0000, "mode set: address latches not cleared");
    wr(2'd1, 8'h34); wr(2'd2, 8'h12);
    chk(rom_address === 16'h1234, "SHLD: rom address");
    rd(2'd0, v); chk(v === pattern(16'h1234), "LDA A000h: ROM byte at 1234h");
    // PC7 high: the ROM off, port A FF, the address A0-A14 unchanged; PC7 low: the byte returns
    wr(2'd3, 8'h0F);
    rd(2'd0, v); chk(v === 8'hFF && rom_address === 16'h1234, "pc7 high: port A not FF or the address changed");
    wr(2'd3, 8'h0E);
    rd(2'd0, v); chk(v === pattern(16'h1234) && rom_address === 16'h1234, "pc7 low again: ROM byte at 1234h");
    // an address written 1 clk before the read
    wr_b_rd_a(8'h56, v); chk(v === pattern(16'h1256), "read 1 clk after the address write");
    // every address
    for (i = 0; i < 32768; i = i + 1) begin
        wr(2'd1, i[7:0]); wr(2'd2, {1'b0, i[14:8]});
        chk(rom_address === i[15:0], "sweep: rom address wiring");
        rd(2'd0, v); chk(v === pattern(i[15:0]), "sweep: ROM byte");
    end
    // the directions of the full 8255
    wr(2'd3, 8'h98); wr(2'd1, 8'h21); wr(2'd2, 8'h03);           // port C upper an input: PC7 high, the ROM off
    chk(rom_address === 16'h7321, "port C upper input: address");
    rd(2'd0, v); chk(v === 8'hFF, "port C upper input: port A not FF");
    wr(2'd3, 8'h91); wr(2'd1, 8'h21); wr(2'd2, 8'h30);           // port C lower an input: PC0-PC3 high
    chk(rom_address === 16'h3F21, "port C lower input: address");
    rd(2'd0, v); chk(v === pattern(16'h3F21), "port C lower input: ROM byte");
    wr(2'd3, 8'h92); wr(2'd2, 8'h05);                            // port B an input: A0-A7 high
    chk(rom_address === 16'h05FF, "port B input: address");
    rd(2'd0, v); chk(v === pattern(16'h05FF), "port B input: ROM byte");
    wr(2'd3, 8'h80); wr(2'd0, 8'h3C);                            // port A an output: the latch, not the ROM
    rd(2'd0, v); chk(v === 8'h3C, "port A output: the latch");
    wr(2'd3, 8'h90);
    rd(2'd0, v); chk(v === pattern(16'h0000), "mode 90h again: ROM byte at 0000h");
    // reset
    @(negedge clk) reset = 1'b1; repeat (2) @(negedge clk); reset = 1'b0; repeat (2) @(negedge clk);
    chk(rom_address === 16'h7FFF, "reset again: rom address not 7FFF");
    rd(2'd0, v); chk(v === 8'hFF, "reset again: port A not FF");
    // the 64 KB wiring
    @(negedge clk) begin reset = 1'b1; wide = 1'b1; end repeat (2) @(negedge clk); reset = 1'b0; repeat (2) @(negedge clk);
    chk(rom_address === 16'hFFFF, "wide reset: rom address not FFFF");
    rd(2'd0, v); chk(v === pattern(16'hFFFF), "wide reset: port A not the ROM byte at FFFF");
    wr(2'd3, 8'h90); wr(2'd1, 8'h34); wr(2'd2, 8'h92);
    chk(rom_address === 16'h9234, "wide SHLD: rom address");
    rd(2'd0, v); chk(v === pattern(16'h9234), "wide: ROM byte above 8000h");
    wr(2'd3, 8'h0E);                                            // PC7 low: A15 0, the ROM still on
    rd(2'd0, v); chk(v === pattern(16'h1234) && rom_address === 16'h1234, "wide pc7 low: ROM byte at 1234h");
    wr(2'd3, 8'h0F);                                            // PC7 high: A15 1
    rd(2'd0, v); chk(v === pattern(16'h9234) && rom_address === 16'h9234, "wide: ROM byte above 8000h after PC7 set");
    for (i = 0; i < 65536; i = i + 1) begin
        wr(2'd1, i[7:0]); wr(2'd2, i[15:8]);
        chk(rom_address === i[15:0], "wide sweep: rom address wiring");
        rd(2'd0, v); chk(v === pattern(i[15:0]), "wide sweep: ROM byte");
    end
    wr(2'd3, 8'h98); wr(2'd1, 8'h21); wr(2'd2, 8'h03);       // port C upper an input: A15 high, the ROM on
    chk(rom_address === 16'hF321, "wide port C upper input: address");
    rd(2'd0, v); chk(v === pattern(16'hF321), "wide: ROM byte above 8000h, port C upper input");
    wr(2'd3, 8'h80); wr(2'd0, 8'h5A);                        // port A an output: the latch, not the ROM
    rd(2'd0, v); chk(v === 8'h5A, "wide port A output: the latch");
    if (errors == 0)
        $display("PASS cart_ppi: 32 KB: reset 7FFF, FA68 sequence, PC7 on / off, read 1 clk after the address, all 32768 addresses, 8255 directions, reset; 64 KB: PC7 = A15, ROM always on, all 65536 addresses, directions");
    $finish;
end
endmodule
`default_nettype wire
