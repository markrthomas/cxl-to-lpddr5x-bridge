---
title: "CXL to LPDDR5X Bridge -- Design Specification"
author: "RTL Workspace"
---

# 1. Purpose and scope

This document specifies the `cxl_lpddr5x_bridge` RTL: a digital-only bridge that
accepts **CXL.mem** requests on a host clock domain, translates each into a single
**LPDDR5X** command flit, and returns memory-side responses as CXL completions. It
covers the architecture, packet format, opcode mapping, interface, the reset-drain
link gate, and the verification stack. Analog PHY, link training, and multi-beat
payload transport are out of scope.

# 2. Background

CXL.mem exposes a load/store request-completion protocol; LPDDR5X DRAM is driven
by a command channel (RD/WR/precharge/mode-register commands). A bridge between
them must translate request semantics, decouple the (independent) host and memory
clocks, meter traffic so neither side overruns the other, and degrade safely when
the link drops. This RTL models those mechanics at flit granularity with an
OSS-verifiable toolchain.

# 3. Goals

- Translate each CXL.mem request into exactly one LPDDR5X command flit.
- Cross the `clk` and `mem_clk` domains with no metastability hazards.
- Enforce per-class credit limits (Posted, Non-Posted, Response).
- Preserve posted-request ordering through the egress arbiter.
- Detect command-channel corruption (CRC-8) and surface it as a CXL INVALID completion.
- Gate the datapath open only while the link is up; drain cleanly on link-down.

# 4. Architecture

The bridge has two request paths (c2m) and one response path (m2c). Requests are
classified Posted vs Non-Posted, buffered in separate async FIFOs, and arbitrated
onto the LPDDR5X command channel. Responses are CRC-checked, translated, buffered,
and presented as CXL completions.

## 4.1 Top-level parameters

| Parameter | Default | Meaning |
|:---|:---|:---|
| `WIDTH` | 64 | Packet/flit width (bits). |
| `FIFO_DEPTH` | 8 | Depth of each async FIFO. |
| `POSTED_CREDITS` | 8 | Posted-class ingress credits. |
| `NP_CREDITS` | 8 | Non-posted-class ingress credits. |
| `RSP_CREDITS` | 8 | Response-class ingress credits. |

## 4.2 Datapath

### 4.2.1 Protocol translation

`translate_cxl_to_lp()` decodes the request kind/opcode and emits one LPDDR5X
command flit, recomputing the CRC-8 over the new header:

| CXL request | Opcode | LPDDR5X command |
|:---|:---|:---|
| `MEM_RD` | normal / auto-precharge | `RD` / `RDA` |
| `MEM_WR` | normal / auto-precharge / masked | `WR` / `WRA` / `MWR` |
| `MEM_MRR` | -- | `MRR` |
| `MEM_MRW` | -- | `MRW` |

`translate_lp_to_cxl()` validates the response checksum and reconstructs a CXL
completion:

| LPDDR5X response | Maps to | Notes |
|:---|:---|:---|
| `RD_RSP` (OK/ERR) | `MEM_RD_DATA` (SC / CA) | read-data completion |
| `WR_RSP` (OK/ERR) | `MEM_CPL` (SC / CA) | write acknowledgement |
| `MRR_RSP` (OK/ERR) | `MRR_DATA` (SC / CA) | mode-register read data |
| bad CRC / unknown kind | `INVALID` | corruption surfaced upstream |

### 4.2.2 Flow control (credits)

Credit availability is derived directly from each class's async-FIFO **write-domain
occupancy**: an ingress class accepts a request only while its FIFO occupancy is
below the credit limit and the FIFO is not full
(`posted_crd_avail = c2m_p_occ < POSTED_CREDITS`, and likewise for `NP_CREDITS` /
`RSP_CREDITS`). Because occupancy is computed from the FIFO's Gray-coded,
glitch-free pointer synchronization, the writer always sees a *conservative
(lagging)* view of how much the reader has drained, so credits are returned
**losslessly** as the far domain pops entries — there is no separate return path to
under- or over-count.

> **History.** An earlier design returned credits with a saturating `credit_counter`
> plus a toggle-handshake `credit_pulse_sync` per class. That handshake can only
> carry return pulses spaced more than ~2 destination clocks apart; under sustained
> back-to-back response draining (the fast `clk`->slow `mem_clk` direction) it leaked
> return pulses and eventually starved the m2c path — a liveness bug the randomized
> cocotb soak (`test_random_soak`) surfaced. Moving to occupancy-derived credits
> removes the lossy return path entirely. `credit_pulse_sync` is retained only for
> the single-event CRC-error counter crossing (where pulses are naturally sparse);
> `credit_counter` is kept as a standalone, formally-verified module.

### 4.2.3 Asynchronous buffering

`async_fifo` is a first-word-fall-through FIFO with Gray-coded read/write pointers
synchronized across domains; `cdc_sync` provides multi-flop level crossings for
control signals (e.g. `link_up`, FIFO-empty flags used by the drain logic).

### 4.2.4 Ordering and arbitration

On the `mem_clk` egress side a posted-priority arbiter selects between the Posted
and Non-Posted FIFOs. When both have data, the Posted (write/MRW) command is sent
first. An arbitration lock (`arb_locked_r` / `arb_sel_posted_r`) holds the selection
of the in-flight command until it is accepted, preventing mid-command switching.

# 5. Packet format

A fixed 64-bit flit is shared in both directions:

| Bits | Field | Use |
|:---|:---|:---|
| `[63:60]` | Kind | CXL or LPDDR5X packet kind. |
| `[59:56]` | Code | Opcode / command sub-op / completion status. |
| `[55:48]` | Tag | Correlates requests and completions. |
| `[47:32]` | Address / byte count | CXL byte address (`{BANK[15:12], ROW[11:0]}` downstream). |
| `[31:24]` | Length | Burst length / column group. |
| `[23:16]` | ID | Requester / source / completer ID. |
| `[15:8]` | Attributes / lower address | Channel/rank attributes or completion lower address. |
| `[7:0]` | Misc | CRC-8/CCITT over bytes `[63:8]`. |

The checksum is **CRC-8/CCITT** (polynomial `0x07`, init `0x00`) over the seven
header bytes; the misc byte is zeroed before computation.

# 6. Interface summary

## 6.1 Common & control

| Signal | Dir | Domain | Description |
|:---|:---|:---|:---|
| `clk` | in | -- | CXL host clock. |
| `mem_clk` | in | -- | LPDDR5X command-channel clock. |
| `rst_n` | in | -- | Active-low asynchronous reset (synchronized internally per domain). |
| `link_up` | in | async | Link-state input to the reset-drain FSM. |
| `err_inj_en` | in | async | Error-injection enable (verification hook). |
| `drain_done` | out | `clk` | High when the bridge is drained and safe to re-sequence. |

## 6.2 CXL port (clk domain in, mem_clk domain out)

| Signal | Dir | Description |
|:---|:---|:---|
| `cxl_in_valid` / `cxl_in_data[WIDTH-1:0]` / `cxl_in_ready` | in/in/out | CXL request ingress (valid/ready). |
| `lp_out_valid` / `lp_out_data[WIDTH-1:0]` / `lp_out_ready` | out/out/in | LPDDR5X command egress (valid/ready). |

## 6.3 LPDDR5X port (mem_clk domain in, clk domain out)

| Signal | Dir | Description |
|:---|:---|:---|
| `lp_in_valid` / `lp_in_data[WIDTH-1:0]` / `lp_in_ready` | in/in/out | LPDDR5X response ingress (valid/ready). |
| `cxl_out_valid` / `cxl_out_data[WIDTH-1:0]` / `cxl_out_ready` | out/out/in | CXL completion egress (valid/ready). |

# 7. Bring-up and non-ideal behavior

## 7.1 Reset-drain FSM

`reset_drain` (clocked on `clk`) gates the datapath:

```
S_DOWN  --(link_up)----> S_UP
S_UP    --(!link_up)---> S_DRAIN
S_DRAIN --(all_empty)--> S_DOWN
```

- `open` (datapath enable) is asserted **only** in `S_UP`.
- `all_empty` ANDs the (synchronized) empty flags of all three FIFOs.
- `drain_done` is combinationally high in `S_DOWN`/`S_DRAIN` while `all_empty`, marking the bridge safe to power down or re-sequence.

On link-down the FSM moves to `S_DRAIN`, stops accepting new traffic, and waits for
in-flight commands/completions to drain before returning to `S_DOWN`.

# 8. Verification

The bridge is verified with an OSS-only toolchain consistent with the workspace
`DV_STANDARDS.md`.

## 8.1 Directed & stress tests

`verification/directed/` (Icarus): self-checking testbench covering link-up gating,
granular opcodes, error injection, and clock ratios 1:1 / 2:1 / 1:3, plus a
backpressure stress phase (`make stress`).

## 8.2 cocotb (OSS UVM-equivalent)

`verification/cocotb/`: 12 tests with a Python gold model (pack helpers + CRC-8)
covering c2m mem rd/wr/masked/auto-precharge, MRR/MRW, m2c response paths, and the
bad-CRC INVALID rejection. All pass under Icarus VPI.

## 8.3 Formal verification

`verification/formal/` (SymbiYosys): 12/12 tasks pass. All four modules —
`credit_counter`, `reset_drain`, the dual-clock `async_fifo`, and the
`cxl_lpddr5x_bridge` top itself — close **unbounded `prove`** (basecase + temporal
k-induction), not just BMC + cover. Properties live in `` `ifdef FORMAL `` blocks
(e.g. the reset-drain legal-encoding and `drain_done` tracking asserts, with
reachability cover goals for the full `DOWN->UP->DRAIN->DOWN` cycle).

Four techniques make the unbounded proofs go through:

- **`async_fifo` ghost counters.** The real Gray pointers are `ADDR_W+1` bits, so
  the modulus is exactly `2*DEPTH` and a binary pointer difference is
  wrap-ambiguous at the FIFO-full boundary (`gap == DEPTH == modulus/2`): a legal
  full-then-drained state is indistinguishable from an illegal "synchronizer ran
  ahead of its source" state, so plain pointer-difference invariants are *not*
  inductive. FORMAL-only free-running **ghost counters** -- one bit wider than the
  real pointers -- shadow each pointer and each two-flop synchronizer stage, and
  are tied back to the RTL by equality. Stated on the ghosts, every live pairwise
  gap (`<= DEPTH`) sits below the ghost half-modulus, so the pointer ordering
  (`f_rs1 <= f_rs0 <= r_cnt <= w_cnt`, symmetric on the read side) and the
  occupancy bound (`occupancy <= DEPTH`) are unambiguous and k-inductive across
  the CDC synchronizers. This is the credit-conservation guarantee proved *for all
  time*.
- **Shadow-register egress data-stability.** A held egress beat
  (`valid && !ready`) must keep its data until accepted. Stating this with `$past`
  is *not* k-inductive under `multiclock on`: the implicit `$past` register is
  clocked by the domain clock, and with the clocks free the solver may leave that
  clock un-ticked across the whole induction window, so `$past` takes an arbitrary
  induction-initial value. Each egress port instead samples a self-clocked shadow
  (`valid`/`ready`/`data` at the previous domain-clock edge) gated by a reset-0
  "sample valid" flag, which pins the comparison to a real prior beat. For
  `lp_out` (behind the posted-priority arbiter) the data is additionally pinned by
  an **arbiter-lock invariant** — while a beat is locked in flight the selected
  source FIFO stays non-empty — composed with the FIFO head-of-line stability
  invariant so the selected head cannot shift under the stalled beat.
- **Assume-guarantee at the FIFO boundary.** The bridge's two `async_fifo` resets
  derive from one async source through per-domain `reset_sync` cells (async
  assert, sync deassert). The brief reset-deassert *skew* lets a flat bridge
  induction seed an unreachable over-full FIFO (a large write count while the read
  domain still reads 0), which no bounded skew could actually produce, so the
  ghost occupancy/ordering invariants are true-but-not-re-derivable in the bridge.
  They are composed under **assume-guarantee** via a `FIFO_OCC_CHECK` macro:
  `assert`ed (and proven inductive) in the standalone `async_fifo` run under its
  common-reset contract, and `assume`d in the bridge integration — discharging the
  obligation once where it is provable and relying on it where it is not.
- **Combinational safety asserts under `multiclock`.** `reset_drain`'s
  legal-encoding (`state != 2'd3`) and `drain_done` asserts are written as
  immediate (`always @(*)`) checks rather than `always_ff @(posedge clk)`. With
  `multiclock on` the solver may freeze a clock for the entire induction window;
  a clocked assertion is then never evaluated, letting induction start in the
  unreachable `state==2'd3` (the FSM scrubs it only via the `default` arm on a
  clock edge that never arrives). An immediate assert holds in every step, so the
  hypothesis carries `state != 2'd3` forward and the transition preserves it.

## 8.4 Coverage

`sim/sim_main.cpp` (Verilator `--coverage`): an asynchronous dual-clock C++ driver
that walks every opcode, fills and drains both flow-control FIFOs, exercises the
CRC-mismatch INVALID path, the error-injection window, and a link-down drain.
`make coverage` emits `sim/coverage.info` at **100%** line coverage and **fails
if line coverage drops below the `COV_MIN` floor (default 80%)** — it parses the
`DA:` records directly (no `lcov` dependency) and prints the measured percentage.
The CI `coverage` job runs `make coverage`, so the floor is enforced in CI.
Closure: the walk exercises the bad-CRC -> INVALID path for **all** response
kinds (RD/WR/MRR); the only non-executable lines (a defensive FSM `default` in
`reset_drain`, and two FIFO status-net declarations) carry documented
`// verilator coverage_off` waivers.

## 8.5 Interface assertions (SVA)

The valid/ready contract is checked on **all four stream interfaces**
(`cxl_in`, `lp_out`, `lp_in`, `cxl_out`): valid holds until a handshake, and data
is stable while a transfer is stalled.

- **Runtime SVA** -- `verification/cxl_lpddr5x_bridge_sva.sv` is a concurrent-SVA
  checker bound to the DUT and run under Verilator `--assert` against the
  `sim/sim_main.cpp` stimulus (`make sva`). It also carries per-interface
  handshake/stall cover goals. (Icarus is not used here; its concurrent-SVA
  support is insufficient.)
- **Formal** -- the same contract is proved in SymbiYosys via the `` `ifdef FORMAL ``
  block of `cxl_lpddr5x_bridge.v`: egress ports (`lp_out`, `cxl_out`) are
  **asserted** (DUT obligation) and ingress ports (`cxl_in`, `lp_in`) are
  **assumed** (environment contract), using the Yosys-supported immediate-assert
  + `$past` style. Proofs start from a power-on reset (`initial assume(!rst_n)`).

The legacy procedural checker `cxl_lpddr5x_bridge_chk.v` (egress stability only)
is retained for the Icarus directed flow, which cannot run concurrent SVA.

## 8.6 Randomized stimulus and waveform debug

`sim/sim_rand.cpp` (Verilator `--trace --assert`) is a reproducible randomized
driver built for waveform debugging. It issues protocol-legal but randomized
traffic -- random opcode mix (including invalid kinds), idle gaps, sink
backpressure on both egress ports, link-down drain windows, and error-injection
windows -- and dumps a short, navigable VCD. Because the interface SVA is bound
under `--assert`, a protocol violation aborts the run with the VCD intact. Runs
are reproducible (`make vlt-rand RAND_SEED=.. RAND_CYCLES=..`); the harness prints
the seed and cycle-stamped event markers (sustained backpressure, link up/down,
`drain_done`, error pulses) to speed navigation. It is gated in CI as a dedicated
`random` job, which uploads the VCD as an artifact on failure.

Waveforms are available from every simulation flow:

| Target | Source | Output |
|:---|:---|:---|
| `make vcd` / `make gtkwave` | Icarus directed TB (scoreboard, clock-ratio sweeps) | `verification/directed/build/waves.vcd` (+ saved GTKWave layout `cxl_lpddr5x_bridge.gtkw`) |
| `make vlt-vcd` | Verilator `--trace` of `sim/sim_main.cpp` | `sim/obj_dir_vcd/waves.vcd` |
| `make vlt-rand` | Verilator randomized harness | `sim/obj_dir_rand/waves.vcd` |

## 8.7 UVM testbench (commercial simulators)

`verification/uvm/` is a full UVM 1.2 environment targeting Cadence Xcelium
(`xrun`), complementing the OSS suites. Two agents drive the design through
clocking blocks on the two asynchronous clocks: a **CXL-side agent** (request
driver on `cxl_in`, completion-ready responder on `cxl_out`, monitor) and an
**LPDDR5X-side agent** (response driver on `lp_in`, command-ready responder on
`lp_out`, monitor). A **scoreboard** checks data end-to-end against a
self-contained reference model -- a SystemVerilog port of `translate_cxl_to_lp` /
`translate_lp_to_cxl` and the CRC-8 from the defs header. Because the bridge
merges separate posted (WR/MRW) and non-posted (RD/MRR/invalid) FIFOs through a
posted-priority arbiter, the c2m check keeps one ordered expected queue **per
class**; m2c is a single ordered queue including the bad-CRC -> INVALID path.
Functional coverage records the request opcode mix, response kind/status, valid
vs corrupted CRC, and their crosses. Tests: `cxl_lpddr5x_smoke_test` (every
opcode + a response burst), `cxl_lpddr5x_random_test` (randomized soak with
backpressure), and `cxl_lpddr5x_err_inj_test` (injection windows; the scoreboard
masks the bridge's bit-0 c2m flip).

Run with `make uvm`, or `make -C verification/uvm [smoke|random|err_inj|waves]`.
This bench needs a licensed UVM simulator and is **not** part of the OSS CI gate;
every target degrades to a no-op when `xrun` is absent. See
`verification/uvm/README.md` for structure and porting notes (VCS / Questa reuse
the same source list).

## 8.8 Continuous integration

`.github/workflows/ci.yml` runs a fast `regress` gate, then fans out to parallel
jobs that each `needs: regress`:

| Job | Runs | Tools |
|:---|:---|:---|
| `regress` | `make regress && make stress` | iverilog, verilator |
| `coverage` | `make coverage` (enforces the 80% line floor; uploads `coverage.info`) | verilator |
| `sva` | `make sva` | verilator |
| `random` | `make vlt-rand RAND_SEED=<n>` over a seed matrix `[1..4]` (per-seed VCD artifact, `if: always()`) | verilator |
| `cocotb` | `make cocotb` | iverilog, cocotb |
| `formal` | `make formal` | OSS CAD Suite (pinned) |

The UVM bench (§8.7) is intentionally excluded from CI (commercial license).

# 9. Roadmap (phased milestones)

The full, prioritized backlog lives in [PLAN.md](PLAN.md); highlights:

- **Constrained-random + scoreboard** -- a randomized opcode/length soak with a reference-model scoreboard (cocotb and/or UVM), plus mid-burst CRC corruption and credit-underflow negatives.
- **Parameter sweep** -- exercise non-default `FIFO_DEPTH` and per-class credit values.
- **Formal depth** -- *done*: `credit_counter` / `reset_drain` / `async_fifo` close unbounded `prove`, the CDC occupancy bound is k-inductive (ghost counters, §8.3), and the bridge BMC depth is raised to 24. Remaining: the bridge *top* unbounded `prove`, blocked only on egress valid/ready data-stability (needs FIFO head-of-line data-path integrity that survives `multiclock` + async reset + `$past`).
- **Synthesis smoke + CDC audit** -- a Yosys `synth; stat` pass plus a structural check that every crossing goes through a synchronizer.
- **UVM extensions** -- the base env has landed (§8.7); add a link-down/drain test, credit stress, and the parameter sweep driven from UVM.
- **Memory model** -- LPDDR5X bank/timing scheduler for end-to-end latency checks.

# 10. Implementation limits

| Area | Current limit |
|:---|:---|
| Protocol compliance | Compact 64-bit model, not a full CXL.mem / LPDDR5X wire encoding. |
| Payload data | Header/control modeled; multi-beat payload transport not implemented. |
| Memory model | Command/response abstraction; no bank/timing scheduler. |
| Link training | `link_up` is an external input; PHY training is out of scope. |
| UVM | Full bench present (`verification/uvm/`, §8.7), but it targets a commercial simulator (Xcelium); the OSS executable regression is directed + cocotb + randomized (`vlt-rand`) + formal. |

# 11. Repository layout

```
rtl.f                             core RTL filelist — single source of truth (root/directed/cocotb)
src/                              RTL source + tb_cxl_lpddr5x_bridge.v + cxl_lpddr5x_bridge_defs.vh
verification/
  cxl_lpddr5x_bridge_sva.sv       concurrent interface SVA (bound; Verilator --assert)
  directed/                       Icarus self-checking TB + saved GTKWave layout + Makefile
  cocotb/                         cocotb tests + Python gold model
  formal/                         SymbiYosys .sby files + Makefile
  uvm/                            full UVM 1.2 bench (Cadence Xcelium; not in CI)
sim/                              Verilator harnesses: sim_main.cpp (coverage / SVA), sim_rand.cpp (randomized + waveform / --assert)
doc/                              this spec, PLAN.md, PDF Makefile
Makefile                          root gates: lint/sim/stress/regress/vcd/gtkwave/vlt-vcd/vlt-rand/coverage/sva/cocotb/uvm/formal/ci
.github/workflows/ci.yml          regress -> coverage / sva / random / cocotb / formal
```
