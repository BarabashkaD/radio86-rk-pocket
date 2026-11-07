// Restarts the video/audio PLL when its lock stays lost (spec 5.2): after TIMEOUT clk of clk_74a
// without lock, pll_reset is high for PULSE clk, then the count starts again. TIMEOUT 2^21 clk is
// 28 ms at 74.25 MHz, well above the Cyclone V PLL lock time (tLOCK at most 1 ms, Cyclone V
// device datasheet; check the value when changing TIMEOUT). The machine clock clk_74a does not
// come from this PLL, so the machine and its RAM never see the restart.
`default_nettype none
module pocket_pll_watchdog #(
    parameter integer TIMEOUT = 2097152,
    parameter integer PULSE = 64
)(
    input  wire clk,
    input  wire locked_s,                 // the PLL lock, synchronized to clk
    output reg  pll_reset = 1'b0
);
reg [21:0] wait_cnt = 22'd0;
reg [6:0] pulse_cnt = 7'd0;
always @(posedge clk) begin
    if (pll_reset) begin
        wait_cnt <= 22'd0;
        if (pulse_cnt == PULSE - 1) begin pll_reset <= 1'b0; pulse_cnt <= 7'd0; end
        else pulse_cnt <= pulse_cnt + 7'd1;
    end else if (locked_s) wait_cnt <= 22'd0;
    else if (wait_cnt == TIMEOUT - 1) begin pll_reset <= 1'b1; wait_cnt <= 22'd0; end
    else wait_cnt <= wait_cnt + 22'd1;
end
endmodule
`default_nettype wire
