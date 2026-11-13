// The A000-BFFF block of the Radio-86RK on the Analogue Pocket: the board's second 8255 (Радио 1986 D14,
// the interface PPI whose ports go to the external connector J6) with a ROM disk on its ports. The 8255 is
// the fork's model k580vv55 (rk86_16/, through rk86_machine16.prj, never copied here). A port is 8 pins of
// the chip; the 4 registers (port A, port B, port C, control) are picked by its address pins A1, A0
// (input a). Port B is the ROM address A0-A7, port C A8-A15, port A the ROM data, always on (no output
// enable; a program that makes port A an output reads its latch). Three cards on J6, chosen by wide and
// card (the image size, pocket_slot_loader; card implies wide):
// - wide = 0, a 32 KB ROM (up to 32768 bytes, e.g. S. Kiselev's): A15 not wired, so 8000-FFFF mirror
//   0000-7FFF: rom_address {0, PC6..PC0, PB}.
// - wide = 1, card = 0, a 64 KB ROM (32769-65536 bytes): {0, PC7..PC0, PB}; no bank latch.
// - card = 1, the J6 bank card (65537-8388608 bytes): {bank, PC7..PC0, PB}, 128 banks of 64 KB. The bank
//   latch takes PB0-PB6 (PB7 ignored) on one event: PC7 falls and, after the fall, PC0-PC6 are all high
//   (port C FF to 7F, or 80..FE to 7F; SELBK: port C FF, port B the bank, bit reset PC7). The monitor's
//   R (FA68) never makes it: its port C stays, counts up by one, drops to 00 (mode set) or wraps FF to 00;
//   an 8255 reset makes PC7 rise. The bank is used only when card (the other cards have no latch, and
//   the event is ignored while card is low).
// The bank is cleared only by card_reset (power-up, a slot load, Cold boot: a new card, or back to the
// card menu); reset (the machine reset, Core Settings > Reset) resets the 8255 only and keeps the bank,
// as the real card has no reset on J6. ROM address A22-A0 (rom_address) goes to the PSRAM
// (pocket_psram), whose byte comes back as rom_data. Pins programmed as inputs float: the ROM sees them
// high. While no image is loaded (loaded = 0: slot 2 empty), port A reads FF on every card. The
// Радио 1987 No. 3 module (PC3-PC5 through a К555ИД7) is not modelled.
`default_nettype none
module pocket_cart_ppi(
    input  wire        clk,
    input  wire        reset,
    input  wire        card_reset,
    input  wire        cs_n,
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire        wide,
    input  wire        card,
    input  wire        loaded,
    input  wire  [1:0] a,
    input  wire  [7:0] d_i,
    output wire  [7:0] d_o,
    output wire [22:0] rom_address,
    input  wire  [7:0] rom_data
);
wire [7:0] pa_o, pb_o, pc_o, pc_oe;
wire pa_oe, pb_oe;
wire [7:0] pb_pin = pb_oe ? pb_o : 8'hFF;
wire [7:0] pc_pin = (pc_oe & pc_o) | ~pc_oe;
reg [6:0] bank = 7'd0;
reg pc7_q = 1'b1;                       // the PC7 pin, one clk back
always @(posedge clk) begin
    pc7_q <= pc_pin[7];
    if (card_reset) bank <= 7'd0;
    else if (card && pc7_q && pc_pin == 8'h7F) bank <= pb_pin[6:0];   // PC7 fell, PC0-PC6 high
end
assign rom_address = {card ? bank : 7'd0, wide & pc_pin[7], pc_pin[6:0], pb_pin};
wire [7:0] pa_pin = loaded ? rom_data : 8'hFF;
k580vv55 ppi(.clk(clk), .reset(reset), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .a(a), .d_i(d_i), .d_o(d_o),
    .pa_i(pa_pin), .pa_o(pa_o), .pa_oe(pa_oe), .pb_i(8'hFF), .pb_o(pb_o), .pb_oe(pb_oe),
    .pc_i(8'hFF), .pc_o(pc_o), .pc_oe(pc_oe));
endmodule
`default_nettype wire
