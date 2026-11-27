# T6 — GLS + PPA plan (cxl_lpddr5x_bridge)

T6 is the post-synthesis sign-off: prove the **gate netlist** is functionally correct and
characterise its **PPA**. Adopted from the shared sign-off kit (`dv-swarm-kit/templates/signoff`),
pathfound on `IP-axi-to-2apbs`.

## What runs here (OSS, no PDK) — real artifacts

| Step | Command | Artifact | Status |
|------|---------|----------|--------|
| **PPA proxy** | `make ppa` (`syn/ppa/ppa.sh`) | `syn/ppa/reports/cxl_lpddr5x_bridge.ppa.rpt` | **PASS** — generic cells ≈ 5204, flip-flops ≈ 1558, logic depth (`ltp`) ≈ 137. |
| **Zero-delay GLS** | `make gls` (`syn/gls/gls.sh`) | `syn/gls/reports/cxl_lpddr5x_bridge.gls.rpt` | **PASS** — the directed self-checking TB (+ checker) passes against the generic-gate netlist; in CI. The earlier failure was a TB sampling race (finding below). |

## T6-GLS finding (corrected 2026-11-27) — it was a TB sampling race, not X-pessimism

The earlier version of this section attributed the GLS failure (`FAIL: smoke mem_wr got
X322400004e5a384`) to X-pessimism of the unreset dual-clock FIFO RAM. A VCD trace of the
gate-level run shows a different mechanism:

- `lp_out_data` is X from 167.5 ns: the FIFOs are empty, so the output mux shows an
  unwritten entry. That is legal, because `lp_out_valid` is low.
- At **237.5 ns**, in **one** zero-delay timestep, `lp_out_valid` rises, the arbiter
  select flips (posted vs non-posted FIFO) and `lp_out_data` settles to
  `8322400004e5a384` (the expected value; the netlist's bit 63 is constant 1 and bit
  61 = bit 62).
- The TB did `wait (lp_out_valid);` and compared **immediately**. That resumes inside the
  timestep, after valid changed but before the data mux output had updated, so the
  compare read the pre-update X. RTL sim passed only because of event ordering: the same
  outputs come from the same flops, and nothing guarantees the order.

**Not a design bug.** `lp_out_valid`/`lp_out_data` are combinational outputs of the same
mem_clk flops; a valid/ready consumer samples them at a clock edge.

**Fix (TB only, no RTL change):** `tb_cxl_lpddr5x_bridge.v` samples one precision step
(`SETTLE_NS` = 1 ps) after each `wait (lp_out_valid|cxl_out_valid)` that is followed by an
immediate compare (13 sites). That point is after every delta of the timestep and far
before the next edge (the fastest clock is a 2.5 ns half-period). The compare itself is
unchanged: a full-width `!==`.

**Evidence:**
- RTL directed sim PASS (all smokes + stress, `c2m_beats=2855 m2c_beats=3051`, unchanged).
- Generic GLS PASS (same beat counts), now in CI (`make gls`).
- Mutation check: `LP_CMD_WR ^ 4'h1` in the RTL makes both the RTL sim and the GLS FAIL with
  fully known data (`smoke mem_wr got 8222400004e5a35b`), so the settled TB still catches
  a 1-bit data error at gate level.

Two kit `gls.sh` pass-criterion bugs were found on the way and fixed in the kit:
- the failure scan matched the passing line `PASS smoke error_injection`;
- `$finish called` was required, but vvp does not print it for `$finish(0)`.

## Post-route GLS on sky130 (open PDK)

`make pnr` (LibreLane, CI `silicon.yml`) routes the block on sky130A. `make gls-sky130` then
runs the same TB on the routed netlist with the sky130_fd_sc_hd cell models (functional,
unit delay) → `syn/pnr/reports/cxl_lpddr5x_bridge.gls.rpt`. Results are in `syn/SIGNOFF.md`.

## What is deferred — `needs-pdk`

1. **Commercial-node Liberty synthesis** with a real SRAM/register-file macro for the FIFO,
   vs the register-lowering here and on sky130.
2. **SDF-annotated (timing) GLS** across `clk`/`mem_clk` with `$sdf_annotate`.
3. **STA sign-off** — OpenSTA/PrimeTime + Liberty + `syn/constraints/cxl_lpddr5x.sdc` (T2);
   CDC paths covered by the T1-CDC audit (`make cdc`).
4. **Area + power** — sky130 post-P&R µm²/mW is in the P&R report; a commercial node is `needs-pdk`.
5. **RTL↔netlist LEC** — Conformal/Formality (OSS `yosys equiv` does not close on the
   generic netlist).
