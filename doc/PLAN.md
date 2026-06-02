# cxl_lpddr5x_bridge — Plan

Bridge RTL translating CXL.mem (M2S/S2M) traffic to an LPDDR5X-style memory
interface, with credit-based flow control, async-FIFO clock-domain crossing, and
per-message CRC validation. Verified with an OSS-only toolchain (Icarus +
Verilator + SymbiYosys + cocotb) consistent with `../DV_STANDARDS.md`.

## Current state (2026-06-01)

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
- **Formal** (`verification/formal/`): SymbiYosys BMC + cover on `credit_counter`,
  `reset_drain`, and the `cxl_lpddr5x_bridge` top. 6/6 tasks PASS. Includes
  valid/ready protocol on all four interfaces (egress asserted, ingress assumed),
  plus credit-conservation invariants (occupancy never exceeds the credit pool)
  and credit-availability cover goals.
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
- **Gates**: root `Makefile` exposes `lint/sim/regress/stress/coverage/sva/
  vlt-rand/formal/cocotb/ci/clean`; `.github/workflows/ci.yml` runs
  regress → coverage / sva / random / cocotb / formal (the `random` job uploads
  its VCD as an artifact, `if: always()`, for debugging a failing run).

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

## Near-term

- **Formal depth**: raise bridge BMC depth past 16 once a k-induction invariant
  closes the CDC sync-chain transient (credit-conservation invariants + cover
  goals already landed; the remaining work is the unbounded `prove` task).

## Medium-term

- **Verible lint + format**: add Google Verible style-lint + formatter as a
  non-blocking CI job for SV consistency; add a CI status badge and pinned
  OSS-tool versions to the README.
- **UVM bench extensions**: the base env has landed (see Current state). A
  `cxl_lpddr5x_link_down_test` (drops `ctrl_vif.link_up` mid-run, waits for
  `drain_done`, then restores) and bursty (multi-cycle) backpressure on both
  egress responders (`cxl_out`/`lp_out`, `*_max_stall` knobs) have landed
  (xrun-only; not in the OSS gate). Next: constrained-random credit stress, the
  parameter sweep above driven from UVM, and optionally a nightly run on a
  licensed simulator.

## Long-term

- LPDDR5X bank/timing scheduler model for end-to-end latency checks; throughput
  characterization vs credit / FIFO-depth settings (reuse the `sim_rand` beat
  counters as a perf harness).
- Synthesis + timing hooks beyond the smoke above; PDF design-spec build via the
  workspace Pandoc stack.
