// The ROM disk in the Pocket's PSRAM cram0 (AS1C8M16PL-70BIN, 1.8 V: two 4M x 16 CellularRAM dies with
// a multiplexed address/data bus). Die 0 only (CE1# held high), asynchronous mode only (CLK held low),
// one state machine on clk_74a: no other clock, no CDC. Sources: the AS1C4M16PL-70BIN data sheet
// (Alliance Memory, Rev 1.0 preliminary, Aug 2018: the 4M x 16 die), the Analogue developer docs
// (External Hardware); agg23/analogue-pocket-utils ip/mem/psram.sv (MIT) read as a reference for the
// pin behaviour, no code taken.
//
// Packed mapping: ROM byte address A22-A0, PSRAM word address = A22-A1; A0 = 0 is D7-D0 (LB#),
// A0 = 1 is D15-D8 (UB#). A bridge word (wr: one clk; wr_word = ROM byte address / 4; wr_data with its
// first byte in 31:24, as the bridge) becomes PSRAM word {wr_word, 0} = {wr_data[23:16], wr_data[31:24]}
// and {wr_word, 1} = {wr_data[7:0], wr_data[15:8]}: two 16-bit writes, both byte lanes.
//
// One access is 13 clk_74a ticks (13.468 ns each), t = 0..12; each cram0 pin may lag its register by up
// to one tick (bounded by the .sdc), and each relation below keeps at least one tick for that skew:
//   t   read                                              write (one 16-bit word)
//   0   CE0# 0, ADV# 0, DQ = word address A15-A0,         same
//       A[21:16], LB#/UB# 0
//   2   ADV# 1 (tVP 5, tAVS 5, tCVS 7 ns min: 27 ns)     same
//   4   DQ released (tAVH 2 ns min: 27 ns)                DQ = data, WE# 0
//   6   OE# 0 (DQ off since t4; the part drives from      -
//       OE# low + tOLZ 3 ns)
//   10  DQ sampled (valid at max(tAA, tAADV, tCO 70      -
//       from t0, tOE 20 from t6) = 101 ns; with 2 ticks
//       of skew 128 ns < 135 ns)
//   11  CE0#, OE#, LB#, UB# 1: a full tick after the      WE#, CE0# 1 (tWP 45: 94 ns; tCW, tVS, tAW,
//       sample (the data sheet gives tOHZ, tHZ only as      tBW 70: 148 ns; tDW 20: 94 ns; each one tick
//       maxima: no minimum output hold after OE#/CE#        less after skew)
//       high; the pins rise at t11 or later, so the
//       part drives the word until then)
//   12  idle (DQ high-Z by t12 + 7 ns at the latest)       DQ released, LB#/UB# 1 (tDH 0)
//   the next access starts at t13 = its t0: CE# high 2 ticks (at least 1 after skew: tCPH 5 ns); our DQ
//   drive at t13 or later, after the part let go (at most t12 + tOHZ 7 ns). CE# is high after every
//   access (tCEM 4 us).
// A read starts when idle and the word held is not word rd_addr[22:1] (or none is held); writes come
// before reads. rd_data = rd_addr[0] ? D15-D8 : D7-D0 of the word held, rd_ready = that word is
// word rd_addr[22:1]: a change of rd_addr[0] needs no access. Read latency after an rd_addr change:
// at most 24 clk (by the count 23: the rest of an access in flight, 12, then 10 ticks to the sample,
// plus the edge; tb_psram checks 24; the 8080 reads port A at least 167 clk after a port write; a
// pending bridge word adds 26). A bridge word: at most 26 clk, plus a read in flight 13; APF sends at
// most one per 88 clk. One word is buffered (pending); a bridge word while one is pending is a sim ERROR.
// Any bridge word drops the word held, and a read that ends while a write is pending is not used:
// never a stale byte.
//
// Start-up: power-up reset (reset, synchronous), then 11 200 ticks (151 us > tPU 150 us; CE# high
// meanwhile), then one register write with CRE high that sets the BCR to its power-up default 9D1Fh
// (BCR[15] = 1: asynchronous mode), in case an earlier core left die 0 in burst mode; then ready.
// The data sheet's CRE write (Access Using CRE, Figure 9, Table 2): the value on A[21:16] and
// A/DQ[15:0] in the address phase, latched at the ADV# rise; A[19:18] = 10b selects the BCR,
// A[21:20], A[17:16] reserved (0): cram_a = 6'b001000, DQ = 9D1Fh; OE# high; WE# low; written at the
// rise of CE# or WE#; LB#/UB# don't care: held high here (no byte lane enabled). The same 13-tick
// write sequence as above (DQ keeps 9D1Fh in the data phase); CRE is low in every other access. The
// software sequence on word 3FFFFFh is never used. Until ready, rd_data is FF, rd_ready 0, and a
// bridge word waits in the buffer.
//
// Every cram0 output and the DQ output enable come straight from a register (fast I/O registers).
`default_nettype none
module pocket_psram(
    input  wire        clk,
    input  wire        reset,             // the power-up reset of pocket_system (high)
    output reg         ready = 1'b0,      // the BCR is written: reads and writes run
    input  wire        wr,
    input  wire [20:0] wr_word,
    input  wire [31:0] wr_data,
    input  wire [22:0] rd_addr,
    output wire  [7:0] rd_data,
    output wire        rd_ready,
    output reg [21:16] cram_a = 6'd0,
    inout  wire [15:0] cram_dq,
    output reg         cram_adv_n = 1'b1,
    output reg         cram_ce0_n = 1'b1,
    output reg         cram_oe_n = 1'b1,
    output reg         cram_we_n = 1'b1,
    output reg         cram_ub_n = 1'b1,
    output reg         cram_lb_n = 1'b1,
    output wire        cram_ce1_n,
    output reg         cram_cre = 1'b0,
    output wire        cram_clk
);
localparam [3:0] T_ADV_HIGH = 4'd2, T_DQ = 4'd4, T_OE = 4'd6, T_SAMPLE = 4'd10, T_END = 4'd11, T_LAST = 4'd12;
localparam [13:0] START_TICKS = 14'd11200;           // 151 us of clk_74a: tPU 150 us
localparam [21:0] BCR_WRITE = {6'b001000, 16'h9D1F};  // A[19:18] = 10b: the BCR; A/DQ: 9D1Fh
localparam [1:0] READ = 2'd0, WRITE = 2'd1, BCR = 2'd2;

assign cram_ce1_n = 1'b1;
assign cram_clk = 1'b0;
reg [15:0] dq_out = 16'd0;
reg dq_oe = 1'b0;
assign cram_dq = dq_oe ? dq_out : 16'hzzzz;

reg [13:0] start_cnt = 14'd0;
reg started = 1'b0;                     // the BCR write has begun
reg busy = 1'b0;
reg [3:0] t = 4'd0;
reg [1:0] kind = READ;
reg [15:0] acc_data = 16'd0;            // the data of the write in flight
reg [21:0] acc_word = 22'd0;            // the word of the read in flight
reg pending = 1'b0, half = 1'b0;        // a bridge word waiting; its second 16-bit write is next
reg [20:0] pend_word = 21'd0;
reg [31:0] pend_data = 32'd0;
reg valid = 1'b0;                       // word holds PSRAM word word_addr
reg [21:0] word_addr = 22'd0;
reg [15:0] word = 16'hFFFF;

wire [3:0] tn = t + 4'd1;
wire step = busy && t != T_LAST;        // the access in flight goes on to tick tn
wire free = !busy || t == T_LAST;       // an access may start at this edge
wire do_bcr = free && !started && start_cnt == START_TICKS;
wire do_write = free && ready && pending;
wire do_read = free && ready && !pending && (!valid || rd_addr[22:1] != word_addr);
wire start = do_bcr || do_write || do_read;
wire sample = step && tn == T_SAMPLE && kind == READ;   // DQ into word at this edge (tb_psram checks its hold)

assign rd_ready = ready && valid && word_addr == rd_addr[22:1];
assign rd_data = !ready ? 8'hFF : rd_addr[0] ? word[15:8] : word[7:0];

always @(posedge clk)
    if (reset) begin
        ready <= 1'b0; start_cnt <= 14'd0; started <= 1'b0; busy <= 1'b0; t <= 4'd0;
        pending <= 1'b0; half <= 1'b0; valid <= 1'b0;
        cram_ce0_n <= 1'b1; cram_adv_n <= 1'b1; cram_oe_n <= 1'b1; cram_we_n <= 1'b1;
        cram_lb_n <= 1'b1; cram_ub_n <= 1'b1; cram_cre <= 1'b0; dq_oe <= 1'b0;
    end else begin
        if (!started && start_cnt != START_TICKS) start_cnt <= start_cnt + 14'd1;
        // the tick counter
        if (start) begin busy <= 1'b1; t <= 4'd0; end
        else if (step) t <= tn;
        else busy <= 1'b0;
        if (busy && t == T_LAST && kind == BCR) ready <= 1'b1;
        // t0: the address phase
        if (start) begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_oe_n <= 1'b1; cram_we_n <= 1'b1; dq_oe <= 1'b1;
        end
        if (do_bcr) begin
            kind <= BCR; started <= 1'b1; cram_cre <= 1'b1;
            {cram_a, dq_out} <= BCR_WRITE; acc_data <= BCR_WRITE[15:0];
            cram_lb_n <= 1'b1; cram_ub_n <= 1'b1;
        end
        if (do_write) begin
            kind <= WRITE; cram_cre <= 1'b0; valid <= 1'b0;
            {cram_a, dq_out} <= {pend_word, half};
            acc_data <= half ? {pend_data[7:0], pend_data[15:8]} : {pend_data[23:16], pend_data[31:24]};
            cram_lb_n <= 1'b0; cram_ub_n <= 1'b0;
            half <= !half;
            if (half) pending <= 1'b0;
        end
        if (do_read) begin
            kind <= READ; cram_cre <= 1'b0;
            {cram_a, dq_out} <= rd_addr[22:1]; acc_word <= rd_addr[22:1];
            cram_lb_n <= 1'b0; cram_ub_n <= 1'b0;
        end
        // the ticks of the access in flight
        if (step && tn == T_ADV_HIGH) cram_adv_n <= 1'b1;
        if (step && tn == T_DQ && kind == READ) dq_oe <= 1'b0;
        if (step && tn == T_DQ && kind != READ) begin dq_out <= acc_data; cram_we_n <= 1'b0; end
        if (step && tn == T_OE && kind == READ) cram_oe_n <= 1'b0;
        if (sample) begin word <= cram_dq; word_addr <= acc_word; valid <= !pending; end
        if (step && tn == T_END) cram_ce0_n <= 1'b1;
        if (step && tn == T_END) begin cram_oe_n <= 1'b1; cram_we_n <= 1'b1; end
        if (step && tn == T_END && kind == READ) begin cram_lb_n <= 1'b1; cram_ub_n <= 1'b1; end
        if (step && tn == T_LAST) begin dq_oe <= 1'b0; cram_lb_n <= 1'b1; cram_ub_n <= 1'b1; cram_cre <= 1'b0; end
        // the bridge word buffer (after the rest: a new word wins over the end of the last one)
        if (wr) begin
            pending <= 1'b1; half <= 1'b0; pend_word <= wr_word; pend_data <= wr_data; valid <= 1'b0;
        end
    end

// synthesis translate_off
always @(posedge clk)
    if (!reset && wr && pending && !(do_write && half))
        $display("ERROR: pocket_psram: a bridge word while one is pending");
// synthesis translate_on
endmodule
`default_nettype wire
