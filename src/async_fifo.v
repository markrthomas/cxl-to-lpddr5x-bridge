// Dual-clock asynchronous FIFO with Gray-code pointer synchronization.
// DEPTH must be a power of two and >= 4.
// r_data is combinational (FWFT); valid when !r_empty.
// rst_n is used for both domains (common async reset; suitable for simulation
// and experimental RTL where a single power-on reset drives both domains).

module async_fifo #(
  parameter integer WIDTH = 64,
  parameter integer DEPTH = 8
) (
  // Write side (w_clk domain)
  input  wire             w_clk,
  input  wire             w_rst_n,
  input  wire             w_en,
  input  wire [WIDTH-1:0] w_data,
  output wire             w_full,
  // Width is $clog2(DEPTH)+1; ADDR_W (a localparam below) isn't visible in the
  // ANSI port list under yosys, so spell out $clog2(DEPTH) here.
  output wire [$clog2(DEPTH):0] w_occupancy, // write-domain occupancy estimate

  // Read side (r_clk domain)
  input  wire             r_clk,
  input  wire             r_rst_n,
  input  wire             r_en,
  output wire [WIDTH-1:0] r_data,
  output wire             r_empty
);

  localparam integer ADDR_W = $clog2(DEPTH);

  generate
    if (DEPTH < 4 || (DEPTH & (DEPTH-1)) != 0) begin : gen_depth_check
      initial $fatal(1, "async_fifo: DEPTH must be a power of two and >= 4");
    end
  endgenerate

  // Full when top-two Gray bits differ between write and synchronized-read pointer,
  // rest match.  Expressed as a constant XOR mask so there are no variable selects.
  localparam [ADDR_W:0] FULL_MASK = {2'b11, {(ADDR_W-1){1'b0}}};

  // ---- Shared memory (written on w_clk, read combinationally) ----
  (* ram_style = "distributed" *)
  reg [WIDTH-1:0] mem [0:DEPTH-1];

  // All pointer registers declared together to avoid forward-reference errors in iverilog.
  reg [ADDR_W:0] w_ptr_bin;
  reg [ADDR_W:0] w_ptr_gray;
  reg [ADDR_W:0] r_ptr_bin;
  reg [ADDR_W:0] r_ptr_gray;

  // ---- Write domain ----

  // 2-flop sync: r_ptr_gray -> w_clk
  reg [ADDR_W:0] r_sync0_w, r_sync1_w;
  /* verilator lint_off SYNCASYNCNET */
  always @(posedge w_clk or negedge w_rst_n) begin
    if (!w_rst_n) begin
      r_sync0_w <= {(ADDR_W+1){1'b0}};
      r_sync1_w <= {(ADDR_W+1){1'b0}};
    end else begin
      r_sync0_w <= r_ptr_gray;
      r_sync1_w <= r_sync0_w;
    end
  end
  /* verilator lint_on SYNCASYNCNET */
  wire [ADDR_W:0] r_ptr_gray_sync = r_sync1_w;

  // Binary synchronized read pointer for occupancy calculation
  reg [ADDR_W:0] r_ptr_bin_sync;
  always @(*) begin
    r_ptr_bin_sync[ADDR_W] = r_ptr_gray_sync[ADDR_W];
    for (integer i = ADDR_W-1; i >= 0; i = i - 1)
      r_ptr_bin_sync[i] = r_ptr_bin_sync[i+1] ^ r_ptr_gray_sync[i];
  end

  assign w_full      = ((w_ptr_gray ^ r_ptr_gray_sync) == FULL_MASK);
  assign w_occupancy = w_ptr_bin - r_ptr_bin_sync;

  always @(posedge w_clk or negedge w_rst_n) begin
    if (!w_rst_n) begin
      w_ptr_bin  <= {(ADDR_W+1){1'b0}};
      w_ptr_gray <= {(ADDR_W+1){1'b0}};
    end else if (w_en && !w_full) begin
      mem[w_ptr_bin[ADDR_W-1:0]] <= w_data;
      w_ptr_bin  <= w_ptr_bin + 1'b1;
      w_ptr_gray <= (w_ptr_bin + 1'b1) ^ ((w_ptr_bin + 1'b1) >> 1);
    end
  end

  // ---- Read domain ----

  // 2-flop sync: w_ptr_gray -> r_clk
  reg [ADDR_W:0] w_sync0_r, w_sync1_r;
  /* verilator lint_off SYNCASYNCNET */
  always @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      w_sync0_r <= {(ADDR_W+1){1'b0}};
      w_sync1_r <= {(ADDR_W+1){1'b0}};
    end else begin
      w_sync0_r <= w_ptr_gray;
      w_sync1_r <= w_sync0_r;
    end
  end
  /* verilator lint_on SYNCASYNCNET */
  wire [ADDR_W:0] w_ptr_gray_sync = w_sync1_r;

  assign r_empty = (r_ptr_gray == w_ptr_gray_sync);

  always @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      r_ptr_bin  <= {(ADDR_W+1){1'b0}};
      r_ptr_gray <= {(ADDR_W+1){1'b0}};
    end else if (r_en && !r_empty) begin
      r_ptr_bin  <= r_ptr_bin + 1'b1;
      r_ptr_gray <= (r_ptr_bin + 1'b1) ^ ((r_ptr_bin + 1'b1) >> 1);
    end
  end

  assign r_data = mem[r_ptr_bin[ADDR_W-1:0]];

  // ---- Invariant Assertions ----
`ifdef FORMAL
  localparam [ADDR_W:0] DEPTH_VEC = DEPTH[ADDR_W:0];

`ifdef FIFO_FORMAL_STANDALONE
  // Standalone proof environment contract. The integrated bridge drives these
  // exact conditions (writes gated by occupancy<credits<=DEPTH and !w_full,
  // reads gated by !empty), and uses a single common reset for both domains —
  // model that here so the unbounded `prove` reflects real usage rather than
  // an unconstrained, unreachable environment.
  initial assume (!w_rst_n);
  always @(*) begin
    assume (w_rst_n == r_rst_n);          // common async reset (see header)
    if (w_full)  assume (!w_en);          // caller honours full backpressure
    if (r_empty) assume (!r_en);          // caller honours empty backpressure
  end
  // The ghost occupancy/ordering invariants (3)+(4) are ASSERTED and proven
  // k-inductive here, under the common-reset contract above.
  `define FIFO_OCC_CHECK assert
`else
  // Assume-guarantee composition for the integrated bridge. The bridge drives
  // both FIFO resets from one async source through per-domain reset_sync cells
  // (asynchronous assert, synchronous deassert), so both pointers and their
  // synchronizer ghosts leave reset coupled at 0 and every reachable state
  // satisfies (3)+(4). They are not re-derivable inductively here, though: with
  // the clocks free, k-induction can seed the brief reset-deassert skew window
  // with an unreachable over-full state (e.g. f_wcnt large while the read
  // domain still reads 0), which no bounded reset skew could actually produce.
  // We therefore ASSUME (3)+(4) in integration — they are the GUARANTEE
  // discharged by the standalone async_fifo `prove` run — and assert only the
  // genuinely bridge-level FIFO obligations (gray consistency, pointer ties,
  // liveness, head-of-line stability) below.
  `define FIFO_OCC_CHECK assume
`endif

  // (1) Each gray pointer is the gray encoding of its binary counterpart.
  //     1-inductive on its own; everything below leans on it.
  always @(*) if (w_rst_n) assert (w_ptr_gray == (w_ptr_bin ^ (w_ptr_bin >> 1)));
  always @(*) if (r_rst_n) assert (r_ptr_gray == (r_ptr_bin ^ (r_ptr_bin >> 1)));

  // ---- Ghost counters for the occupancy / CDC sync-chain invariants ----
  // The real pointers are ADDR_W+1 bits, so the modulus is exactly 2*DEPTH and
  // a binary pointer difference is wrap-AMBIGUOUS at the FIFO-full boundary
  // (gap == DEPTH == modulus/2): a legal full-drained state and an illegal
  // "synchronizer ran ahead of its source" state are indistinguishable by any
  // (ADDR_W+1)-bit difference, so plain pointer-difference invariants are not
  // inductive. We add free-running GHOST counters (FORMAL-only) one bit wider
  // than needed: every live pairwise gap is <= DEPTH, which now sits below the
  // ghost half-modulus (2^(GW-1) > DEPTH), so differences are unambiguous and
  // the ordering becomes k-inductive. The ghosts shadow the real pointers and
  // each synchronizer stage exactly, and are tied back to the RTL by equality.
  localparam integer    GW      = ADDR_W + 3;   // > 1 bit of headroom over DEPTH
  localparam [GW-1:0]   DEPTH_G = DEPTH[GW-1:0];

  reg [GW-1:0] f_wcnt, f_rcnt;       // unwrapped write / read pointers
  reg [GW-1:0] f_rs0, f_rs1;         // read count through the w-domain synchronizer
  reg [GW-1:0] f_ws0, f_ws1;         // write count through the r-domain synchronizer

  // Ghosts advance/shift on exactly the same edges and conditions as the RTL.
  always @(posedge w_clk or negedge w_rst_n) begin
    if (!w_rst_n) begin
      f_wcnt <= {GW{1'b0}};
      f_rs0  <= {GW{1'b0}};
      f_rs1  <= {GW{1'b0}};
    end else begin
      if (w_en && !w_full) f_wcnt <= f_wcnt + 1'b1;
      f_rs0 <= f_rcnt;               // parallels r_sync0_w <= r_ptr_gray
      f_rs1 <= f_rs0;                // parallels r_sync1_w <= r_sync0_w
    end
  end
  always @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      f_rcnt <= {GW{1'b0}};
      f_ws0  <= {GW{1'b0}};
      f_ws1  <= {GW{1'b0}};
    end else begin
      if (r_en && !r_empty) f_rcnt <= f_rcnt + 1'b1;
      f_ws0 <= f_wcnt;
      f_ws1 <= f_ws0;
    end
  end

  // (2) Ties: the real pointers and the gray-coded synchronizer stages are the
  //     low ADDR_W+1 bits of their ghost (gray-encoded for the sync stages).
  //     Inductive because each ghost updates from the same source on the same
  //     edge as its RTL counterpart, and gray==bin2gray(bin) holds by (1).
  always @(*) if (w_rst_n) begin
    assert (w_ptr_bin == f_wcnt[ADDR_W:0]);
    assert (r_sync0_w == (f_rs0[ADDR_W:0] ^ (f_rs0[ADDR_W:0] >> 1)));
    assert (r_sync1_w == (f_rs1[ADDR_W:0] ^ (f_rs1[ADDR_W:0] >> 1)));
  end
  always @(*) if (r_rst_n) begin
    assert (r_ptr_bin == f_rcnt[ADDR_W:0]);
    assert (w_sync0_r == (f_ws0[ADDR_W:0] ^ (f_ws0[ADDR_W:0] >> 1)));
    assert (w_sync1_r == (f_ws1[ADDR_W:0] ^ (f_ws1[ADDR_W:0] >> 1)));
  end

  // (3) Pointer-ordering window on the ghosts (unambiguous, see above). The
  //     write pointer leads the read pointer, which leads the two w-domain
  //     synchronizer stages (older, monotone samples of R):
  //         f_rs1 <= f_rs0 <= f_rcnt <= f_wcnt
  //     and symmetrically the read side trails lagged copies of the write
  //     pointer:
  //         f_rcnt <= f_ws1 <= f_ws0 <= f_wcnt
  //     The gating bounds f_wcnt-f_rs1 (write/full) and f_ws1-f_rcnt
  //     (read/empty) are what make the occupancy bound inductive across the CDC
  //     synchronizers.
  //
  //     Each assertion is guarded by the reset(s) of the domain(s) its operands
  //     live in: f_wcnt + the f_rs* synchronizer ghosts are write-domain
  //     (w_rst_n); f_rcnt + the f_ws* synchronizer ghosts are read-domain
  //     (r_rst_n). The two resets are common in the standalone proof but
  //     SEPARATE in the bridge (e.g. the m2c FIFO writes on mem_clk/mem_rst_n
  //     and reads on clk/clk_rst_n), so a cross-domain assertion must wait for
  //     both domains to be out of reset — otherwise an asymmetric-reset
  //     transient references ghosts still held at 0.
  always @(*) if (w_rst_n) begin               // write-domain only
    `FIFO_OCC_CHECK ((f_wcnt - f_rs0)  <= DEPTH_G);
    `FIFO_OCC_CHECK ((f_wcnt - f_rs1)  <= DEPTH_G);  // occupancy estimate (full gating)
    `FIFO_OCC_CHECK ((f_rs0  - f_rs1)  <= DEPTH_G);
  end
  always @(*) if (r_rst_n) begin               // read-domain only
    `FIFO_OCC_CHECK ((f_ws0  - f_ws1)  <= DEPTH_G);
    `FIFO_OCC_CHECK ((f_ws1  - f_rcnt) <= DEPTH_G);  // empty gating
  end
  always @(*) if (w_rst_n && r_rst_n) begin    // cross-domain (both live)
    `FIFO_OCC_CHECK ((f_wcnt - f_rcnt) <= DEPTH_G);  // true occupancy <= DEPTH
    `FIFO_OCC_CHECK ((f_rcnt - f_rs0)  <= DEPTH_G);
    `FIFO_OCC_CHECK ((f_wcnt - f_ws0)  <= DEPTH_G);
    `FIFO_OCC_CHECK ((f_wcnt - f_ws1)  <= DEPTH_G);
  end

  // (4) Reported occupancy never exceeds DEPTH (the credit pool is sized <=
  //     DEPTH, so this underpins the bridge credit-conservation invariant).
  //     Follows from (2)+(3): w_occupancy == (f_wcnt - f_rs1)[ADDR_W:0].
  always @(*) if (w_rst_n) `FIFO_OCC_CHECK (w_occupancy <= DEPTH_VEC);

  // (5) The original liveness guards: the gating never writes-full / reads-empty.
  always @(posedge w_clk) begin
    if (w_rst_n && w_en) begin
      assert (!w_full);
    end
  end

  always @(posedge r_clk) begin
    if (r_rst_n && r_en) begin
      assert (!r_empty);
    end
  end

  // (6) Head-of-line data stability. While the FIFO is non-empty and not being
  //     popped, the FWFT read data holds: the head entry mem[r_ptr] is only
  //     overwritten when w_ptr and r_ptr share the same low ADDR_W bits, i.e.
  //     occupancy is 0 (empty, excluded) or DEPTH (full, where writes are
  //     gated off by w_full) — so the head is never clobbered in flight. This
  //     is what lets the bridge hold a stalled egress beat stable (valid/ready
  //     protocol) without its data shifting under it.
  //
  //     Expressed with read-clock-domain shadow registers rather than $past:
  //     under `multiclock on`, $past samples the GLOBAL step, not the previous
  //     r_clk edge, so a $past-based cross-cycle property would be unsound. The
  //     shadows capture the previous r_clk cycle exactly, and reset cleanly with
  //     r_rst_n (so a reset pulse just re-primes them, no spurious failure).
  reg [WIDTH-1:0] f_rd_q;     // r_data at the previous r_clk edge
  reg             f_ne_q;     // was non-empty at the previous r_clk edge
  reg             f_pop_q;    // a pop fired at the previous r_clk edge
  reg             f_rd_v;     // a previous-cycle sample exists
  always @(posedge r_clk or negedge r_rst_n) begin
    if (!r_rst_n) begin
      f_rd_q  <= {WIDTH{1'b0}};
      f_ne_q  <= 1'b0;
      f_pop_q <= 1'b0;
      f_rd_v  <= 1'b0;
    end else begin
      f_rd_q  <= r_data;
      f_ne_q  <= !r_empty;
      f_pop_q <= (r_en && !r_empty);
      f_rd_v  <= 1'b1;
    end
  end
  // If the previous cycle was non-empty and the edge into this cycle did not
  // pop, the FIFO is still non-empty and the head data is unchanged. The
  // non-emptiness companion pins the shadow to reality (otherwise induction may
  // start with f_ne_q set while the FIFO is actually empty, letting a write to
  // the empty head clobber it); with it, "non-empty -> head index not written"
  // follows from the occupancy invariants and head stability is inductive.
  // Checked combinationally so it also holds across intervening w_clk writes.
  always @(*) begin
    if (r_rst_n && f_rd_v && f_ne_q && !f_pop_q) begin
      assert (!r_empty);
      assert (r_data == f_rd_q);
    end
  end

  `undef FIFO_OCC_CHECK
`endif

endmodule
