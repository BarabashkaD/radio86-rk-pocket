// The A000-BFFF block of the Radio-86RK on the Analogue Pocket: the board's second 8255 (Радио 1986 D14,
// the interface PPI whose ports go to the external connector) with S. Kiselev's ROM disk on its ports. The
// 8255 is the fork's model k580vv55 (rk86_16/, through rk86_machine16.prj, never copied here). A port is 8
// pins of the chip; the 4 registers (port A, port B, port C, control) are picked by its address pins A1, A0
// (input a). ROM disk wiring, as in 0.7.x: port B and PC0-PC6 are the ROM address A0-A14, port A the ROM
// data while PC7 is low (PC7 high: the ROM's outputs off). Pins programmed as inputs float: the ROM sees them
// high, an undriven port A reads FF. The Радио 1987 No. 3 module (PC3-PC5 through a К555ИД7) is not modelled.
`default_nettype none
module pocket_cart_ppi(
    input  wire        clk,
    input  wire        reset,
    input  wire        cs_n,
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire  [1:0] a,
    input  wire  [7:0] d_i,
    output wire  [7:0] d_o,
    output wire [14:0] rom_address,
    input  wire  [7:0] rom_data
);
wire [7:0] pa_o, pb_o, pc_o, pc_oe;
wire pa_oe, pb_oe;
wire [7:0] pb_pin = pb_oe ? pb_o : 8'hFF;
wire [7:0] pc_pin = (pc_oe & pc_o) | ~pc_oe;
assign rom_address = {pc_pin[6:0], pb_pin};
wire [7:0] pa_pin = pc_pin[7] ? 8'hFF : rom_data;       // PC7 low enables the ROM's outputs
k580vv55 ppi(.clk(clk), .reset(reset), .cs_n(cs_n), .rd_n(rd_n), .wr_n(wr_n), .a(a), .d_i(d_i), .d_o(d_o),
    .pa_i(pa_pin), .pa_o(pa_o), .pa_oe(pa_oe), .pb_i(8'hFF), .pb_o(pb_o), .pb_oe(pb_oe),
    .pc_i(8'hFF), .pc_o(pc_o), .pc_oe(pc_oe));
endmodule
`default_nettype wire
