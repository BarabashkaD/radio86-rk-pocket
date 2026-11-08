# The K1 panel state crossing: pocket_bus_cdc instance panel_cdc, clk_74a -> clk_core_12288.
# Read after pocket_machine_cdc.sdc (pocket_first_register). Do not cut the clock domains.
# The held word is loaded together with the req_token toggle and stays unchanged until
# ack_token returns; the destination copies it 3-4 destination clocks after the toggle, so the
# held -> dst_data paths have more than 3 destination periods (240 ns) and are cut. Only the
# first stage of each synchronizer samples the other domain; the stage-to-stage links remain
# normally timed.
proc pocket_bus_registers {instance name} {
    set nodes [get_registers "*|${instance}|${name}*"]
    set count 0
    foreach_in_collection node $nodes {
        if {![regexp [format {\|%s(\[[0-9]+\])?(~DUPLICATE.*)?$} $name] [get_register_info -name $node]]} {
            error "Unexpected Pocket bus CDC register: [get_register_info -name $node]"
        }
        incr count
    }
    if {$count < 1} {error "Missing Pocket bus CDC register: ${instance}|${name}"}
    return $nodes
}
set pocket_panel_held [pocket_bus_registers panel_cdc held]
set pocket_panel_dst [pocket_bus_registers panel_cdc dst_data]
set pocket_panel_req [pocket_bus_registers panel_cdc req_token]
set pocket_panel_ack [pocket_bus_registers panel_cdc ack_token]
set pocket_panel_req_first [pocket_first_register {*|panel_cdc|req_sync*} {\|req_sync\[0\]$}]
set pocket_panel_ack_first [pocket_first_register {*|panel_cdc|ack_sync*} {\|ack_sync\[0\]$}]
set_false_path -from $pocket_panel_held -to $pocket_panel_dst
set_false_path -from $pocket_panel_req -to $pocket_panel_req_first
set_false_path -from $pocket_panel_ack -to $pocket_panel_ack_first
