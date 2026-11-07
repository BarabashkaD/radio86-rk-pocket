# Report only. Run quartus_sta -t <this script> inside an isolated machine build.
project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist
if {[file exists cdc-audit]} { error "Preserving existing cdc-audit directory" }
file mkdir cdc-audit
proc one_machine_register {pattern expression} {
    set matches [list]
    foreach_in_collection node [get_registers $pattern] {
        if {[regexp $expression [get_register_info -name $node]]} { lappend matches $node }
    }
    if {[llength $matches] != 1} {error "Unexpected CDC register collection: $pattern $expression"}
    return [lindex $matches 0]
}
foreach chain {request_sync ack_sync error_sync} {
    for {set index 0} {$index < 2} {incr index} {
        set source [one_machine_register "*|video|${chain}*" [format {\|%s\[%d\]$} $chain $index]]
        set target [one_machine_register "*|video|${chain}*" [format {\|%s\[%d\]$} $chain [expr {$index+1}]]]
        report_timing -setup -from $source -to $target -npaths 1 -file "cdc-audit/${chain}-${index}-setup.txt"
        report_timing -hold -from $source -to $target -npaths 1 -file "cdc-audit/${chain}-${index}-hold.txt"
    }
}
set request_source [pocket_token_registers request_token]
set ack_source [pocket_token_registers ack_token]
set request_first [one_machine_register {*|video|request_sync*} {\|request_sync\[0\]$}]
set ack_first [one_machine_register {*|video|ack_sync*} {\|ack_sync\[0\]$}]
set error_first [one_machine_register {*|video|error_sync*} {\|error_sync\[0\]$}]
report_timing -setup -from $request_source -to $request_first -npaths 1 -file cdc-audit/excluded-request.txt
report_timing -setup -from $ack_source -to $ack_first -npaths 1 -file cdc-audit/excluded-ack.txt
report_timing -setup -from [get_clocks clk_74a] -to $error_first -npaths 1 -file cdc-audit/excluded-error.txt
puts "PASS report generation: three first receivers and six timed internal stage links"
project_close
