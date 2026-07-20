#!/usr/bin/env bash
# Latency / throughput characterization sweep for cxl_lpddr5x_bridge.
#
# Drives the LPDDR5X bank/timing perf harness (make perf) across a grid of
# credit + FIFO-depth settings and address-locality patterns, re-elaborating the
# DUT for each credit/FIFO point, and tabulates the achieved command throughput
# and end-to-end latency. Shows the latency/throughput knee (small credits limit
# throughput; large credits only add queueing) and the locality effect (stream
# vs rand vs hotbank).
#
# Usage:  make perf-sweep   (or  sim/perf_sweep.sh)
# Env knobs: SWEEP_CYCLES (default 12000), SWEEP_LOAD (90), SWEEP_SEED (1),
#            SWEEP_DEPTHS ("4 8 16 32"), SWEEP_PATTERNS ("rand stream hotbank").
# (FIFO_DEPTH must be a power of two and >= 4 — the async FIFO asserts otherwise.)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v verilator >/dev/null 2>&1; then
    echo "[PERF-SWEEP] verilator not on PATH; skipping"
    exit 0
fi

CYCLES="${SWEEP_CYCLES:-12000}"
LOAD="${SWEEP_LOAD:-90}"
SEED="${SWEEP_SEED:-1}"
DEPTHS="${SWEEP_DEPTHS:-4 8 16 32}"
PATTERNS="${SWEEP_PATTERNS:-rand stream hotbank}"

echo "cxl_lpddr5x_bridge — latency/throughput sweep"
echo "  cycles=$CYCLES load=${LOAD}% seed=$SEED"
echo "  credit=FIFO depths: $DEPTHS   patterns: $PATTERNS"
echo
printf "%-8s %6s %8s %8s %9s %9s %9s %9s\n" \
    pattern cred hit% cmd/cyc cpl/cyc e2e_mean e2e_p95 e2e_p99
printf -- "------------------------------------------------------------------------\n"

# Parse a "key=value key=value" line into a shell-eval-safe assoc lookup.
field() { sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p"; }

for pat in $PATTERNS; do
    for d in $DEPTHS; do
        # Credits capped by FIFO depth (occupancy-based credits). Keep credits ==
        # FIFO depth so both scale together; that is the interesting design axis.
        params="-GFIFO_DEPTH=$d -GPOSTED_CREDITS=$d -GNP_CREDITS=$d -GRSP_CREDITS=$d"
        line="$(make perf PERF_PARAMS="$params" PERF_CYCLES="$CYCLES" \
                     PERF_LOAD="$LOAD" PERF_SEED="$SEED" PERF_PATTERN="$pat" 2>/dev/null \
                | grep '^\[perf-csv\]' || true)"
        if [ -z "$line" ]; then
            printf "%-8s %6s %8s\n" "$pat" "$d" "(no result — check FIFO_DEPTH legality)"
            continue
        fi
        hit="$(echo "$line"   | field hit_pct)"
        lpt="$(echo "$line"   | field lp_out_tput)"
        cpt="$(echo "$line"   | field cxl_out_tput)"
        em="$(echo "$line"    | field e2e_mean)"
        p95="$(echo "$line"   | field e2e_p95)"
        p99="$(echo "$line"   | field e2e_p99)"
        printf "%-8s %6s %8s %8s %9s %9s %9s %9s\n" \
            "$pat" "$d" "$hit" "$lpt" "$cpt" "$em" "$p95" "$p99"
    done
    printf -- "------------------------------------------------------------------------\n"
done

echo
echo "cmd/cyc = lp_out command throughput (per mem_clk); cpl/cyc = cxl_out"
echo "completion throughput (per host clk); e2e_* = end-to-end latency (host clk)."
