# cxl_lpddr5x_bridge — Plan

Bridge RTL translating CXL.mem (M2S/S2M) traffic to an LPDDR5X-style memory
interface, with credit-based flow control, async-FIFO clock-domain crossing, and
per-message CRC validation. Verified with an OSS-only toolchain (Icarus +
Verilator + SymbiYosys + cocotb) consistent with `../DV_STANDARDS.md`.

## Current state (2026-07-20)

- **RTL** (`src/`): `cxl_lpddr5x_bridge` top + `async_fifo`, `cdc_sync`,
  `reset_sync`, `reset_drain`, `credit_counter`, `credit_pulse_sync`, and a
  bound checker `cxl_lpddr5x_bridge_chk`. Per-class flow control is **occupancy
  based** — credit availability is `FIFO occupancy < credit limit`, read straight
  off the async FIFO's Gray-coded pointer sync (CDC-lossless, no return-pulse
  path). `credit_pulse_sync` now carries only the sparse CRC-error event;
  `credit_counter` is retained as a standalone formally-verified module.
- **Directed** (`verification/directed/`): Icarus self-checking TB — link-up
  gating, granular opcodes, error injection, clock ratios (1:1, 2:1, 1:3), and a
  backpressure stress phase. `make sim` / `make stress`.
- **cocotb** (`verification/cocotb/`): 12 OSS UVM-equivalent tests (c2m mem
  rd/wr/masked/autopre, MRR/MRW, m2c rsp paths, bad-CRC reject). All PASS.
- **Formal** (`verification/formal/`): SymbiYosys, 12/12 tasks PASS. All four
  modules — `credit_counter`, `reset_drain`, `async_fifo`, and the
  `cxl_lpddr5x_bridge` top itself — close **unbounded `prove`** (basecase +
  k-induction), not just BMC + cover. `async_fifo` carries the CDC sync-chain
  proof: free-running ghost counters (one bit wider than the real pointers, so
  live pointer gaps stay below the wrap-ambiguous half-modulus) make the
  Gray-pointer ordering and the occupancy bound (`occupancy <= DEPTH`)
  k-inductive across the two-flop synchronizers. The bridge proof includes
  valid/ready protocol on all four interfaces (egress asserted, ingress
  assumed), credit-conservation invariants (occupancy never exceeds the credit
  pool) and credit-availability cover goals. The bridge top is k-inductive
  given two ingredients: egress data-stability is stated with self-clocked
  shadow registers (not `multiclock`-fragile `$past`), pinned by an arbiter-lock
  invariant; and the FIFO occupancy/ordering invariants are composed under
  **assume-guarantee** (asserted+proven in the standalone `async_fifo` run under
  its common-reset contract, assumed in the bridge, where the asymmetric
  reset-deassert skew makes them true-but-not-re-derivable).
- **Interface SVA** (`verification/cxl_lpddr5x_bridge_sva.sv`): concurrent SVA on
  all four valid/ready ports (valid-stable, data-stable, handshake/stall cover),
  bound to the DUT and run under Verilator `--assert` via `make sva`.
- **Coverage** (`sim/sim_main.cpp`): Verilator `--coverage` C++ driver walks every
  opcode, both flow-control FIFOs to full/empty, the CRC-mismatch INVALID path,
  the error-injection window, and a link-down drain. `make coverage` emits
  `sim/coverage.info` at **100% line coverage** (enforced against the 80% floor).
- **Waveform / debug**: `make vcd` / `make gtkwave` (Icarus directed TB + a saved
  GTKWave layout) and `make vlt-vcd` (Verilator `--trace` of the coverage walk).
  `make vlt-rand` (`sim/sim_rand.cpp`) drives randomized, protocol-legal traffic
  under `--trace --assert` and dumps a navigable VCD with cycle-stamped event
  markers; reproducible via `RAND_SEED` / `RAND_CYCLES`.
- **UVM bench** (`verification/uvm/`): full UVM 1.2 env — CXL/LP agents, a
  scoreboard with a reference-model translation check and per-class c2m ordering,
  functional coverage, and smoke / random / err_inj tests. Targets Cadence
  Xcelium (`make uvm`); degrades to a no-op without `xrun` and is deliberately
  outside the OSS CI gate (commercial license).
- **Performance model** (`sim/lpddr5x_timing_model.h`, `sim/sim_perf.cpp`): an
  LPDDR5X bank/timing scheduler model (16 banks / 4 bank groups; tRCD/tRP/tRAS/tRC,
  tCCD_L/S, tRRD_L/S, tFAW, tRL/tWL, tWR/tRTP; a finite controller command queue
  for backpressure) serves the `lp_out` command stream and returns `lp_in`
  responses after a bank-state-derived latency, closing a realistic end-to-end
  loop. `make perf` reports end-to-end latency (min/mean/p50/p95/p99/max), the row
  hit/miss mix, and command/completion throughput for a chosen offered load and
  address-locality pattern (`rand`/`stream`/`hotbank`); `make perf-sweep` tabulates
  the latency/throughput knee across credit + FIFO-depth settings; `make
  perf-selftest` unit-checks the model's timing arithmetic (plain g++). It is a
  characterization tool, **not** a correctness gate (directed / cocotb / formal own
  correctness).
- **Gates**: root `Makefile` exposes `lint/sim/regress/stress/coverage/sva/
  vlt-rand/synth/perf/formal/cocotb/ci/clean`; `.github/workflows/ci.yml` runs
  regress → coverage / sva / random / cocotb / formal / synth / docs (the `random`
  job uploads its VCD, `synth` its gate-level netlist, and `docs` the design-spec
  PDF, as artifacts).

## Completed

- **[done 2026-06-01] RTL filelist (DRY)**: `rtl.f` at the repo root is now the
  single source of truth for the core module list, consumed by the root `Makefile`
  (Verilator, verbatim), `verification/directed` and `verification/cocotb` (with a
  path prefix), and the directed Verilator lint (`-f rtl.f`). The formal
  `cxl_lpddr5x_bridge.sby` keeps explicit reads (task-subdir path base) but its
  bmc/cover duplication was collapsed and it points at `rtl.f` as canonical. All
  OSS flows (regress / coverage / sva / vlt-rand / cocotb / formal) re-verified.
- **[done 2026-06-01] Coverage gate**: `make coverage` now parses the `DA:`
  records in `sim/coverage.info` and fails if line coverage is below the
  `COV_MIN` floor (default 80%); it prints the measured % and PASS/FAIL. Enforced
  in CI automatically (the `coverage` job runs `make coverage`). (No `lcov`
  dependency — parsed directly.)
- **[done 2026-06-01] Coverage closure**: added the bad-CRC → INVALID stimulus
  for WR_RSP and MRR_RSP (the RD_RSP path was already covered), taking line
  coverage 96.9% → 100%. The remaining non-executable lines — a defensive FSM
  `default` in `reset_drain` and two FIFO status-net declarations — carry
  documented `// verilator coverage_off` waivers.
- **[done 2026-06-01] Random seed breadth**: the CI `random` job is now a seed
  matrix (`seed: [1,2,3,4]`, `fail-fast: false`), each running
  `make vlt-rand RAND_SEED=<n>` and uploading a per-seed VCD artifact. Verified
  all four seeds pass (SVA clean) with distinct traffic.
- **[done 2026-06-01] Randomized soak + scoreboard**: Extended the cocotb env
  with a robust randomized soak and reference-model scoreboard. Added negative
  tests for mid-burst CRC corruption and credit-underflow attempts.
- **[done 2026-06-01] Parameter sweep**: Created `verification/cocotb/sweep.sh`
  to systematically test FIFO_DEPTH and credit settings.
- **[done 2026-06-01] Synthesis smoke (Yosys)**: Added `make synth` to the root
  Makefile; verified no inferred latches and captured area stats.
- **[done 2026-07-20] PDF design-spec build**: made the pandoc PDF build robust
  and first-class. `doc/Makefile` now auto-detects the LaTeX engine (pdflatex
  preferred — proven clean on the spec's only non-ASCII glyphs `—`/`§` — then
  xelatex), stamps a build date, adds a depth-2 TOC and `tango` code highlighting,
  and **degrades to a clean skip** (exit 0) if pandoc or a LaTeX engine is absent,
  so it never breaks a tree-wide build. Wired into the root Makefile as `make doc`
  (help + `.PHONY`). Added a `docs` CI job (pandoc + texlive) that builds the PDF
  and uploads `design-spec.pdf` as an artifact. The spec has no mermaid diagrams
  (those live only in the README), so no diagram-rendering filter is needed.
  Verified: 270 KB PDF builds with pdflatex, no missing-glyph warnings; the
  no-engine skip path works.
- **[done 2026-07-20] Synthesis area/timing gate**: promoted `make synth` from a
  smoke into a regression gate — Yosys generic synth (flattened) now gates on (1)
  no inferred latches (`$_DLATCH_` cells), (2) a cell-count ceiling `SYNTH_MAX_CELLS`
  (area proxy; design ~5223, ceiling 7000), and (3) an `ltp` longest-topological-
  path ceiling `SYNTH_MAX_DEPTH` (logic depth = liberty-free timing proxy; design
  25, ceiling 40), so a change that balloons area or lengthens the critical path
  fails without needing a standard-cell `.lib` / STA tool (none is bundled). Writes
  a flat gate-level netlist (`sim/synth_netlist.v`). Added a `synth` CI job (reuses
  the pinned OSS CAD Suite from the formal job) that runs the gate and uploads the
  netlist artifact. Ceilings are generous (version-drift tolerant) and bumped
  deliberately, like the coverage floor. Verified: PASS at 5223 cells / depth 25;
  both ceilings demonstrably fail the build when breached.
- **[done 2026-06-01] Invariant assertions**: Added top-level and FIFO-level
  assertions for overflow/underflow and credit pool conservation.
- **[done 2026-06-01] Error/event counters**: Implemented `crc_err_cnt`,
  `drain_cnt`, and FIFO `max_occ` status ports for improved observability.
- **[done 2026-06-01] Credit-return CDC deadlock fix**: the randomized soak
  surfaced an m2c liveness bug — the toggle-based `credit_pulse_sync` return path
  drops pulses spaced below ~2 destination clocks, so sustained back-to-back
  response draining (fast `clk` -> slow `mem_clk`) leaked response credits and
  eventually starved the path. Reworked all three classes to **occupancy-based
  credits** (availability = `FIFO occupancy < credit limit`), which is CDC-lossless
  by construction. Removed the per-class `credit_counter` + `credit_pulse_sync`
  instances from the datapath; added formal credit-conservation invariants and
  cover goals. `test_random_soak` now drains back-to-back with no pacing and
  passes; full OSS suite (regress / stress / coverage 100% / sva / vlt-rand /
  cocotb 16/16 / formal 6/6) re-verified green. Also fixed the `max_occ` width
  (8-bit) lint error that broke the `a2dd31b` CI run.
- **[done 2026-06-02] Formal depth / k-induction**: closed the CDC sync-chain
  transient with unbounded `prove`. `async_fifo` now carries free-running ghost
  counters (FORMAL-only, one bit wider than the real Gray pointers) that shadow
  each pointer and synchronizer stage; stated on the ghosts — where live gaps
  stay below the wrap-ambiguous half-modulus — the pointer ordering and the
  occupancy bound (`occupancy <= DEPTH`) become k-inductive, so `async_fifo`,
  `reset_drain`, and `credit_counter` all pass unbounded `prove`. `reset_drain`
  also needed its legal-encoding/`drain_done` assertions moved to combinational
  (immediate) form: under `multiclock on` the solver can freeze a clock for the
  whole induction window, leaving a clocked assertion unevaluated and letting
  induction start in the unreachable `state==2'd3`. The bridge BMC depth was
  raised 16 -> 24 (cover stays 32). Formal task count 6 -> 11. The bridge *top*
  unbounded `prove` was the one remaining gap (closed below).
- **[done 2026-06-02] Bridge top unbounded prove**: the `cxl_lpddr5x_bridge` top
  now closes unbounded `prove` (k-induction, depth 24), so all four modules are
  proven for all time (task count 11 -> 12). Two pieces closed it. (1) Egress
  valid/ready data-stability (`cxl_out`/`lp_out`) was non-inductive because the
  implicit `$past` register is clocked by the domain clock, and with the clocks
  free k-induction can leave that clock un-ticked across the whole window so
  `$past` takes an arbitrary value. Reformulated with self-clocked shadow
  registers gated by a reset-0 "sample valid" flag; the `lp_out` arbiter path is
  pinned by an arbiter-lock invariant (a locked, in-flight beat keeps its source
  FIFO non-empty) plus the `async_fifo` head-of-line stability invariant. (2) The
  FIFO occupancy/ordering invariants are not re-derivable in the bridge — its two
  FIFO resets come from one async source through per-domain `reset_sync` cells, so
  the brief reset-deassert skew lets induction seed an unreachable over-full state
  (large `f_wcnt` while the read domain still reads 0). These are composed under
  **assume-guarantee**: asserted+proven in the standalone `async_fifo` run (common
  reset), assumed in the bridge integration (`FIFO_OCC_CHECK` macro).
- **[done 2026-07-20] LPDDR5X bank/timing scheduler model + perf harness**: added
  a behavioral LPDDR5X bank/timing model (`sim/lpddr5x_timing_model.h`) and a
  Verilator perf harness (`sim/sim_perf.cpp`, `make perf`) that attaches it as the
  memory side — every `lp_out` command is decoded and served by the model, which
  returns the matching `lp_in` response after a latency derived from bank state
  (row hit vs miss/empty), the JEDEC-style timing set (tRCD/tRP/tRAS/tRC, tCCD_L/S,
  tRRD_L/S, tFAW, tRL/tWL, tWR/tRTP, tMRR), and a finite controller command queue
  that backpressures `lp_out_ready` so an over-offered load backs up through the
  bridge credits instead of producing an unbounded schedule. The harness
  correlates each request (cxl_in accept) to its completion (cxl_out) by a
  partitioned tag and reports end-to-end latency percentiles, the row hit/miss mix,
  and command/completion throughput, under a chosen offered load and locality
  pattern (`rand`/`stream`/`hotbank`). `make perf-sweep` re-elaborates the DUT
  across credit + FIFO-depth points and tabulates the tradeoff: throughput is
  memory-bound (flat, set by locality) while latency grows with credits, so
  over-crediting is pure latency cost (Little's law);
  `make perf-selftest` is a deterministic g++ unit test pinning the model's timing
  arithmetic (row-hit = tRL+tBURST, miss adds tRP+tRCD, writes use tWL). The model
  is in-order (FCFS), documented as a characterization tool, not a sign-off memory
  model or a correctness gate. Validated: stream (locality + bank parallelism)
  delivers ~2x the throughput and lowest latency of rand; hotbank (bank conflicts)
  is worst; self-test passes.
- **[done 2026-06-02] Verible style-lint + CI hygiene**: added a Google Verible
  SystemVerilog style-lint as a non-blocking (`continue-on-error`) CI job and a
  `make verible-lint` target, driven by a tuned `.rules.verible_lint` baseline
  (house style: `always @(*)`, `ALL_CAPS_SNAKE` localparams, untyped state/mask
  localparams, `[0:N-1]` memories, 100-col). The baseline is CLEAN on the
  synthesizable RTL — fixed the handful of real findings it surfaced (trailing
  whitespace, four >100-col lines). Pinned Verible (`v0.0-3946-g851d3ff4`) in the
  workflow env and added a "Pinned tool versions" table to the README. Fixed the
  broken CI status badge URL (wrong repo slug `cxl_lpddr5x_bridge` ->
  `cxl-to-lpddr5x-bridge`, modern workflow-file badge). `make verible-format` is
  provided but opt-in/local only (it would reflow the deliberate hand-alignment),
  so formatting is not gated.

## Near-term

- *(none currently — the formal-depth track is complete; see Medium-term.)*

## Medium-term

- **UVM bench extensions**: the base env has landed (see Current state). A
  `cxl_lpddr5x_link_down_test` (drops `ctrl_vif.link_up` mid-run, waits for
  `drain_done`, then restores) and bursty (multi-cycle) backpressure on both
  egress responders (`cxl_out`/`lp_out`, `*_max_stall` knobs) have landed
  (xrun-only; not in the OSS gate). Next: constrained-random credit stress, the
  parameter sweep above driven from UVM, and optionally a nightly run on a
  licensed simulator.

## Long-term

- Real STA sign-off (standard-cell `.lib` + `.sdc` constraints) and a structural
  CDC audit — beyond the liberty-free area/depth synth gate now in place.
- Perf model extensions: FR-FCFS reordering and a write buffer in the LPDDR5X
  model (currently in-order/FCFS); a UVM-driven perf mode on a licensed simulator.
