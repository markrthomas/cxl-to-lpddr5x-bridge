# UVM on open-source Verilator (`verification/uvm/vlt`)

Runs the CXL<->LPDDR5x bridge UVM environment under open-source **Verilator
5.050** with the bundled Accellera UVM 2020.3.1 library — a license-free path
(the repo's `verification/uvm/Makefile` otherwise needs Xcelium/xrun).

## Prerequisites
- **Verilator >= 5.050, UVM-capable** (OSS CAD Suite's is not). Local ref:
  `~/verilator/bin/verilator`. **`unset VERILATOR_ROOT`** after sourcing the OSS
  CAD Suite env. **`UVM_HOME`** = `~/verilator/test_regress/t/uvm`.
- **In an OSS-off shell** (`OSS_CAD=0` at start, or `oss-cad-off`) `~/.bashrc`
  already puts Verilator 5.050 on `PATH`, unsets `VERILATOR_ROOT`, and exports
  `UVM_HOME` — so the explicit `VERILATOR=`/`UVM_HOME=` and `unset` below are
  optional there.

## Usage
```sh
V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
( unset VERILATOR_ROOT; make -C verification/uvm/vlt lint  VERILATOR=$V UVM_HOME=$U )  # RAM-safe
( unset VERILATOR_ROOT; make -C verification/uvm/vlt smoke VERILATOR=$V UVM_HOME=$U )  # build + run
```
Top `cxl_lpddr5x_tb_top`; test via `+UVM_TESTNAME` (default
`cxl_lpddr5x_smoke_test`, override with `UVM_TEST=<name>`). The `--binary` build
belongs in CI (`.github/workflows/verilator-uvm.yml`), not a RAM-constrained host.

## `uvm_macros.svh`
Required tracked empty include-shim (the monolithic UVM header defines the
macros). Do not delete.
