# pkg/ — IP packaging (tapeout-readiness T7)

Packaging deliverables for the CXL ↔ LPDDR5X bridge. Adopted from the shared sign-off kit
(`dv-swarm-kit/templates/signoff/pkg`), pathfound on `IP-axi-to-2apbs`.

## Contents

| Path | What |
|---|---|
| `ip-xact/cxl_lpddr5x_bridge.xml` | IP-XACT (IEEE 1685-2014) component (22 ports; 4 DataStream channels + 2 clocks + 1 reset; parameters). |
| `INTEGRATION.md` | Integration guide: interfaces, clock/reset/power (CDC), sideband, parameter/config matrix. |
| `check_ipxact.sh` | The `make pkg` gate: well-formed + structural + IP-XACT↔RTL port-sync. |

## Run the gate

```
make pkg          # xmllint well-formed + structural + model-ports-match-RTL (22)
IPXACT_XSD=/path/to/1685-2014/index.xsd make pkg   # + full XSD schema validation
```

`make pkg` is wired into CI and fails on any drift between the IP-XACT model ports and the RTL.

## Scope

OSS, no-PDK packaging layer. Real-silicon collateral needing a PDK or licensed tool is
tracked in [`../syn/SIGNOFF.md`](../syn/SIGNOFF.md). Note T6-GLS does not close under OSS
generic synth for this block (see `../syn/gls/T6_PLAN.md`).
