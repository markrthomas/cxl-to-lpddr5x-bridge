// Performance / latency characterization harness for cxl_lpddr5x_bridge.
//
// Unlike sim/sim_rand.cpp (a randomized *waveform-debug* run whose lp_in
// responder is uncorrelated noise), this harness attaches a real LPDDR5X bank /
// timing scheduler model (sim/lpddr5x_timing_model.h) as the memory side: every
// command the bridge emits on lp_out is decoded and served by the model, which
// returns the matching response on lp_in after a bank-state / timing-derived
// latency. That closes a realistic end-to-end loop, so the harness can measure:
//
//   * end-to-end request latency  (cxl_in accept -> cxl_out completion, per tag),
//   * DRAM service latency         (from the model: row hit/miss mix),
//   * throughput                   (lp_out command rate, cxl_out completion rate),
//
// under a chosen offered load and address-locality pattern. It is the perf
// harness the roadmap calls for (reuses the sim_rand beat-counter idea) and the
// engine driven by the credit / FIFO-depth sweep (sim/perf_sweep.sh).
//
// It scores no functional correctness (the directed TB + cocotb + formal own
// that). Reproducible: +seed=<N>; run length +cycles=<N> (host clk cycles);
// offered load +load=<pct>; locality +pattern=rand|stream|hotbank; egress host
// backpressure +bp=<pct>. Build/run with `make perf`.

#include "Vcxl_lpddr5x_bridge.h"
#include "verilated.h"

#include "../sim/lpddr5x_timing_model.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <queue>
#include <vector>

// ---- packet kinds / opcodes (mirror src/cxl_lpddr5x_bridge_defs.vh) ----
enum {
    KIND_MEM_RD = 0x1, KIND_MEM_WR = 0x2, KIND_MEM_MRR = 0x3, KIND_MEM_MRW = 0x4,
    KIND_LP_CMD = 0x8,
};
enum { RD_NORMAL = 0x0, RD_AUTOPRE = 0x1 };
enum { WR_NORMAL = 0x0, WR_AUTOPRE = 0x1, WR_MASKED = 0x2 };

static uint64_t pack(uint8_t kind, uint8_t code, uint8_t tag, uint16_t addr,
                     uint8_t len, uint8_t id, uint8_t aux, uint8_t misc) {
    return ((uint64_t)(kind & 0xF) << 60) | ((uint64_t)(code & 0xF) << 56) |
           ((uint64_t)tag << 48) | ((uint64_t)addr << 32) | ((uint64_t)len << 24) |
           ((uint64_t)id << 16) | ((uint64_t)aux << 8) | (uint64_t)misc;
}
static uint8_t pkt_kind(uint64_t p) { return (uint8_t)((p >> 60) & 0xF); }
static uint8_t pkt_code(uint64_t p) { return (uint8_t)((p >> 56) & 0xF); }
static uint8_t pkt_tag(uint64_t p)  { return (uint8_t)((p >> 48) & 0xFF); }
static uint16_t pkt_addr(uint64_t p){ return (uint16_t)((p >> 32) & 0xFFFF); }
static uint8_t pkt_len(uint64_t p)  { return (uint8_t)((p >> 24) & 0xFF); }
static uint8_t pkt_id(uint64_t p)   { return (uint8_t)((p >> 16) & 0xFF); }

// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8].
static uint8_t crc8_step(uint8_t b) {
    for (int i = 0; i < 8; ++i) b = (b & 0x80) ? ((b << 1) ^ 0x07) : (b << 1);
    return b;
}
static uint64_t with_checksum(uint64_t p) {
    p &= ~0xFFull;
    uint8_t c = 0;
    for (int sh = 56; sh >= 8; sh -= 8) c = crc8_step(c ^ (uint8_t)((p >> sh) & 0xFF));
    return p | c;
}

// ---- reproducible PRNG (xorshift32) ----
static uint32_t rng_state = 1;
static uint32_t xs32() {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}
static int pct(int p) { return (int)(xs32() % 100) < p; }
static uint32_t rnd(uint32_t n) { return n ? xs32() % n : 0; }

// ---- address-locality generator ------------------------------------------
// Controls the row-hit rate the memory model sees, which dominates latency and
// throughput. rand = mostly conflicts; stream = long same-row runs (high hit
// rate); hotbank = few banks/rows (bank-cycle contention).
enum { PAT_RAND = 0, PAT_STREAM = 1, PAT_HOTBANK = 2, PAT_MIXED = 3 };
struct AddrGen {
    int pattern = PAT_RAND;
    uint32_t seq = 0;
    void next(uint8_t& b, uint16_t& r, uint8_t& c) {
        switch (pattern) {
            case PAT_MIXED: {
                // Interleave ready row-HITS with blocking row-MISSES *out of
                // order*, which is exactly what a reordering scheduler exploits.
                // 70%: a "hot" access to banks 0..7, each pinned to its own home
                // row (revisits are hits); 30%: a "cold" access to banks 8..15
                // with a random far row (a miss that would stall a following hit
                // under strict in-order issue). The two bank sets are disjoint so
                // cold misses never disturb the hot banks' open rows.
                uint32_t s = seq++;
                if ((s % 10) < 3) {                       // cold: miss / bank cycling
                    b = (uint8_t)(8 + rnd(8));
                    r = (uint16_t)rnd(4096);
                    c = (uint8_t)(1 + rnd(15));
                } else {                                  // hot: home-row hit
                    b = (uint8_t)(s & 0x7);
                    r = (uint16_t)(0x100 + b);            // stable per-bank home row
                    c = (uint8_t)(1 + ((s >> 3) & 0xF));
                }
                break;
            }
            case PAT_STREAM:
                // Bank-interleaved sweep: consecutive accesses hit different banks
                // (bank-level parallelism, tCCD_S column spacing) while the row
                // advances only every 256 accesses, so each bank's open row is
                // revisited as a row HIT. Best-case locality + parallelism.
                b = (uint8_t)(seq & 0xF);
                c = (uint8_t)(1 + ((seq >> 4) & 0xF));
                r = (uint16_t)((seq >> 8) & 0x0FFF);
                ++seq;
                break;
            case PAT_HOTBANK:
                // Few banks / few rows -> constant row conflicts on those banks,
                // tRC bank-cycle contention with little parallelism.
                b = (uint8_t)rnd(4); r = (uint16_t)rnd(8); c = (uint8_t)(1 + rnd(15));
                break;
            default:  // PAT_RAND -> mostly row misses spread across all 16 banks
                b = (uint8_t)rnd(16); r = (uint16_t)rnd(4096); c = (uint8_t)(1 + rnd(15));
        }
    }
};

// Build a protocol-legal c2m request of the given kind (chosen by the caller so
// the tag partition matches). No INVALID kinds — those would leave a dangling
// outstanding entry. The address comes from the locality generator.
static uint64_t rand_c2m(AddrGen& ag, uint8_t kind, uint8_t tag) {
    uint8_t b; uint16_t r; uint8_t c;
    ag.next(b, r, c);
    uint16_t addr = (uint16_t)((b << 12) | (r & 0x0FFF));
    uint8_t id = (uint8_t)rnd(256);
    switch (kind) {
        case KIND_MEM_RD:
            return pack(KIND_MEM_RD, pct(30) ? RD_AUTOPRE : RD_NORMAL, tag, addr, c, id, 0, 0);
        case KIND_MEM_WR: {
            uint8_t op = pct(20) ? WR_AUTOPRE : (pct(15) ? WR_MASKED : WR_NORMAL);
            return pack(KIND_MEM_WR, op, tag, addr, c, id, 0, 0);
        }
        case KIND_MEM_MRR:
            return pack(KIND_MEM_MRR, 0, tag, rnd(64), 0, id, 0, 0);
        default:  // KIND_MEM_MRW
            return pack(KIND_MEM_MRW, 0, tag, rnd(64), (uint8_t)rnd(256), id, 0, 0);
    }
}

// Kinds that will yield a cxl_out completion we can time.
static bool req_completes(uint8_t k) {
    return k == KIND_MEM_RD || k == KIND_MEM_WR || k == KIND_MEM_MRR || k == KIND_MEM_MRW;
}
// Partition the tag space so a read and a non-read never share a tag: bit 7 = 1
// for read requests, 0 otherwise. Guarantees per-tag completion ordering is
// same-class, so latency correlation is unambiguous.
static uint8_t next_tag(uint8_t k) {
    static uint8_t seq_rd = 0, seq_other = 0;
    if (k == KIND_MEM_RD) return 0x80 | (seq_rd++ & 0x7F);
    return seq_other++ & 0x7F;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    uint32_t seed = 1;
    uint64_t cycles = 20000;         // host clk cycles of offered traffic
    int load = 90;                   // offered-load percent on cxl_in
    int bp = 0;                      // host egress backpressure percent on cxl_out
    int pattern = PAT_RAND;
    int sched = 0;                   // 0 = FCFS, 1 = FR-FCFS
    bool sched_given = false;        // did the caller select a policy explicitly?
    int wbuf = 0;                    // read-priority write buffer (FR-FCFS only)
    int window = 16;                 // FR-FCFS reorder lookahead window
    int starve = 0;                  // FR-FCFS anti-starvation cap (0 = off)
    for (int i = 1; i < argc; ++i) {
        if (!strncmp(argv[i], "+seed=", 6))        seed = (uint32_t)strtoul(argv[i] + 6, nullptr, 0);
        else if (!strncmp(argv[i], "+cycles=", 8)) cycles = strtoull(argv[i] + 8, nullptr, 0);
        else if (!strncmp(argv[i], "+load=", 6))   load = (int)strtol(argv[i] + 6, nullptr, 0);
        else if (!strncmp(argv[i], "+bp=", 4))     bp = (int)strtol(argv[i] + 4, nullptr, 0);
        else if (!strncmp(argv[i], "+window=", 8)) window = (int)strtol(argv[i] + 8, nullptr, 0);
        else if (!strncmp(argv[i], "+starve=", 8)) starve = (int)strtol(argv[i] + 8, nullptr, 0);
        else if (!strncmp(argv[i], "+wbuf=", 6))   wbuf = (int)strtol(argv[i] + 6, nullptr, 0);
        else if (!strncmp(argv[i], "+sched=", 7)) {
            const char* p = argv[i] + 7;
            sched = (!strcmp(p, "frfcfs") || !strcmp(p, "fr-fcfs")) ? 1 : 0;
            sched_given = true;
        }
        else if (!strncmp(argv[i], "+pattern=", 9)) {
            const char* p = argv[i] + 9;
            pattern = !strcmp(p, "stream") ? PAT_STREAM :
                      !strcmp(p, "hotbank") ? PAT_HOTBANK :
                      !strcmp(p, "mixed") ? PAT_MIXED : PAT_RAND;
        }
    }
    rng_state = seed ? seed : 1;
    const char* pat_name = pattern == PAT_STREAM ? "stream" :
                           pattern == PAT_HOTBANK ? "hotbank" :
                           pattern == PAT_MIXED ? "mixed" : "rand";
    // "fcfs" with no explicit +sched uses the model's default immediate path;
    // an explicit +sched=fcfs uses the queued scheduler with FCFS selection, so
    // it shares the identical queue/backpressure model as +sched=frfcfs (fair A/B).
    const char* sched_name = !sched_given ? "fcfs" :
                             sched ? (wbuf ? "frfcfs+wb" : "frfcfs") : "fcfs(q)";
    printf("[perf] seed=%u cycles=%llu load=%d%% bp=%d%% pattern=%s sched=%s\n",
           seed, (unsigned long long)cycles, load, bp, pat_name, sched_name);

    Vcxl_lpddr5x_bridge* dut = new Vcxl_lpddr5x_bridge;
    Lpddr5xTimingModel dram;
    if (sched_given) {
        Lpddr5xTimingModel::Policy pol;
        pol.sched = sched ? Lpddr5xTimingModel::SCHED_FRFCFS
                          : Lpddr5xTimingModel::SCHED_FCFS;
        pol.reorder_window = window > 0 ? window : 1;
        pol.starve_cap = starve;
        pol.write_buffer = wbuf != 0;
        dram.set_policy(pol);
    }
    AddrGen ag; ag.pattern = pattern;

    dut->rst_n = 0; dut->clk = 0; dut->mem_clk = 0;
    dut->link_up = 0; dut->err_inj_en = 0;
    dut->cxl_in_valid = 0; dut->cxl_in_data = 0;
    dut->lp_in_valid = 0; dut->lp_in_data = 0;
    dut->lp_out_ready = 1;              // DRAM command bus always accepts a command
    dut->cxl_out_ready = 1;
    dut->eval();

    const int CLK_H = 5;               // clk half-period (period 10)
    const int MEM_H = 7;               // mem_clk half-period (period 14, async)
    // Run offered traffic for `cycles`, then drain outstanding before reporting.
    const uint64_t T_TRAFFIC = cycles * (2 * CLK_H);
    const uint64_t T_DRAIN   = 200000ull * MEM_H;   // generous safety cap
    const uint64_t T_END     = T_TRAFFIC + T_DRAIN;

    int prev_clk = 0, prev_mem = 0;
    long clk_cyc = 0, mem_cyc = 0;
    int prev_cxl_in_ready = 0, prev_lp_in_ready = 0;

    // Per-tag FIFO of accept-times (host clk cycles) for latency correlation.
    std::queue<long> outstanding[256];
    long n_out = 0;

    // Counters / stats.
    long c2m_offered = 0, c2m_accepted = 0;
    long lp_out_beats = 0, cxl_out_beats = 0;
    long clk_active_start = -1, clk_active_end = 0;
    long mem_active_start = -1, mem_active_end = 0;
    std::vector<long> e2e;             // end-to-end latencies (host clk cycles)
    e2e.reserve(1 << 16);

    bool traffic_on = true;

    for (uint64_t t = 1; t < T_END && !Verilated::gotFinish(); ++t) {
        int clk = (int)((t / CLK_H) & 1);
        int mem = (int)((t / MEM_H) & 1);

        if (clk_cyc >= 20) dut->rst_n = 1;
        dut->link_up = (clk_cyc >= 40) ? 1 : 0;

        // Stop offering new traffic after the traffic window; keep clocking to
        // drain what's in flight, then finish once everything has completed.
        if (t >= T_TRAFFIC) traffic_on = false;

        dut->clk = clk; dut->mem_clk = mem;
        dut->eval();

        int clk_rise = (clk == 1 && prev_clk == 0);
        int mem_rise = (mem == 1 && prev_mem == 0);

        if (clk_rise) {
            ++clk_cyc;
            // Egress completion side (host domain).
            dut->cxl_out_ready = (bp && pct(bp)) ? 0 : 1;
            if (dut->cxl_out_valid && dut->cxl_out_ready) {
                ++cxl_out_beats;
                uint8_t tg = pkt_tag(dut->cxl_out_data);
                if (!outstanding[tg].empty()) {
                    long t0 = outstanding[tg].front(); outstanding[tg].pop();
                    e2e.push_back(clk_cyc - t0);
                    --n_out;
                }
                if (clk_active_start < 0) clk_active_start = clk_cyc;
                clk_active_end = clk_cyc;
            }
            // Ingress request side (host domain): offered load, protocol-legal.
            int accepted = dut->cxl_in_valid && prev_cxl_in_ready;
            if (accepted) {
                ++c2m_accepted;
                uint8_t k = pkt_kind(dut->cxl_in_data);
                if (req_completes(k)) { outstanding[pkt_tag(dut->cxl_in_data)].push(clk_cyc); ++n_out; }
            }
            if (!dut->cxl_in_valid || accepted) {
                int active = traffic_on && (clk_cyc >= 45);
                int drive = active && pct(load);
                dut->cxl_in_valid = drive;
                if (drive) {
                    // Choose kind first so the tag partition matches the kind.
                    uint32_t pk = rnd(100);
                    uint8_t k = pk < 48 ? KIND_MEM_RD : pk < 90 ? KIND_MEM_WR :
                                pk < 95 ? KIND_MEM_MRR : KIND_MEM_MRW;
                    dut->cxl_in_data = rand_c2m(ag, k, next_tag(k));
                    ++c2m_offered;
                }
            }
        }

        if (mem_rise) {
            ++mem_cyc;
            dram.tick(mem_cyc);   // advance the (FR-FCFS) scheduler even if lp_in stalls
            // Command egress (mem domain). lp_out_ready in effect for this edge was
            // set on the previous mem cycle (below), so the handshake is consistent
            // with what the bridge sampled.
            if (dut->lp_out_valid && dut->lp_out_ready) {
                ++lp_out_beats;
                uint64_t f = dut->lp_out_data;
                if (pkt_kind(f) == KIND_LP_CMD) {
                    LpCmd c;
                    c.op   = pkt_code(f);
                    c.tag  = pkt_tag(f);
                    c.id   = pkt_id(f);
                    uint16_t a = pkt_addr(f);
                    c.bank = (uint8_t)((a >> 12) & 0xF);
                    c.row  = (uint16_t)(a & 0x0FFF);
                    c.col  = pkt_len(f);
                    dram.accept(c, mem_cyc);
                }
                if (mem_active_start < 0) mem_active_start = mem_cyc;
                mem_active_end = mem_cyc;
            }
            // Response ingress (mem domain): deliver a due response when lp_in is
            // free (respect the handshake / hold protocol).
            int m_accepted = dut->lp_in_valid && prev_lp_in_ready;
            if (!dut->lp_in_valid || m_accepted) {
                LpResp r;
                if (dram.due(mem_cyc, r)) {
                    uint64_t p = pack(r.kind, r.status, r.tag, r.byte_count, r.length, r.id, 0, 0);
                    dut->lp_in_data = with_checksum(p);
                    dut->lp_in_valid = 1;
                } else {
                    dut->lp_in_valid = 0;
                }
            }
            // Controller-queue backpressure for the NEXT edge: deassert lp_out_ready
            // when the model's schedule horizon is a full queue ahead of now.
            dut->lp_out_ready = dram.can_accept(mem_cyc) ? 1 : 0;
        }

        prev_clk = clk; prev_mem = mem;
        prev_cxl_in_ready = dut->cxl_in_ready;
        prev_lp_in_ready = dut->lp_in_ready;

        // Early finish: traffic done and everything drained.
        if (!traffic_on && n_out == 0 && !dram.has_pending()) break;
    }

    dut->final();

    // ---- report ----
    std::sort(e2e.begin(), e2e.end());
    auto pctl = [&](double q) -> long {
        if (e2e.empty()) return 0;
        size_t idx = (size_t)(q * (e2e.size() - 1) + 0.5);
        return e2e[idx];
    };
    long e2e_sum = 0; for (long v : e2e) e2e_sum += v;
    double e2e_mean = e2e.empty() ? 0.0 : (double)e2e_sum / e2e.size();
    long e2e_max = e2e.empty() ? 0 : e2e.back();

    const auto& ms = dram.stats();
    double hit_rate = ms.n_cmd ? 100.0 * ms.n_hit / ms.n_cmd : 0.0;
    double svc_mean = ms.n_cmd ? (double)ms.sum_service / ms.n_cmd : 0.0;

    long clk_span = (clk_active_start < 0) ? 1 : (clk_active_end - clk_active_start + 1);
    long mem_span = (mem_active_start < 0) ? 1 : (mem_active_end - mem_active_start + 1);

    printf("\n==================== cxl_lpddr5x_bridge perf ====================\n");
    printf("config        : seed=%u load=%d%% bp=%d%% pattern=%s sched=%s\n",
           seed, load, bp, pat_name, sched_name);
    printf("cycles        : %ld clk / %ld mem_clk\n", clk_cyc, mem_cyc);
    printf("--- traffic -----------------------------------------------------\n");
    printf("c2m offered   : %ld\n", c2m_offered);
    printf("c2m accepted  : %ld  (%.1f%% of offered)\n",
           c2m_accepted, c2m_offered ? 100.0 * c2m_accepted / c2m_offered : 0.0);
    printf("completions   : %ld\n", (long)e2e.size());
    printf("--- DRAM model (bank/timing) ------------------------------------\n");
    printf("commands      : %ld  (row hit %.1f%% / miss %ld / empty %ld)\n",
           ms.n_cmd, hit_rate, ms.n_miss, ms.n_empty);
    printf("mem residency : mean %.1f  max %ld  (mem_clk cycles, service->ready)\n",
           svc_mean, ms.max_service);
    if (sched_given) {
        printf("scheduler     : %s  reorders %ld  write-drains %ld  peak-queue %ld\n",
               sched_name, ms.n_reorder, ms.n_wr_drain, ms.max_queue);
    }
    printf("--- throughput --------------------------------------------------\n");
    printf("lp_out cmds   : %ld beats / %ld mem_clk = %.3f cmd/mem_cyc\n",
           lp_out_beats, mem_span, (double)lp_out_beats / mem_span);
    printf("cxl_out cpl   : %ld beats / %ld clk = %.3f cpl/clk_cyc\n",
           cxl_out_beats, clk_span, (double)cxl_out_beats / clk_span);
    printf("--- end-to-end latency (host clk cycles) ------------------------\n");
    if (e2e.empty()) {
        printf("(no completions measured)\n");
    } else {
        printf("min %ld  mean %.1f  p50 %ld  p95 %ld  p99 %ld  max %ld\n",
               e2e.front(), e2e_mean, pctl(0.50), pctl(0.95), pctl(0.99), e2e.back());
    }
    printf("=================================================================\n");
    // Machine-readable one-liner for the sweep to parse.
    printf("[perf-csv] pattern=%s sched=%s load=%d bp=%d completions=%ld hit_pct=%.1f "
           "svc_mean=%.1f lp_out_tput=%.3f cxl_out_tput=%.3f e2e_mean=%.1f "
           "e2e_p95=%ld e2e_p99=%ld e2e_max=%ld reorders=%ld\n",
           pat_name, sched_name, load, bp, (long)e2e.size(), hit_rate, svc_mean,
           (double)lp_out_beats / mem_span, (double)cxl_out_beats / clk_span,
           e2e_mean, pctl(0.95), pctl(0.99), e2e_max, ms.n_reorder);

    delete dut;
    return 0;
}
