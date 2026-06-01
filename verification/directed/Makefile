# Run from this directory: make
# Requires: iverilog, vvp (e.g. sudo apt install iverilog)
# Optional: gtkwave (e.g. sudo apt install gtkwave) for make gtkwave

BUILD_DIR := build
SRC_DIR   := ../../src
VCD       := $(BUILD_DIR)/waves.vcd

# Core RTL from the shared root filelist (rtl.f, repo-root-relative → prefix
# ../../); the checker and TB are directed-flow-only.
RTL     := $(addprefix ../../,$(shell grep -vE '^[[:space:]]*(#|$$)' ../../rtl.f))
SOURCES := $(RTL) $(SRC_DIR)/cxl_lpddr5x_bridge_chk.v $(SRC_DIR)/tb_cxl_lpddr5x_bridge.v
OUT     := $(BUILD_DIR)/tb.out

.PHONY: all run sim compile stress vcd gtkwave lint clean

all: run

compile: $(OUT)

run sim: compile
	vvp $(OUT)

# Default smoke + moderate stress; this adds a second phase with harsh sink backpressure.
stress: compile
	vvp $(OUT) +stress

# Regenerate simulation and write $(VCD) (run from this directory so path matches $dumpfile)
vcd: compile
	vvp $(OUT) +vcd

# Generate VCD then open in gtkwave (blocking until gtkwave exits)
gtkwave: vcd
	gtkwave $(VCD) cxl_lpddr5x_bridge.gtkw

$(OUT): $(SOURCES) | $(BUILD_DIR)
	iverilog -g2005-sv -I$(SRC_DIR) -o $@ $(SOURCES)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Verilator second-opinion lint (from repo root paths).
lint:
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module cxl_lpddr5x_bridge -f rtl.f
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module async_fifo src/async_fifo.v
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module cdc_sync src/cdc_sync.v
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module reset_sync src/reset_sync.v
	cd ../.. && verilator -Isrc --lint-only -Wall -top-module credit_pulse_sync src/credit_pulse_sync.v

clean:
	rm -rf $(BUILD_DIR)
