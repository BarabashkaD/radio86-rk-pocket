# Run with quartus_sta -t <absolute script path> from an isolated build directory.
project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 10 -detail full_path -file setup-details.txt
report_timing -hold -npaths 10 -detail full_path -file hold-details.txt
report_timing -recovery -npaths 10 -detail full_path -file recovery-details.txt
report_timing -removal -npaths 10 -detail full_path -file removal-details.txt
report_ucp -file unconstrained-details.txt
report_clocks -file clock-details.txt
project_close
