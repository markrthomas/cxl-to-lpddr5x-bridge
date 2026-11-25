# PPA plan (cxl_lpddr5x_bridge)

PPA is part of the T6 sign-off. The full plan — what runs OSS here (`make ppa`) and what is
deferred as `needs-pdk` — lives in [`../gls/T6_PLAN.md`](../gls/T6_PLAN.md).

`make ppa` emits, to `syn/ppa/reports/cxl_lpddr5x_bridge.ppa.rpt`:
- **area proxy** — generic cell count (≈ 5204) + flip-flop count (≈ 1558), post-synth, flattened;
- **timing proxy** — longest topological logic path (`ltp`), i.e. combinational depth (≈ 137).

Tracked baselines that move monotonically with the real post-PDK numbers.
