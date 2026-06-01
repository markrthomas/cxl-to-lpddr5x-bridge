SIM          ?= icarus
TOPLEVEL_LANG = verilog

SRC_DIR := $(PWD)/../../src

# Core RTL from the shared root filelist (rtl.f, repo-root-relative → absolute via $(PWD)/../../).
VERILOG_SOURCES = $(addprefix $(PWD)/../../,$(shell grep -vE '^[[:space:]]*(#|$$)' $(PWD)/../../rtl.f))

TOPLEVEL = cxl_lpddr5x_bridge
MODULE   = test_cxl_lpddr5x_bridge

# SystemVerilog (function automatic) + include path for cxl_lpddr5x_bridge_defs.vh
ICARUS_BIN_DIR ?= /usr/bin
COMPILE_ARGS    = -g2005-sv -I$(SRC_DIR)

export PYTHONPATH := $(PWD):$(PYTHONPATH)

# Strip OSS CAD Suite Python environment so cocotb's pip-installed VPI loads cleanly.
SIM_CMD_PREFIX          := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)

include $(shell cocotb-config --makefiles)/Makefile.sim
