// Power-up values of the machine and the native video for the system TB (spec 5.3, 9.5).
// M: the rk86_machine instance, V: the rk86_video instance; uses the integer i of the TB.
`define ZERO_UP(M, V) \
	V.state = 2'd0; V.d_cnt = 3'd0; V.data = 6'd0; V.h_cnt = 11'd0; V.v_cnt = 11'd0; \
	M.CPU.B = 8'h00; M.CPU.C = 8'h00; M.CPU.D = 8'h00; M.CPU.E = 8'h00; M.CPU.H = 8'h00; \
	M.CPU.L = 8'h00; M.CPU.A = 8'h00; M.CPU.SP = 16'h0000; M.CPU.W = 8'h00; M.CPU.Z = 8'h00; \
	M.CPU.IR = 8'h00; M.CPU.call = 1'b0; M.CPU.read_r = 1'b0; M.CPU.read_rp = 1'b0; \
	M.CPU.xthl = 1'b0; M.CPU.xchg = 1'b0; M.CPU.sphl = 1'b0; M.CPU.daa = 1'b0; M.CPU.T5 = 1'b0; \
	for (i = 0; i < 4; i = i + 1) begin M.dma.chaddr[i] = 16'h0000; M.dma.chtcnt[i] = 16'h0000; end \
	M.dma.channel = 2'd0; \
	M.crt.init0 = 8'h00; M.crt.init1 = 8'h00; M.crt.init2 = 8'h00; M.crt.init3 = 8'h00; \
	M.crt.enable = 1'b0; M.crt.inte = 1'b0; M.crt.dmae = 1'b0; M.crt.dmadelay = 3'd0; M.crt.dmalen = 2'd0; \
	M.crt.curx = 7'd0; M.crt.cury = 6'd0; M.crt.chline = 5'd0; M.crt.attr = 6'd0; M.crt.exattr = 6'd0; \
	M.crt.iposf = 4'd0; M.crt.oposf = 4'd0; M.crt.ipos = 7'h7F; M.crt.opos = 8'd0; M.crt.ypos = 6'd0; \
	M.crt.frame = 5'd0; M.crt.lineff = 1'b0; M.crt.exwe_n = 1'b0; M.crt.exrd_n = 1'b0; \
	M.crt.exvrtc = 1'b0; M.crt.exhrtc = 1'b0; M.crt.err = 1'b0; M.crt.vspfe = 1'b0; \
	M.crt.pstate = 3'd0; M.crt.istate = 1'b0; M.crt.drq = 1'b0; M.crt.irq = 1'b0; M.crt.ochar = 7'd0; \
	for (i = 0; i < 80; i = i + 1) begin M.crt.buf0[i] = 8'h00; M.crt.buf1[i] = 8'h00; end \
	for (i = 0; i < 16; i = i + 1) begin M.crt.fifo0[i] = 7'h00; M.crt.fifo1[i] = 7'h00; end

`define RANDOM_UP(M, V) \
	`ZERO_UP(M, V) \
	V.state = $random; V.d_cnt = $random; V.data = $random; V.h_cnt = $random; V.v_cnt = $random; \
	M.crt.init0 = $random; M.crt.init1 = $random; M.crt.init2 = $random; M.crt.init3 = $random; \
	M.crt.enable = $random; M.crt.inte = $random; M.crt.dmae = $random; M.crt.dmadelay = $random; M.crt.dmalen = $random; \
	M.crt.curx = $random; M.crt.cury = $random; M.crt.chline = $random; M.crt.attr = $random; M.crt.exattr = $random; \
	M.crt.iposf = $random; M.crt.oposf = $random; M.crt.ipos = $random; M.crt.opos = $random; M.crt.ypos = $random; \
	M.crt.frame = $random; M.crt.lineff = $random; M.crt.exwe_n = $random; M.crt.exrd_n = $random; \
	M.crt.exvrtc = $random; M.crt.exhrtc = $random; M.crt.err = $random; M.crt.vspfe = $random; \
	M.crt.pstate = $random; M.crt.istate = $random; M.crt.drq = $random; M.crt.irq = $random; M.crt.ochar = $random; \
	for (i = 0; i < 80; i = i + 1) begin M.crt.buf0[i] = $random; M.crt.buf1[i] = $random; end \
	for (i = 0; i < 16; i = i + 1) begin M.crt.fifo0[i] = $random; M.crt.fifo1[i] = $random; end
