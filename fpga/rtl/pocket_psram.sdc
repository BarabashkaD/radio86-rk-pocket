# cram0 (pocket_psram): asynchronous PSRAM accesses sequenced in clk_74a ticks. Each pin may lag its
# register by up to one tick, which the tick counts of pocket_psram.v allow for: bound it here.
set psram_out [get_ports {cram0_a[*] cram0_dq[*] cram0_adv_n cram0_ce0_n cram0_oe_n cram0_we_n cram0_ub_n cram0_lb_n cram0_cre}]
set psram_in [get_ports {cram0_dq[*]}]
if {[get_collection_size $psram_out] != 29 || [get_collection_size $psram_in] != 16} {
    error "cram0 port count changed; review pocket_psram.sdc"
}
set_output_delay -clock clk_74a -max 0 $psram_out
set_output_delay -clock clk_74a -min 0 $psram_out
set_input_delay -clock clk_74a -max 0 $psram_in
set_input_delay -clock clk_74a -min 0 $psram_in
# Hold of the DQ sample: pocket_psram.v samples DQ at t10 and raises OE#/CE#/LB#/UB# at t11, a full tick
# later. The input register takes the pad value of t10 or earlier (pad-to-register delay 0 to one tick);
# the OE#/CE# pins rise at t11 or later (register-to-pad delay 0 to one tick). The part has no minimum
# output hold after OE#/CE# high, but it drives the word until those pins rise: at least one tick after
# the value taken. The tick counts carry that relation, not this analysis: cut it here.
set_false_path -hold -from $psram_in
