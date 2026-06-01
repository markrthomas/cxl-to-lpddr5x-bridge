# cxl_lpddr5x_bridge — Plan

Bridge RTL translating CXL.mem (M2S/S2M) traffic to an LPDDR5X-style memory
interface, with credit-based flow control, async-FIFO clock-domain crossing, and
per-message CRC validation. Verified with an OSS-only toolchain (Icarus +
Verilator + SymbiYosys + cocotb) consistent with `../DV_STANDARDS.md`.

## Current state (2026-05-31)

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
- **Gates**: root `Makefile` exposes `lint/sim/regress/coverage/formal/ci/clean`;
  `.github/workflows/ci.yml` runs regress → coverage / cocotb / formal.

## Near-term

- **Coverage closure**: chase the residual ~3% (8 lines in the bridge top, 1 in
  `reset_drain`) — mostly defensive/unreachable default branches; add cover-driven
  stimulus or waive with comments.
- **cocotb negatives**: extend bad-CRC handling to mid-burst corruption and
  credit-underflow attempts; add randomized opcode/length soak.

## Medium-term

- **Formal depth**: raise bridge BMC depth past 16 once a k-induction invariant
  closes the CDC sync-chain transient; add credit-conservation cover goals.
- **UVM bench** (`verification/uvm/`): populate the VCS UVM env (agents/seq/env/
  tests) mirroring the cocotb scoreboard; keep local-only (no CI license).

## Long-term

- LPDDR5X bank/timing scheduler model for end-to-end latency checks.
- Synthesis + timing hooks; PDF design-spec build via the workspace Pandoc stack.
