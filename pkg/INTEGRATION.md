# Integration guide — CXL ↔ LPDDR5X bridge

Tapeout-readiness program **T7** (integration / packaging) deliverable. This guide + the
IP-XACT in `ip-xact/` are what an SoC integrator needs to instance the IP. The IP-XACT port
list is kept in sync with the RTL by `make pkg`.

## IP

| Top (module / IP-XACT name) | What |
|---|---|
| `cxl_lpddr5x_bridge` | Credit-based CXL ↔ LPDDR5X streaming bridge with a `clk`↔`mem_clk` clock-domain crossing, drain/reset sequencing, and CRC/occupancy telemetry. |

## Interfaces

| Interface | Role | Signals |
|---|---|---|
| `CXL_RX` | stream **consumer** (slave) | `cxl_in_valid` / `cxl_in_data[WIDTH-1:0]` / `cxl_in_ready` |
| `LP_TX`  | stream **producer** (master) | `lp_out_valid` / `lp_out_data[WIDTH-1:0]` / `lp_out_ready` |
| `LP_RX`  | stream **consumer** (slave) | `lp_in_valid` / `lp_in_data[WIDTH-1:0]` / `lp_in_ready` |
| `CXL_TX` | stream **producer** (master) | `cxl_out_valid` / `cxl_out_data[WIDTH-1:0]` / `cxl_out_ready` |
| `clk` / `mem_clk` | clocks | **Two domains** — the CXL↔mem crossing is the block's CDC (gated by `make cdc`, T1-CDC). |
| `rst_n` | reset | Active-low, asynchronous assert. |
| sideband | status / control | in: `link_up`, `err_inj_en`; out: `drain_done`, `crc_err_cnt[15:0]`, `drain_cnt[15:0]`, `max_occ_c2m[7:0]`, `max_occ_m2c[7:0]`. |

## Clock / reset / power

- **Clocks:** `clk` (CXL domain) and `mem_clk` (LPDDR5X/mem domain). Every crossing goes
  through a sanctioned synchronizer (`async_fifo`, `cdc_sync`, `credit_pulse_sync`) — asserted
  by `make cdc` (T1-CDC). Constrain both with `../syn/constraints/cxl_lpddr5x.sdc` (T2).
- **Reset:** `rst_n` async active-low (`reset_sync` / `reset_drain` sequence the drain);
  false-path in the SDC; drive from the SoC reset controller.
- **Power:** the T3 power intent (`../syn/lp/cxl_lpddr5x.upf`) models the domains; if the SoC
  does not power-gate this IP, tie into a single always-on domain.

## Address / register map

No memory-mapped CSR block — the bridge is a streaming datapath. Control/status is the
**sideband** (`link_up`, `err_inj_en` in; `drain_done`, `crc_err_cnt`, `drain_cnt`,
`max_occ_*` out), documented above; there is no CSR RAL to generate. Credit depths are set
by the `*_CREDITS` / `FIFO_DEPTH` parameters, not an address-mapped register.

## Parameters / configuration matrix

| Parameter | Default | Meaning |
|---|---|---|
| `WIDTH` | 64 | CXL/LPDDR5X stream data width |
| `FIFO_DEPTH` | 8 | CDC async-FIFO depth (power of two, ≥ 4) |
| `POSTED_CREDITS` / `NP_CREDITS` / `RSP_CREDITS` | 8 / 8 / 8 | credit allocation per class |

## Consuming the package

- **IP-XACT** (`ip-xact/cxl_lpddr5x_bridge.xml`): IEEE 1685-2014 component — four
  `DataStream` valid/ready/data bus interfaces (CXL_RX, LP_TX, LP_RX, CXL_TX), two clocks,
  one reset, the full 22-port model, and the parameter set. Clocks/reset reference the AMBA
  defs by VLNV; the stream interfaces reference a vendor `DataStream` def.
- **RTL** source is referenced from the component's `fileSet`.
- **Validate** with `make pkg` (`pkg/check_ipxact.sh`): well-formed + structural + a hard
  IP-XACT↔RTL model-port match (22 ports; fails on drift). Full XSD: `make pkg-xsd`.

## Sign-off cross-reference

See [`../syn/SIGNOFF.md`](../syn/SIGNOFF.md) for T0–T7. T6 zero-delay GLS passes (the
earlier failure was a TB sampling race, see `../syn/gls/T6_PLAN.md`). **Integrator note:**
sample `lp_out_*` / `cxl_out_*` at a clock edge, not on a `valid` event: valid and data
settle in the same timestep. Full XSD: `make pkg-xsd`. Real STA / SDF GLS / PPA /
scan+ATPG / power-aware sim are tagged there.
