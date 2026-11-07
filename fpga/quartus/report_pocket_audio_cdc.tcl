# Report only; run after the native target's compilation.
project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist
if {[file exists audio-cdc-audit]} {error "Preserving existing audio-cdc-audit"}
file mkdir audio-cdc-audit
proc audio_register {index} {
    return [pocket_first_register {*|audio|beeper_sync*} [format {\|beeper_sync\[%d\]$} $index]]
}
report_timing -setup -from $audio_sources -to [audio_register 0] -npaths 1 -file audio-cdc-audit/excluded-beeper.txt
for {set index 0} {$index < 2} {incr index} {
    set source [audio_register $index]
    set target [audio_register [expr {$index+1}]]
    report_timing -setup -from $source -to $target -npaths 1 -file "audio-cdc-audit/beeper-${index}-setup.txt"
    report_timing -hold -from $source -to $target -npaths 1 -file "audio-cdc-audit/beeper-${index}-hold.txt"
}
puts "PASS audio CDC report generation: native BEEPER to first receiver only; two timed internal links"
project_close
