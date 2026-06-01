# cxl_lpddr5x_bridge — Plan

Bridge RTL translating CXL.mem (M2S/S2M) traffic to an LPDDR5X-style memory
interface, with credit-based flow control, async-FIFO clock-domain crossing, and
per-message CRC validation. Verified with an OSS-only toolchain (Icarus +
Verilator + SymbiYosys + cocotb) consistent with `../DV_STANDARDS.md`.

## Current state (2026-06-01)

- **RTL** (`src/`): `cxl_lpddr5x_bridge` top + `async_fifo`, `cdc_sync`,
  `reset_sync`, `reset_drain`, `credit_counter`, `credit_pulse_sync`, and a
  bound checker `cxl_lpddr5x_bridge_chk`.
- **Directed** (`verification/directed/`): Icarus self-checking TB — link-up
  gating, granular opcodes, error injection, clock ratios (1:1, 2:1, 1:3), and a
  backpressure stress phase. `make sim` / `make stress`.
- **cocotb** (`verification/cocotb/`): 12 OSS UVM-equivalent tests (c2m mem
  rd/wr/masked/autopre, MRR/MRW, m2c rsp paths, bad-CRC reject). All PASS.
- **Formal** (`verification/formal/`): SymbiYosys BMC + cover on `credit_counter`,
  `reset_drain`, and the `cxl_lpddr5x_bridge` top. 6/6 tasks PASS. Includes
  valid/ready protocol on all four interfaces (egress asserted, ingress assumed).
- **Interface SVA** (`verification/cxl_lpddr5x_bridge_sva.sv`): concurrent SVA on
  all four valid/ready ports (valid-stable, data-stable, handshake/stall cover),
  bound to the DUT and run under Verilator `--assert` via `make sva`.
- **Coverage** (`sim/sim_main.cpp`): Verilator `--coverage` C++ driver walks every
  opcode, both flow-control FIFOs to full/empty, the CRC-mismatch INVALID path,
  the error-injection window, and a link-down drain. `make coverage` emits
  `sim/coverage.info` at **96.9% line coverage** (above the 80% floor).
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
  in CI automatically (the `coverage` job runs `make coverage`). Current: 96.9%.
  (No `lcov` dependency — parsed directly.)

## Near-term

- **Coverage closure**: chase the residual ~3% (8 lines in the bridge top, 1 in
  `reset_drain`) — mostly defensive/unreachable default branches; add cover-driven
  stimulus or waive with comments.
- **Randomized soak + scoreboard**: `sim/sim_rand.cpp` checks *protocol* (SVA) but
  not *data* — it cannot catch a wrong opcode translation or a payload corruption,
  only the directed TB's scoreboard does and only on fixed vectors. Extend the
  cocotb env with a randomized opcode/length soak driven by a reference-model
  scoreboard so those bugs are caught end-to-end. Also add the bad-CRC negatives:
  mid-burst corruption and credit-underflow attempts.
- **Random seed breadth**: the CI `random` job runs one fixed seed. Add a small
  seed matrix (and/or a scheduled nightly over many seeds) surfacing the failing
  seed + VCD as artifacts; the harness already prints a replayable seed.

## Medium-term

- **Parameter sweep**: every test runs the defaults (`FIFO_DEPTH=8`, all credits
  8). Sweep `FIFO_DEPTH ∈ {2,8}` and `*_CREDITS ∈ {1,8}` across `sim_rand` /
  cocotb to flush out depth/credit off-by-one and starvation bugs that hide at the
  default.
- **Synthesis smoke + CDC audit (Yosys)**: add `make synth`
  (`yosys -p "read_verilog … ; synth ; stat"`) to catch inferred latches /
  unintended priority logic and track cell/area as a regression signal — Yosys is
  already in the pinned OSS CAD Suite. Add a structural CDC check that every
  crossing goes through `cdc_sync` / `async_fifo` / `credit_pulse_sync`.
- **Stronger invariant assertions**: beyond cover goals, assert `credit ≤ CREDITS`,
  no FIFO write-when-full / read-when-empty, and `accepted_responses ==
  returned_credits + in_flight`. These are the invariants most likely to break
  under the parameter sweep. (Extends the formal credit-conservation work below.)
- **Formal depth**: raise bridge BMC depth past 16 once a k-induction invariant
  closes the CDC sync-chain transient; add credit-conservation cover goals.
- **Error/event counters**: expose read-only status counters (CRC errors, dropped
  flits, FIFO high-water, drain events). Failures become observable in sim and
  silicon, and the scoreboard gets concrete signals to check.
- **Verible lint + format**: add Google Verible style-lint + formatter as a
  non-blocking CI job for SV consistency; add a CI status badge and pinned
  OSS-tool versions to the README.
- **UVM bench extensions**: the base env has landed (see Current state). Next:
  a link-down/drain test (toggle `ctrl_vif.link_up`), constrained-random credit
  stress, the parameter sweep above driven from UVM, and optionally a nightly run
  on a licensed simulator.

## Long-term

- LPDDR5X bank/timing scheduler model for end-to-end latency checks; throughput
  characterization vs credit / FIFO-depth settings (reuse the `sim_rand` beat
  counters as a perf harness).
- Synthesis + timing hooks beyond the smoke above; PDF design-spec build via the
  workspace Pandoc stack.
