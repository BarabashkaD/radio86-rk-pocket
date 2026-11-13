`timescale 1ns/1ps
`default_nettype none
// One die of the Analogue Pocket's PSRAM (cram0, AS1C8M16PL-70BIN: two 4M x 16 CellularRAM dies), in
// asynchronous mode, as a checker of the controller pocket_psram. Die 0 only: CE1# must stay high and
// CLK low. The address/data bus is multiplexed: ADV# low with A[21:16] and A/DQ[15:0] = the word
// address, latched at the ADV# rise; then data on DQ. Timing values: the AS1C4M16PL-70BIN data sheet
// (Alliance Memory, Rev 1.0 preliminary, Aug 2018), asynchronous READ and WRITE AC tables.
// Every check prints one line "ERROR: psram model: <what>" and stops the simulation:
// - at the ADV# rise with CE# low: ADV# low tVP, address (A, DQ) stable tAVS before, CE# low tCVS before,
//   OE# high (the data sheet: OE# high while the address is on the bus); A or DQ changing within tAVH
//   after it;
// - CE# low longer than tCEM; CE# high shorter than tCPH between accesses;
// - CE1# low or CLK high at any time (die 1 or CLK used);
// - a CRE cycle (CRE high at the ADV# rise) must be a write of the BCR (A[19:18] = 10b, the other bits
//   of A[21:16] 0) with the value 9D1Fh (asynchronous mode, the power-up default) on A/DQ[15:0]: else
//   "BCR write %h" ({A[21:16], A/DQ[15:0]}); its CE# fall not before tPU (150 us after time 0); a
//   read with CRE high: "CRE read";
// - an array access (CRE low) before that BCR write; a word address at or beyond 2^AW;
// - read (OE# low with CE# low and WE# high, after the latch): DQ must be all Z 2.9 ns after the OE#
//   fall (the model drives from tOLZ = 3 ns); the model drives X until max(ADV# low + tAADV, CE# low +
//   tCO, OE# low + tOE, A change + tAA), then the word until OE# or CE# rises; from that rise X (the
//   data sheet gives tOHZ, tHZ only as maxima: no minimum output hold) until tOHZ (tHZ), then Z; while
//   it drives, DQ different from what it drives is contention;
// - write (WE# low with CE# low; it ends at the first rise of WE# or CE#): tWP, tCW, tVS, tAW, tDW,
//   tBW, then the lanes enabled by LB# (DQ[7:0]) and UB# (DQ[15:8]) into mem;
// - read, read, write, write on word 3FFFFFh in a row: the configuration register software sequence.
// mem: 2^AW words (AW = 22: the whole die), 16'hFFFF when FILL, else X; a testbench may fill it by
// hierarchy before the first access.
module psram_model #(
    parameter FILL = 1'b1,
    parameter integer AW = 22,
    parameter real T_AA = 70.0,         // address to data valid
    parameter real T_AADV = 70.0,       // ADV# low to data valid
    parameter real T_CO = 70.0,         // CE# low to data valid
    parameter real T_OE = 20.0,         // OE# low to data valid
    parameter real T_OLZ = 3.0,         // OE# low to the part driving DQ
    parameter real T_OHZ = 7.0,         // DQ released after OE# high (tHZ after CE# high: also 7 ns)
    parameter real T_VP = 5.0,          // ADV# low pulse
    parameter real T_AVS = 5.0,         // address setup to ADV# high
    parameter real T_AVH = 2.0,         // address hold after ADV# high
    parameter real T_CVS = 7.0,         // CE# low to ADV# high
    parameter real T_CPH = 5.0,         // CE# high between accesses
    parameter real T_WP = 45.0,         // WE# low pulse
    parameter real T_CW = 70.0,         // CE# low to the end of a write
    parameter real T_VS = 70.0,         // ADV# low to the end of a write
    parameter real T_AW = 70.0,         // address valid to the end of a write
    parameter real T_BW = 70.0,         // LB#/UB# low to the end of a write
    parameter real T_DW = 20.0,         // data setup to the end of a write
    parameter real T_CEM = 4000.0,      // CE# low at most (refresh)
    parameter real T_PU = 150000.0      // power-up: CE# high until then
) (
    input  wire [21:16] a,
    inout  wire  [15:0] dq,
    input  wire         adv_n,
    input  wire         ce0_n,
    input  wire         ce1_n,
    input  wire         oe_n,
    input  wire         we_n,
    input  wire         ub_n,
    input  wire         lb_n,
    input  wire         cre,
    input  wire         clk
);
reg [15:0] mem [0:(1 << AW) - 1];
integer k;
initial if (FILL) for (k = 0; k < (1 << AW); k = k + 1) mem[k] = 16'hFFFF;

reg drive = 1'b0;
reg [15:0] drive_val = 16'hxxxx;
assign dq = drive ? drive_val : 16'hzzzz;

task fail(input [8*72-1:0] what);
    begin $display("ERROR: psram model: %0s (at %0.3f ns)", what, $realtime); $finish; end
endtask

real t_a = 0.0, t_dq = 0.0;                        // the last change of A[21:16], of DQ
real t_adv_fall = 0.0, t_adv_rise = -1.0e9, t_ce_fall = 0.0, t_ce_rise = -1.0e9;
real t_we_fall = 0.0, t_oe_fall = 0.0, t_lane = 0.0, te = 0.0, tv = 0.0;
reg ce_low = 1'b0;          // CE# seen low: the cycle's end is still to come
reg latched = 1'b0;         // the address of this CE# cycle is latched
reg cre_cycle = 1'b0;       // CRE was high at the latch
reg bcr_done = 1'b0;
reg writing = 1'b0, did_read = 1'b0, did_write = 1'b0;
reg [21:0] addr = 22'd0;
reg [15:0] w = 16'd0;
reg [3:0] h_wr = 4'd0, h_top = 4'd0;   // the last 4 array accesses: a write, on word 3FFFFFh
integer h_n = 0;

// die 1 and CLK are never used
initial #1 if (ce1_n !== 1'b1 || clk !== 1'b0) fail("die 1 or CLK used");
always @(ce1_n or clk) if (ce1_n === 1'b0 || clk === 1'b1) fail("die 1 or CLK used");

always @(a) begin
    t_a = $realtime;
    if (latched && ce0_n === 1'b0 && $realtime - t_adv_rise < T_AVH) fail("A changed within tAVH after ADV# high");
end
always @(dq) begin
    t_dq = $realtime;
    if (latched && ce0_n === 1'b0 && $realtime - t_adv_rise < T_AVH) fail("DQ changed within tAVH after ADV# high");
    if (drive && dq !== drive_val) fail("DQ contention");
end

// the address latch
always @(negedge adv_n) t_adv_fall = $realtime;
always @(posedge adv_n) if (ce0_n === 1'b0) begin
    if ($realtime - t_adv_fall < T_VP) fail("ADV# low shorter than tVP");
    if ($realtime - t_a < T_AVS || $realtime - t_dq < T_AVS) fail("address setup to ADV# high shorter than tAVS");
    if ($realtime - t_ce_fall < T_CVS) fail("CE# low to ADV# high shorter than tCVS");
    if (oe_n !== 1'b1) fail("OE# low while the address is on DQ");
    if (^{a, dq, cre} === 1'bx) fail("address or CRE not 0 or 1 at the ADV# rise");
    addr = {a, dq};
    latched = 1'b1;
    cre_cycle = cre;
    t_adv_rise = $realtime;
    if (!cre) begin
        if (!bcr_done) fail("access before the BCR write");
        if (addr >= (1 << AW)) begin $display("ERROR: psram model: word %h beyond AW", addr); $finish; end
    end
end

// CE#: tCPH before, tCEM while low
always @(negedge ce0_n) begin
    if ($realtime - t_ce_rise < T_CPH) fail("CE# high shorter than tCPH between accesses");
    if (we_n === 1'b0) fail("WE# low at the CE# fall");
    t_ce_fall = $realtime;
    ce_low = 1'b1; latched = 1'b0; did_read = 1'b0; did_write = 1'b0;
end
always @(negedge ce0_n) begin : cem_timer
    #(T_CEM);
    fail("CE# low longer than tCEM");
end

// write: from the WE# fall with CE# low to the first rise of WE# or CE#; then the end of the CE# cycle
always @(negedge lb_n or negedge ub_n) t_lane = $realtime;
always @(negedge we_n) if (ce0_n === 1'b0) begin
    writing = 1'b1;
    t_we_fall = $realtime;
end
always @(posedge we_n or posedge ce0_n) begin
    if (writing) begin
        writing = 1'b0;
        te = $realtime;
        if (!latched) fail("a write without a latched address");
        if (te - t_we_fall < T_WP) fail("WE# low shorter than tWP");
        if (te - t_ce_fall < T_CW) fail("CE# low to the end of a write shorter than tCW");
        if (te - t_adv_fall < T_VS) fail("ADV# low to the end of a write shorter than tVS");
        if (te - t_a < T_AW) fail("address to the end of a write shorter than tAW");
        if (te - t_dq < T_DW) fail("data setup to the end of a write shorter than tDW");
        if (cre_cycle) begin
            // the data sheet: CRE write values on A[21:16] and A/DQ[15:0]; LB#/UB# don't care
            if (t_ce_fall < T_PU) fail("BCR write before tPU");
            if (addr !== 22'h089D1F) begin $display("ERROR: psram model: BCR write %h", addr); $finish; end
            bcr_done = 1'b1;
        end else begin
            if ((lb_n === 1'b0 || ub_n === 1'b0) && te - t_lane < T_BW) fail("LB#/UB# low to the end of a write shorter than tBW");
            w = mem[addr];
            if (lb_n === 1'b0) w[7:0] = dq[7:0];
            if (ub_n === 1'b0) w[15:8] = dq[15:8];
            mem[addr] = w;
            did_write = 1'b1;
        end
    end
    if (ce_low && ce0_n !== 1'b0) begin
        ce_low = 1'b0;
        disable cem_timer;
        t_ce_rise = $realtime;
        if (latched && !cre_cycle && (did_read || did_write)) begin
            h_wr = {h_wr[2:0], did_write};
            h_top = {h_top[2:0], addr == 22'h3FFFFF};
            if (h_n < 4) h_n = h_n + 1;
            if (h_n == 4 && h_top == 4'b1111 && h_wr == 4'b0011) fail("configuration register sequence");
        end
        latched = 1'b0;
    end
end

// read: the drive of DQ
event rd_go;
always @(negedge oe_n) if (ce0_n === 1'b0 && we_n === 1'b1) begin
    if (!latched) fail("OE# low without a latched address");
    if (cre_cycle) fail("CRE read");
    did_read = 1'b1;
    t_oe_fall = $realtime;
    -> rd_go;
end
always @(rd_go) begin : rd_drive
    #(T_OLZ - 0.1);
    if (dq !== 16'hzzzz) fail("DQ driven by the controller while OE# low");
    #(0.1);
    drive_val = 16'hxxxx;
    drive = 1'b1;
    tv = t_adv_fall + T_AADV;
    if (t_ce_fall + T_CO > tv) tv = t_ce_fall + T_CO;
    if (t_oe_fall + T_OE > tv) tv = t_oe_fall + T_OE;
    if (t_a + T_AA > tv) tv = t_a + T_AA;
    if (tv > $realtime) #(tv - $realtime);
    drive_val = mem[addr];
end
always @(posedge oe_n or posedge ce0_n) begin
    disable rd_drive;
    if (drive) begin
        drive_val = 16'hxxxx;           // no output hold: the word is gone at the rise
        #(T_OHZ);
        drive = 1'b0;
    end
end
endmodule
`default_nettype wire
