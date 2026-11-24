# DFT_PLAN.md — cxl_lpddr5x_bridge DFT (T4)

DFT intent for the tapeout-readiness program (`../../../DESIGN_READINESS.md`). Adopted from
the sign-off kit's DFT template, tuned to this block.

Two layers (program doctrine — *no artifact = not verified*):

1. **Scan-readiness audit — OSS, runs here now** (`make dft` → `scan_readiness.sh`).
   On the synthesized netlist, asserts the structural conditions that must hold *before*
   scan insertion, and inventories the flops for scan planning. Current result: **PASS**
   (1557 flops, latch-free, no combinational loops; 10% reset-controllable, 157 async
   set/reset, 0 inferred RAM at this mapping).
2. **Scan insertion + ATPG (+ MBIST if RAM-mapped) — `needs-license`** (DFT Compiler /
   Tessent scan stitch; TestMAX / Tessent ATPG) on the PDK-mapped netlist. Authored here
   as the recipe.

## Scan-readiness result (this block)

| Metric | Value | Meaning for scan |
|--------|-------|------------------|
| flip-flops | **1557** | scan-chain length budget (balance into N chains) |
| reset-controllable | **10%** | most flops are datapath FIFO storage (no reset) — see note |
| async set/reset | **157** | need async-reset-disable during scan shift (scan-enable gates the reset) |
| D-latches | **0** | HARD PASS — latches are not scannable |
| combinational loops | **0** | HARD PASS — ATPG cannot justify a comb loop |
| memory arrays | **0** | the async FIFOs map to flop registers at this synth config (no RAM macro ⇒ no MBIST here) |

Two async clock domains (`clk` CXL, `mem_clk` LPDDR5X) ⇒ **two scan regimes**: per-domain
scan chains, each holding its async reset inactive during shift. The low reset-controllable
fraction is expected — the bulk of the flops are the `async_fifo` storage arrays (`u_c2m_posted`,
`u_c2m_np`, `u_m2c`), which hold data, not control state; their pointers/control are
reset-controllable. The CDC synchronizers across `clk`↔`mem_clk` must be bypassed or
lock-up-latch protected on the scan path.

## Scan insertion + ATPG recipe (needs-license)

1. **Scan stitch** (DFT Compiler / Tessent) on the Liberty-mapped netlist (T6/`needs-pdk`):
   - `set_scan_configuration -style multiplexed_flip_flop`
   - two clock-grouped chains (one per clock domain); do **not** mix `clk` and `mem_clk`
     flops in one chain (shift-clock skew across the CDC boundary).
   - lock-up latches at any intra-chain clock-domain handoff.
2. **Scan reset gating**: route `scan_enable` to hold the 157 async set/reset flops'
   async control inactive during shift.
3. **ATPG** (TestMAX / Tessent): stuck-at + transition; target ≥99% test coverage.
   CDC synchronizer flops → constrain or exclude from at-speed transition patterns.
4. **MBIST**: not required at this mapping (FIFOs are flop-based, `mem=0`). If the data
   FIFOs are remapped to a compiled dual-port RAM at T6/PPA, add a BIST controller per RAM
   and re-run this audit to confirm the `mem` count and the resulting non-scannable storage.

## Exit criteria (T4)

- Scan-readiness audit PASS (here now).
- Scan chains stitched, DRC-clean (needs-license); ATPG coverage ≥99% stuck-at;
  scan-shift reset gating verified; per-domain chains with lock-up latches confirmed;
  MBIST re-evaluated if FIFOs become RAM macros.
