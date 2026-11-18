# Random regression (Swarm B)

Seeded random stimulus through the **existing cocotb scoreboard** (`verification/cocotb/test_cxl_lpddr5x_bridge.py`
`_Scoreboard` + the `env.py` gold model); no separate checker. Sim: cocotb + Icarus (`make rr-build`).
Files: `rr.py` (driver), `rr_test.py` (cocotb test + knob sets), `Makefile` (sim build), `corpus.json`.

## Contract
- `make rr-build` - build `build/sim.vvp` once (rebuilds if `src/` changes).
- `make rr N=<jobs> JOBS=<parallel> [SEED=<base>] [CONFIG=<knob set>]` - job i uses seed `SEED+i`; config is
  `NAMES[seed % len]` unless `CONFIG` is given. Writes `runs/<UTC ts>/results.jsonl` (one JSON line per job:
  job, seed, config, status, signature, log, repro), prints `rr run: <dir> seed_base=<s> jobs=<N> fail=<F>`,
  exits non-zero iff F > 0. `runs/` is git-ignored.
- `make rr-triage [RUN=<dir>]` - cluster FAILs by signature (default: latest run); one line per cluster
  with count, configs, repro, log.
- `make rr-replay` - rerun `corpus.json`; entries with `"fixed": true` must PASS (non-zero exit otherwise).
  Add entries with `python3 verification/random/rr.py promote --seed S [--config C] --signature "..." --note "..."`.
- Determinism: one `(seed, config)` pair is bit-reproducible (`RR_TRACE=1` logs every scoreboard event; the
  trace of a seed is identical across runs). `RR_TRACE=1` can be passed as a make variable.

## Knob sets (`rr_test.py: CONFIGS`)
Each sets: clk / mem_clk period (ns), max idle gap between flits, sink-ready probability (back-pressure),
request/response counts. `base` (10/14 ns async, = the cocotb soak), `ratio_1_1`, `mem_fast`, `mem_slow`,
`bp_heavy` (ready 20%), `bursty` (no gaps, 800 req), `sparse`.
Randomized per seed: opcodes/sub-ops, tags, addresses, lengths, invalid kinds, response status, bad-CRC flits.

## Harness note (found while bootstrapping) - resolved: testbench race, not a DUT bug
Driving the first flit in the same simulation timestep as `reset_dut()` returns lost the first request on
`bursty` seeds. Root cause (traced 2026-11-18, `verification/cocotb/test_reset_handoff.py`): with clk 10 ns /
mem_clk 14 ns, `reset_dut()` returns on the mem_clk edge at 140 ns, which is also a clk edge. The producer
wrote `valid`/`data` and then awaited `RisingEdge(clk)`, which fired in that same timestep; cocotb applies the
write only in the ReadWrite phase, so the DUT sampled `valid=0` at 140 ns while the producer read `ready=1` and
counted the flit as accepted. The DUT never saw it; the scoreboard then expected it. Each producer here therefore
waits for its own clock edge before driving.

Directed checks (part of `make cocotb`): `test_first_flit_after_reset_{c2m,m2c}` drive mid-cycle and require the
first flit to be accepted and delivered; `test_same_timestep_drive_{c2m,m2c}` use the racy drive with an
independent edge monitor feeding the scoreboard, so the DUT side is exact either way and the race is logged
(`... lost by the TESTBENCH (race), 0 by the DUT`; reproduces for c2m when the test starts at sim time 0).
Teeth: an RTL mutation that drops the first accepted request after reset fails both c2m tests.
Latent: `test_random_soak`'s `_cxl_in_producer` uses the same drive pattern; it passes with its fixed seed
because its first gap is non-zero, but a re-seed could hit the same race.

## Teeth
Mutation (flip one address bit in the MEM_WR path of `translate_cxl_to_lp`): `make rr N=20` -> fail=20, one
cluster `c2m mismatch: req got != exp`; restored: fail=0.

## Stimulus backlog
- B1 link_up toggling / drain windows mid-traffic (scoreboard must model dropped/blocked flits first).
- B2 error injection (`err_inj_en`) windows with the matching gold-model change.
- B3 credit exhaustion: back-to-back traffic with sinks stalled long enough to fill FIFOs and credits.
- B4 randomized FIFO_DEPTH / *_CREDITS parameters (needs a per-config build).
- B5 mid-run reset.
- B6 port the sweep to the Verilator (`sim/sim_rand.cpp`) and UVM envs once a scoreboard exists there.
- B7 randomize clock ratios per run (ppm-style phase offsets) rather than a fixed set.
