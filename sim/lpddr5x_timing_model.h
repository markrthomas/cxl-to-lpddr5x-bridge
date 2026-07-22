// LPDDR5X bank / timing scheduler model (behavioral, for the perf harness).
//
// This is a *characterization* model, not a sign-off memory model: it services
// the DRAM command stream the bridge emits on lp_out and returns responses on
// lp_in after a latency derived from bank state and JEDEC-style timing, so the
// perf harness (sim/sim_perf.cpp) can measure end-to-end latency and throughput
// versus locality, offered load, credit, and FIFO-depth settings.
//
// Scope / modeling choices (documented on purpose — this is not silicon sign-off):
//   * Default is an in-order (FCFS) controller: commands are served in the order
//     the bridge presents them at lp_out (the bridge preserves per-class order, so
//     this mirrors a simple direct scheduler). set_policy() opts into a queued
//     scheduler with FR-FCFS row-hit reordering and an optional read-priority write
//     buffer; FCFS and FR-FCFS then share one command-queue / backpressure model so
//     a policy A/B is apples-to-apples (see SchedPolicy / Policy below).
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

    // Command-scheduling policy. FCFS is the default and mirrors the in-order
    // stream the bridge presents (commands served in arrival order). FR_FCFS
    // adds first-ready, first-come-first-served reordering: within a bounded
    // lookahead window, a column command to an already-open row (a row hit) is
    // promoted ahead of older commands that would pay an activate/precharge,
    // which is the classic DRAM-controller throughput win. Optionally a
    // read-priority write buffer holds writes and drains them in bursts (a
    // watermark hysteresis) so reads jump the queue — cutting read latency at
    // the cost of bursty write turnaround, again as on real controllers.
    enum SchedPolicy { SCHED_FCFS, SCHED_FRFCFS };
    struct Policy {
        SchedPolicy sched = SCHED_FCFS;
        int reorder_window = 16;   // max lookahead (commands) for row-hit promotion
        int starve_cap = 0;        // 0 = off; else force the head once it has waited
                                   //   this many cycles (anti-starvation)
        bool write_buffer = false; // read-priority write draining (FR-FCFS only)
        int wr_hi = 16;            // enter write-drain at this write-queue occupancy
        int wr_lo = 4;             // leave write-drain at this occupancy
    };

    Lpddr5xTimingModel() { reset(); }
    explicit Lpddr5xTimingModel(const Timing& t) : tm_(t) { reset(); }

    // Depth of the modeled controller command queue, in commands. The model
    // accepts a command (asserts backpressure otherwise, see can_accept) only
    // while its scheduling horizon stays within this many commands of `now`, so
    // an offered load above the memory's sustainable rate backs up through the
    // bridge instead of producing an unbounded schedule. Latency-under-load then
    // follows Little's law from this depth, as on real hardware.
    void set_queue_depth(int commands) { cmd_q_depth_ = commands > 1 ? commands : 1; }

    // Select the scheduling policy (see SchedPolicy / Policy) and switch the
    // model onto the queued scheduler path. Both SCHED_FCFS and SCHED_FRFCFS then
    // share the identical command-queue / backpressure model and differ ONLY in
    // which queued command is issued next, so a policy A/B is apples-to-apples.
    // Without this call the model stays on its default immediate-FCFS fast path
    // (commands scheduled in arrival order the instant they arrive).
    void set_policy(const Policy& p) {
        pol_ = p;
        if (pol_.reorder_window < 1) pol_.reorder_window = 1;
        queued_ = true;
    }
    const Policy& policy() const { return pol_; }

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
        pend_.clear();
        wr_pending_ = 0;
        draining_ = false;
        st_ = Stats{};
    }

    // Backpressure: is the modeled command queue able to take another command?
    // The horizon is the latest column time scheduled so far; commands still to
    // be issued occupy the bus roughly every tCCD_S, so a horizon more than
    // cmd_q_depth columns ahead of `now` means the queue is full.
    bool can_accept(long now) const {
        if (queued_)
            return (int)pend_.size() < cmd_q_depth_;   // real command-queue occupancy
        return (horizon_ - now) <= (long)cmd_q_depth_ * tm_.tCCD_S;
    }

    // Accept a command presented at lp_out at mem-cycle `now`. Under FCFS the
    // command is scheduled immediately (in arrival order) and its modeled DRAM
    // service latency is returned. Under FR-FCFS it is enqueued into the command
    // queue and issued later by the reordering scheduler (pump); the return is 0
    // in that case (per-command service latency is available via stats()).
    long accept(const LpCmd& c, long now) {
        if (!queued_) return schedule_cmd(c, now);   // default immediate-FCFS path
        pend_.push_back(PendCmd{c, now});
        if (is_write(c)) ++wr_pending_;
        if ((long)pend_.size() > st_.max_queue) st_.max_queue = (long)pend_.size();
        pump(now);
        return 0;
    }

    // Advance the FR-FCFS scheduler to `now`: issue as many queued commands as
    // bank/bus timing permits, most-ready-first. A no-op under FCFS. Call it
    // every cycle the model is polled (accept/due already do).
    void tick(long now) { pump(now); }

    // Schedule a single command in issue order (the FCFS fast path, and the
    // per-command work FR-FCFS performs once it picks a command to issue).
    // Returns the modeled DRAM service latency (cycles) from `now` to ready.
    long schedule_cmd(const LpCmd& c, long now) {
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
        pump(now);   // let FR-FCFS issue any commands that became ready by `now`
        if (heap_.empty() || heap_.top().ready > now) return false;
        out = heap_.top().resp;
        heap_.pop();
        return true;
    }

    // Pending == scheduled-but-undelivered responses PLUS (FR-FCFS) commands
    // still queued for issue, so the harness's drain check waits for both.
    bool has_pending() const { return !heap_.empty() || !pend_.empty(); }
    size_t pending() const { return heap_.size() + pend_.size(); }

    struct Stats {
        long n_cmd = 0, n_hit = 0, n_miss = 0, n_empty = 0;
        long sum_service = 0, max_service = 0;
        // FR-FCFS bookkeeping (0 under FCFS):
        long n_reorder = 0;    // row-hit promotions that jumped an older command
        long n_wr_drain = 0;   // write-drain episodes entered (write-buffer mode)
        long max_queue = 0;    // peak command-queue occupancy observed
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

    // A command waiting in the FR-FCFS command queue, with its arrival time.
    struct PendCmd {
        LpCmd cmd;
        long  arrival;
    };

    static int group_of(uint8_t bank) { return (bank >> 2) & (NGROUPS - 1); }

    static bool is_write(const LpCmd& c) {
        return c.op == OP_WR || c.op == OP_WRA || c.op == OP_MWR;
    }

    // A column command that can issue without an ACT/PRE right now: the bank is
    // open on the requested row. Mode-register commands are never "hits".
    bool is_row_hit(const LpCmd& c) const {
        if (c.op == OP_MRR || c.op == OP_MRW) return false;
        const Bank& b = banks_[c.bank & (NBANKS - 1)];
        return b.open && b.row == c.row;
    }

    // FR-FCFS engine: issue queued commands, most-ready-first. Each issue reuses
    // schedule_cmd, so the reordering rides on exactly the same bus/bank timing
    // arithmetic the FCFS path uses — only the *order* differs. Issue is allowed
    // to run the schedule horizon ahead of `now` by the same bound FCFS uses (a
    // full command queue of tCCD_S column slots), which throttles issue to the
    // sustainable bus rate while letting the pipeline stay full. The un-issued
    // queue pend_ then backs up under overload and gates the bridge (can_accept).
    void pump(long now) {
        if (!queued_) return;
        while (!pend_.empty() &&
               (horizon_ - now) <= (long)cmd_q_depth_ * tm_.tCCD_S) {
            int pick = select(now);
            if (pick < 0) break;
            PendCmd pc = pend_[pick];
            if (is_write(pc.cmd)) --wr_pending_;
            pend_.erase(pend_.begin() + pick);
            schedule_cmd(pc.cmd, now);   // `now` floors the issue time; maxes do the rest
        }
    }

    // Pick the next command to issue from the head window of the queue under the
    // FR-FCFS + (optional) write-buffer policy. Returns an index into pend_, or
    // -1 if nothing should issue. Updates reorder / write-drain stats.
    int select(long now) {
        const int n = (int)pend_.size();
        int window = n < pol_.reorder_window ? n : pol_.reorder_window;

        // Anti-starvation: once the head has waited long enough, force it.
        if (pol_.starve_cap > 0 && now - pend_[0].arrival >= pol_.starve_cap)
            return 0;

        // Strict FCFS: always the oldest command, no reordering.
        if (pol_.sched == SCHED_FCFS) return 0;

        // Write-buffer hysteresis: reads are preferred until the write queue
        // fills to wr_hi (enter drain), and stay preferred again below wr_lo.
        bool prefer_write = false;
        if (pol_.write_buffer) {
            if (!draining_ && wr_pending_ >= pol_.wr_hi) { draining_ = true; ++st_.n_wr_drain; }
            else if (draining_ && wr_pending_ <= pol_.wr_lo) draining_ = false;
            prefer_write = draining_;
        }

        // Baseline (no reorder): oldest command of the preferred class in the
        // window; row-hit promotion picks the oldest hit of that class instead.
        int oldest_pref = -1, oldest_hit = -1;
        for (int i = 0; i < window; ++i) {
            const LpCmd& c = pend_[i].cmd;
            bool pref = !pol_.write_buffer || (is_write(c) == prefer_write);
            if (!pref) continue;
            if (oldest_pref < 0) oldest_pref = i;
            if (oldest_hit < 0 && is_row_hit(c)) oldest_hit = i;
        }
        if (oldest_hit >= 0) {
            if (oldest_hit != oldest_pref) ++st_.n_reorder;
            return oldest_hit;
        }
        if (oldest_pref >= 0) return oldest_pref;
        // Preferred class empty in the window (e.g. draining but only reads left,
        // or vice versa): fall back to the absolute oldest command.
        return 0;
    }

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
    Policy pol_;                // scheduling policy (default: FCFS)
    bool   queued_ = false;     // true once set_policy() selects the queued path
    int    cmd_q_depth_ = 24;   // controller command-queue depth (backpressure)
    long   horizon_ = kNeg;     // latest column time scheduled so far
    std::vector<PendCmd> pend_; // FR-FCFS command queue (arrival order)
    int    wr_pending_ = 0;     // writes currently in pend_ (write-buffer state)
    bool   draining_ = false;   // write-drain hysteresis state
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
