# UVM testbench runner for cxl_lpddr5x_bridge — Cadence Xcelium (xrun).
#
# This bench targets a commercial UVM simulator and is NOT part of the OSS CI
# gate (the repo's regress/coverage/sva/formal/cocotb flows use Icarus +
# Verilator + SymbiYosys). If xrun is not on PATH, every target degrades to a
# graceful no-op so `make -C verification/uvm` never breaks an OSS-only checkout.
#
# Usage:
#   make                       # smoke test
#   make random                # randomized soak
#   make err_inj               # error-injection
#   make run UVM_TEST=<name> SEED=<n> UVM_VERBOSITY=UVM_HIGH
#   make waves UVM_TEST=<name> # same, with an SHM waveform (SimVision)

XRUN          ?= xrun
UVM_TEST      ?= cxl_lpddr5x_smoke_test
UVM_VERBOSITY ?= UVM_MEDIUM
SEED          ?= 1
XRUN_EXTRA    ?=

SRC := ../../src
RTL := \
    $(SRC)/async_fifo.v \
    $(SRC)/cdc_sync.v \
    $(SRC)/credit_counter.v \
    $(SRC)/credit_pulse_sync.v \
    $(SRC)/reset_drain.v \
    $(SRC)/reset_sync.v \
    $(SRC)/cxl_lpddr5x_bridge.v

# Order: interfaces, then the UVM package, then the TB top (instantiates DUT).
UVM_SRC := \
    cxl_lpddr5x_if.sv \
    cxl_lpddr5x_uvm_pkg.sv \
    tb/cxl_lpddr5x_tb_top.sv

XRUN_ARGS := -uvm -sv -timescale 1ns/1ps -incdir $(SRC) -incdir . \
             -top cxl_lpddr5x_tb_top \
             $(RTL) $(UVM_SRC) \
             +UVM_TESTNAME=$(UVM_TEST) +UVM_VERBOSITY=$(UVM_VERBOSITY) -svseed $(SEED)

.PHONY: all run smoke random err_inj waves clean help

all: smoke

help:
	@echo "cxl_lpddr5x_bridge UVM bench (Xcelium):"
	@echo "  make smoke    — cxl_lpddr5x_smoke_test (every opcode + response burst)"
	@echo "  make random   — cxl_lpddr5x_random_test (randomized soak, backpressure)"
	@echo "  make err_inj  — cxl_lpddr5x_err_inj_test (err_inj windows; LSB-masked c2m)"
	@echo "  make run UVM_TEST=<t> SEED=<n> UVM_VERBOSITY=<v>"
	@echo "  make waves UVM_TEST=<t>   — run with SHM waveform (SimVision)"

run:
	@if command -v $(XRUN) >/dev/null 2>&1; then \
	  set -x; $(XRUN) $(XRUN_ARGS) $(XRUN_EXTRA); \
	else \
	  echo "[UVM] xrun (Xcelium) not on PATH — this bench needs a commercial UVM simulator; skipping."; \
	  echo "[UVM] OSS verification lives in verification/{directed,cocotb,formal} + sim/ (make ci)."; \
	fi

smoke:
	@$(MAKE) run UVM_TEST=cxl_lpddr5x_smoke_test

random:
	@$(MAKE) run UVM_TEST=cxl_lpddr5x_random_test

err_inj:
	@$(MAKE) run UVM_TEST=cxl_lpddr5x_err_inj_test

waves:
	@$(MAKE) run XRUN_EXTRA="+define+DUMP -access +rwc $(XRUN_EXTRA)"

clean:
	rm -rf xcelium.d xrun.log xrun.history .simvision simvision*.diag \
	       waves.shm *.shm INCA_libs cov_work *.vcd
