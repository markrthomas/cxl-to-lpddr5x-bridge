`timescale 1ns / 1ps

// Stress testbench: bursts, random backpressure, concurrent directions, scoreboard.
// Dual-clock (clk=CXL host, mem_clk=LPDDR5X command channel); clock-ratio tests 1:1, 2:1, 1:3.

`include "cxl_lpddr5x_bridge_defs.vh"

module tb_cxl_lpddr5x_bridge;

  localparam integer W                = 64;
  localparam integer FIFO_DEPTH       = 8;
  localparam integer NUM_CYCLES       = 4000;
  localparam integer NUM_STRESS_HEAVY = 12000;
  localparam integer GOLD_SZ          = 32768;

  reg clk;
  reg mem_clk;
  reg rst_n;

  // mem_clk half-period (ns): changed per clock-ratio test.
  real mem_clk_half;

  reg         cxl_in_valid;
  reg [W-1:0] cxl_in_data;
  wire        cxl_in_ready;
  wire        lp_out_valid;
  wire [W-1:0] lp_out_data;
  reg         lp_out_ready;

  reg         lp_in_valid;
  reg [W-1:0] lp_in_data;
  wire        lp_in_ready;
  wire        cxl_out_valid;
  wire [W-1:0] cxl_out_data;
  reg         cxl_out_ready;

  reg         link_up;
  reg         err_inj_en;
  wire        drain_done;

  reg [31:0] seed;
  integer cyc;
  integer p1_c2m_sent, p1_m2c_sent;

  // c2m gold queues split by ordering class
  reg [W-1:0] gold_c2m_posted[GOLD_SZ];
  reg [W-1:0] gold_c2m_np[GOLD_SZ];
  integer     c2m_posted_gold_wr, c2m_posted_gold_rd;
  integer     c2m_np_gold_wr,     c2m_np_gold_rd;

  reg [W-1:0] pending_c2m_data[GOLD_SZ];
  reg         pending_c2m_posted[GOLD_SZ];
  integer     c2m_pending_wr, c2m_pending_rd;

  reg [W-1:0] gold_m2c[GOLD_SZ];
  integer     m2c_gold_wr, m2c_gold_rd;

  integer     c2m_sent, m2c_sent;
  integer     c2m_rcvd, m2c_rcvd;

  cxl_lpddr5x_bridge #(
    .WIDTH      (W),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) dut (
    .clk(clk),
    .mem_clk(mem_clk),
    .rst_n(rst_n),
    .cxl_in_valid(cxl_in_valid),
    .cxl_in_data(cxl_in_data),
    .cxl_in_ready(cxl_in_ready),
    .lp_out_valid(lp_out_valid),
    .lp_out_data(lp_out_data),
    .lp_out_ready(lp_out_ready),
    .lp_in_valid(lp_in_valid),
    .lp_in_data(lp_in_data),
    .lp_in_ready(lp_in_ready),
    .cxl_out_valid(cxl_out_valid),
    .cxl_out_data(cxl_out_data),
    .cxl_out_ready(cxl_out_ready),
    .link_up(link_up),
    .err_inj_en(err_inj_en),
    .drain_done(drain_done)
  );

  cxl_lpddr5x_bridge_chk #(.WIDTH(W)) u_chk (
    .clk(clk),
    .mem_clk(mem_clk),
    .rst_n(rst_n),
    .lp_out_valid(lp_out_valid),
    .lp_out_data(lp_out_data),
    .lp_out_ready(lp_out_ready),
    .cxl_out_valid(cxl_out_valid),
    .cxl_out_data(cxl_out_data),
    .cxl_out_ready(cxl_out_ready)
  );

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/waves.vcd");
      $dumpvars(0, tb_cxl_lpddr5x_bridge);
    end
  end

  // CXL host clock: 10 ns period (100 MHz)
  always #5 clk = ~clk;

  // LPDDR5X command-channel clock: phase-shifted so it never fires on the same
  // timestamp as clk. Period controlled by mem_clk_half (set before each ratio test).
  initial begin
    mem_clk = 1'b0;
    #2.5;
    forever begin
      #(mem_clk_half) mem_clk = ~mem_clk;
    end
  end

  task automatic do_reset;
    begin
      rst_n         = 1'b0;
      cxl_in_valid  = 1'b0;
      cxl_in_data   = {W{1'b0}};
      lp_out_ready  = 1'b0;
      lp_in_valid   = 1'b0;
      lp_in_data    = {W{1'b0}};
      cxl_out_ready = 1'b0;
      link_up       = 1'b0;
      err_inj_en    = 1'b0;
      c2m_pending_wr = 0;
      c2m_pending_rd = 0;
      repeat (6) @(posedge clk);
      rst_n   = 1'b1;
      link_up = 1'b1;
      repeat (4) @(posedge clk);
      repeat (4) @(posedge mem_clk);
    end
  endtask

  function automatic [31:0] rnd32;
    input [31:0] s;
    reg [31:0] x;
    begin
      x     = s;
      x     = x ^ (x << 13);
      x     = x ^ (x >> 17);
      x     = x ^ (x << 5);
      rnd32 = x;
    end
  endfunction

  // Gold model: mirrors translate_cxl_to_lp in the bridge RTL.
  function automatic [63:0] expect_lp_from_cxl;
    input [63:0] cxl_pkt;
    reg [63:0] raw_pkt;
    reg [7:0]  attr;
    reg [3:0]  lp_op;
    begin
      attr = cxl_pkt[PKT_AUX_MSB:PKT_AUX_LSB] ^ cxl_pkt[PKT_MISC_MSB:PKT_MISC_LSB];
      case (cxl_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CXL_PKT_KIND_MEM_RD: begin
          lp_op = (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_RD_OP_AUTOPRE) ?
                  LP_CMD_RDA : LP_CMD_RD;
          raw_pkt = pack_lp_cmd(lp_op, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_lp_from_cxl = raw_pkt;
        end
        CXL_PKT_KIND_MEM_WR: begin
          lp_op = (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_AUTOPRE) ? LP_CMD_WRA :
                  (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_MASKED)  ? LP_CMD_MWR :
                                                                             LP_CMD_WR;
          raw_pkt = pack_lp_cmd(lp_op, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_lp_from_cxl = raw_pkt;
        end
        CXL_PKT_KIND_MEM_MRR: begin
          raw_pkt = pack_lp_cmd(LP_CMD_MRR, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_lp_from_cxl = raw_pkt;
        end
        CXL_PKT_KIND_MEM_MRW: begin
          raw_pkt = pack_lp_cmd(LP_CMD_MRW, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_lp_from_cxl = raw_pkt;
        end
        default: begin
          raw_pkt = {LP_PKT_KIND_ERROR, 4'h0, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                     16'h0000, 8'h00, cxl_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          expect_lp_from_cxl = raw_pkt;
        end
      endcase
    end
  endfunction

  // Gold model: mirrors translate_lp_to_cxl in the bridge RTL.
  function automatic [63:0] expect_cxl_from_lp;
    input [63:0] lp_pkt;
    reg [63:0] chk_pkt;
    begin
      chk_pkt = lp_pkt;
      chk_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = 8'h00;
      case (lp_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        LP_PKT_KIND_RD_RSP:
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_cxl_from_lp = pack_cxl_rd_data(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB], lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_cxl_from_lp = {CXL_PKT_KIND_INVALID, 4'h0,
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        LP_PKT_KIND_WR_RSP:
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_cxl_from_lp = pack_cxl_mem_cpl(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB], lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_cxl_from_lp = {CXL_PKT_KIND_INVALID, 4'h0,
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        LP_PKT_KIND_MRR_RSP:
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt))
            expect_cxl_from_lp = pack_cxl_mrr_data(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB], lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB], lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          else
            expect_cxl_from_lp = {CXL_PKT_KIND_INVALID, 4'h0,
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
        default:
          expect_cxl_from_lp = {CXL_PKT_KIND_INVALID, 4'h0,
            lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB], 16'h0000, 8'h00,
            lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
      endcase
    end
  endfunction

  // Mirrors bridge RTL is_posted: true for MEM_WR and MEM_MRW kinds.
  function automatic is_posted_cxl;
    input [63:0] pkt;
    begin
      case (pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CXL_PKT_KIND_MEM_WR:  is_posted_cxl = 1'b1;
        CXL_PKT_KIND_MEM_MRW: is_posted_cxl = 1'b1;
        default:              is_posted_cxl = 1'b0;
      endcase
    end
  endfunction

  // Determines if an LPDDR5X command came from the posted c2m FIFO.
  // WR/WRA/MWR (writes) and MRW can only originate from posted CXL requests.
  function automatic is_lp_posted;
    input [63:0] pkt;
    begin
      case (pkt[PKT_CODE_MSB:PKT_CODE_LSB])
        LP_CMD_WR:  is_lp_posted = 1'b1;
        LP_CMD_WRA: is_lp_posted = 1'b1;
        LP_CMD_MWR: is_lp_posted = 1'b1;
        LP_CMD_MRW: is_lp_posted = 1'b1;
        default:    is_lp_posted = 1'b0;
      endcase
    end
  endfunction

  task automatic scoreboard_step_clk;
    begin
      if (cxl_in_valid && cxl_in_ready) begin
        if (is_posted_cxl(cxl_in_data)) begin
          if (c2m_posted_gold_wr >= GOLD_SZ) begin
            $display("FAIL: gold_c2m_posted overflow"); $finish(1);
          end
          gold_c2m_posted[c2m_posted_gold_wr] = expect_lp_from_cxl(cxl_in_data);
          c2m_posted_gold_wr = c2m_posted_gold_wr + 1;
        end else begin
          if (c2m_np_gold_wr >= GOLD_SZ) begin
            $display("FAIL: gold_c2m_np overflow"); $finish(1);
          end
          gold_c2m_np[c2m_np_gold_wr] = expect_lp_from_cxl(cxl_in_data);
          c2m_np_gold_wr = c2m_np_gold_wr + 1;
        end
        c2m_sent = c2m_sent + 1;
      end

      if (cxl_out_valid && cxl_out_ready) begin
        if (m2c_gold_rd >= m2c_gold_wr) begin
          $display("FAIL: m2c pop underrun"); $finish(1);
        end
        if (cxl_out_data !== gold_m2c[m2c_gold_rd]) begin
          $display("FAIL: m2c data mismatch exp=%h got=%h", gold_m2c[m2c_gold_rd], cxl_out_data);
          $finish(1);
        end
        m2c_gold_rd = m2c_gold_rd + 1;
        m2c_rcvd    = m2c_rcvd + 1;
      end

      while (c2m_pending_rd < c2m_pending_wr) begin
        if (pending_c2m_posted[c2m_pending_rd]) begin
          if (c2m_posted_gold_rd >= c2m_posted_gold_wr) begin
            $display("FAIL: c2m posted pop underrun"); $finish(1);
          end
          if (pending_c2m_data[c2m_pending_rd] !== gold_c2m_posted[c2m_posted_gold_rd]) begin
            $display("FAIL: c2m posted mismatch exp=%h got=%h",
                     gold_c2m_posted[c2m_posted_gold_rd], pending_c2m_data[c2m_pending_rd]);
            $finish(1);
          end
          c2m_posted_gold_rd = c2m_posted_gold_rd + 1;
        end else begin
          if (c2m_np_gold_rd >= c2m_np_gold_wr) begin
            $display("FAIL: c2m np pop underrun"); $finish(1);
          end
          if (pending_c2m_data[c2m_pending_rd] !== gold_c2m_np[c2m_np_gold_rd]) begin
            $display("FAIL: c2m np mismatch exp=%h got=%h",
                     gold_c2m_np[c2m_np_gold_rd], pending_c2m_data[c2m_pending_rd]);
            $finish(1);
          end
          c2m_np_gold_rd = c2m_np_gold_rd + 1;
        end
        c2m_pending_rd = c2m_pending_rd + 1;
        c2m_rcvd       = c2m_rcvd + 1;
      end
    end
  endtask

  task automatic scoreboard_step_mem;
    begin
      if (lp_out_valid && lp_out_ready) begin
        if (c2m_pending_wr >= GOLD_SZ) begin
          $display("FAIL: c2m pending overflow"); $finish(1);
        end
        pending_c2m_data[c2m_pending_wr]   = lp_out_data;
        pending_c2m_posted[c2m_pending_wr] = is_lp_posted(lp_out_data);
        c2m_pending_wr = c2m_pending_wr + 1;
      end

      if (lp_in_valid && lp_in_ready) begin
        if (m2c_gold_wr >= GOLD_SZ) begin
          $display("FAIL: gold_m2c overflow"); $finish(1);
        end
        gold_m2c[m2c_gold_wr] = expect_cxl_from_lp(lp_in_data);
        m2c_gold_wr          = m2c_gold_wr + 1;
        m2c_sent             = m2c_sent + 1;
      end
    end
  endtask

  initial begin
    forever begin
      @(posedge mem_clk);
      if (rst_n) scoreboard_step_mem();
    end
  end

  initial begin
    clk                = 1'b0;
    mem_clk            = 1'b0;
    mem_clk_half       = 5.0;   // start 1:1 (both 10 ns)
    rst_n              = 1'b0;
    cxl_in_valid       = 1'b0;
    cxl_in_data        = {W{1'b0}};
    lp_out_ready       = 1'b0;
    lp_in_valid        = 1'b0;
    lp_in_data         = {W{1'b0}};
    cxl_out_ready      = 1'b0;
    link_up            = 1'b0;
    err_inj_en         = 1'b0;
    seed               = 32'hACE15EED;
    c2m_posted_gold_wr = 0;
    c2m_posted_gold_rd = 0;
    c2m_np_gold_wr     = 0;
    c2m_np_gold_rd     = 0;
    c2m_pending_wr     = 0;
    c2m_pending_rd     = 0;
    m2c_gold_wr        = 0;
    m2c_gold_rd        = 0;
    c2m_sent           = 0;
    m2c_sent           = 0;
    c2m_rcvd           = 0;
    m2c_rcvd           = 0;

    // --- Clock ratio 1:1 ---
    $display("INFO: clock ratio 1:1  clk=100MHz mem_clk=100MHz");
    mem_clk_half = 5.0;
    do_reset();

    // --- Smoke 1: CXL.mem read -> LPDDR5X RD, then RD_RSP -> CXL read-data ---
    @(posedge clk);
    cxl_in_data  = pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 8'h3c, 16'hbeef, 8'h04, 8'ha1, 8'h0f);
    cxl_in_valid = 1'b1;
    lp_out_ready = 1'b1;
    @(posedge clk);
    while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
    cxl_in_valid = 1'b0;

    wait (lp_out_valid);
    if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 8'h3c, 16'hbeef, 8'h04, 8'ha1, 8'h0f))) begin
      $display("FAIL: smoke mem_rd lp_out_data got %h", lp_out_data);
      $finish(1);
    end
    @(posedge mem_clk); #1;

    @(posedge clk);
    lp_in_data   = pack_lp_rd_rsp(LP_RSP_OK, 8'h3c, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
    lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(lp_in_data);
    lp_in_valid   = 1'b1;
    cxl_out_ready = 1'b1;
    @(posedge clk);
    while (!(lp_in_valid && lp_in_ready)) @(posedge clk);
    lp_in_valid = 1'b0;

    wait (cxl_out_valid);
    @(posedge clk);
    if (cxl_out_data !== expect_cxl_from_lp(lp_in_data)) begin
      $display("FAIL: smoke rd_rsp cxl_out_data got %h", cxl_out_data);
      $finish(1);
    end

    // --- Smoke 2: all request/response kinds ---
    begin : blk_smoke_new_kinds
      reg [W-1:0] rpkt;

      // CXL.mem write (posted) -> LPDDR5X WR
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 8'h22, 16'h4000, 8'h04, 8'he5, 8'ha3);
      cxl_in_valid = 1'b1; lp_out_ready = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 8'h22, 16'h4000, 8'h04, 8'he5, 8'ha3))) begin
        $display("FAIL: smoke mem_wr got %h", lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      // CXL.mem MRR (non-posted) -> LPDDR5X MRR
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_mrr(4'h0, 8'h33, 16'h0008, 8'h01, 8'hf6, 8'h77);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_mrr(4'h0, 8'h33, 16'h0008, 8'h01, 8'hf6, 8'h77))) begin
        $display("FAIL: smoke mrr got %h", lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      // CXL.mem MRW (posted) -> LPDDR5X MRW
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_mrw(4'h0, 8'h44, 16'h000c, 8'h01, 8'ha7, 8'h5b);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_mrw(4'h0, 8'h44, 16'h000c, 8'h01, 8'ha7, 8'h5b))) begin
        $display("FAIL: smoke mrw got %h", lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      // LPDDR5X WR_RSP -> CXL MEM_CPL
      rpkt = pack_lp_wr_rsp(LP_RSP_OK, 8'h22, 16'h0040, 8'h04, 8'he5, 8'ha3, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      lp_in_data = rpkt; lp_in_valid = 1'b1; cxl_out_ready = 1'b1;
      @(posedge clk); while (!(lp_in_valid && lp_in_ready)) @(posedge clk);
      lp_in_valid = 1'b0;
      wait (cxl_out_valid); @(posedge clk);
      if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
        $display("FAIL: smoke wr_rsp got %h", cxl_out_data); $finish(1);
      end

      // LPDDR5X MRR_RSP -> CXL MRR_DATA
      rpkt = pack_lp_mrr_rsp(LP_RSP_OK, 8'h33, 16'h0001, 8'h01, 8'hf6, 8'h77, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      lp_in_data = rpkt; lp_in_valid = 1'b1;
      @(posedge clk); while (!(lp_in_valid && lp_in_ready)) @(posedge clk);
      lp_in_valid = 1'b0;
      wait (cxl_out_valid); @(posedge clk);
      if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
        $display("FAIL: smoke mrr_rsp got %h", cxl_out_data); $finish(1);
      end

      // LPDDR5X RD_RSP with ERR status -> CXL read-data (CA-equivalent)
      rpkt = pack_lp_rd_rsp(LP_RSP_ERR, 8'h5a, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
      @(posedge clk);
      lp_in_data = rpkt; lp_in_valid = 1'b1;
      @(posedge clk); while (!(lp_in_valid && lp_in_ready)) @(posedge clk);
      lp_in_valid = 1'b0;
      wait (cxl_out_valid); @(posedge clk);
      if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
        $display("FAIL: smoke rd_rsp_err got %h", cxl_out_data); $finish(1);
      end

      // LPDDR5X RD_RSP with CORRUPT checksum -> CXL INVALID
      rpkt = pack_lp_rd_rsp(LP_RSP_OK, 8'h77, 16'h0040, 8'h04, 8'hc3, 8'h18, 8'h00);
      rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt) ^ 8'hFF;  // bad CRC
      @(posedge clk);
      lp_in_data = rpkt; lp_in_valid = 1'b1;
      @(posedge clk); while (!(lp_in_valid && lp_in_ready)) @(posedge clk);
      lp_in_valid = 1'b0;
      wait (cxl_out_valid); @(posedge clk);
      if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
        $display("FAIL: smoke bad_crc got %h (want INVALID)", cxl_out_data); $finish(1);
      end
      if (cxl_out_data[PKT_KIND_MSB:PKT_KIND_LSB] !== CXL_PKT_KIND_INVALID) begin
        $display("FAIL: bad_crc did not map to INVALID got %h", cxl_out_data); $finish(1);
      end
    end

    // --- Smoke 3: ordering — posted (writes) bypass non-posted (reads) ---
    begin : blk_ordering
      reg [W-1:0] exp_posted0, exp_posted1, exp_np0, exp_np1;

      lp_out_ready = 1'b0;

      // posted packet 0: MEM_WR
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 8'hB1, 16'h3000, 8'h04, 8'h30, 8'h00);
      exp_posted0  = expect_lp_from_cxl(cxl_in_data);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;

      // posted packet 1: MEM_MRW
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_mrw(4'h0, 8'hB2, 16'h0004, 8'h01, 8'h40, 8'h00);
      exp_posted1  = expect_lp_from_cxl(cxl_in_data);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;

      // NP packet 0: MEM_RD (arrives after posted; arbiter already locked to posted)
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 8'hA1, 16'h1000, 8'h04, 8'h10, 8'h00);
      exp_np0      = expect_lp_from_cxl(cxl_in_data);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;

      // NP packet 1: MEM_MRR
      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_mrr(4'h0, 8'hA2, 16'h0002, 8'h01, 8'h20, 8'h00);
      exp_np1      = expect_lp_from_cxl(cxl_in_data);
      cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;

      // Release sink — posted FIFO has priority so posted drains first.
      @(posedge clk);
      lp_out_ready = 1'b1;

      wait (lp_out_valid);
      if (lp_out_data !== exp_posted0) begin
        $display("FAIL: ordering[0] want posted WR=%h got=%h", exp_posted0, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      wait (lp_out_valid);
      if (lp_out_data !== exp_posted1) begin
        $display("FAIL: ordering[1] want posted MRW=%h got=%h", exp_posted1, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      wait (lp_out_valid);
      if (lp_out_data !== exp_np0) begin
        $display("FAIL: ordering[2] want np RD=%h got=%h", exp_np0, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      wait (lp_out_valid);
      if (lp_out_data !== exp_np1) begin
        $display("FAIL: ordering[3] want np MRR=%h got=%h", exp_np1, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;
    end

    // --- Smoke 4: link_up gating ---
    begin : blk_link_up
      @(posedge clk);
      link_up = 1'b0;
      repeat (4) @(posedge clk);

      cxl_in_valid = 1'b1;
      cxl_in_data  = pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 8'hdd, 16'h5000, 8'h04, 8'h50, 8'h00);
      if (cxl_in_ready !== 1'b0) begin
        $display("FAIL: link_up_gate: cxl_in_ready must be 0 when bridge is closed"); $finish(1);
      end
      cxl_in_valid = 1'b0;

      @(posedge clk);
      if (!drain_done) begin
        $display("FAIL: link_up_gate: drain_done not asserted after FIFOs empty"); $finish(1);
      end

      link_up = 1'b1;
      repeat (4) @(posedge clk);
      $display("PASS smoke link_up_gating");
    end

    // --- Smoke 4.5: granular command opcodes (RDA / WRA / MWR) ---
    begin : blk_granular_ops
      reg [W-1:0] test_pkt;
      reg [W-1:0] exp_pkt;

      // RDA (read auto-precharge)
      @(posedge clk);
      test_pkt = pack_cxl_mem_rd(CXL_RD_OP_AUTOPRE, 8'hD1, 16'h7000, 8'h04, 8'h71, 8'h00);
      exp_pkt  = expect_lp_from_cxl(test_pkt);
      cxl_in_data = test_pkt; cxl_in_valid = 1'b1; lp_out_ready = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== exp_pkt) begin
        $display("FAIL: granular RDA exp=%h got=%h", exp_pkt, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      // WRA (write auto-precharge)
      @(posedge clk);
      test_pkt = pack_cxl_mem_wr(CXL_WR_OP_AUTOPRE, 8'hD2, 16'h8000, 8'h04, 8'h72, 8'h00);
      exp_pkt  = expect_lp_from_cxl(test_pkt);
      cxl_in_data = test_pkt; cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== exp_pkt) begin
        $display("FAIL: granular WRA exp=%h got=%h", exp_pkt, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      // MWR (masked write)
      @(posedge clk);
      test_pkt = pack_cxl_mem_wr(CXL_WR_OP_MASKED, 8'hD3, 16'h9000, 8'h04, 8'h73, 8'h00);
      exp_pkt  = expect_lp_from_cxl(test_pkt);
      cxl_in_data = test_pkt; cxl_in_valid = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid);
      if (lp_out_data !== exp_pkt) begin
        $display("FAIL: granular MWR exp=%h got=%h", exp_pkt, lp_out_data); $finish(1);
      end
      @(posedge mem_clk); #1;

      $display("PASS smoke granular_opcodes");
    end

    // --- Smoke 5: error injection (command-channel bit flip) ---
    begin : blk_err_inj
      reg [W-1:0] inj_pkt;
      reg [W-1:0] expected_clean;

      inj_pkt        = pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 8'hee, 16'h6000, 8'h04, 8'h60, 8'h00);
      expected_clean = expect_lp_from_cxl(inj_pkt);

      @(posedge clk);
      err_inj_en   = 1'b1;
      repeat (4) @(posedge clk);
      cxl_in_data  = inj_pkt;
      cxl_in_valid = 1'b1;
      lp_out_ready = 1'b1;

      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      err_inj_en   = 1'b0;

      wait (lp_out_valid);
      if (lp_out_data !== {expected_clean[W-1:1], ~expected_clean[0]}) begin
        $display("FAIL: err_inj: expected checksum bit 0 flipped exp=%h got=%h",
                 {expected_clean[W-1:1], ~expected_clean[0]}, lp_out_data);
        $finish(1);
      end
      $display("PASS smoke error_injection");
    end

    // --- Smoke 6: clock ratio 2:1 (mem_clk faster: 200 MHz) ---
    begin : blk_ratio_2_1
      $display("INFO: clock ratio 2:1  clk=100MHz mem_clk=200MHz");
      mem_clk_half = 2.5;
      do_reset();
      c2m_posted_gold_wr = 0; c2m_posted_gold_rd = 0;
      c2m_np_gold_wr     = 0; c2m_np_gold_rd     = 0;
      m2c_gold_wr        = 0; m2c_gold_rd        = 0;

      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_rd(CXL_RD_OP_AUTOPRE, 8'hA0, 16'h1234, 8'h04, 8'h10, 8'h00);
      cxl_in_valid = 1'b1; lp_out_ready = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid); @(posedge mem_clk);
      if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_rd(CXL_RD_OP_AUTOPRE, 8'hA0, 16'h1234, 8'h04, 8'h10, 8'h00))) begin
        $display("FAIL: ratio_2_1 c2m got=%h", lp_out_data); $finish(1);
      end

      begin : b21_m2c
        reg [W-1:0] rpkt;
        rpkt = pack_lp_rd_rsp(LP_RSP_OK, 8'hA0, 16'h0400, 8'h04, 8'h10, 8'hf5, 8'h00);
        rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
        @(posedge mem_clk);
        lp_in_data = rpkt; lp_in_valid = 1'b1; cxl_out_ready = 1'b1;
        @(posedge mem_clk); while (!(lp_in_valid && lp_in_ready)) @(posedge mem_clk);
        lp_in_valid = 1'b0;
        wait (cxl_out_valid); @(posedge clk);
        if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
          $display("FAIL: ratio_2_1 m2c got=%h", cxl_out_data); $finish(1);
        end
      end
      $display("PASS smoke ratio_2_1");
    end

    // --- Smoke 7: clock ratio 1:3 (mem_clk slower: ~67 MHz) ---
    begin : blk_ratio_1_3
      $display("INFO: clock ratio 1:3  clk=100MHz mem_clk=~67MHz");
      mem_clk_half = 7.5;
      do_reset();
      c2m_posted_gold_wr = 0; c2m_posted_gold_rd = 0;
      c2m_np_gold_wr     = 0; c2m_np_gold_rd     = 0;
      m2c_gold_wr        = 0; m2c_gold_rd        = 0;

      @(posedge clk);
      cxl_in_data  = pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 8'hB0, 16'h5678, 8'h02, 8'h20, 8'h00);
      cxl_in_valid = 1'b1; lp_out_ready = 1'b1;
      @(posedge clk); while (!(cxl_in_valid && cxl_in_ready)) @(posedge clk);
      cxl_in_valid = 1'b0;
      wait (lp_out_valid); @(posedge mem_clk);
      if (lp_out_data !== expect_lp_from_cxl(pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 8'hB0, 16'h5678, 8'h02, 8'h20, 8'h00))) begin
        $display("FAIL: ratio_1_3 c2m got=%h", lp_out_data); $finish(1);
      end

      begin : b13_m2c
        reg [W-1:0] rpkt;
        rpkt = pack_lp_wr_rsp(LP_RSP_OK, 8'hB0, 16'h0200, 8'h02, 8'h20, 8'h18, 8'h00);
        rpkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(rpkt);
        @(posedge mem_clk);
        lp_in_data = rpkt; lp_in_valid = 1'b1; cxl_out_ready = 1'b1;
        @(posedge mem_clk); while (!(lp_in_valid && lp_in_ready)) @(posedge mem_clk);
        lp_in_valid = 1'b0;
        wait (cxl_out_valid); @(posedge clk);
        if (cxl_out_data !== expect_cxl_from_lp(rpkt)) begin
          $display("FAIL: ratio_1_3 m2c got=%h", cxl_out_data); $finish(1);
        end
      end
      $display("PASS smoke ratio_1_3");
    end

    // Reset back to 1:1 for the stress run
    $display("INFO: returning to clock ratio 1:1 for stress");
    mem_clk_half = 5.0;
    do_reset();
    c2m_posted_gold_wr = 0; c2m_posted_gold_rd = 0;
    c2m_np_gold_wr     = 0; c2m_np_gold_rd     = 0;
    m2c_gold_wr        = 0; m2c_gold_rd        = 0;

    // --- Stress: concurrent traffic + random ready ---
    c2m_sent = 0; m2c_sent = 0; c2m_rcvd = 0; m2c_rcvd = 0;

    for (cyc = 0; cyc < NUM_CYCLES; cyc = cyc + 1) begin
      @(posedge clk);
      scoreboard_step_clk();

      seed         = rnd32(seed);
      lp_out_ready <= (seed % 5) != 0;
      seed         = rnd32(seed);
      cxl_out_ready <= (seed % 5) != 0;

      // CXL -> LPDDR5X source: all request kinds
      if (cxl_in_valid && cxl_in_ready) begin
        seed = rnd32(seed);
        if ((seed % 4) == 0)
          cxl_in_valid <= 1'b0;
        else begin
          cxl_in_valid <= 1'b1;
          cxl_in_data  <= cxl_in_data + 64'h00000000_00001001;
        end
      end else if (!cxl_in_valid) begin
        seed = rnd32(seed);
        if ((seed % 3) != 0) begin
          cxl_in_valid <= 1'b1;
          case (seed[20:18] % 4)
            3'd0: cxl_in_data <= pack_cxl_mem_rd(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd1: cxl_in_data <= pack_cxl_mem_wr(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd2: cxl_in_data <= pack_cxl_mem_mrr(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            default: cxl_in_data <= pack_cxl_mem_mrw(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
          endcase
        end
      end

      // LPDDR5X -> CXL source: all response kinds
      if (lp_in_valid && lp_in_ready) begin
        seed = rnd32(seed);
        if ((seed % 5) == 0)
          lp_in_valid <= 1'b0;
        else begin
          lp_in_valid <= 1'b1;
          lp_in_data  <= lp_in_data ^ 64'h10000000_00000001;
        end
      end else if (!lp_in_valid) begin
        seed = rnd32(seed);
        if ((seed % 4) != 0) begin
          lp_in_valid <= 1'b1;
          case (seed[19:18] % 3)
            2'd0: begin
              lp_in_data <= pack_lp_rd_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_rd_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                               seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                               seed[23:16], seed[7:0], 8'h00));
            end
            2'd1: begin
              lp_in_data <= pack_lp_wr_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_wr_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                               seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                               seed[23:16], seed[7:0], 8'h00));
            end
            default: begin
              lp_in_data <= pack_lp_mrr_rsp(seed[16] ? LP_RSP_ERR : LP_RSP_OK,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_mrr_rsp(seed[16] ? LP_RSP_ERR : LP_RSP_OK,
                                seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                                seed[23:16], seed[7:0], 8'h00));
            end
          endcase
        end
      end
    end

    // Drain
    @(posedge clk);
    scoreboard_step_clk();

    cxl_in_valid  <= 1'b0;
    lp_in_valid   <= 1'b0;
    lp_out_ready  <= 1'b1;
    cxl_out_ready <= 1'b1;

    repeat (FIFO_DEPTH + 64) begin
      @(posedge clk);
      if (cxl_out_valid && cxl_out_ready) begin
        if (m2c_gold_rd >= m2c_gold_wr) begin
          $display("FAIL: drain m2c underrun"); $finish(1);
        end
        if (cxl_out_data !== gold_m2c[m2c_gold_rd]) begin
          $display("FAIL: drain m2c mismatch exp=%h got=%h", gold_m2c[m2c_gold_rd], cxl_out_data);
          $finish(1);
        end
        m2c_gold_rd = m2c_gold_rd + 1;
        m2c_rcvd    = m2c_rcvd + 1;
      end
    end

    repeat (8) begin
      @(posedge clk);
      scoreboard_step_clk();
    end

    if (c2m_posted_gold_rd !== c2m_posted_gold_wr) begin
      $display("FAIL: c2m posted gold not empty wr=%0d rd=%0d", c2m_posted_gold_wr, c2m_posted_gold_rd); $finish(1);
    end
    if (c2m_np_gold_rd !== c2m_np_gold_wr) begin
      $display("FAIL: c2m np gold not empty wr=%0d rd=%0d", c2m_np_gold_wr, c2m_np_gold_rd); $finish(1);
    end
    if (c2m_pending_rd !== c2m_pending_wr) begin
      $display("FAIL: c2m pending not empty wr=%0d rd=%0d", c2m_pending_wr, c2m_pending_rd); $finish(1);
    end
    if (m2c_gold_rd !== m2c_gold_wr) begin
      $display("FAIL: m2c gold not empty wr=%0d rd=%0d", m2c_gold_wr, m2c_gold_rd); $finish(1);
    end
    if (lp_out_valid) begin
      $display("FAIL: lp_out still valid after drain"); $finish(1);
    end
    if (cxl_out_valid) begin
      $display("FAIL: cxl_out still valid after drain"); $finish(1);
    end
    if (c2m_sent !== c2m_rcvd) begin
      $display("FAIL: c2m sent=%0d rcvd=%0d", c2m_sent, c2m_rcvd); $finish(1);
    end
    if (m2c_sent !== m2c_rcvd) begin
      $display("FAIL: m2c sent=%0d rcvd=%0d", m2c_sent, m2c_rcvd); $finish(1);
    end

    p1_c2m_sent = c2m_sent;
    p1_m2c_sent = m2c_sent;
    $display("PASS stress c2m_beats=%0d m2c_beats=%0d", p1_c2m_sent, p1_m2c_sent);

    if (!$test$plusargs("stress"))
      $finish(0);

    // --- Heavy stress: longer run, sinks ready ~20% ---
    c2m_sent = 0; m2c_sent = 0; c2m_rcvd = 0; m2c_rcvd = 0;
    seed     = 32'hC0FFEE01;

    for (cyc = 0; cyc < NUM_STRESS_HEAVY; cyc = cyc + 1) begin
      @(posedge clk);
      scoreboard_step_clk();

      seed         = rnd32(seed);
      lp_out_ready <= (seed % 10) < 2;
      seed         = rnd32(seed);
      cxl_out_ready <= (seed % 10) < 2;

      if (cxl_in_valid && cxl_in_ready) begin
        seed = rnd32(seed);
        if ((seed % 4) == 0)
          cxl_in_valid <= 1'b0;
        else begin
          cxl_in_valid <= 1'b1;
          cxl_in_data  <= cxl_in_data + 64'h00000000_00001001;
        end
      end else if (!cxl_in_valid) begin
        seed = rnd32(seed);
        if ((seed % 3) != 0) begin
          cxl_in_valid <= 1'b1;
          case (seed[20:18] % 4)
            3'd0: cxl_in_data <= pack_cxl_mem_wr(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd1: cxl_in_data <= pack_cxl_mem_mrw(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            3'd2: cxl_in_data <= pack_cxl_mem_rd(seed[5:4], seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
            default: cxl_in_data <= pack_cxl_mem_mrr(4'h0, seed[15:8], seed[31:16],
                                   {6'h0, seed[7:6]}, seed[23:16], seed[7:0]);
          endcase
        end
      end

      if (lp_in_valid && lp_in_ready) begin
        seed = rnd32(seed);
        if ((seed % 5) == 0)
          lp_in_valid <= 1'b0;
        else begin
          lp_in_valid <= 1'b1;
          lp_in_data  <= lp_in_data ^ 64'h10000000_00000001;
        end
      end else if (!lp_in_valid) begin
        seed = rnd32(seed);
        if ((seed % 4) != 0) begin
          lp_in_valid <= 1'b1;
          case (seed[19:18] % 3)
            2'd0: begin
              lp_in_data <= pack_lp_rd_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_rd_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                               seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                               seed[23:16], seed[7:0], 8'h00));
            end
            2'd1: begin
              lp_in_data <= pack_lp_wr_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_wr_rsp(seed[16] ? LP_RSP_OK : LP_RSP_ERR,
                               seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                               seed[23:16], seed[7:0], 8'h00));
            end
            default: begin
              lp_in_data <= pack_lp_mrr_rsp(seed[16] ? LP_RSP_ERR : LP_RSP_OK,
                             seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                             seed[23:16], seed[7:0], 8'h00);
              lp_in_data[PKT_MISC_MSB:PKT_MISC_LSB] <= bridge_checksum(
                pack_lp_mrr_rsp(seed[16] ? LP_RSP_ERR : LP_RSP_OK,
                                seed[15:8], seed[31:16], {6'h0, seed[7:6]},
                                seed[23:16], seed[7:0], 8'h00));
            end
          endcase
        end
      end
    end

    @(posedge clk);
    scoreboard_step_clk();

    cxl_in_valid  <= 1'b0;
    lp_in_valid   <= 1'b0;
    lp_out_ready  <= 1'b1;
    cxl_out_ready <= 1'b1;

    repeat (FIFO_DEPTH + 128) begin
      @(posedge clk);
      if (cxl_out_valid && cxl_out_ready) begin
        if (m2c_gold_rd >= m2c_gold_wr) begin
          $display("FAIL: heavy drain m2c underrun"); $finish(1);
        end
        if (cxl_out_data !== gold_m2c[m2c_gold_rd]) begin
          $display("FAIL: heavy drain m2c mismatch exp=%h got=%h", gold_m2c[m2c_gold_rd], cxl_out_data);
          $finish(1);
        end
        m2c_gold_rd = m2c_gold_rd + 1;
        m2c_rcvd    = m2c_rcvd + 1;
      end
    end

    repeat (8) begin
      @(posedge clk);
      scoreboard_step_clk();
    end

    if (c2m_posted_gold_rd !== c2m_posted_gold_wr) begin
      $display("FAIL: heavy c2m posted gold not empty wr=%0d rd=%0d", c2m_posted_gold_wr, c2m_posted_gold_rd); $finish(1);
    end
    if (c2m_np_gold_rd !== c2m_np_gold_wr) begin
      $display("FAIL: heavy c2m np gold not empty wr=%0d rd=%0d", c2m_np_gold_wr, c2m_np_gold_rd); $finish(1);
    end
    if (c2m_pending_rd !== c2m_pending_wr) begin
      $display("FAIL: heavy c2m pending not empty wr=%0d rd=%0d", c2m_pending_wr, c2m_pending_rd); $finish(1);
    end
    if (m2c_gold_rd !== m2c_gold_wr) begin
      $display("FAIL: heavy m2c gold not empty wr=%0d rd=%0d", m2c_gold_wr, m2c_gold_rd); $finish(1);
    end
    if (lp_out_valid) begin
      $display("FAIL: heavy lp_out still valid after drain"); $finish(1);
    end
    if (cxl_out_valid) begin
      $display("FAIL: heavy cxl_out still valid after drain"); $finish(1);
    end
    if (c2m_sent !== c2m_rcvd) begin
      $display("FAIL: heavy c2m sent=%0d rcvd=%0d", c2m_sent, c2m_rcvd); $finish(1);
    end
    if (m2c_sent !== m2c_rcvd) begin
      $display("FAIL: heavy m2c sent=%0d rcvd=%0d", m2c_sent, m2c_rcvd); $finish(1);
    end

    $display("PASS stress_heavy c2m_beats=%0d m2c_beats=%0d (after default stress %0d/%0d)",
             c2m_sent, m2c_sent, p1_c2m_sent, p1_m2c_sent);
    $finish(0);
  end

endmodule
