// LPDDR5X bank / timing scheduler model (behavioral, for the perf harness).
//
// This is a *characterization* model, not a sign-off memory model: it services
// the DRAM command stream the bridge emits on lp_out and returns responses on
// lp_in after a latency derived from bank state and JEDEC-style timing, so the
// perf harness (sim/sim_perf.cpp) can measure end-to-end latency and throughput
// versus locality, offered load, credit, and FIFO-depth settings.
//
// Scope / modeling choices (documented on purpose — this is not silicon sign-off):
//   * In-order (FCFS) controller: commands are served in the order the bridge
//     presents them at lp_out. No FR-FCFS reordering, no write buffering. The
//     bridge preserves per-class order, so this mirrors a simple direct scheduler.
//   * 16 banks in 4 bank groups (bank[3:2] = group, bank[1:0] = bank-in-group),
//     addressed by the flit's ADDR field {bank[15:12], row[11:0]}.
//   * Timing is expressed in mem_clk (command-clock) cycles. The defaults are
//     representative of LPDDR5X near CK ~= 800 MHz (tCK ~= 1.25 ns); they are a
//     plausible operating point for relative comparisons, not a specific speed
//     bin. Override via Timing to model a different grade or to sweep.
//   * Models the first-order effects that dominate latency/throughput: row
//     hit/miss (tRCD, tRP, tRAS, tRC), column throughput (tCCD_L/S), activate
//     throttles (tRRD_L/S, tFAW), read/write latency (tRL/tWL), burst occupancy,
//     write recovery (tWR) and read-to-precharge (tRTP). Second-order bus
//     turnarounds (tWTR / tRTW) are intentionally omitted for readability.
//
// Header-only and free of any Verilator / RTL dependency, so it can be unit
// tested and reused (see sim/tb_timing_model.cpp).

#ifndef LPDDR5X_TIMING_MODEL_H_
#define LPDDR5X_TIMING_MODEL_H_

#include <cstddef>
#include <cstdint>
#include <queue>
#include <vector>

// ---- decoded command handed to the model (layout-agnostic) ----------------
// The harness decodes an lp_out flit into this; the model never touches bit
// fields. op values mirror LP_CMD_* in src/cxl_lpddr5x_bridge_defs.vh.
struct LpCmd {
    uint8_t  op;    // LP_CMD_RD/RDA/WR/WRA/MWR/MRW/MRR
    uint8_t  tag;   // correlates the response
    uint8_t  id;    // src id, echoed back
    uint8_t  bank;  // [3:0]
    uint16_t row;   // [11:0]
    uint8_t  col;   // column / burst-length group (LEN field)
};

// ---- response payload the model schedules back onto lp_in ------------------
struct LpResp {
    uint8_t  kind;        // LP_PKT_KIND_RD_RSP / WR_RSP / MRR_RSP
    uint8_t  status;      // LP_RSP_OK
    uint8_t  tag;
    uint8_t  id;
    uint16_t byte_count;
    uint8_t  length;
};

class Lpddr5xTimingModel {
public:
    // LP_CMD_* opcodes (mirror the defs header).
    enum { OP_RD = 0x1, OP_RDA = 0x2, OP_WR = 0x3, OP_WRA = 0x4,
           OP_MWR = 0x5, OP_MRW = 0x6, OP_MRR = 0x7 };
    // LP_PKT_KIND_* response kinds (mirror the defs header).
    enum { KIND_RD_RSP = 0xa, KIND_WR_RSP = 0xb, KIND_MRR_RSP = 0xc };
    enum { RSP_OK = 0x1 };

    // Timing parameters, in mem_clk cycles. Defaults ~ LPDDR5X @ CK ~800 MHz.
    struct Timing {
        int tRCD   = 15;  // ACT -> column command
        int tRP    = 15;  // PRE -> ACT (same bank)
        int tRAS   = 34;  // ACT -> PRE (row-open minimum)
        int tRC    = 49;  // ACT -> ACT (same bank) == tRAS + tRP
        int tRL    = 20;  // read column -> first read data
        int tWL    = 10;  // write column -> first write data
        int tBURST = 8;   // data-bus occupancy of one burst (BL16 @ 2:1 WCK)
        int tCCD_S = 4;   // column -> column, different bank group
        int tCCD_L = 8;   // column -> column, same bank group
        int tRRD_S = 4;   // ACT -> ACT, different bank group
        int tRRD_L = 6;   // ACT -> ACT, same bank group
        int tFAW   = 20;  // window bounding any four ACTs
        int tWR    = 15;  // write-recovery: last write data -> PRE
        int tRTP   = 6;   // read column -> PRE (read-to-precharge)
        int tMRR   = 12;  // mode-register access (no bank timing)
    };

    // Classification of how a command hit the bank array, for stats.
    enum Access { ROW_HIT, ROW_MISS, ROW_EMPTY, NON_BANK };

    Lpddr5xTimingModel() { reset(); }
    explicit Lpddr5xTimingModel(const Timing& t) : tm_(t) { reset(); }

    // Depth of the modeled controller command queue, in commands. The model
    // accepts a command (asserts backpressure otherwise, see can_accept) only
    // while its scheduling horizon stays within this many commands of `now`, so
    // an offered load above the memory's sustainable rate backs up through the
    // bridge instead of producing an unbounded schedule. Latency-under-load then
    // follows Little's law from this depth, as on real hardware.
    void set_queue_depth(int commands) { cmd_q_depth_ = commands > 1 ? commands : 1; }

    void reset() {
        for (int b = 0; b < NBANKS; ++b) {
            banks_[b] = Bank{};
            banks_[b].t_pre = -tm_.tRP;   // start precharged & immediately actable
        }
        for (int g = 0; g < NGROUPS; ++g) last_act_group_[g] = kNeg;
        last_act_any_ = kNeg;
        last_col_time_ = kNeg;
        last_col_group_ = -1;
        for (int i = 0; i < 4; ++i) faw_[i] = kNeg;
        faw_pos_ = 0;
        while (!heap_.empty()) heap_.pop();
        horizon_ = kNeg;
        st_ = Stats{};
    }

    // Backpressure: is the modeled command queue able to take another command?
    // The horizon is the latest column time scheduled so far; commands still to
    // be issued occupy the bus roughly every tCCD_S, so a horizon more than
    // cmd_q_depth columns ahead of `now` means the queue is full.
    bool can_accept(long now) const {
        return (horizon_ - now) <= (long)cmd_q_depth_ * tm_.tCCD_S;
    }

    // Accept a command presented at lp_out at mem-cycle `now`; schedules its
    // response internally. Returns the modeled DRAM service latency (cycles)
    // from acceptance to response-ready, for the caller's own bookkeeping.
    long accept(const LpCmd& c, long now) {
        long ready;
        Access acc;
        LpResp r{};
        r.tag = c.tag;
        r.id  = c.id;

        if (c.op == OP_MRR || c.op == OP_MRW) {
            ready = now + tm_.tMRR;
            acc = NON_BANK;
            r.kind = KIND_MRR_RSP;     // MRW acks on the WR path below; MRR reads
            if (c.op == OP_MRW) { r.kind = KIND_WR_RSP; }
            r.byte_count = (c.op == OP_MRR) ? 0x0002 : 0x0000;
            r.length = 0;
        } else {
            const bool is_read = (c.op == OP_RD || c.op == OP_RDA);
            const bool auto_pre = (c.op == OP_RDA || c.op == OP_WRA);
            ready = service_bank(c, now, is_read, auto_pre, acc);
            r.kind = is_read ? KIND_RD_RSP : KIND_WR_RSP;
            r.byte_count = is_read ? 0x0040 : 0x0000;
            r.length = c.col ? c.col : 1;
        }
        r.status = RSP_OK;

        heap_.push(Pending{ready, r});
        // stats
        st_.n_cmd++;
        switch (acc) {
            case ROW_HIT:   st_.n_hit++;   break;
            case ROW_MISS:  st_.n_miss++;  break;
            case ROW_EMPTY: st_.n_empty++; break;
            default: break;
        }
        long lat = ready - now;
        st_.sum_service += lat;
        if (lat > st_.max_service) st_.max_service = lat;
        return lat;
    }

    // If a response is ready at or before `now`, pop and return it. One per call
    // (the caller gates delivery on lp_in_ready, one beat per mem cycle).
    bool due(long now, LpResp& out) {
        if (heap_.empty() || heap_.top().ready > now) return false;
        out = heap_.top().resp;
        heap_.pop();
        return true;
    }

    bool has_pending() const { return !heap_.empty(); }
    size_t pending() const { return heap_.size(); }

    struct Stats {
        long n_cmd = 0, n_hit = 0, n_miss = 0, n_empty = 0;
        long sum_service = 0, max_service = 0;
    };
    const Stats& stats() const { return st_; }

private:
    static constexpr int NBANKS = 16;
    static constexpr int NGROUPS = 4;
    static constexpr long kNeg = -(1L << 40);   // "long ago" sentinel

    struct Bank {
        bool open = false;
        uint16_t row = 0;
        long t_act = kNeg;   // last ACT to this bank
        long t_pre = kNeg;   // last PRE action (bank closed at/after this)
        long t_col = kNeg;   // last column command to this bank
        bool col_was_read = false;
    };

    struct Pending {
        long ready;
        LpResp resp;
    };
    struct PendingCmp {
        bool operator()(const Pending& a, const Pending& b) const {
            return a.ready > b.ready;   // min-heap by ready time
        }
    };

    static int group_of(uint8_t bank) { return (bank >> 2) & (NGROUPS - 1); }

    // Compute response-ready time for a bank-directed (RD/WR) command, updating
    // bank and bus state. Sets `acc` to how the row was hit.
    long service_bank(const LpCmd& c, long now, bool is_read, bool auto_pre,
                      Access& acc) {
        const int idx = c.bank & (NBANKS - 1);
        const int grp = group_of(idx);
        Bank& b = banks_[idx];

        long col_earliest;   // earliest the RD/WR column command may issue
        if (b.open && b.row == c.row) {
            acc = ROW_HIT;
            col_earliest = now;    // row already open; tRCD long since met
        } else {
            acc = b.open ? ROW_MISS : ROW_EMPTY;
            // If a different row is open, precharge it first.
            long pre_time = b.t_pre;
            if (b.open) {
                pre_time = now;
                pre_time = max2(pre_time, b.t_act + tm_.tRAS);       // row-open min
                if (b.col_was_read)
                    pre_time = max2(pre_time, b.t_col + tm_.tRTP);   // read-to-PRE
                else
                    pre_time = max2(pre_time, b.t_col + tm_.tWL + tm_.tBURST + tm_.tWR); // write recovery
                b.t_pre = pre_time;
            }
            // ACT: after tRP from precharge, tRC from our own last ACT, and the
            // inter-activate throttles (tRRD_L/S, tFAW).
            long act = max2(now, b.t_pre + tm_.tRP);
            act = max2(act, b.t_act + tm_.tRC);
            act = max2(act, last_act_group_[grp] + tm_.tRRD_L);
            act = max2(act, last_act_any_ + tm_.tRRD_S);
            act = max2(act, faw_[faw_pos_] + tm_.tFAW);   // 4th-oldest ACT
            // commit the ACT
            b.open = true;
            b.row = c.row;
            b.t_act = act;
            last_act_group_[grp] = act;
            last_act_any_ = act;
            faw_[faw_pos_] = act;
            faw_pos_ = (faw_pos_ + 1) & 3;
            col_earliest = act + tm_.tRCD;
        }

        // Column-command spacing on the shared command/data bus (tCCD).
        long col = col_earliest;
        if (last_col_time_ != kNeg) {
            int ccd = (last_col_group_ == grp) ? tm_.tCCD_L : tm_.tCCD_S;
            col = max2(col, last_col_time_ + ccd);
        }
        last_col_time_ = col;
        last_col_group_ = grp;
        b.t_col = col;
        b.col_was_read = is_read;
        if (col > horizon_) horizon_ = col;   // schedule horizon for backpressure

        long ready = is_read ? (col + tm_.tRL + tm_.tBURST)
                             : (col + tm_.tWL + tm_.tBURST);

        if (auto_pre) {
            // Row closes automatically after the access; record when the bank is
            // precharged so the next ACT to it observes tRP.
            b.open = false;
            b.t_pre = is_read ? (col + tm_.tRTP)
                              : (col + tm_.tWL + tm_.tBURST + tm_.tWR);
        }
        return ready;
    }

    static long max2(long a, long b) { return a > b ? a : b; }

    Timing tm_;
    int    cmd_q_depth_ = 24;   // controller command-queue depth (backpressure)
    long   horizon_ = kNeg;     // latest column time scheduled so far
    Bank   banks_[NBANKS];
    long   last_act_group_[NGROUPS];
    long   last_act_any_;
    long   last_col_time_;
    int    last_col_group_;
    long   faw_[4];
    int    faw_pos_;
    std::priority_queue<Pending, std::vector<Pending>, PendingCmp> heap_;
    Stats  st_;
};

#endif  // LPDDR5X_TIMING_MODEL_H_
