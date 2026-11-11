# Creates the Quartus project ap_core in a build directory outside the source tree (spec 8):
#   quartus_sh -t fpga/quartus/create_project.tcl <build dir>
# Sources are referenced where they are: fpga/ and the core (RK86_CORE_DIR or the submodule).
# The APF pre-flow script writes apf/build_id.mif relative to the project, so into <build dir>.
set fpga [file normalize [file join [file dirname [info script]] ..]]
set root [file normalize [file join $fpga ..]]
if {[info exists ::env(RK86_CORE_DIR)]} {
    set core [file normalize $::env(RK86_CORE_DIR)]
} else {
    set core [file join $root cores karabas-go-core-rk86 src]
}
set build [file normalize [lindex $argv 0]]
file mkdir [file join $build apf]
cd $build
project_new ap_core -overwrite
source [file join $fpga quartus ap_core.qsf]
set_global_assignment -name SEARCH_PATH [file join $fpga rtl]
set_global_assignment -name PRE_FLOW_SCRIPT_FILE "quartus_sh:[file join $fpga apf build_id_gen.tcl]"
set_global_assignment -name QIP_FILE [file join $fpga apf apf.qip]
set_global_assignment -name QIP_FILE [file join $fpga core mf_pllbase.qip]
foreach f {core_top.v core_bridge_cmd.v} {
    set_global_assignment -name VERILOG_FILE [file join $fpga core $f]
}
foreach f [lsort [glob [file join $fpga rtl *.v]]] {
    set_global_assignment -name VERILOG_FILE $f
}
set prj [open [file join $core rk86_machine16.prj]]
while {[gets $prj line] >= 0} {
    if {[regexp {^verilog\s+\S+\s+"([^"]+)"} $line -> rel]} {
        set_global_assignment -name VERILOG_FILE [file join $core $rel]
    }
}
close $prj
# apf_constraints.sdc reads core/core_constraints.sdc relative to the project directory: place a copy in the build
file mkdir [file join $build core]
file copy -force [file join $fpga core core_constraints.sdc] [file join $build core core_constraints.sdc]
foreach f {rtl/pocket_machine_cdc.sdc rtl/pocket_audio_cdc.sdc rtl/pocket_bus_cdc.sdc} {
    set_global_assignment -name SDC_FILE [file join $fpga $f]
}
set_global_assignment -name ALLOW_POWER_UP_DONT_CARE OFF
# initial loops: pocket_memory clears its 32768-byte RAM, pocket_rom8 fills the 65536-byte ROM disk with FF
# (the default limit is 5000 iterations)
set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 70000
project_close
