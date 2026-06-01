# UVM testbench — cxl_lpddr5x_bridge

A full UVM 1.2 environment for the bridge, intended for **commercial simulators**
(developed against Cadence **Xcelium**/`xrun`). It complements the repo's OSS
verification (Icarus directed TB, cocotb, SymbiYosys formal, Verilator coverage /
SVA / randomized waveform run) — those remain the CI gate; this bench is **not**
run in CI because it needs a licensed UVM simulator.

## Running

```bash
make -C verification/uvm smoke      # every opcode + a response burst (directed)
make -C verification/uvm random     # randomized soak with backpressure
make -C verification/uvm err_inj    # error-injection windows
make -C verification/uvm run  UVM_TEST=cxl_lpddr5x_random_test SEED=7 UVM_VERBOSITY=UVM_HIGH
make -C verification/uvm waves UVM_TEST=cxl_lpddr5x_random_test   # + SHM waveform (SimVision)
```

If `xrun` is not on `PATH`, every target prints a notice and exits 0, so an
OSS-only checkout is never broken.

Other UVM simulators (VCS `vcs -ntb_opts uvm`, Questa `qrun -uvm`) can reuse the
same source list — see `UVM_SRC` / `RTL` in the `Makefile`; only the invocation
differs.

## Structure

```
verification/uvm/
  cxl_lpddr5x_if.sv          cxl_if (clk), lp_if (mem_clk), ctrl_if — clocking-block driven
  cxl_lpddr5x_flit.svh       base 64-bit flit object (monitors broadcast this)
  cxl_lpddr5x_uvm_pkg.sv     package: constants + CRC/pack/translate reference model + includes
  agents/cxl_agent/          request driver (cxl_in), completion responder (cxl_out_ready), monitor
  agents/lp_agent/           response driver (lp_in), command responder (lp_out_ready), monitor
  env/                       cfg, scoreboard, functional coverage, virtual sequencer, env
  seq/                       request / response / virtual sequences (random + directed)
  tb/cxl_lpddr5x_tb_top.sv   clocks, DUT + interface instantiation, run_test
  tests/                     base test + smoke / random / err_inj
```

## What it checks

The scoreboard is a self-contained reference model (SV port of the RTL
`translate_*` functions and the CRC-8/CCITT in `cxl_lpddr5x_bridge_defs.vh`),
checking **data correctness end-to-end**, not just protocol:

- **c2m** — every accepted CXL request (`cxl_in`) must produce the correct
  LPDDR5X command (`lp_out`). Because the bridge uses separate posted (WR/MRW)
  and non-posted (RD/MRR/invalid) FIFOs merged by a posted-priority arbiter, the
  scoreboard keeps one ordered expected queue **per class** and matches each
  observed command against its class — order is preserved within a class, classes
  interleave.
- **m2c** — every accepted LPDDR5X response (`lp_in`) must produce the correct
  CXL completion (`cxl_out`), including the bad-CRC → `INVALID` completion path.
  Single completion FIFO, so this is one strictly-ordered queue.
- **err_inj** — the test enables `err_inj_en` in windows; the bridge flips bit 0
  of the c2m command, so the scoreboard masks that bit while injection runs.

Functional coverage records the request opcode mix, response kind/status, valid
vs corrupted CRC, and the kind×opcode / kind×CRC crosses.

## Tests

| Test                          | Stimulus                                             |
|-------------------------------|------------------------------------------------------|
| `cxl_lpddr5x_smoke_test`      | one request of every kind/opcode + a short response burst, light backpressure |
| `cxl_lpddr5x_random_test`     | long randomized request + response soak, heavy backpressure |
| `cxl_lpddr5x_err_inj_test`    | randomized soak with `err_inj_en` windows (c2m LSB masked) |

## Notes for porting / extension

- The reference model lives in `cxl_lpddr5x_uvm_pkg.sv`. If the RTL packet format
  or translation changes, update the package functions (and the cocotb `env.py`
  gold model) to match.
- Reset and `link_up` are driven from the base test via `ctrl_if`; the bench
  keeps the link up throughout. A link-down/drain test can be added by toggling
  `ctrl_vif.link_up` (the scoreboard pauses naturally since it keys off observed
  handshakes).
