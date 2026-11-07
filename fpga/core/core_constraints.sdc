#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# PLL output clocks are related to clk_74a and to one another; do not cut them.
set core_clocks [get_clocks {clk_74a *|mp1|*}]
set_clock_groups -asynchronous \
    -group [get_clocks bridge_spiclk] \
    -group [get_clocks clk_74b] \
    -group $core_clocks
derive_clock_uncertainty

# reset_n is deliberately sampled as an asynchronous reset by exactly these
# three receiver stages. Keep their internal shift paths and the downstream
# synchronized AV reset timed; cut only the source-to-reset-receiver paths.
set shell_reset_sync [get_registers {*|run_sync*}]
set shell_reset_source [get_registers {*icb*reset_n}]
if {[get_collection_size $shell_reset_sync] != 3 || [get_collection_size $shell_reset_source] < 1} {
    error "Shell reset synchronizer endpoint count changed; review the exception"
}
# The fitter may replicate this source FF. Accept only it and its named replicas.
foreach_in_collection node $shell_reset_source {
    if {![regexp {\|reset_n(~DUPLICATE.*)?$} [get_register_info -name $node]]} {
        error "Unexpected reset source in the receiver exception"
    }
}
set_false_path -from $shell_reset_source -to $shell_reset_sync
