# SIGNOFF.md — cxl_lpddr5x_bridge tapeout sign-off checklist

Tracks the eight T-gates from the workspace program (`../DESIGN_READINESS.md`). A gate
passes only with a cited **artifact** (*no artifact = not verified*); `needs-license` /
`needs-pdk` items are authored here and run where the tools/PDK exist.

**Design facts:** two asynchronous clock domains — CXL (`clk`) and LPDDR5X command
channel (`mem_clk`); async-FIFO + 2-flop synchronizers, asserted by `make cdc`. Top:
`cxl_lpddr5x_bridge`. This block already had the richest T1 gate of the five (it is the
source of the canonical `synth`/`cdc` pattern now rolled to the others).

| Gate | Status | Artifact / where | Notes |
|------|--------|------------------|-------|
| **T0** spec freeze | ◐ open | `doc/PLAN.md` tapeout section | **Interface realism** is the gap: make the "LPDDR5X-style" side a real LPDDR5X DFI/PHY contract + bank/timing scheduler; freeze the CXL.mem wire-encoding decision. Cite CXL rev + JESD209-5. |
| **T1** synthesizable | ◐ **PASS** | `make synth` → `sim/synth_netlist.v`, `sim/synth.log` | Latch-free + cell/depth ceilings. Liberty-mapped synth = `needs-pdk`. |
| **T1-CDC** | ✅ **PASS** | `make cdc` → `sim/cdc.log` | No unsynchronized `clk`↔`mem_clk` crossing (structural Yosys audit). |
| **T2** STA | ◐ collateral | `syn/constraints/cxl_lpddr5x.sdc`, `syn/sta/opensta.tcl` | Two async clock groups, async-reset false path, I/O budgets. **sky130 open-PDK run:** `make pnr` (LibreLane, CI `silicon.yml`) → `syn/pnr/reports/cxl_lpddr5x_bridge.pnr.rpt` — 9-corner STA against this SDC, DRC/LVS/antenna, area/power; FAIL on flow/DRC/LVS/hold, setup reported (multi-clock: worst WNS over both groups, no single Fmax). **First CI result pending.** Clock targets (1 GHz / 1.6 GHz) are placeholders — owner's call. Commercial-node STA = `needs-pdk`. |
| **T3** low-power | ◐ authored + OSS-lint | `make lp` → `syn/lp/cxl_lpddr5x.upf`, `syn/lp/LP_PLAN.md` | LPDDR5X low-power intent (PD_AON CXL link + switchable PD_MEM via link-drain); UPF consistency lint PASS (2 domains/3 supplies/iso+ret/3 PST). VCS `-upf` + RTL↔UPF LEC = `needs-license`. |
| **T4** DFT | ◐ **PASS** (scan-ready) | `make dft` → `syn/dft/reports/`, `syn/dft/DFT_PLAN.md` | Latch-free + no comb loops; 1557 flops (10% reset-controllable — most are FIFO data, 157 async set/reset, 0 RAM at this mapping). Per-domain scan chains over `clk`/`mem_clk`. Scan stitch + ATPG (+MBIST if FIFOs → RAM) = `needs-license`. |
| **T5** verif sign-off | ◑ strong | 12 cocotb OSS-UVM tests; 100% line cov; **unbounded formal prove** + assume-guarantee; SVA on all 4 ports | Promote to licensed UVM + perf mode; keep the formal as a first-class sign-off artifact. `needs-license` for the run. |
| **T6** PPA + GLS | ◐ **PASS** (zero-delay GLS + PPA proxy) | `make gls` → `syn/gls/reports/cxl_lpddr5x_bridge.gls.rpt`; `make ppa` → `syn/ppa/reports/cxl_lpddr5x_bridge.ppa.rpt`; `syn/gls/T6_PLAN.md` | **GLS PASS:** the directed self-checking TB (+ checker) passes against the generic-gate netlist; in CI. The earlier "X-pessimism" failure was a **TB sampling race** (compare straight after `wait (valid)`, before the zero-delay data mux settled), fixed TB-side with a 1 ps settle; mutation-checked (T6_PLAN.md). **PPA proxy PASS:** cells≈5204, flops≈1558, logic-depth≈137. **Post-route GLS (sky130):** `make gls-sky130` → `syn/pnr/reports/cxl_lpddr5x_bridge.gls.rpt` — **first CI result pending.** SDF-timing GLS, commercial Liberty map + RAM macro, RTL↔netlist LEC = open (`needs-pdk`). |
| **T7** integration/pkg | ◐ **PASS** (IP-XACT + guide, gated) | `make pkg` → `pkg/check_ipxact.sh`; `pkg/ip-xact/cxl_lpddr5x_bridge.xml`, `pkg/INTEGRATION.md` | IP-XACT (IEEE 1685-2014): 4 `DataStream` valid/ready/data bus interfaces (CXL_RX, LP_TX, LP_RX, CXL_TX) + 2 clocks + 1 reset, full 22-port model, parameter set. `make pkg` gates well-formed + structural + **IP-XACT↔RTL port-sync** (22/22; fails on drift). Integration guide + CDC/clock/reset + sideband + config matrix in `pkg/INTEGRATION.md`. No CSR RAL: streaming datapath, control/status is the sideband. **Full XSD:** `make pkg-xsd` (IEEE 1685-2014 from Accellera → eda.org → pinned GitHub copy, SHA-256 pinned) → XSD valid. **Release flow:** `make release-check` (reproducible bundle + `MANIFEST.json`, CI dry run) and `.github/workflows/release.yml`; publishing is **blocked until T0** (pre-flight requires `contract-v1.0` + `doc/design_contract.md`). |

Legend: ✅ passed · ◑ authored-not-run · ◐ partial/pathfind · ☐ not started.

The T1 (`synth`) and T1-CDC (`cdc`) gates here are the **canonical pattern** for the
program; `syn/constraints/*.sdc` + `syn/sta/opensta.tcl` + this checklist complete the
T2 collateral. This repo's gates + collateral are the template promoted to the kit.
