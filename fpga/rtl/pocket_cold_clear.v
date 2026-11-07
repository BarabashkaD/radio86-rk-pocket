// Clears the 32 KB RAM through the loader port of pocket_memory: at the first boot and on the
// interact Cold boot (spec 5.2, 5.4). One byte per clk; the machine is held in reset meanwhile.
`default_nettype none
module pocket_cold_clear(
    input  wire        clk,
    input  wire        start,          // a clk with start begins a clear when none runs
    output reg         active = 1'b0,
    output wire        we,
    output reg  [14:0] a = 15'd0,
    output wire  [7:0] d,
    output reg         done = 1'b0     // set after the first complete clear, then stays set
);
assign we = active;
assign d = 8'h00;
always @(posedge clk) begin
    if (start && !active) begin
        active <= 1'b1;
        a <= 15'd0;
    end else if (active) begin
        if (a == 15'h7FFF) begin active <= 1'b0; done <= 1'b1; end
        a <= a + 15'd1;
    end
end
endmodule
`default_nettype wire
