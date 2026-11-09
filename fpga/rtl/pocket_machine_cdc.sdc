# Machine-only CDC constraints. Do not cut the related root/PLL clock domains.
# Token data is held until its round-trip acknowledgement; only receiver stage 0
# samples the other domain. Later synchronizer stages remain normally timed.
proc pocket_first_register {pattern expression} {
    set found [list]
    foreach_in_collection node [get_registers $pattern] {
        if {[regexp $expression [get_register_info -name $node]]} {
            lappend found $node
        }
    }
    if {[llength $found] != 1} {
        error "Pocket CDC endpoint changed: $pattern / $expression: [llength $found] matches"
    }
    return [lindex $found 0]
}
# Physical synthesis can replicate a token register. Include only that register
# and its named replicas, still ending at the single first receiver stage.
proc pocket_token_registers {name} {
    set sources [get_registers "*|video|${name}*"]
    set count 0
    foreach_in_collection node $sources {
        if {![regexp [format {\|%s(~DUPLICATE.*)?$} $name] [get_register_info -name $node]]} {
            error "Unexpected Pocket token source: [get_register_info -name $node]"
        }
        incr count
    }
    if {$count < 1} {error "Missing Pocket token source: $name"}
    return $sources
}
set pocket_request_source [pocket_token_registers request_token]
set pocket_ack_source [pocket_token_registers ack_token]
set pocket_request_first [pocket_first_register {*|video|request_sync*} {\|request_sync\[0\]$}]
set pocket_ack_first [pocket_first_register {*|video|ack_sync*} {\|ack_sync\[0\]$}]
set_false_path -from $pocket_request_source -to $pocket_request_first
set_false_path -from $pocket_ack_source -to $pocket_ack_first
# The text colour (interact, clk_74a) is a static setting: only its first receiver is cut.
set pocket_green_first [pocket_first_register {*|video|green_sync*} {\|green_sync\[0\]$}]
set_false_path -from [get_clocks clk_74a] -to $pocket_green_first
