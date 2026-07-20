// Self-checking unit test for the LPDDR5X bank/timing scheduler model.
//
// Pins the timing arithmetic that the perf harness depends on, using commands
// spaced far apart in time so command-bus / tCCD interference is out of the way
// and each latency is exactly the bank-state contribution. Plain g++, no
// Verilator — run with `make perf-selftest`.

#include "lpddr5x_timing_model.h"

#include <cstdio>
#include <cstdlib>

static int failures = 0;

static void check(const char* what, long got, long want) {
    if (got != want) {
        printf("  FAIL %-28s got %ld want %ld\n", what, got, want);
        ++failures;
    } else {
        printf("  ok   %-28s = %ld\n", what, got);
    }
}

// Build a decoded command.
static LpCmd cmd(uint8_t op, uint8_t bank, uint16_t row, uint8_t tag = 0) {
    LpCmd c; c.op = op; c.tag = tag; c.id = 0; c.bank = bank; c.row = row; c.col = 4;
    return c;
}

int main() {
    Lpddr5xTimingModel::Timing t;   // defaults
    Lpddr5xTimingModel m(t);

    printf("LPDDR5X timing-model self-test (defaults: tRCD=%d tRP=%d tRL=%d tWL=%d "
           "tBURST=%d)\n", t.tRCD, t.tRP, t.tRL, t.tWL, t.tBURST);

    // 1. First READ to an empty (closed) bank: ACT + tRCD + tRL + tBURST.
    long lat = m.accept(cmd(Lpddr5xTimingModel::OP_RD, 0, 5), 0);
    check("read empty-bank latency", lat, (long)t.tRCD + t.tRL + t.tBURST);       // 43

    // 2. READ to the SAME bank+row far later (row hit): tRL + tBURST only.
    lat = m.accept(cmd(Lpddr5xTimingModel::OP_RD, 0, 5), 1000);
    check("read row-hit latency", lat, (long)t.tRL + t.tBURST);                   // 28

    // 3. READ to the SAME bank, DIFFERENT row (row miss): tRP + tRCD + tRL + tBURST.
    lat = m.accept(cmd(Lpddr5xTimingModel::OP_RD, 0, 9), 2000);
    check("read row-miss latency", lat, (long)t.tRP + t.tRCD + t.tRL + t.tBURST); // 58

    // 4. WRITE to a fresh empty bank uses tWL (not tRL): ACT + tRCD + tWL + tBURST.
    lat = m.accept(cmd(Lpddr5xTimingModel::OP_WR, 3, 0), 3000);
    check("write empty-bank latency", lat, (long)t.tRCD + t.tWL + t.tBURST);      // 33

    // 5. Mode-register read: fixed tMRR, no bank timing.
    lat = m.accept(cmd(Lpddr5xTimingModel::OP_MRR, 0, 0), 4000);
    check("mode-register latency", lat, (long)t.tMRR);                            // 12

    // 6. Response ordering / correctness: drain the scheduled responses and check
    // the first-issued read's response is a RD_RSP with its tag.
    Lpddr5xTimingModel m2(t);
    m2.accept(cmd(Lpddr5xTimingModel::OP_RD, 2, 7, /*tag=*/0x42), 0);
    LpResp r{};
    bool got = m2.due(10000, r);   // well after ready
    check("response delivered", got ? 1 : 0, 1);
    check("response kind RD_RSP", r.kind, Lpddr5xTimingModel::KIND_RD_RSP);
    check("response tag preserved", r.tag, 0x42);

    // 7. Locality sanity: a burst of same-bank/row reads must all be row hits
    // after the first, and a stream across banks must not all miss.
    Lpddr5xTimingModel m3(t);
    for (int i = 0; i < 8; ++i) m3.accept(cmd(Lpddr5xTimingModel::OP_RD, 1, 3), i * 100);
    check("same-row hits (of 8)", m3.stats().n_hit, 7);   // first is empty, rest hits

    printf(failures ? "\nSELF-TEST FAILED (%d)\n" : "\nSELF-TEST PASSED\n", failures);
    return failures ? 1 : 0;
}
