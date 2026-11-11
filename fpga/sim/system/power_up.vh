// Power-up values of the machine for the system TB (spec 7, 9.5): rk86_machine16. M: the
// rk86_machine16 instance; uses the integer i of the TB. The 8080 (Vslav's model) has no initial
// values: ZERO_UP is CPU16_ZERO of the core (src/sim/machine16/cpu_power_up.vh; compile with -I for
// that folder), which sets every register of it that is X to 0, as Quartus powers registers up. The
// 8275, the 8257, the 8255 and the clocks start from the initial values in their RTL (0, as in Quartus).
// RANDOM_UP (scenario powerup, after ZERO_UP and after the RTL's own initial blocks: the TB waits 1 ns)
// puts garbage into the 8275's parameters and counters and the 8257's address and count registers:
// the monitor's programming must win over it.
`include "cpu_power_up.vh"

`define ZERO_UP(M) \
	`CPU16_ZERO(M.cpu)

`define RANDOM_UP(M) \
	M.crt.p_s = $random; M.crt.p_h = $random; M.crt.p_v = $random; M.crt.p_r = $random; M.crt.p_u = $random; \
	M.crt.p_l = $random; M.crt.p_m = $random; M.crt.p_f = $random; M.crt.p_c = $random; M.crt.p_z = $random; \
	M.crt.p_bs = $random; M.crt.p_bc = $random; M.crt.cur_c = $random; M.crt.cur_r = $random; \
	M.crt.ch = $random; M.crt.ln = $random; M.crt.rw = $random; \
	for (i = 0; i < 4; i = i + 1) begin M.dma.ad[i] = $random; M.dma.tr[i] = $random; end
