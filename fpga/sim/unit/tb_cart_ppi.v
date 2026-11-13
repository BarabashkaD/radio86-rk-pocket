`timescale 1ns/1ps
`default_nettype none
// pocket_cart_ppi, the ROM disk glue around the fork's k580vv55, with its ROM data from the PSRAM: rom_address
// is pocket_psram's rd_addr, rom_data its rd_data, on psram_model (AW = 22: the whole die, FILL 1: FFFF),
// whose words 0..262143 (ROM bytes 0-7FFFF: banks 0-7) are filled after time 0 (after the model's own fill)
// with {pattern(2w+1), pattern(2w)} (the even ROM byte in D7-D0). pattern() depends on A0-A22, so a byte
// read in the wrong bank differs. An address beyond bank 7 reads FF (never an access the model refuses).
// All at the clk_74a rate (74.25 MHz), so the model's ns checks see the build's tick lengths. The PSRAM
// controller is reset once (the power-up reset) and the TB waits for its ready; the 8255 has its own reset
// (the machine reset); card_reset (power-up, slot load, Cold boot) clears the bank only.
// 32 KB card (wide 0, card 0): A15 not wired, 8000-FFFF mirror 0000-7FFF: after reset every pin an input
// (the ROM address 7FFF, port A the byte at 7FFF); the monitor's FA68 sequence (control word 90h, SHLD
// A001h, LDA A000h) reads the ROM byte at HL; PC7 high (bit set 0Fh) keeps A15 0 and port A on; a port A
// read READ_AFTER_WR clk after the port B write that set the address; every one of the 32768 addresses
// 0000-7FFF; F3A5 reads 73A5; the directions of the full 8255 (port C upper an input: PC7 high, the mirror;
// port C lower or port B an input: those address pins high; port A an output: its latch); reset again.
// 64 KB card (wide 1, card 0): after reset the address FFFF; PC7 is ROM A15; every one of the 65536
// addresses; port C upper an input: A15 high; port A an output: its latch.
// Bank card (wide 1, card 1): card reset: bank 0; events (PC7 falls, PC0-PC6 high after it; the latch takes
// PB0-PB6) from bank 0: FF->7F PB 03, 80->7F PB 01, C3->7F PB 06, FE->7F PB 04, BSR 0Eh from FF PB 07 (SELBK),
// FF->7F PB 85h (PB7 ignored: bank 5); each: rom_address checked, then port A READ_AFTER_WR clk after the
// event's WR rise (the PSRAM's latency after the bank change). Bank 2, then with PB 06 written first, no
// event: FF->7E, FF->3F, FF->00, 7F->80, FE->FF, 7E->7F, 7F->7F again with PB 66h, BSR set PC7 from 7F,
// BSR reset PC0 then PC7 from FF, mode set 90h from FF, port C 00..FF ascending, an FA68 wrap FFF0..000F;
// the machine reset keeps bank 2; the card reset clears it. Not a bank card: an FF->7F event with card 0
// leaves the bank 0. Outside the card: bank 4, then card 0: the bank is not used (A16-A22 0).
// No image (loaded 0): port A FF on all three cards, at addresses whose byte is not FF.
// CS / RD / WR strobes held 4 clk, as in the fork's tb_vv55.v. Every port A read: RD falls READ_AFTER_WR clk
// after the last WR rise (or the 8255's reset, a card reset or a card change), d_o taken 4 clk later.
module tb_cart_ppi;
// The 8080's shortest port-write to port-A-read interval: after the write, the next instruction's M1
// (4 T-states) comes before the read cycle; the CPU runs at 16 MHz / 9 = 1.778 MHz (562.5 ns a T-state),
// 4 x 562.5 ns = 2250 ns = 167 clk of 74.25 MHz. The TB reads at READ_AFTER_WR, about half of that.
localparam integer BUS_MIN_CLK = 167;
localparam integer READ_AFTER_WR = 80;
localparam real T_CLK = 13.468;          // ns, one clk_74a tick
initial if (2 * READ_AFTER_WR >= BUS_MIN_CLK) begin $display("FATAL: cart_ppi: READ_AFTER_WR not below half the 8080's minimum"); $finish; end
reg clk = 1'b0, reset = 1'b1, card_reset = 1'b1, psram_reset = 1'b1, cs_n = 1'b1, rd_n = 1'b1, wr_n = 1'b1;
reg wide = 1'b0, card = 1'b0, loaded = 1'b1;
reg [1:0] a = 2'd0;
reg [7:0] d_i = 8'h00;
wire [7:0] d_o, rom_data;
wire [22:0] rom_address;
wire ready, rd_ready;
wire [21:16] cram_a;
wire [15:0] cram_dq;
wire cram_adv_n, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n, cram_cre, cram_clk;
always #6.734 clk = ~clk;                // 74.25 MHz
function [7:0] pattern(input [22:0] address);
    pattern = (address[7:0] * 8'd37) ^ address[15:8] ^ {address[22:16], 1'b1} ^ 8'hA5;
endfunction
pocket_cart_ppi dut(.clk(clk), .reset(reset), .card_reset(card_reset), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n),
    .wide(wide), .card(card), .loaded(loaded), .a(a), .d_i(d_i), .d_o(d_o), .rom_address(rom_address),
    .rom_data(rom_data));
pocket_psram psram_ctl(.clk(clk), .reset(psram_reset), .ready(ready), .wr(1'b0), .wr_word(21'd0), .wr_data(32'd0),
    .rd_addr(rom_address), .rd_data(rom_data), .rd_ready(rd_ready), .cram_a(cram_a), .cram_dq(cram_dq),
    .cram_adv_n(cram_adv_n), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n),
    .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n), .cram_cre(cram_cre), .cram_clk(cram_clk));
psram_model #(.FILL(1'b1), .AW(22)) psram(.a(cram_a), .dq(cram_dq), .adv_n(cram_adv_n), .ce0_n(cram_ce0_n),
    .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram_ub_n), .lb_n(cram_lb_n), .cre(cram_cre),
    .clk(cram_clk));
integer errors = 0, i, n;
reg [7:0] v;
reg [15:0] hl;
realtime t_wr_up = 0.0;                  // the last WR rise (or the 8255's reset release, a card change)
task chk(input ok, input [8*64-1:0] what);
    begin
        if (!ok) begin $display("ERROR: cart_ppi: %0s at %0t", what, $time); errors = errors + 1; end
        if (errors >= 20) begin $display("FATAL: cart_ppi: too many errors"); $finish; end
    end
endtask
task chk_ff(input [7:0] q);
    begin
        if (q !== 8'hFF) begin $display("ERROR: cart_ppi: no image: port A %h, expected FF", q); errors = errors + 1; end
        if (errors >= 20) begin $display("FATAL: cart_ppi: too many errors"); $finish; end
    end
endtask
// to the negedge READ_AFTER_WR clk after the last WR rise (at once when that is past)
task wait_after_wr;
    while ($realtime - t_wr_up < (READ_AFTER_WR - 0.5) * T_CLK) @(negedge clk);
endtask
task wr(input [1:0] ad, input [7:0] dd);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = ad; d_i = dd; end
        @(negedge clk) wr_n = 1'b0;
        repeat (4) @(negedge clk); wr_n = 1'b1; t_wr_up = $realtime;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
task rd(input [1:0] ad, output [7:0] dd);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = ad; end
        @(negedge clk);
        wait_after_wr;
        rd_n = 1'b0;
        repeat (4) @(negedge clk); dd = d_o; rd_n = 1'b1;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
// a port B write, and a port A read READ_AFTER_WR clk after its WR rise (CS held)
task wr_b_rd_a(input [7:0] dd, output [7:0] q);
    begin
        @(negedge clk) begin cs_n = 1'b0; a = 2'd1; d_i = dd; end
        @(negedge clk) wr_n = 1'b0;
        repeat (4) @(negedge clk); wr_n = 1'b1; t_wr_up = $realtime;
        @(negedge clk) a = 2'd0;
        wait_after_wr;
        rd_n = 1'b0;
        repeat (4) @(negedge clk); q = d_o; rd_n = 1'b1;
        @(negedge clk) cs_n = 1'b1;
        repeat (2) @(negedge clk);
    end
endtask
// the 8255's reset (the machine reset; the PSRAM keeps running, the bank is kept), with wide and card set
// while it is held
task ppi_reset(input w, input c);
    begin
        @(negedge clk) begin reset = 1'b1; wide = w; card = c; end
        repeat (2) @(negedge clk); reset = 1'b0; t_wr_up = $realtime;
        repeat (2) @(negedge clk);
    end
endtask
// the card reset (power-up, slot load, Cold boot): one clk, the 8255 untouched
task card_reset_pulse;
    begin
        @(negedge clk) card_reset = 1'b1;
        @(negedge clk) begin card_reset = 1'b0; t_wr_up = $realtime; end
        repeat (2) @(negedge clk);
    end
endtask
// another card type without any reset (wide, card change; the 8255 and the bank untouched)
task set_card(input w, input c);
    begin
        @(negedge clk) begin wide = w; card = c; t_wr_up = $realtime; end
        repeat (2) @(negedge clk);
    end
endtask
// after an event that loads bank nb over bank prev: rom_address first, then port A at {nb, a16}
task chk_event(input [6:0] prev, input [6:0] nb, input [15:0] a16);
    begin
        if (rom_address[22:16] === prev) chk(1'b0, "card: bank not loaded by the event");
        else chk(rom_address === {nb, a16}, "card: rom address");
        rd(2'd0, v); chk(v === pattern({nb, a16}), "card: ROM byte in the new bank");
    end
endtask
// after a step that must keep bank nb: rom_address first, then port A at {nb, a16}
task chk_kept(input [6:0] nb, input [15:0] a16, input [8*64-1:0] what);
    begin
        chk(rom_address[22:16] === nb, what);
        chk(rom_address[15:0] === a16, "card: rom address");
        rd(2'd0, v); chk(v === pattern({nb, a16}), "card: ROM byte");
    end
endtask
// no image: port A at address ad (port B, port C) must be FF
task no_image_read(input [15:0] ad);
    begin
        wr(2'd1, ad[7:0]); wr(2'd2, ad[15:8]);
        rd(2'd0, v); chk_ff(v);
    end
endtask
initial begin
    // the ROM disk image in the PSRAM: ROM byte 2w in D7-D0 of word w, 2w + 1 in D15-D8; after time 0, so
    // after the model's FILL
    @(negedge clk);
    for (i = 0; i < 262144; i = i + 1) psram.mem[i] = {pattern(2 * i + 1), pattern(2 * i)};
    // the power-up reset of the PSRAM controller: its BCR write after 150 us, then ready
    repeat (3) @(negedge clk); psram_reset = 1'b0;
    n = 0;
    while (ready !== 1'b1) begin
        @(negedge clk); n = n + 1;
        if (n > 11300) begin $display("FATAL: cart_ppi: the PSRAM controller not ready"); $finish; end
    end
    repeat (4) @(negedge clk); reset = 1'b0; card_reset = 1'b0; t_wr_up = $realtime; repeat (2) @(negedge clk);

    // ---- the 32 KB card (wide 0): A15 not wired, 8000-FFFF mirror 0000-7FFF ----
    // reset: every pin an input, high: FFFF on the pins, 7FFF to the ROM
    chk(rom_address === 23'h007FFF, "mirror: reset: rom address not 7FFF");
    rd(2'd0, v); chk(v === pattern(23'h007FFF), "mirror: reset: port A not the ROM byte at 7FFF");
    // the monitor's FA68: MVI A,90h; STA A003h; SHLD A001h (HL = 1234h); LDA A000h
    wr(2'd3, 8'h90);
    chk(rom_address === 23'h000000, "mode set: address latches not cleared");
    wr(2'd1, 8'h34); wr(2'd2, 8'h12);
    chk(rom_address === 23'h001234, "SHLD: rom address");
    rd(2'd0, v); chk(v === pattern(23'h001234), "LDA A000h: ROM byte at 1234h");
    // PC7 high: A15 not wired, the address and the byte unchanged, port A on; PC7 low again
    wr(2'd3, 8'h0F);
    chk(rom_address === 23'h001234, "mirror: pc7 high: rom address not 1234");
    rd(2'd0, v); chk(v === pattern(23'h001234), "mirror: pc7 high: ROM byte at 1234h");
    wr(2'd3, 8'h0E);
    rd(2'd0, v); chk(v === pattern(23'h001234) && rom_address === 23'h001234, "pc7 low again: ROM byte at 1234h");
    // a port A read READ_AFTER_WR clk after the port B write that set the address
    wr_b_rd_a(8'h56, v); chk(v === pattern(23'h001256), "read 80 clk after the address write");
    // every address 0000-7FFF
    for (i = 0; i < 32768; i = i + 1) begin
        wr(2'd1, i[7:0]); wr(2'd2, {1'b0, i[14:8]});
        chk(rom_address === {7'd0, i[15:0]}, "sweep: rom address wiring");
        rd(2'd0, v); chk(v === pattern({7'd0, i[15:0]}), "sweep: ROM byte");
    end
    // above 8000h: the mirror (F3A5 reads 73A5)
    wr(2'd1, 8'hA5); wr(2'd2, 8'hF3);
    chk(rom_address === 23'h0073A5, "mirror: F3A5: rom address not 73A5");
    rd(2'd0, v); chk(v === pattern(23'h0073A5), "mirror: F3A5: ROM byte at 73A5h");
    // the directions of the full 8255
    wr(2'd3, 8'h98); wr(2'd1, 8'h21); wr(2'd2, 8'h03);           // port C upper an input: PC7 high, the mirror
    chk(rom_address === 23'h007321, "mirror: port C upper input: address");
    rd(2'd0, v); chk(v === pattern(23'h007321), "mirror: port C upper input: ROM byte at 7321h");
    wr(2'd3, 8'h91); wr(2'd1, 8'h21); wr(2'd2, 8'h30);           // port C lower an input: PC0-PC3 high
    chk(rom_address === 23'h003F21, "port C lower input: address");
    rd(2'd0, v); chk(v === pattern(23'h003F21), "port C lower input: ROM byte");
    wr(2'd3, 8'h92); wr(2'd2, 8'h05);                            // port B an input: A0-A7 high
    chk(rom_address === 23'h0005FF, "port B input: address");
    rd(2'd0, v); chk(v === pattern(23'h0005FF), "port B input: ROM byte");
    wr(2'd3, 8'h80); wr(2'd0, 8'h3C);                            // port A an output: the latch, not the ROM
    rd(2'd0, v); chk(v === 8'h3C, "port A output: the latch");
    wr(2'd3, 8'h90);
    rd(2'd0, v); chk(v === pattern(23'h000000), "mode 90h again: ROM byte at 0000h");
    // reset
    ppi_reset(1'b0, 1'b0);
    chk(rom_address === 23'h007FFF, "mirror: reset again: rom address not 7FFF");
    rd(2'd0, v); chk(v === pattern(23'h007FFF), "mirror: reset again: port A not the ROM byte at 7FFF");

    // ---- the 64 KB card (wide 1, card 0): PC7 = A15 ----
    ppi_reset(1'b1, 1'b0);
    chk(rom_address === 23'h00FFFF, "wide reset: rom address not FFFF");
    rd(2'd0, v); chk(v === pattern(23'h00FFFF), "wide reset: port A not the ROM byte at FFFF");
    wr(2'd3, 8'h90); wr(2'd1, 8'h34); wr(2'd2, 8'h92);
    chk(rom_address === 23'h009234, "wide SHLD: rom address");
    rd(2'd0, v); chk(v === pattern(23'h009234), "wide: ROM byte above 8000h");
    wr(2'd3, 8'h0E);                                            // PC7 low: A15 0
    rd(2'd0, v); chk(v === pattern(23'h001234) && rom_address === 23'h001234, "wide pc7 low: ROM byte at 1234h");
    wr(2'd3, 8'h0F);                                            // PC7 high: A15 1
    rd(2'd0, v); chk(v === pattern(23'h009234) && rom_address === 23'h009234, "wide: ROM byte above 8000h after PC7 set");
    for (i = 0; i < 65536; i = i + 1) begin
        wr(2'd1, i[7:0]); wr(2'd2, i[15:8]);
        chk(rom_address === {7'd0, i[15:0]}, "wide sweep: rom address wiring");
        rd(2'd0, v); chk(v === pattern({7'd0, i[15:0]}), "wide sweep: ROM byte");
    end
    wr(2'd3, 8'h98); wr(2'd1, 8'h21); wr(2'd2, 8'h03);       // port C upper an input: A15 high
    chk(rom_address === 23'h00F321, "wide port C upper input: address");
    rd(2'd0, v); chk(v === pattern(23'h00F321), "wide: ROM byte above 8000h, port C upper input");
    wr(2'd3, 8'h80); wr(2'd0, 8'h5A);                        // port A an output: the latch, not the ROM
    rd(2'd0, v); chk(v === 8'h5A, "wide port A output: the latch");

    // ---- the bank card (wide 1, card 1): {bank, PC7..PC0, PB} ----
    ppi_reset(1'b1, 1'b1);
    card_reset_pulse;
    chk(rom_address === 23'h00FFFF, "card: bank not cleared by the card reset");
    wr(2'd3, 8'h90);                                         // port C FF -> 00: PC7 falls, PC0-PC6 low: no event
    chk(rom_address === 23'h000000, "card: bank changed without the event");
    // events, each into a bank other than the one before
    wr(2'd2, 8'hFF); wr(2'd1, 8'h03); wr(2'd2, 8'h7F);       // FF -> 7F, PB 03
    chk_event(7'd0, 7'd3, 16'h7F03);                         // (its port A read: READ_AFTER_WR after the WR rise)
    wr(2'd2, 8'h80); wr(2'd1, 8'h01); wr(2'd2, 8'h7F);       // 80 -> 7F, PB 01
    chk_event(7'd3, 7'd1, 16'h7F01);
    wr(2'd2, 8'hC3); wr(2'd1, 8'h06); wr(2'd2, 8'h7F);       // C3 -> 7F, PB 06
    chk_event(7'd1, 7'd6, 16'h7F06);
    wr(2'd2, 8'hFE); wr(2'd1, 8'h04); wr(2'd2, 8'h7F);       // FE -> 7F, PB 04
    chk_event(7'd6, 7'd4, 16'h7F04);
    wr(2'd2, 8'hFF); wr(2'd1, 8'h07); wr(2'd3, 8'h0E);       // SELBK: port C FF, PB 07, bit reset PC7
    chk_event(7'd4, 7'd7, 16'h7F07);
    wr(2'd2, 8'hFF); wr(2'd1, 8'h85); wr(2'd2, 8'h7F);       // FF -> 7F, PB 85h: PB7 ignored, bank 5
    chk_event(7'd7, 7'd5, 16'h7F85);
    wr(2'd2, 8'hFF); wr(2'd1, 8'h02); wr(2'd2, 8'h7F);       // bank 2 for the steps without an event
    chk_event(7'd5, 7'd2, 16'h7F02);
    // no event: port B 06 (bank 6 if it were latched) written before each step
    wr(2'd2, 8'hFF); wr(2'd1, 8'h06); wr(2'd2, 8'h7E);       // FF -> 7E
    chk_kept(7'd2, 16'h7E06, "card: bank changed without the event");
    wr(2'd2, 8'hFF); wr(2'd1, 8'h06); wr(2'd2, 8'h3F);       // FF -> 3F
    chk_kept(7'd2, 16'h3F06, "card: bank changed without the event");
    wr(2'd2, 8'hFF); wr(2'd1, 8'h06); wr(2'd2, 8'h00);       // FF -> 00
    chk_kept(7'd2, 16'h0006, "card: bank changed without the event");
    wr(2'd2, 8'h7F); wr(2'd1, 8'h06); wr(2'd2, 8'h80);       // 00 -> 7F (PC7 low before), then 7F -> 80
    chk_kept(7'd2, 16'h8006, "card: bank changed without the event");
    wr(2'd2, 8'hFE); wr(2'd1, 8'h06); wr(2'd2, 8'hFF);       // FE -> FF
    chk_kept(7'd2, 16'hFF06, "card: bank changed without the event");
    wr(2'd2, 8'h7E); wr(2'd1, 8'h06); wr(2'd2, 8'h7F);       // FF -> 7E (PC0 low), then 7E -> 7F
    chk_kept(7'd2, 16'h7F06, "card: bank changed without the event");
    wr(2'd1, 8'h66); wr(2'd2, 8'h7F);                        // 7F -> 7F again, PB 66h
    chk_kept(7'd2, 16'h7F66, "card: bank changed without the event");
    wr(2'd1, 8'h06); wr(2'd3, 8'h0F);                        // bit set PC7 from 7F: 7F -> FF
    chk_kept(7'd2, 16'hFF06, "card: bank changed without the event");
    wr(2'd1, 8'h06); wr(2'd3, 8'h00); wr(2'd3, 8'h0E);       // from FF: bit reset PC0 (FE), PC7 (7E)
    chk_kept(7'd2, 16'h7E06, "card: bank changed without the event");
    wr(2'd2, 8'hFF); wr(2'd1, 8'h06); wr(2'd3, 8'h90);       // mode set 90h from FF: port B, port C 00
    chk_kept(7'd2, 16'h0000, "card: bank changed without the event");
    wr(2'd1, 8'h06);
    for (i = 0; i < 256; i = i + 1) begin                    // port C 00..FF ascending, PB 06
        wr(2'd2, i[7:0]);
        chk_kept(7'd2, {i[7:0], 8'h06}, "card: bank changed without the event");
    end
    wr(2'd3, 8'h90);                                         // FA68 (R) from FFF0 to 000F: the FFFF -> 0000 wrap
    hl = 16'hFFF0;
    for (i = 0; i < 32; i = i + 1) begin
        wr(2'd1, hl[7:0]); wr(2'd2, hl[15:8]);
        chk_kept(7'd2, hl, "card: bank changed without the event");
        hl = hl + 16'd1;
    end
    // the machine reset (Core Settings > Reset) keeps the bank; the card reset clears it
    ppi_reset(1'b1, 1'b1);
    chk_kept(7'd2, 16'hFFFF, "card: bank lost on the machine reset");
    card_reset_pulse;
    chk_kept(7'd0, 16'hFFFF, "card: bank not cleared by the card reset");
    // not a bank card: an FF -> 7F event with card 0 (wide 1) loads nothing; card 1 again without a reset
    set_card(1'b1, 1'b0);
    wr(2'd3, 8'h90); wr(2'd2, 8'hFF); wr(2'd1, 8'h06); wr(2'd2, 8'h7F);
    chk(rom_address === 23'h007F06, "card 0: rom address");
    set_card(1'b1, 1'b1);
    chk_kept(7'd0, 16'h7F06, "card: bank changed without the event");
    // outside the card: bank 4, then card 0 (wide 1) without a reset: A16-A22 0
    wr(2'd2, 8'hFF); wr(2'd1, 8'h04); wr(2'd2, 8'h7F);
    chk_event(7'd0, 7'd4, 16'h7F04);
    set_card(1'b1, 1'b0);
    chk(rom_address[22:16] === 7'd0, "card: bank used outside the card");
    chk(rom_address[15:0] === 16'h7F04, "card 0: rom address");
    rd(2'd0, v); chk(v === pattern(23'h007F04), "card 0: ROM byte at 7F04h");

    // ---- no image (slot 2 empty): port A FF on every card (the bytes there are not FF) ----
    loaded = 1'b0;
    wr(2'd3, 8'h90);                                         // the 64 KB card
    no_image_read(16'h0000); no_image_read(16'h1234); no_image_read(16'h9234); no_image_read(16'hFFFF);
    ppi_reset(1'b0, 1'b0);                                   // the 32 KB card
    wr(2'd3, 8'h90);
    no_image_read(16'h0000); no_image_read(16'h1234); no_image_read(16'h5678); no_image_read(16'h7FFE);
    ppi_reset(1'b1, 1'b1);                                   // the bank card, bank 4
    wr(2'd3, 8'h90);
    chk(rom_address[22:16] === 7'd4, "card: bank lost on the machine reset");
    no_image_read(16'h0000); no_image_read(16'h1234); no_image_read(16'h9234); no_image_read(16'hFFFF);
    if (errors == 0)
        $display("PASS cart_ppi: 32 KB: reset 7FFF, FA68 sequence, 8000-FFFF mirror, port A read 80 clk after the address write (8080 minimum 167 clk), ROM data from the PSRAM, all 32768 addresses, 8255 directions, reset; 64 KB: PC7 = A15, all 65536 addresses, directions; bank card: 6 events (FF, 80, C3, FE to 7F, SELBK, PB7 ignored), 10 steps without an event, port C 00-FF, FFFF wrap, bank kept on the machine reset, cleared by the card reset, ignored by the other cards; no image: port A FF");
    $finish;
end
endmodule
`default_nettype wire
