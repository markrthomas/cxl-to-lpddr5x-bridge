# Random-regression sim build (cocotb + Icarus). Used by the root `make rr-build`.
TOPLEVEL_LANG = verilog
SIM          ?= icarus
HERE    := $(CURDIR)
SRC_DIR := $(HERE)/../../src
VERILOG_SOURCES = $(addprefix $(HERE)/../../,$(shell grep -vE '^[[:space:]]*(\#|$$)' $(HERE)/../../rtl.f))
TOPLEVEL = cxl_lpddr5x_bridge
MODULE   = rr_test
SIM_BUILD = $(HERE)/build
COMPILE_ARGS = -g2005-sv -I$(SRC_DIR)
export PYTHONPATH := $(HERE):$(HERE)/../cocotb:$(PYTHONPATH)
SIM_CMD_PREFIX := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
include $(shell cocotb-config --makefiles)/Makefile.sim
