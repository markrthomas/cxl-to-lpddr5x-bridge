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

Each ingress class has a saturating `credit_counter`: a request consumes one credit
when accepted (`cxl_in_ready` / `lp_in_ready` only assert while credits remain and
the FIFO is not full). When a command/completion is later popped on the far domain,
a one-cycle pulse is carried back through a `credit_pulse_sync` (toggle handshake)
and returns the credit. Posted and Non-Posted credits return from `mem_clk`->`clk`;
Response credits return from `clk`->`mem_clk`.

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

`verification/formal/` (SymbiYosys): BMC + cover on `credit_counter`, `reset_drain`,
and the `cxl_lpddr5x_bridge` top -- 6/6 tasks pass. Properties live in `` `ifdef FORMAL ``
blocks (e.g. the reset-drain legal-encoding and `drain_done` tracking asserts, with
reachability cover goals for the full `DOWN->UP->DRAIN->DOWN` cycle).

## 8.4 Coverage

`sim/sim_main.cpp` (Verilator `--coverage`): an asynchronous dual-clock C++ driver
that walks every opcode, fills and drains both flow-control FIFOs, exercises the
CRC-mismatch INVALID path, the error-injection window, and a link-down drain.
`make coverage` emits `sim/coverage.info` at **96.9%** line coverage (>= 80% floor).

# 9. Roadmap (phased milestones)

- **Coverage closure** -- chase the residual ~3% (defensive default branches).
- **Negative tests** -- mid-burst CRC corruption, credit-underflow attempts, randomized opcode/length soak.
- **Formal depth** -- raise bridge BMC depth past 16 via k-induction; add credit-conservation cover goals.
- **UVM bench** -- populate `verification/uvm/` (VCS, local-only) mirroring the cocotb scoreboard.
- **Memory model** -- LPDDR5X bank/timing scheduler for end-to-end latency checks.

# 10. Implementation limits

| Area | Current limit |
|:---|:---|
| Protocol compliance | Compact 64-bit model, not a full CXL.mem / LPDDR5X wire encoding. |
| Payload data | Header/control modeled; multi-beat payload transport not implemented. |
| Memory model | Command/response abstraction; no bank/timing scheduler. |
| Link training | `link_up` is an external input; PHY training is out of scope. |
| UVM | Placeholder; directed + cocotb tests are the executable regression baseline. |

# 11. Repository layout

```
src/                              RTL source + cxl_lpddr5x_bridge_defs.vh
verification/
  directed/                       Icarus self-checking TB + Makefile
  cocotb/                         cocotb tests + Python gold model
  formal/                         SymbiYosys .sby files + Makefile
  uvm/                            VCS UVM bench (placeholder; local only)
sim/                              Verilator coverage harness (sim_main.cpp)
doc/                              this spec, PLAN.md, PDF Makefile
Makefile                          root gates: lint/sim/regress/coverage/formal/ci
.github/workflows/ci.yml          regress -> coverage / cocotb / formal
```
