# Verilator UVM flow for the CXL<->LPDDR5x bridge UVM environment
# (../ = verification/uvm; RTL in <repo>/src).
#
# Runs the *same* SystemVerilog UVM env as Xcelium (xrun) would, but under
# open-source Verilator (>= 5.050) with the Accellera UVM 2020.3.1 library
# bundled in the Verilator source tree (test_regress/t/uvm).
#
# Quick start (local lint is RAM-safe; the full --binary build belongs in CI):
#   V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
#   ( unset VERILATOR_ROOT; make -C verification/uvm/vlt lint  VERILATOR=$V UVM_HOME=$U )
#   ( unset VERILATOR_ROOT; make -C verification/uvm/vlt smoke VERILATOR=$V UVM_HOME=$U )

VERILATOR ?= verilator

UVM_HOME ?= $(error Set UVM_HOME to the bundled Verilator UVM dir, e.g. \
  ~/verilator/test_regress/t/uvm)
UVM_HDR := $(UVM_HOME)/uvm_pkg_all_v2020_3_1_dpi.svh
UVM_DPI := $(UVM_HOME)/v2020_3_1/dpi/uvm_dpi.cc

BUILD_JOBS ?= 1
UVM_TEST   ?= cxl_lpddr5x_smoke_test

VFLAGS ?= --binary --timing --vpi -j $(BUILD_JOBS) --build-jobs $(BUILD_JOBS) \
          -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD --CFLAGS -O0
UVM_PLUSARGS ?= +UVM_NO_RELNOTES

VLT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UVMROOT := $(abspath $(VLT_DIR)/..)
TB      := $(UVMROOT)/tb
SRC     := $(abspath $(VLT_DIR)/../../../src)
OBJ     := $(VLT_DIR)/obj

INCS := +incdir+$(UVMROOT) +incdir+$(TB) +incdir+$(SRC) +incdir+$(VLT_DIR) \
        +incdir+$(UVM_HOME)

RTL := $(SRC)/async_fifo.v $(SRC)/cdc_sync.v $(SRC)/credit_counter.v \
       $(SRC)/credit_pulse_sync.v $(SRC)/reset_drain.v $(SRC)/reset_sync.v \
       $(SRC)/cxl_lpddr5x_bridge.v
# Order: RTL, interfaces, UVM package (pulls in the env via `include), TB top.
SRCS := $(RTL) $(UVMROOT)/cxl_lpddr5x_if.sv $(UVMROOT)/cxl_lpddr5x_uvm_pkg.sv \
        $(TB)/cxl_lpddr5x_tb_top.sv

define build
	rm -rf $(OBJ)/cxl_lpddr5x_tb_top
	mkdir -p $(OBJ)/cxl_lpddr5x_tb_top
	$(VERILATOR) $(VFLAGS) --top-module cxl_lpddr5x_tb_top \
	  --Mdir $(OBJ)/cxl_lpddr5x_tb_top $(INCS) $(UVM_HDR) $(UVM_DPI) $(SRCS)
endef
define run
	$(OBJ)/cxl_lpddr5x_tb_top/Vcxl_lpddr5x_tb_top $(UVM_PLUSARGS) +UVM_TESTNAME=$(1)
endef

.PHONY: all build smoke lint clean

all: smoke

build:
	$(build)

# The TB top calls run_test() with no default, so the test is chosen here.
smoke: build
	$(call run,$(UVM_TEST))

LINTFLAGS ?= --lint-only --timing -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD
lint:
	$(VERILATOR) $(LINTFLAGS) --top-module cxl_lpddr5x_tb_top $(INCS) \
	  $(UVM_HDR) $(SRCS)

clean:
	rm -rf $(OBJ)
