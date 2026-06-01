# Core synthesizable RTL for cxl_lpddr5x_bridge — single source of truth.
#
# Paths are relative to the repo root. Consumers:
#   - root Makefile          : used verbatim (Verilator runs from root)
#   - verification/directed  : prefixed with ../../ (adds the TB + checker)
#   - verification/cocotb    : prefixed with $(PWD)/../../
# The formal .sby scripts read the same modules explicitly (different path base /
# per-task subsets); keep them in sync with this list. Top module last.
src/async_fifo.v
src/cdc_sync.v
src/credit_counter.v
src/credit_pulse_sync.v
src/reset_drain.v
src/reset_sync.v
src/cxl_lpddr5x_bridge.v
