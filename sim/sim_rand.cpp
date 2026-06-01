// Randomized waveform-debug harness for cxl_lpddr5x_bridge.
//
// Unlike sim/sim_main.cpp (a fixed walk tuned for coverage / SVA gates), this
// driver throws *randomized but protocol-legal* traffic at the bridge and dumps
// a VCD meant to be opened in GTKWave and read by a human: random opcode mix,
// random valid gaps, random sink backpressure on both egress ports, link-down
// drain windows, and random error-injection pulses. It is short by design (a few
// thousand host cycles) so the trace stays navigable.
//
// To keep the completion path lively, m2c responses mostly carry the tag of an
// actually-outstanding request (so the bridge emits a real completion on
// cxl_out); a minority are unmatched / error / CRC-corrupt flits to exercise
// those paths too.
//
// It does NOT score correctness (the directed TB + cocotb own that). Instead it
// prints cycle-stamped *event markers* — sustained ingress backpressure, link
// up/down, drain_done, error-injection pulses — so you can jump straight to the
// interesting region in the waveform.
//
// Reproducible: the seed is printed at startup and settable with +seed=<N>; the
// run length is settable with +cycles=<N> (host clk cycles). Build/run with
// `make vlt-rand` (Verilator --trace + --assert: the interface SVA is live, so a
// protocol violation aborts the run and you still have the VCD up to that point).
//
// Run from the Verilator --Mdir; writes waves.vcd there (override with +vcd=).

#include "Vcxl_lpddr5x_bridge.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ---- packet kinds / opcodes (mirror src/cxl_lpddr5x_bridge_defs.vh) ----
enum {
    KIND_MEM_RD = 0x1, KIND_MEM_WR = 0x2, KIND_MEM_MRR = 0x3, KIND_MEM_MRW = 0x4,
    KIND_RD_RSP = 0xa, KIND_WR_RSP = 0xb, KIND_MRR_RSP = 0xc, KIND_LP_ERROR = 0xe,
    KIND_INVALID = 0xf,
};
enum { RD_NORMAL = 0x0, RD_AUTOPRE = 0x1 };
enum { WR_NORMAL = 0x0, WR_AUTOPRE = 0x1, WR_MASKED = 0x2 };
enum { RSP_OK = 0x1, RSP_ERR = 0x2 };

static uint64_t pack(uint8_t kind, uint8_t code, uint8_t tag, uint16_t addr,
                     uint8_t len, uint8_t id, uint8_t aux, uint8_t misc) {
    return ((uint64_t)(kind & 0xF) << 60) | ((uint64_t)(code & 0xF) << 56) |
           ((uint64_t)tag << 48) | ((uint64_t)addr << 32) | ((uint64_t)len << 24) |
           ((uint64_t)id << 16) | ((uint64_t)aux << 8) | (uint64_t)misc;
}
static uint8_t pkt_kind(uint64_t p) { return (uint8_t)((p >> 60) & 0xF); }
static uint8_t pkt_tag(uint64_t p)  { return (uint8_t)((p >> 48) & 0xFF); }

// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8]; matches
// bridge_checksum / crc8_step in the defs header and the gold models.
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

// ---- self-contained reproducible PRNG (xorshift32; independent of libc) ----
static uint32_t rng_state = 1;
static uint32_t xs32() {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}
static int pct(int p) { return (int)(xs32() % 100) < p; }            // true p% of the time
static uint32_t rnd(uint32_t n) { return n ? xs32() % n : 0; }       // [0, n)

// ---- outstanding-request tracking ----------------------------------------
// Ring of (tag, expected response kind) for accepted requests. m2c flow itself is
// credit-gated (lp_in_ready = bridge_open_mem && !m2c_w_full && rsp_crd_avail),
// not tag-matched -- so this is purely for *trace coherence*: responses mostly
// carry a tag/kind of a real recent request, so a completion you see on cxl_out
// can be traced back to its request on cxl_in.
struct Outstanding { uint8_t tag; uint8_t resp_kind; };
static Outstanding out_ring[256];
static int out_head = 0, out_count = 0;
static void out_push(uint8_t tag, uint8_t resp_kind) {
    out_ring[(out_head + out_count) & 0xFF] = {tag, resp_kind};
    if (out_count < 256) ++out_count;
    else out_head = (out_head + 1) & 0xFF;   // full: drop oldest
}

// A random, protocol-legal c2m request. ~6% of the time emits an INVALID kind
// (exercises the bridge's bad-opcode path); the rest pick a real kind + a legal
// sub-op. Ingress flits are left unchecksummed (the bridge recomputes the CRC),
// matching the gold producer in sim_main.cpp.
static uint64_t rand_c2m() {
    uint8_t tag  = (uint8_t)rnd(256);
    uint16_t addr = (uint16_t)rnd(0x10000);
    uint8_t len  = (uint8_t)(1 + rnd(16));
    uint8_t id   = (uint8_t)rnd(256);
    if (pct(6)) return pack(KIND_INVALID, rnd(16), tag, addr, len, id, 0, 0);
    switch (rnd(4)) {
        case 0: return pack(KIND_MEM_RD,  pct(50) ? RD_AUTOPRE : RD_NORMAL, tag, addr, len, id, 0, 0);
        case 1: { uint8_t op = (uint8_t)rnd(3); // NORMAL / AUTOPRE / MASKED
                  return pack(KIND_MEM_WR, op, tag, addr, len, id, op == WR_MASKED ? (uint8_t)rnd(256) : 0, 0); }
        case 2: return pack(KIND_MEM_MRR, 0, tag, rnd(64), 0, id, 0, 0);
        default: return pack(KIND_MEM_MRW, 0, tag, rnd(64), (uint8_t)rnd(256), id, 0, 0);
    }
}

// Response kind the bridge expects back for a given request kind.
static uint8_t resp_kind_for(uint8_t req_kind) {
    switch (req_kind) {
        case KIND_MEM_RD:  return KIND_RD_RSP;
        case KIND_MEM_MRR: return KIND_MRR_RSP;
        case KIND_MEM_WR:
        case KIND_MEM_MRW: return KIND_WR_RSP;
        default:           return 0;            // INVALID / unknown: no completion
    }
}

// A random m2c response, checksummed. Mostly answers a real outstanding request
// (matching kind/tag) so the completion fires; the rest are unmatched flits,
// ERROR flits, RSP_ERR codes, and (~8%) a CRC-corrupted flit -> INVALID path.
static uint64_t rand_m2c() {
    uint8_t id = (uint8_t)rnd(256);
    uint64_t p;
    if (out_count && pct(75)) {
        Outstanding o = out_ring[(out_head + rnd(out_count)) & 0xFF];
        if (o.resp_kind == KIND_MRR_RSP) p = pack(o.resp_kind, RSP_OK, o.tag, 0x0002, 0, id, 0, 0);
        else p = pack(o.resp_kind, pct(20) ? RSP_ERR : RSP_OK, o.tag, 0x0040, 1 + rnd(16), id, 0, 0);
    } else if (pct(60)) {
        p = pack(KIND_RD_RSP, RSP_OK, (uint8_t)rnd(256), 0x0040, 1 + rnd(16), id, 0, 0); // unmatched
    } else {
        p = pack(KIND_LP_ERROR, 0, (uint8_t)rnd(256), 0, 0, 0, 0, 0);                    // error flit
    }
    p = with_checksum(p);
    if (pct(8)) p ^= (1ull << (8 + rnd(48)));  // flip a header bit -> bad CRC
    return p;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    uint32_t seed = 7;
    uint64_t cycles = 3000;          // host clk cycles to run
    const char* vcd_path = "waves.vcd";
    for (int i = 1; i < argc; ++i) {
        if (!strncmp(argv[i], "+seed=", 6))        seed = (uint32_t)strtoul(argv[i] + 6, nullptr, 0);
        else if (!strncmp(argv[i], "+cycles=", 8)) cycles = strtoull(argv[i] + 8, nullptr, 0);
        else if (!strncmp(argv[i], "+vcd=", 5))    vcd_path = argv[i] + 5;
    }
    rng_state = seed ? seed : 1;     // 0 would freeze xorshift
    printf("[sim_rand] seed=%u cycles=%llu vcd=%s\n",
           seed, (unsigned long long)cycles, vcd_path);

    Vcxl_lpddr5x_bridge* dut = new Vcxl_lpddr5x_bridge;
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open(vcd_path);

    dut->rst_n = 0;
    dut->clk = 0;
    dut->mem_clk = 0;
    dut->link_up = 0;
    dut->err_inj_en = 0;
    dut->cxl_in_valid = 0;
    dut->cxl_in_data = 0;
    dut->lp_in_valid = 0;
    dut->lp_in_data = 0;
    dut->lp_out_ready = 1;
    dut->cxl_out_ready = 1;
    dut->eval();

    const int CLK_H = 5;             // clk half-period (period 10)
    const int MEM_H = 7;             // mem_clk half-period (period 14, async to clk)
    const uint64_t T_END = cycles * (2 * CLK_H) + 400;

    // One guaranteed link-down/drain window mid-run so the default trace shows it.
    const long forced_down_lo = (long)cycles / 2;
    const long forced_down_hi = forced_down_lo + 60;

    int prev_clk = 0, prev_mem = 0;
    long clk_cyc = 0, mem_cyc = 0;
    // Preponed (pre-edge) ready samples, as in sim_main.cpp: each ingress ready is
    // constant between its own posedges, so last iteration's value is SVA-sampled.
    int prev_cxl_in_ready = 0, prev_lp_in_ready = 0;
    // Marker state.
    int last_link = 0, last_drain = 0, last_err = 0;
    int cxl_stall = 0, lp_stall = 0;     // consecutive ingress-ready-low run lengths
    long link_down_until = -1, link_next_check = 200;
    long err_until = -1, err_next_check = 120;
    // Counters.
    long c2m_acc = 0, m2c_acc = 0, lp_out_beats = 0, cxl_out_beats = 0, crc_bad = 0;

    for (uint64_t t = 1; t < T_END && !Verilated::gotFinish(); ++t) {
        int clk = (int)((t / CLK_H) & 1);
        int mem = (int)((t / MEM_H) & 1);

        // Reset 20 cycles; link up at 40; then random down windows + one forced one.
        if (clk_cyc >= 20) dut->rst_n = 1;
        if (clk_cyc >= 40 && clk_cyc == link_next_check) {
            if (pct(35)) link_down_until = clk_cyc + 30 + rnd(70);
            link_next_check = clk_cyc + 200 + rnd(300);
        }
        if (link_down_until >= 0 && clk_cyc >= link_down_until) link_down_until = -1;
        int want_up = (clk_cyc >= 40)
                   && !(clk_cyc >= forced_down_lo && clk_cyc < forced_down_hi)
                   && !(link_down_until >= 0);
        dut->link_up = want_up;
        // Occasional short error-injection windows (scheduled, so they're rare and
        // legible in the trace rather than a per-cycle dither).
        if (clk_cyc >= 60 && clk_cyc == err_next_check) {
            err_until = clk_cyc + 5 + rnd(15);
            err_next_check = clk_cyc + 400 + rnd(600);
        }
        if (err_until >= 0 && clk_cyc >= err_until) err_until = -1;
        dut->err_inj_en = (err_until >= 0) ? 1 : 0;

        dut->clk = clk;
        dut->mem_clk = mem;
        dut->eval();
        tfp->dump((uint64_t)t);

        int clk_rise = (clk == 1 && prev_clk == 0);
        int mem_rise = (mem == 1 && prev_mem == 0);

        if (clk_rise) {
            ++clk_cyc;
            // cxl_out (m2c completion egress) is a clk-domain interface: random
            // backpressure here; draining returns response credits to the mem side.
            dut->cxl_out_ready = pct(25) ? 0 : 1;
            if (dut->cxl_out_valid && dut->cxl_out_ready) ++cxl_out_beats;
            // Protocol-compliant producer: only (re)drive valid/data after a
            // handshake or while idle; hold both stable through a stall. Preponed
            // ready (captured last iteration) matches SVA sampling.
            int accepted = dut->cxl_in_valid && prev_cxl_in_ready;
            if (accepted) {
                ++c2m_acc;
                uint8_t rk = resp_kind_for(pkt_kind(dut->cxl_in_data));
                if (rk) out_push(pkt_tag(dut->cxl_in_data), rk);
            }
            if (!dut->cxl_in_valid || accepted) {
                int active = (clk_cyc >= 45);
                dut->cxl_in_valid = active && pct(70);   // ~30% idle gaps
                if (dut->cxl_in_valid) dut->cxl_in_data = rand_c2m();
            } // else valid && !ready: hold valid + data stable

            // ---- event markers (clk domain) ----
            if (dut->cxl_in_ready) {
                if (cxl_stall >= 4)
                    printf("[clk %5ld] c2m ingress backpressured %d cyc (request FIFO full)\n",
                           clk_cyc, cxl_stall);
                cxl_stall = 0;
            } else ++cxl_stall;
            if (dut->link_up != last_link) {
                printf("[clk %5ld] link_up %d->%d%s\n", clk_cyc, last_link, dut->link_up,
                       dut->link_up ? "" : "  (draining)");
                last_link = dut->link_up;
            }
            if (dut->drain_done != last_drain) {
                printf("[clk %5ld] drain_done %d->%d\n", clk_cyc, last_drain, dut->drain_done);
                last_drain = dut->drain_done;
            }
            if (dut->err_inj_en != last_err) {
                if (dut->err_inj_en) printf("[clk %5ld] err_inj_en pulse\n", clk_cyc);
                last_err = dut->err_inj_en;
            }
        }

        if (mem_rise) {
            ++mem_cyc;
            // lp_out (c2m command egress) is a mem_clk-domain interface.
            dut->lp_out_ready = pct(25) ? 0 : 1;
            if (dut->lp_out_valid && dut->lp_out_ready) ++lp_out_beats;
            int m_accepted = dut->lp_in_valid && prev_lp_in_ready;
            if (m_accepted) ++m2c_acc;
            if (!dut->lp_in_valid || m_accepted) {
                int active = (mem_cyc >= 35);
                dut->lp_in_valid = active && pct(70);
                if (dut->lp_in_valid) {
                    uint64_t r = rand_m2c();
                    if (with_checksum(r) != r) ++crc_bad;
                    dut->lp_in_data = r;
                }
            } // else hold valid + data stable

            if (dut->lp_in_ready) {
                if (lp_stall >= 4)
                    printf("[mem %5ld] m2c ingress backpressured %d cyc (completion FIFO full)\n",
                           mem_cyc, lp_stall);
                lp_stall = 0;
            } else ++lp_stall;
        }

        prev_clk = clk;
        prev_mem = mem;
        prev_cxl_in_ready = dut->cxl_in_ready;
        prev_lp_in_ready = dut->lp_in_ready;
    }

    dut->final();
    tfp->close();
    delete tfp;
    printf("[sim_rand] VCD written to %s\n", vcd_path);
    printf("[sim_rand] done: %ld clk / %ld mem_clk cycles; "
           "c2m accepted=%ld lp_out beats=%ld | m2c accepted=%ld cxl_out beats=%ld | bad-CRC flits=%ld\n",
           clk_cyc, mem_cyc, c2m_acc, lp_out_beats, m2c_acc, cxl_out_beats, crc_bad);
    printf("[sim_rand] reproduce with: +seed=%u +cycles=%llu\n",
           seed, (unsigned long long)cycles);
    delete dut;
    return 0;
}
