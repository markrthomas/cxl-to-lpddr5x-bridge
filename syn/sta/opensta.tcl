# opensta.tcl — STA driver for cxl_lpddr5x_bridge (T2 collateral; not run here:
# no OpenSTA/liberty in this workspace). Set LIB + NETLIST (use the existing
# `make synth` output sim/synth_netlist.v once liberty-mapped). TOP=cxl_lpddr5x_bridge.
if {![info exists ::env(LIB)] || ![info exists ::env(NETLIST)]} {
  puts "SKIP: set LIB + NETLIST (liberty-mapped). No liberty/OpenSTA in this workspace."; exit 0 }
read_liberty $::env(LIB)
read_verilog  $::env(NETLIST)
link_design   cxl_lpddr5x_bridge
read_sdc      [file join [file dirname [info script]] .. constraints cxl_lpddr5x.sdc]
report_checks -path_delay max -digits 4
report_checks -path_delay min -digits 4
report_worst_slack -max ; report_worst_slack -min
report_tns ; report_wns
