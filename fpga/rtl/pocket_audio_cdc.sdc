# Only the first receiver of the registered native one-bit BEEPER crossing.
# Existing video exceptions remain independent; audio stage-to-stage links time normally.
set audio_first [pocket_first_register {*beeper_sync*} {\|beeper_sync\[0\]$}]
set audio_sources [get_registers {*beeper_level*}]
set audio_source_count 0
foreach_in_collection node $audio_sources {
    if {![regexp {\|beeper_level(~DUPLICATE.*)?$} [get_register_info -name $node]]} {
        error "Unexpected native BEEPER source: [get_register_info -name $node]"
    }
    incr audio_source_count
}
if {$audio_source_count < 1} {error "Native BEEPER source register missing"}
set_false_path -from $audio_sources -to $audio_first
