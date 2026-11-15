# Creates the Quartus project ap_core in a build directory outside the source tree (spec 8):
#   quartus_sh -t fpga/quartus/create_project.tcl <build dir>
# Sources are referenced where they are: fpga/ and the machine with its chips from lib/retroMachines,
# through the file list <build dir>/rk86_machine16_files.qsf that scripts/build.ps1 writes first:
#   python -B scripts/simrun.py filelist machines/rk86 --format qsf --relative-to <build dir>
# (simrun's order, dependencies first; paths relative to the build dir; RETRO_MACHINES_DIR moves them).
# The APF pre-flow script writes apf/build_id.mif relative to the project, so into <build dir>.
set fpga [file normalize [file join [file dirname [info script]] ..]]
set build [file normalize [lindex $argv 0]]
set machine_files [file join $build rk86_machine16_files.qsf]
if {![file exists $machine_files]} {
    error "$machine_files missing: run scripts/build.ps1 (it writes the file list with scripts/simrun.py filelist)"
}
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
set list [open $machine_files]
set count 0
while {[gets $list line] >= 0} {
    if {[regexp {^set_global_assignment -name (VERILOG_FILE|SYSTEMVERILOG_FILE|SEARCH_PATH) "?([^"]+)"?$} $line -> kind path]} {
        set_global_assignment -name $kind [file normalize [file join $build $path]]
        incr count
    } elseif {[string trim $line] ne ""} {
        error "$machine_files: unexpected line: $line"
    }
}
close $list
if {$count == 0} { error "$machine_files lists no files" }
# apf_constraints.sdc reads core/core_constraints.sdc relative to the project directory: place a copy in the build
file mkdir [file join $build core]
file copy -force [file join $fpga core core_constraints.sdc] [file join $build core core_constraints.sdc]
foreach f {rtl/pocket_machine_cdc.sdc rtl/pocket_audio_cdc.sdc rtl/pocket_bus_cdc.sdc rtl/pocket_psram.sdc} {
    set_global_assignment -name SDC_FILE [file join $fpga $f]
}
set_global_assignment -name ALLOW_POWER_UP_DONT_CARE OFF
# initial loop: pocket_memory sets its 34816 bytes (the 32768-byte RAM to 00, the monitor's 2048 to FF);
# the default limit is 5000 iterations
set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 70000
project_close
