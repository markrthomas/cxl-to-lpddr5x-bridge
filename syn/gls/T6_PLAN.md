# T6 — GLS + PPA plan (cxl_lpddr5x_bridge)

T6 is the post-synthesis sign-off: prove the **gate netlist** is functionally correct and
characterise its **PPA**. Adopted from the shared sign-off kit (`dv-swarm-kit/templates/signoff`),
pathfound on `IP-axi-to-2apbs`.

## What runs here (OSS, no PDK) — real artifacts

| Step | Command | Artifact | Status |
|------|---------|----------|--------|
| **PPA proxy** | `make ppa` (`syn/ppa/ppa.sh`) | `syn/ppa/reports/cxl_lpddr5x_bridge.ppa.rpt` | **PASS** — generic cells ≈ 5204, flip-flops ≈ 1558, logic depth (`ltp`) ≈ 137. |
| **Zero-delay GLS** | `make gls` (`syn/gls/gls.sh`) | `syn/gls/reports/cxl_lpddr5x_bridge.gls.log` | **Does not close under OSS generic synth** — see the finding below. Not wired into the CI green path; the capability is authored here, the clean run is `needs-pdk`. |

## T6-GLS finding — unreset dual-clock-RAM X-pessimism (OSS generic synth)

Running the directed `tb_cxl_lpddr5x_bridge` against the Yosys generic-gate netlist fails
with (reproducible):

```
FAIL: smoke mem_wr got X322400004e5a384
```

i.e. the MSB nibble of `lp_out_data` reads **X**. Root cause, confirmed by inspection:

- The block crosses two clock domains (`clk` / `mem_clk`) through `async_fifo`, whose storage
  is a **true dual-clock RAM** (write on one clock, read on another). Yosys cannot keep a
  dual-clock memory as a single-clock `$mem`, so `synth` lowers it to **registers**
  ("Replacing memory \mem with list of registers"). Those registers have **no reset** (a
  FIFO RAM is written-before-read by protocol, not reset), and the netlist carries **no
  `initial`** values (synthesizable RTL has none — confirmed with and without `-noattr`).
- In zero-delay GLS the unreset RAM powers up X, and the combinational read path lets an
  unwritten-entry X bleed into the upper data field → the X nibble.

This is **X-pessimism of the OSS generic-synth lowering, not a design bug**: the RTL
directed sim and the SymbiYosys formal proofs pass, so the protocol provably never reads an
unwritten entry. The sibling CDC block `axi4_to_dfi_ddr` (also dual-clock, also
register-lowered) passes GLS — this is specific to how this FIFO's read path exposes the
unwritten upper bits in the smoke test, not a template problem.

**Not forced green** (doctrine: never weaken a gate; a skip/fail is not a pass). The clean
sign-off is the `needs-pdk` path below — SDF GLS on a Liberty-mapped netlist with a real
compiled-RAM model (which defines power-up state and controls X), or the same OSS flow once
a controlled RAM-init / X-pessimism sequence is agreed with the design owner.

## What is deferred — `needs-pdk`

1. **Liberty-mapped synthesis** with a real SRAM/register-file macro for the FIFO (defined
   power-up state), vs the generic register-lowering here.
2. **SDF-annotated (timing) GLS** across `clk`/`mem_clk` with `$sdf_annotate`.
3. **STA sign-off** — OpenSTA/PrimeTime + Liberty + `syn/constraints/cxl_lpddr5x.sdc` (T2);
   CDC paths covered by the T1-CDC audit (`make cdc`).
4. **Area + power** — post-P&R µm²/mW.
5. **RTL↔netlist LEC** — Conformal/Formality (OSS `yosys equiv` does not close on the
   generic netlist).
