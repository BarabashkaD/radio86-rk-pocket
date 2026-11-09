// A byte-wide memory of the Radio-86RK board that the CPU never writes: the font (read by the
// video) and the ROM disk (read through the PPI in A000-BFFF). pocket_slot_loader writes it from
// its APF data slot while the machine is in reset. One write port and one read port (one block
// RAM copy); the data and its address (tag) 1 clk after the read address. FILL: the bytes that no
// slot wrote.
`default_nettype none
module pocket_rom8 #(
    parameter integer AW = 10,
    parameter [7:0] FILL = 8'h00
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire    [7:0] wd,
    input  wire [AW-1:0] ra,
    output reg     [7:0] rd = FILL,
    output reg  [AW-1:0] tag = {AW{1'b1}}
);
reg [7:0] mem [0:(1 << AW) - 1];
integer k;
initial for (k = 0; k < (1 << AW); k = k + 1) mem[k] = FILL;
always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    rd <= mem[ra];
    tag <= ra;
end
endmodule
`default_nettype wire
