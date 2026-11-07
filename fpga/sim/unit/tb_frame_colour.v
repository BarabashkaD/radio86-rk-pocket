`timescale 1ns/1ps
`default_nettype none
// pocket_frame_video colour (spec 5.5): lit dots white, then green after the setting changes.
module tb_frame_colour;
reg sclk = 1'b0, pclk = 1'b0;
always #6.734 sclk = ~sclk;          // clk_74a, 74.25 MHz
always #40.690 pclk = ~pclk;         // clk_core_12288: the real ratio, 6.04
reg srst = 1'b0, prst = 1'b0, green = 1'b0, valid = 1'b0, data = 1'b0, fs = 1'b0, fe = 1'b0;
reg [16:0] addr = 17'd0;
wire [23:0] rgb;
wire de, hs, vs, skip, adac, alr;
wire [31:0] fc, fd, fdisp;
pocket_frame_video dut(.source_clk(sclk), .source_reset_n(srst), .pixel_clk(pclk), .pixel_reset_n(prst),
    .pixel_valid(valid), .pixel_data(data), .frame_start(fs), .frame_end(fe), .pixel_address(addr),
    .diagnostic_error(1'b0), .green(green), .rgb(rgb), .de(de), .hs(hs), .vs(vs), .skip(skip),
    .audio_dac(adac), .audio_lrck(alr), .frames_completed(fc), .frames_dropped(fd), .frames_displayed(fdisp));
task send_frame;
    integer i;
    begin
        for (i = 0; i < 122400; i = i + 1) begin
            @(negedge sclk); valid = 1'b1; data = i[0]; addr = i; fs = i == 0; fe = i == 122399;
        end
        @(negedge sclk); valid = 1'b0; fs = 1'b0; fe = 1'b0;
    end
endtask
task check_colour(input [23:0] want);
    integer n, lit, dark;
    begin
        lit = 0; dark = 0;
        wait (dut.x == 0 && dut.y == 0); @(posedge pclk);
        for (n = 0; n < 512 * 400; n = n + 1) begin
            @(posedge pclk); #1;
            if (de) begin
                if (rgb == want) lit = lit + 1;
                else if (rgb == 24'h0) dark = dark + 1;
                else begin $display("ERROR: colour %h, expected %h", rgb, want); $finish; end
            end
        end
        if (lit < 60000 || dark < 60000) begin $display("ERROR: lit %0d dark %0d", lit, dark); $finish; end
    end
endtask
initial begin
    // a real reset: high, then low for a few clks of each domain (an initial 0 gives no negedge), then released
    #10 srst = 1'b1; prst = 1'b1;
    #200 srst = 1'b0; prst = 1'b0;
    #200 srst = 1'b1; prst = 1'b1;
    send_frame; send_frame;
    wait (fdisp >= 1); check_colour(24'hFFFFFF);
    green = 1'b1; send_frame; check_colour(24'h00FF00);
    $display("PASS frame colour: white, then green lit dots, black between");
    $finish;
end
endmodule
`default_nettype wire
