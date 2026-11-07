// The interact registers of the Core Settings menu (spec 5.7). No reset: Pocket OS writes the
// saved values while reset_n is low, before Reset Exit, and reads them back every frame; the
// initial values are the defaults of package/core/interact.json.
//   0x100 action: 1 Reset, 2 Cold boot (one clk each); reads 0
//   0x104 Sound (bit 0)   0x108 Text colour (bit 0: green)   0x10C Keys (0..3)   0x110 Keys on (0..1)
//   0x114 Escape (0..2)   0x118 ... 0x144 reserved (read 0). Out-of-range writes are ignored.
`default_nettype none
module pocket_interact(
    input  wire        clk,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output reg  [31:0] rd_data,
    output wire        selected,
    output reg         warm_reset = 1'b0,
    output reg         cold_boot = 1'b0,
    output reg         sound_on = 1'b1,
    output reg         green = 1'b0,
    output reg   [1:0] preset = 2'd0,
    output reg         keys_on = 1'b0,
    output reg   [1:0] escape = 2'd0
);
wire [7:0] offset = bridge_addr[7:0];
assign selected = bridge_addr[31:8] == 24'h000001 && offset[1:0] == 2'b00 && offset <= 8'h44;
always @* begin
    rd_data = 32'd0;
    if (offset == 8'h04) rd_data = {31'd0, sound_on};
    else if (offset == 8'h08) rd_data = {31'd0, green};
    else if (offset == 8'h0C) rd_data = {30'd0, preset};
    else if (offset == 8'h10) rd_data = {31'd0, keys_on};
    else if (offset == 8'h14) rd_data = {30'd0, escape};
end
always @(posedge clk) begin
    warm_reset <= 1'b0;
    cold_boot <= 1'b0;
    if (bridge_wr && selected) begin
        if (offset == 8'h00) begin
            warm_reset <= bridge_wr_data == 32'd1;
            cold_boot <= bridge_wr_data == 32'd2;
        end else if (offset == 8'h04) sound_on <= bridge_wr_data[0];
        else if (offset == 8'h08) green <= bridge_wr_data[0];
        else if (offset == 8'h0C) begin
            if (bridge_wr_data <= 32'd3) preset <= bridge_wr_data[1:0];
        end else if (offset == 8'h10) begin
            if (bridge_wr_data <= 32'd1) keys_on <= bridge_wr_data[0];
        end else if (offset == 8'h14) begin
            if (bridge_wr_data <= 32'd2) escape <= bridge_wr_data[1:0];
        end
    end
end
endmodule
`default_nettype wire
