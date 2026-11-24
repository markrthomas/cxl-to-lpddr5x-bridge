# LP_PLAN.md — cxl_lpddr5x_bridge low-power (T3)

Low-power intent for the tapeout-readiness program (`../../../DESIGN_READINESS.md`). Adopted
from the sign-off kit's low-power template, tuned to this block's LPDDR5X low-power story.

Two layers (program doctrine — *no artifact = not verified*):

1. **UPF consistency lint — OSS, runs here now** (`make lp` → `upf_lint.tcl cxl_lpddr5x.upf`).
   No OSS tool models UPF power *semantics*; this catches a malformed/inconsistent UPF
   (dangling domains, supplies, iso/retention strategies, power-state tables) before the
   licensed flow. Current result: **PASS** (2 domains, 3 supplies, iso + retention, 3 PST
   states).
2. **Power-aware simulation + LEC — `needs-license`** (VCS `-upf`; Conformal/Formality
   RTL↔UPF LEC). Authored here as the recipe.

## Power architecture

| Domain | Rail | Contents | Rationale |
|--------|------|----------|-----------|
| **PD_AON** | `VDD` (always-on) | CXL link side (`clk`): link-up, credit counters, command issue | must stay up to maintain CXL link credits / flow control while the memory side sleeps |
| **PD_MEM** | `VDD_SW` (switched) | LPDDR5X mem side (`mem_clk`): reset-drain + mem-facing logic | power-gated in the LPDDR5X low-power state; woken for the next memory access |

- **Header switch** `mem_hdr_sw`: `VDD → VDD_SW`, gated by `pmu_mem_pwr_en`.
- **Isolation** `mem_iso`: clamp PD_MEM outputs crossing into PD_AON to 0 when off
  (`pmu_mem_iso_en`, active-high, parent location) — the CXL link side never samples a
  floating memory-side value. The dual-clock async FIFOs straddle the boundary; the
  mem-side read ports take the clamp.
- **Retention** `mem_ret`: save/restore the mem-side credit / drain / config state
  (`pmu_mem_save`/`pmu_mem_restore`) so the memory path resumes without a full re-handshake.

## Power states

| Mode | VDD | VDD_SW | Meaning |
|------|-----|--------|---------|
| **P0 active**   | ON | ON  | normal CXL↔LPDDR5X traffic |
| **P1 drain**    | ON | ON  | PD_MEM isolated, still powered — `u_reset_drain` quiesces the link and in-flight memory commands complete before shutoff |
| **P2 lpddr_lp** | ON | OFF | PD_MEM rail off, mem-side state retained; LPDDR5X low-power |

Sign-off sequence to run: **P0 → P1 → P2 → P1 → P0**, asserting (a) the reset-drain reaches
a quiesced state and credits are reconciled before `pmu_mem_pwr_en` deasserts, (b) retention
save before off / restore after on, (c) no AON (link) corruption while PD_MEM is down,
(d) correct LPDDR5X low-power *exit* and functional resume on the next memory access.

## Control (PMU) contract

The power controller (PMU — in PD_AON) drives, in order, for power-down:
`pmu_mem_save` ↑ → `pmu_mem_iso_en` ↑ → `pmu_mem_pwr_en` ↓; and reverse for power-up:
`pmu_mem_pwr_en` ↑ → (settle + LPDDR5X LP exit) → `pmu_mem_restore` ↑ → `pmu_mem_iso_en` ↓.
These are the UPF control ports above. A gate-level PMU + the P0→P2→P0 testbench are the next
authored artifact; the `ucie_rdi_to_pcie6_pipe7` repo has a runnable Verilator `-upf`
skeleton (`make verilator_upf`) this block can adopt.

## Exit criteria (T3)

- UPF consistency lint PASS (here now).
- VCS `-upf` power-aware sim of the P0→P2→P0 LPDDR5X low-power sequence clean; RTL↔UPF LEC
  clean; isolation/retention timing vs. the PMU sequence verified (needs-license).
- `-elements` instance paths in `cxl_lpddr5x.upf` confirmed against the synthesized
  hierarchy (in particular the dual-clock FIFO straddle at the PD_AON/PD_MEM boundary).
