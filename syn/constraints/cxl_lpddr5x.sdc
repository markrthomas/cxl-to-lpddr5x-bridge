# cxl_lpddr5x.sdc — timing constraints for cxl_lpddr5x_bridge.
# T0/T2 collateral (tapeout-readiness program). Run on OpenSTA (pathfind) or
# PrimeTime (sign-off) against a target liberty — neither exists in this workspace.
#
# TWO asynchronous clock domains: CXL side (clk) and LPDDR5X command channel
# (mem_clk). All crossings go through async_fifo / cdc_sync / reset_sync (asserted
# by `make cdc`), so the two clocks are a false-path (asynchronous) group.

set CXL_PERIOD 1.0 ;# 1 GHz placeholder
set MEM_PERIOD 0.625 ;# 1.6 GHz placeholder (WCK-derived command clock)
create_clock -name clk     -period $CXL_PERIOD [get_ports clk]
create_clock -name mem_clk -period $MEM_PERIOD [get_ports mem_clk]

# Asynchronous domains — cut inter-clock timing (CDC synchronizers handle it;
# `make cdc` proves no crossing bypasses one).
set_clock_groups -asynchronous -group {clk} -group {mem_clk}

# Asynchronous active-low reset: not a setup/hold path.
set_false_path -from [get_ports rst_n]

# I/O budgets (40% in / 40% out).
set_input_delay  -clock clk [expr {0.40*$CXL_PERIOD}] [remove_from_collection [all_inputs] [get_ports {clk mem_clk rst_n}]]
set_output_delay -clock clk [expr {0.40*$CXL_PERIOD}] [all_outputs]
# (Split outputs per true launch domain at integration; single group shown here.)
