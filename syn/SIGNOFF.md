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
| **T2** STA | ◐ collateral | `syn/constraints/cxl_lpddr5x.sdc`, `syn/sta/opensta.tcl` | Two async clock groups, async-reset false path, I/O budgets. Run = `needs-pdk`. |
| **T3** low-power | ◐ authored + OSS-lint | `make lp` → `syn/lp/cxl_lpddr5x.upf`, `syn/lp/LP_PLAN.md` | LPDDR5X low-power intent (PD_AON CXL link + switchable PD_MEM via link-drain); UPF consistency lint PASS (2 domains/3 supplies/iso+ret/3 PST). VCS `-upf` + RTL↔UPF LEC = `needs-license`. |
| **T4** DFT | ◐ **PASS** (scan-ready) | `make dft` → `syn/dft/reports/`, `syn/dft/DFT_PLAN.md` | Latch-free + no comb loops; 1557 flops (10% reset-controllable — most are FIFO data, 157 async set/reset, 0 RAM at this mapping). Per-domain scan chains over `clk`/`mem_clk`. Scan stitch + ATPG (+MBIST if FIFOs → RAM) = `needs-license`. |
| **T5** verif sign-off | ◑ strong | 12 cocotb OSS-UVM tests; 100% line cov; **unbounded formal prove** + assume-guarantee; SVA on all 4 ports | Promote to licensed UVM + perf mode; keep the formal as a first-class sign-off artifact. `needs-license` for the run. |
| **T6** GLS + PPA | ☐ open | — | SDF GLS incl. memory-command timing; power; LEC; PPA. `needs-pdk`. |
| **T7** integration/pkg | ☐ open | `pkg/` (to author) | IP-XACT; register/config map; LPDDR5X PHY integration guide; CXL link attach. |

Legend: ✅ passed · ◑ authored-not-run · ◐ partial/pathfind · ☐ not started.

The T1 (`synth`) and T1-CDC (`cdc`) gates here are the **canonical pattern** for the
program; `syn/constraints/*.sdc` + `syn/sta/opensta.tcl` + this checklist complete the
T2 collateral. This repo's gates + collateral are the template promoted to the kit.
