`timescale 1ns/1ps
`default_nettype none
// The K1 panel in pocket_frame_video: one background frame through the source port, then one
// displayed frame per state, compared pixel by pixel with the model (scripts/k1/layout.py).
// Inputs (run_sim.py k1_panel_inputs): k1_panel_bg.hex (122400 bits), k1_panel_states.hex
// ({error, green, panel_state[77:0]} per line), k1_panel_exp_<n>.hex (RRGGBB per pixel).
// Writes k1_panel_<n>.hex, the captured frames.
module tb_k1_panel;
reg sclk = 1'b0, pclk = 1'b0;
always #6.734 sclk = ~sclk;          // clk_74a, 74.25 MHz
always #40.690 pclk = ~pclk;         // clk_core_12288
reg srst = 1'b0, prst = 1'b0, green = 1'b0, error = 1'b0, valid = 1'b0, data = 1'b0, fs = 1'b0, fe = 1'b0;
reg [16:0] addr = 17'd0;
reg [77:0] panel_state = 78'd0;
wire [23:0] rgb;
wire de, hs, vs, skip, adac, alr;
wire [31:0] fc, fd, fdisp;
pocket_frame_video dut(.source_clk(sclk), .source_reset_n(srst), .pixel_clk(pclk), .pixel_reset_n(prst),
    .pixel_valid(valid), .pixel_data(data), .frame_start(fs), .frame_end(fe), .pixel_address(addr),
    .diagnostic_error(error), .green(green), .panel_state(panel_state), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
    .skip(skip), .audio_dac(adac), .audio_lrck(alr), .frames_completed(fc), .frames_dropped(fd),
    .frames_displayed(fdisp));
reg bg[0:122399];
reg [23:0] expected[0:122399];
reg [79:0] states[0:31];
integer nstates, fd_states, r;
reg [79:0] word;
task send_frame;
    integer i;
    begin
        for (i = 0; i < 122400; i = i + 1) begin
            @(negedge sclk); valid = 1'b1; data = bg[i]; addr = i; fs = i == 0; fe = i == 122399;
        end
        @(negedge sclk); valid = 1'b0; fs = 1'b0; fe = 1'b0;
    end
endtask
// Sets the state now (before the next x == 0 && y == 0 latch) and checks the frame latched there.
task check_state(input integer n);
    reg [8*32:1] name;
    integer out, count, cycles;
    begin
        word = states[n];
        @(negedge pclk); error = word[79]; green = word[78]; panel_state = word[77:0];
        $sformat(name, "k1_panel_exp_%0d.hex", n);
        $readmemh(name, expected);
        $sformat(name, "k1_panel_%0d.hex", n);
        out = $fopen(name, "w");
        wait (dut.x == 0 && dut.y == 0); @(posedge pclk);
        count = 0; cycles = 0;
        while (count < 122400 && cycles < 512 * 400) begin
            @(posedge pclk); #1; cycles = cycles + 1;
            if (de) begin
                $fdisplay(out, "%06h", rgb);
                if (rgb !== expected[count]) begin
                    $display("ERROR: pixel %0d,%0d got %06h expected %06h (state %0d)",
                             count % 408, count / 408, rgb, expected[count], n);
                    $fclose(out); $finish;
                end
                count = count + 1;
            end
        end
        $fclose(out);
        if (count != 122400) begin $display("ERROR: state %0d: %0d pixels with de", n, count); $finish; end
    end
endtask
integer n;
initial begin
    $readmemh("k1_panel_bg.hex", bg);
    nstates = 0;
    fd_states = $fopen("k1_panel_states.hex", "r");
    if (fd_states == 0) begin $display("ERROR: no k1_panel_states.hex"); $finish; end
    while (!$feof(fd_states)) begin
        r = $fscanf(fd_states, "%h\n", word);
        if (r == 1) begin states[nstates] = word; nstates = nstates + 1; end
    end
    $fclose(fd_states);
    if (nstates == 0) begin $display("ERROR: no states"); $finish; end
    #10 srst = 1'b1; prst = 1'b1;
    #200 srst = 1'b0; prst = 1'b0;
    #200 srst = 1'b1; prst = 1'b1;
    send_frame;
    wait (fdisp >= 1);
    for (n = 0; n < nstates; n = n + 1) check_state(n);
    $display("PASS k1 panel: %0d states, every pixel equal to the model", nstates);
    $finish;
end
endmodule
`default_nettype wire
