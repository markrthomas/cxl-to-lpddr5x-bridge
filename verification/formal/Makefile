# SymbiYosys formal targets for cxl_lpddr5x_bridge.
# Run from this directory: make  (or: make -C verification/formal from repo root)
# Requires: sby (SymbiYosys) from OSS CAD Suite or standalone install.
# The .sby files use relative paths (../../../../src/) that resolve correctly
# from the task subdirectories SymbiYosys creates here.

SBY ?= sby

.PHONY: all credit_counter reset_drain cxl_lpddr5x_bridge clean

all: credit_counter reset_drain cxl_lpddr5x_bridge
	@echo "[FORMAL] All SymbiYosys checks passed."

credit_counter:
	$(SBY) -f credit_counter.sby
	@echo "[FORMAL] credit_counter: PASS"

reset_drain:
	$(SBY) -f reset_drain.sby
	@echo "[FORMAL] reset_drain: PASS"

cxl_lpddr5x_bridge:
	$(SBY) -f cxl_lpddr5x_bridge.sby
	@echo "[FORMAL] cxl_lpddr5x_bridge: PASS"

clean:
	rm -rf credit_counter_bmc credit_counter_cover \
	       reset_drain_bmc reset_drain_cover \
	       cxl_lpddr5x_bridge_bmc cxl_lpddr5x_bridge_cover \
	       credit_counter_ci.sby reset_drain_ci.sby cxl_lpddr5x_bridge_ci.sby
