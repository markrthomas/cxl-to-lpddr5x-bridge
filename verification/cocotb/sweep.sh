#!/bin/bash
set -e

# Parameter sweep script for cxl_lpddr5x_bridge cocotb tests.
# Sweeps FIFO_DEPTH and credit settings to flush out off-by-one bugs.

SIM=icarus
LOG_DIR=sweep_logs
mkdir -p $LOG_DIR

# Combinations of (FIFO_DEPTH, CREDITS)
# Note: async_fifo requires DEPTH to be power-of-two and >= 4. 
# Wait, PLAN.md said {2, 8}. If async_fifo requires >= 4, I'll use {4, 8}.
# Let me check async_fifo.v again.
# "DEPTH must be a power of two and >= 4." -> Okay, {4, 8}.

DEPTHS="4 8"
CREDITS="1 8"

for d in $DEPTHS; do
    for c in $CREDITS; do
        echo "===================================================="
        echo "Running sweep: FIFO_DEPTH=$d, CREDITS=$c"
        echo "===================================================="
        
        COMPILE_ARGS="-g2005-sv -I../../src -P cxl_lpddr5x_bridge.FIFO_DEPTH=$d -P cxl_lpddr5x_bridge.POSTED_CREDITS=$c -P cxl_lpddr5x_bridge.NP_CREDITS=$c -P cxl_lpddr5x_bridge.RSP_CREDITS=$c" \
        make -C . SIM=$SIM clean sim > $LOG_DIR/sweep_d${d}_c${c}.log 2>&1
        
        if [ $? -eq 0 ]; then
            echo "PASS: d=$d, c=$c"
        else
            echo "FAIL: d=$d, c=$c (see $LOG_DIR/sweep_d${d}_c${c}.log)"
            exit 1
        fi
    done
done

echo "Parameter sweep completed successfully!"
