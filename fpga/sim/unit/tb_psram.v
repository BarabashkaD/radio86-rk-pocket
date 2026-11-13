`timescale 1ns/1ps
`default_nettype none
// pocket_psram on the PSRAM model (psram_model, the whole die: AW = 22, FILL 0: unwritten words are X)
// at the clk_74a rate, so the model's ns checks see the build's tick lengths. Bridge words come 88 clk
// apart (APF's maximum rate). Cases, in order:
// 0 start-up: after the reset, ready low, reads give FF and a bridge word waits; exactly one CRE write,
//   after 150 us, the only access before ready; ready within 11 200 + 13 + 2 clk of the reset; the
//   waiting word lands after ready;
// 1 write: bridge words at word addresses 0, every single bit 2^0..2^20, 1FFFFEh, 1FFFFFh (ROM bytes
//   7FFFF8h-7FFFFFh), all bytes distinct; each becomes two PSRAM words, the even ROM byte in D7-D0;
// 2 read: every byte of those words through rd_addr: rd_ready within 24 clk, then rd_data;
// 3 same word: the other byte of the word held: no PSRAM access, the byte at once;
// 4 stale: read W, write W, read W: never the old byte;
// 5 address change during a read: rd_addr changed 3 clk after a read started: the new byte;
// 6 write during a read: wr in the clk of an rd_addr change, the read inside that word: both done
//   within 88 clk, never the old byte;
// 7 idle 5 us: a stable address: CE# high, no access (the model's tCEM check covers the controller).
// Every read sample (dut.sample): DQ at the pins must not change within 1 ns after that edge. The data
// sheet has no minimum output hold after OE#/CE# high and the model drives X from that rise, so a sample
// on the edge that raises OE# or CE# fails here, although a zero-delay simulation would take the word.
// The model stops the simulation at its first ERROR (its timing and protocol checks).
module tb_psram;
reg clk = 1'b0;
always #6.734 clk = ~clk;                  // 74.25 MHz
reg reset = 1'b1, wr = 1'b0;
reg [20:0] wr_word = 21'd0;
reg [31:0] wr_data = 32'd0;
reg [22:0] rd_addr = 23'd0;
wire [7:0] rd_data;
wire rd_ready, ready;
wire [21:16] cram_a;
wire [15:0] cram_dq;
wire cram_adv_n, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n, cram_cre, cram_clk;
pocket_psram dut(.clk(clk), .reset(reset), .ready(ready), .wr(wr), .wr_word(wr_word), .wr_data(wr_data),
    .rd_addr(rd_addr), .rd_data(rd_data), .rd_ready(rd_ready), .cram_a(cram_a), .cram_dq(cram_dq),
    .cram_adv_n(cram_adv_n), .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n),
    .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n), .cram_cre(cram_cre), .cram_clk(cram_clk));
psram_model #(.FILL(1'b0)) psram(.a(cram_a), .dq(cram_dq), .adv_n(cram_adv_n), .ce0_n(cram_ce0_n),
    .ce1_n(cram_ce1_n), .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram_ub_n), .lb_n(cram_lb_n), .cre(cram_cre),
    .clk(cram_clk));

integer ce_falls = 0, cre_writes = 0;
realtime cre_time = 0.0;
always @(negedge cram_ce0_n) ce_falls = ce_falls + 1;
always @(posedge cram_cre) begin cre_writes = cre_writes + 1; cre_time = $realtime; end

task fail(input [8*72-1:0] what);
    begin $display("ERROR: psram: %0s", what); $finish; end
endtask
// byte j (0 is the first, bits 31:24) of test word i: all 96 distinct (37 is odd)
function [7:0] pat(input integer i, input integer j);
    pat = (4 * i + j) * 37 + 11;
endfunction
function [31:0] wdata(input integer i);
    wdata = {pat(i, 0), pat(i, 1), pat(i, 2), pat(i, 3)};
endfunction
// one bridge word; the next one 88 clk later
task bridge_word(input [20:0] w, input [31:0] d);
    begin
        @(negedge clk); wr_word = w; wr_data = d; wr = 1'b1;
        @(negedge clk); wr = 1'b0;
        repeat (86) @(negedge clk);
    end
endtask
// the two PSRAM words of bridge word w: ROM bytes 4w, 4w+1 in word 2w (the even byte in D7-D0), 4w+2, 4w+3 in 2w+1
task check_word(input [20:0] w, input [31:0] d);
    begin
        if (psram.mem[{w, 1'b0}] !== {d[23:16], d[31:24]}) begin
            $display("ERROR: psram: word %h is %h, expected %h", {w, 1'b0}, psram.mem[{w, 1'b0}], {d[23:16], d[31:24]});
            $finish;
        end
        if (psram.mem[{w, 1'b1}] !== {d[7:0], d[15:8]}) begin
            $display("ERROR: psram: word %h is %h, expected %h", {w, 1'b1}, psram.mem[{w, 1'b1}], {d[7:0], d[15:8]});
            $finish;
        end
    end
endtask
// the hold of the read sample: DQ unchanged for 1 ns after the edge that samples it
reg [15:0] dq_sampled;
always @(posedge clk) if (dut.sample) begin
    dq_sampled = cram_dq;
    #1.0;
    if (cram_dq !== dq_sampled) begin
        $display("ERROR: psram: DQ changed within 1 ns after the sample (%h, then %h)", dq_sampled, cram_dq); $finish;
    end
end
// rd_addr = ad: rd_ready within 24 clk of the change, then rd_data
task read_byte(input [22:0] ad, input [7:0] expected);
    integer n;
    begin
        @(negedge clk); rd_addr = ad; #1;
        n = 0;
        while (rd_ready !== 1'b1) begin
            @(negedge clk); n = n + 1;
            if (n > 24 && rd_ready !== 1'b1) begin
                $display("ERROR: psram: read of %h not ready within 24 clk", ad); $finish;
            end
        end
        if (rd_data !== expected) begin
            $display("ERROR: psram: read of %h is %h, expected %h", ad, rd_data, expected); $finish;
        end
    end
endtask

reg [20:0] words [0:23];
integer i, j, n, falls;
reg [31:0] nd;
initial begin
    words[0] = 21'd0;
    for (i = 0; i <= 20; i = i + 1) words[i + 1] = 21'd1 << i;
    words[22] = 21'h1FFFFE;
    words[23] = 21'h1FFFFF;

    // 0 start-up
    repeat (3) @(negedge clk);
    reset = 1'b0; rd_addr = 23'h000005;
    n = 0;
    while (ready !== 1'b1) begin
        @(negedge clk); n = n + 1;
        if (n == 100) begin wr_word = 21'h0ABCD; wr_data = 32'h5EC0FFEE; wr = 1'b1; end
        if (n == 101) wr = 1'b0;
        if (ready !== 1'b1 && (rd_data !== 8'hFF || rd_ready !== 1'b0)) fail("a read before ready is not FF");
        if (n > 11200 + 13 + 2) fail("ready not within 11215 clk of the reset");
    end
    falls = ce_falls;
    if (psram.mem[{21'h0ABCD, 1'b0}] !== 16'hxxxx || psram.mem[{21'h0ABCD, 1'b1}] !== 16'hxxxx)
        fail("a bridge word written before ready");
    repeat (40) @(negedge clk);
    check_word(21'h0ABCD, 32'h5EC0FFEE);
    if (falls != 1) begin $display("ERROR: psram: %0d accesses before ready, expected 1 (the BCR write)", falls); $finish; end
    if (cre_writes != 1) begin $display("ERROR: psram: %0d CRE writes at the start-up, expected 1", cre_writes); $finish; end
    if (cre_time < 150000.0) begin $display("ERROR: psram: the CRE write at %0.3f ns, before 150 us", cre_time); $finish; end

    // 1 write
    for (i = 0; i < 24; i = i + 1) bridge_word(words[i], wdata(i));
    for (i = 0; i < 24; i = i + 1) check_word(words[i], wdata(i));

    // 2 read
    for (i = 0; i < 24; i = i + 1)
        for (j = 0; j < 4; j = j + 1) read_byte({words[i], j[1:0]}, pat(i, j));

    // 3 same word: the other byte of the word held
    read_byte({words[5], 2'd0}, pat(5, 0));
    falls = ce_falls;
    for (j = 1; j < 6; j = j + 1) begin
        @(negedge clk); rd_addr[0] = j[0]; #1;
        if (rd_ready !== 1'b1 || rd_data !== pat(5, j % 2)) fail("an access for the other byte of a word");
    end
    repeat (20) @(negedge clk);
    if (ce_falls != falls || rd_ready !== 1'b1) fail("an access for the other byte of a word");

    // 4 stale: read W, write W, read W
    read_byte({words[7], 2'd2}, pat(7, 2));
    nd = 32'hA1B2C3D4;
    @(negedge clk); wr_word = words[7]; wr_data = nd; wr = 1'b1;
    @(negedge clk); wr = 1'b0; #1;
    n = 0;
    while (!(rd_ready === 1'b1 && psram.mem[{words[7], 1'b1}] === {nd[7:0], nd[15:8]})) begin
        if (rd_ready === 1'b1 && rd_data !== nd[15:8]) fail("stale word after a write");
        @(negedge clk); n = n + 1;
        if (n > 88) fail("stale word after a write: not read within 88 clk");
    end
    if (rd_data !== nd[15:8]) fail("stale word after a write");
    check_word(words[7], nd);

    // 5 address change during a read: 3 clk after the read of word 10 started, a byte of word 12
    @(negedge clk); rd_addr = {words[10], 2'd1};
    repeat (3) @(negedge clk);
    if (cram_ce0_n !== 1'b0 || cram_we_n !== 1'b1) fail("address change: no read in flight");
    rd_addr = {words[12], 2'd3}; #1;
    n = 0;
    while (rd_ready !== 1'b1) begin
        @(negedge clk); n = n + 1;
        if (n > 24 && rd_ready !== 1'b1) fail("address change: not ready within 24 clk");
    end
    if (rd_data !== pat(12, 3)) begin
        $display("ERROR: psram: address change: read %h, expected %h", rd_data, pat(12, 3)); $finish;
    end

    // 6 write during a read: wr and an rd_addr change in one clk, the read inside the written word
    nd = 32'h5A6B7C8D;
    @(negedge clk); rd_addr = {words[15], 2'd3}; wr_word = words[15]; wr_data = nd; wr = 1'b1;
    @(negedge clk); wr = 1'b0; #1;
    n = 1;
    while (!(rd_ready === 1'b1 && psram.mem[{words[15], 1'b1}] === {nd[7:0], nd[15:8]})) begin
        if (rd_ready === 1'b1 && rd_data !== nd[7:0]) begin
            $display("ERROR: psram: write during a read: read %h, expected %h", rd_data, nd[7:0]); $finish;
        end
        @(negedge clk); n = n + 1;
        if (n > 88) fail("write during a read: not done within 88 clk");
    end
    if (rd_data !== nd[7:0]) begin
        $display("ERROR: psram: write during a read: read %h, expected %h", rd_data, nd[7:0]); $finish;
    end
    check_word(words[15], nd);

    // 7 idle 5 us (372 clk) with a stable address
    repeat (2) @(negedge clk);
    falls = ce_falls;
    for (n = 0; n < 372; n = n + 1) begin
        @(negedge clk);
        if (cram_ce0_n !== 1'b1) fail("CE# low while idle");
    end
    if (ce_falls != falls) fail("CE# low while idle");
    if (cre_writes != 1) fail("a CRE write after the start-up");
    $display("PASS psram: writes in two byte lanes, 23-bit addresses, reads within 24 clk, sample hold, byte mux, stale word, address change, write during a read, CE# released");
    $finish;
end
endmodule
`default_nettype wire
