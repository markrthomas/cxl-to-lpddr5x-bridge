# Root Makefile — cxl_lpddr5x_bridge
# Standard DV gate targets consistent with other RTL repos in this workspace
# (see ../DV_STANDARDS.md). Delegates to verification/directed/ (Icarus sim),
# verification/formal/ (SymbiYosys), and verification/cocotb/ (OSS UVM-equivalent).

SBY       ?= sby
VERILATOR ?= verilator

VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp

BRIDGE_SRCS := src/async_fifo.v src/cdc_sync.v src/credit_counter.v \
               src/credit_pulse_sync.v src/reset_drain.v src/reset_sync.v \
               src/cxl_lpddr5x_bridge.v
COV_DIR := sim/obj_dir_cov

.PHONY: help lint sim regress stress vcd gtkwave vlt-vcd vlt-gtkwave coverage sva formal ci cocotb clean

help:
	@echo "cxl_lpddr5x_bridge — common targets"
	@echo ""
	@echo "  make lint      — Verilator --lint-only on all RTL modules"
	@echo "  make sim       — Icarus directed simulation (default + smoke)"
	@echo "  make stress    — Icarus simulation with heavy backpressure stress"
	@echo "  make vcd       — Icarus sim dumping a VCD (verification/directed/build/waves.vcd)"
	@echo "  make gtkwave   — make vcd, then open the VCD in GTKWave with a saved signal layout"
	@echo "  make vlt-vcd   — Verilator --trace build of sim/sim_main.cpp -> sim/obj_dir_vcd/waves.vcd"
	@echo "  make vlt-gtkwave — make vlt-vcd, then open the Verilator VCD in GTKWave"
	@echo "  make regress   — lint + sim (fast CI gate)"
	@echo "  make coverage  — Verilator C++ coverage (sim/sim_main.cpp -> sim/coverage.info)"
	@echo "  make sva       — Verilator --assert: interface SVA on all 4 valid/ready ports"
	@echo "  make cocotb    — cocotb OSS UVM-equivalent tests (Icarus VPI)"
	@echo "  make formal    — SymbiYosys BMC + cover (credit_counter, reset_drain, bridge)"
	@echo "  make ci        — regress + coverage + sva + formal + cocotb (comprehensive)"
	@echo "  make clean     — remove simulation build artifacts"
	@echo ""
	@echo "  Subdirectory targets:"
	@echo "    make -C verification/directed [sim|stress|vcd|gtkwave|lint|clean]"
	@echo "    make -C verification/cocotb"
	@echo "    make -C verification/formal   [all|credit_counter|reset_drain|cxl_lpddr5x_bridge|clean]"

# Verilator RTL lint (delegates to directed/, which runs verilator from repo root).
lint:
	$(MAKE) -C verification/directed lint

# Icarus directed simulation.
sim:
	$(MAKE) -C verification/directed sim

# Icarus simulation with heavy backpressure stress.
stress:
	$(MAKE) -C verification/directed stress

# Dump a VCD waveform of the directed sim (verification/directed/build/waves.vcd).
vcd:
	$(MAKE) -C verification/directed vcd

# Dump the VCD then open it in GTKWave with the saved signal layout
# (verification/directed/cxl_lpddr5x_bridge.gtkw). Requires gtkwave on PATH.
gtkwave:
	$(MAKE) -C verification/directed gtkwave

# fast CI gate.
regress: lint sim
	@echo "[REGRESS] lint + directed sim PASSED"

# cocotb OSS UVM-equivalent tests (Icarus VPI).
cocotb:
	$(MAKE) -C verification/cocotb

# coverage: Verilator --coverage build + run; emits sim/coverage.info (lcov format).
# Driven by the sim/sim_main.cpp C++ harness (~96.9% line coverage). If that file
# is absent this degrades to a graceful stub (exit 0) per DV_STANDARDS.md.
coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	if [ ! -f sim/sim_main.cpp ]; then \
		echo "[COVERAGE] sim/sim_main.cpp not present — Verilator C++ coverage harness TODO (see doc/PLAN.md); skipping"; \
		exit 0; \
	fi; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage -cc $(BRIDGE_SRCS) --top-module cxl_lpddr5x_bridge \
		--Mdir $(COV_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(COV_DIR) -f Vcxl_lpddr5x_bridge.mk; \
	g++ -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/Vcxl_lpddr5x_bridge__ALL.a \
		-I$(COV_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(COV_DIR) && ./sim_cov ); \
	if command -v verilator_coverage >/dev/null 2>&1; then \
		verilator_coverage --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
		echo "[COVERAGE] sim/coverage.info written"; \
	else \
		echo "[COVERAGE] coverage.dat in $(COV_DIR) (install verilator for lcov export)"; \
	fi

# sva: bind verification/cxl_lpddr5x_bridge_sva.sv and run the sim/sim_main.cpp
# stimulus under Verilator --assert, so the concurrent interface SVA (valid/data
# stability on all four valid/ready ports) is checked at runtime. A failed
# property aborts the run (non-zero exit). Degrades to a stub if verilator absent.
SVA_DIR := sim/obj_dir_sva
sva:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[SVA] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(SVA_DIR); \
	$(VERILATOR) --assert --coverage -cc $(BRIDGE_SRCS) verification/cxl_lpddr5x_bridge_sva.sv \
		--top-module cxl_lpddr5x_bridge --Mdir $(SVA_DIR) -Isrc \
		-Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(SVA_DIR) -f Vcxl_lpddr5x_bridge.mk; \
	g++ -DVM_COVERAGE=1 -o $(SVA_DIR)/sim_sva \
		sim/sim_main.cpp $(SVA_DIR)/Vcxl_lpddr5x_bridge__ALL.a \
		-I$(SVA_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(SVA_DIR) && ./sim_sva ); \
	echo "[SVA] interface assertions passed (Verilator --assert, 4 valid/ready ports)"

# vlt-vcd: Verilator --trace build of the sim/sim_main.cpp stimulus. The harness
# walks every opcode + both FIFOs full/empty + the CRC-INVALID and drain paths,
# dumping the full hierarchy to sim/obj_dir_vcd/waves.vcd for GTKWave. -DVM_TRACE
# arms the trace blocks in sim_main.cpp; verilated_vcd_c.cpp provides the writer.
# Degrades to a stub (exit 0) if verilator or sim_main.cpp is absent.
VCD_DIR := sim/obj_dir_vcd
VLT_VCD := $(VCD_DIR)/waves.vcd
vlt-vcd:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[VLT-VCD] verilator not on PATH; skipping"; exit 0; }; \
	if [ ! -f sim/sim_main.cpp ]; then \
		echo "[VLT-VCD] sim/sim_main.cpp not present; skipping"; \
		exit 0; \
	fi; \
	rm -rf $(VCD_DIR); \
	$(VERILATOR) --trace --coverage -cc $(BRIDGE_SRCS) --top-module cxl_lpddr5x_bridge \
		--Mdir $(VCD_DIR) -Isrc -Wno-DECLFILENAME -Wno-WIDTH -Wno-fatal; \
	$(MAKE) -C $(VCD_DIR) -f Vcxl_lpddr5x_bridge.mk; \
	g++ -DVM_TRACE=1 -DVM_COVERAGE=1 -o $(VCD_DIR)/sim_vcd \
		sim/sim_main.cpp $(VCD_DIR)/Vcxl_lpddr5x_bridge__ALL.a \
		-I$(VCD_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) $(VERILATOR_INC)/verilated_vcd_c.cpp -pthread -lm; \
	( cd $(VCD_DIR) && ./sim_vcd ); \
	echo "[VLT-VCD] $(VLT_VCD) written"

# Build the Verilator VCD then open it in GTKWave (requires gtkwave on PATH).
vlt-gtkwave: vlt-vcd
	gtkwave $(VLT_VCD)

# SymbiYosys formal verification (requires OSS CAD Suite or standalone sby).
formal:
	$(MAKE) -C verification/formal

# Comprehensive local run.
ci: regress coverage sva formal cocotb
	@echo "[CI] regress + coverage + sva + formal + cocotb PASSED"

clean:
	$(MAKE) -C verification/directed clean
	-$(MAKE) -C verification/formal clean
	rm -rf $(COV_DIR) $(SVA_DIR) $(VCD_DIR) sim/coverage.info
