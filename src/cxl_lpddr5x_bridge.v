// CXL <-> LPDDR5X bridge (digital-only RTL).
//
// Upstream (host) side runs on `clk`; downstream LPDDR5X command channel runs
// on `mem_clk`.  The two domains are decoupled by dual-clock async FIFOs.
//
// c2m path (CXL request -> LPDDR5X command):
//   posted FIFO   : writes (MEM_WR) and mode-register writes (MEM_MRW)
//   non-posted FIFO: reads (MEM_RD) and mode-register reads (MEM_MRR)
//   Each request is translated into one LPDDR5X command flit (RD/RDA/WR/WRA/
//   MWR/MRW/MRR) with a CRC-8 appended on the command channel.
//
// m2c path (LPDDR5X response -> CXL completion):
//   completion FIFO: read-data / write-ack / mode-register responses.
//   The command-channel CRC is checked; a corrupted response becomes a CXL
//   INVALID completion.
//
// Per-class credit counters meter ingress; credit-return pulses cross domains
// through toggle-based pulse synchronizers.  A reset/drain FSM gates the bridge
// open only while the LPDDR5X link is up and drains cleanly on link-down.

/* verilator lint_off UNUSEDPARAM */
`include "cxl_lpddr5x_bridge_defs.vh"
/* verilator lint_on UNUSEDPARAM */

module cxl_lpddr5x_bridge #(
  parameter integer WIDTH          = 64,
  parameter integer FIFO_DEPTH     = 8,
  parameter integer POSTED_CREDITS = 8,
  parameter integer NP_CREDITS     = 8,
  parameter integer RSP_CREDITS    = 8
) (
  input  wire                  clk,
  input  wire                  mem_clk,    // LPDDR5X command-channel domain clock
  input  wire                  rst_n,
  // CXL -> LPDDR5X  (clk domain in, mem_clk domain out)
  input  wire                  cxl_in_valid,
  input  wire [WIDTH-1:0]      cxl_in_data,
  output wire                  cxl_in_ready,
  output wire                  lp_out_valid,
  output wire [WIDTH-1:0]      lp_out_data,
  input  wire                  lp_out_ready,
  // LPDDR5X -> CXL  (mem_clk domain in, clk domain out)
  input  wire                  lp_in_valid,
  input  wire [WIDTH-1:0]      lp_in_data,
  output wire                  lp_in_ready,
  output wire                  cxl_out_valid,
  output wire [WIDTH-1:0]      cxl_out_data,
  input  wire                  cxl_out_ready,
  // Link readiness and error injection
  input  wire                  link_up,
  input  wire                  err_inj_en,
  output wire                  drain_done
);

  generate
    if (WIDTH != 64) begin : gen_width_check
      initial $fatal(1, "cxl_lpddr5x_bridge: WIDTH must be 64 for the typed packet model");
    end
  endgenerate

  // --- Reset synchronization ---
  wire clk_rst_n;
  wire mem_rst_n;

  reset_sync #(.STAGES(2)) u_clk_rst_sync (
    .clk(clk), .async_rst_n(rst_n), .sync_rst_n(clk_rst_n)
  );
  reset_sync #(.STAGES(2)) u_mem_rst_sync (
    .clk(mem_clk), .async_rst_n(rst_n), .sync_rst_n(mem_rst_n)
  );

  // --- CDC for external control signals ---
  wire link_up_clk;
  wire err_inj_en_clk;

  cdc_sync #(.STAGES(2)) u_link_up_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(link_up), .q(link_up_clk)
  );
  cdc_sync #(.STAGES(2)) u_err_inj_cdc (
    .clk(clk), .rst_n(clk_rst_n), .d(err_inj_en), .q(err_inj_en_clk)
  );

  // --- Request ordering classification ---
  // Posted: writes and mode-register writes (fire-and-forget).
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic is_posted;
    input [WIDTH-1:0] pkt;
    begin
      case (pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CXL_PKT_KIND_MEM_WR:  is_posted = 1'b1;
        CXL_PKT_KIND_MEM_MRW: is_posted = 1'b1;
        default:              is_posted = 1'b0;
      endcase
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // --- Translation: CXL request -> LPDDR5X command flit ---

  function automatic [WIDTH-1:0] translate_cxl_to_lp;
    input [WIDTH-1:0] cxl_pkt;
    reg [63:0] raw_pkt;
    reg [7:0]  attr;
    reg [3:0]  lp_op;
    begin
      // Channel/rank attributes derive from the request's aux/misc bytes.
      attr = cxl_pkt[PKT_AUX_MSB:PKT_AUX_LSB] ^ cxl_pkt[PKT_MISC_MSB:PKT_MISC_LSB];
      case (cxl_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        CXL_PKT_KIND_MEM_RD: begin
          lp_op = (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_RD_OP_AUTOPRE) ?
                  LP_CMD_RDA : LP_CMD_RD;
          raw_pkt = pack_lp_cmd(lp_op,
            cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
            cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB],
            attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          translate_cxl_to_lp = raw_pkt[WIDTH-1:0];
        end
        CXL_PKT_KIND_MEM_WR: begin
          lp_op = (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_AUTOPRE) ? LP_CMD_WRA :
                  (cxl_pkt[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_MASKED)  ? LP_CMD_MWR :
                                                                             LP_CMD_WR;
          raw_pkt = pack_lp_cmd(lp_op,
            cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
            cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB],
            attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          translate_cxl_to_lp = raw_pkt[WIDTH-1:0];
        end
        CXL_PKT_KIND_MEM_MRR: begin
          raw_pkt = pack_lp_cmd(LP_CMD_MRR,
            cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
            cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB],
            attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          translate_cxl_to_lp = raw_pkt[WIDTH-1:0];
        end
        CXL_PKT_KIND_MEM_MRW: begin
          raw_pkt = pack_lp_cmd(LP_CMD_MRW,
            cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
            cxl_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
            cxl_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
            cxl_pkt[PKT_ID_MSB:PKT_ID_LSB],
            attr, 8'h00);
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          translate_cxl_to_lp = raw_pkt[WIDTH-1:0];
        end
        default: begin
          raw_pkt = {LP_PKT_KIND_ERROR, 4'h0, cxl_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                     16'h0000, 8'h00, cxl_pkt[PKT_ID_MSB:PKT_ID_LSB],
                     8'h00, 8'h00};
          raw_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = bridge_checksum(raw_pkt);
          translate_cxl_to_lp = raw_pkt[WIDTH-1:0];
        end
      endcase
    end
  endfunction

  // --- Translation: LPDDR5X response -> CXL completion flit ---

  function automatic [WIDTH-1:0] translate_lp_to_cxl;
    input [WIDTH-1:0] lp_pkt;
    reg [63:0] raw_pkt;
    reg [63:0] chk_pkt;
    begin
      chk_pkt = lp_pkt;
      chk_pkt[PKT_MISC_MSB:PKT_MISC_LSB] = 8'h00;
      case (lp_pkt[PKT_KIND_MSB:PKT_KIND_LSB])
        LP_PKT_KIND_RD_RSP: begin
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt)) begin
            raw_pkt = pack_cxl_rd_data(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB],
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
              lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB],
              lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          end else begin
            raw_pkt = {CXL_PKT_KIND_INVALID, 4'h0, lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                       16'h0000, 8'h00, lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          end
          translate_lp_to_cxl = raw_pkt[WIDTH-1:0];
        end
        LP_PKT_KIND_WR_RSP: begin
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt)) begin
            raw_pkt = pack_cxl_mem_cpl(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB],
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
              lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB],
              lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          end else begin
            raw_pkt = {CXL_PKT_KIND_INVALID, 4'h0, lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                       16'h0000, 8'h00, lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          end
          translate_lp_to_cxl = raw_pkt[WIDTH-1:0];
        end
        LP_PKT_KIND_MRR_RSP: begin
          if (lp_pkt[PKT_MISC_MSB:PKT_MISC_LSB] == bridge_checksum(chk_pkt)) begin
            raw_pkt = pack_cxl_mrr_data(
              lp_pkt[PKT_CODE_MSB:PKT_CODE_LSB],
              lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
              lp_pkt[PKT_ADDR_MSB:PKT_ADDR_LSB],
              lp_pkt[PKT_LEN_MSB:PKT_LEN_LSB],
              lp_pkt[PKT_ID_MSB:PKT_ID_LSB],
              lp_pkt[PKT_AUX_MSB:PKT_AUX_LSB]);
          end else begin
            raw_pkt = {CXL_PKT_KIND_INVALID, 4'h0, lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                       16'h0000, 8'h00, lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          end
          translate_lp_to_cxl = raw_pkt[WIDTH-1:0];
        end
        default: begin
          raw_pkt = {CXL_PKT_KIND_INVALID, 4'h0, lp_pkt[PKT_TAG_MSB:PKT_TAG_LSB],
                     16'h0000, 8'h00, lp_pkt[PKT_ID_MSB:PKT_ID_LSB], 8'h00, 8'h00};
          translate_lp_to_cxl = raw_pkt[WIDTH-1:0];
        end
      endcase
    end
  endfunction

  // --- Internal signals ---

  // Async FIFO status (per clock domain)
  wire c2m_posted_w_full;   // clk domain
  wire c2m_posted_r_empty;  // mem_clk domain
  wire c2m_np_w_full;       // clk domain
  wire c2m_np_r_empty;      // mem_clk domain
  wire m2c_w_full;          // mem_clk domain
  wire m2c_r_empty;         // clk domain

  // FIFO read data (combinational, respective read domain)
  wire [WIDTH-1:0] c2m_posted_rd_data;  // mem_clk domain
  wire [WIDTH-1:0] c2m_np_rd_data;      // mem_clk domain
  wire [WIDTH-1:0] m2c_rd_data;         // clk domain

  // Synchronize c2m r_empty signals to clk for drain_done
  wire c2m_posted_r_empty_clk;
  wire c2m_np_r_empty_clk;
  cdc_sync #(.STAGES(2)) u_p_empty_cdc (
    .clk  (clk), .rst_n(clk_rst_n),
    .d    (c2m_posted_r_empty), .q(c2m_posted_r_empty_clk)
  );
  cdc_sync #(.STAGES(2)) u_np_empty_cdc (
    .clk  (clk), .rst_n(clk_rst_n),
    .d    (c2m_np_r_empty),    .q(c2m_np_r_empty_clk)
  );

  // Link readiness FSM (clk domain)
  wire all_empty = c2m_posted_r_empty_clk && c2m_np_r_empty_clk && m2c_r_empty;
  wire bridge_open;

  reset_drain u_reset_drain (
    .clk       (clk),
    .rst_n     (clk_rst_n),
    .link_up   (link_up_clk),
    .all_empty (all_empty),
    .open      (bridge_open),
    .drain_done(drain_done)
  );

  // Synchronize bridge_open to mem_clk domain
  wire bridge_open_mem;
  cdc_sync #(.STAGES(2)) u_open_cdc (
    .clk  (mem_clk), .rst_n(mem_rst_n),
    .d    (bridge_open), .q(bridge_open_mem)
  );

  // Error injection (clk domain — corrupts CXL->LPDDR5X command data, models a
  // command-channel bit error that the downstream CRC check must catch).
  wire [WIDTH-1:0] c2m_wr_data_raw = translate_cxl_to_lp(cxl_in_data);
  wire [WIDTH-1:0] c2m_wr_data     = err_inj_en_clk ?
    {c2m_wr_data_raw[WIDTH-1:1], ~c2m_wr_data_raw[0]} : c2m_wr_data_raw;

  // LPDDR5X->CXL translation (mem_clk domain input)
  wire [WIDTH-1:0] m2c_wr_data = translate_lp_to_cxl(lp_in_data);

  wire cxl_in_is_posted_w = is_posted(cxl_in_data);

  // --- CXL domain ingress gating (clk) ---
  wire posted_crd_avail;
  wire np_crd_avail;
  assign cxl_in_ready  = bridge_open && (cxl_in_is_posted_w ?
                         (!c2m_posted_w_full && posted_crd_avail) :
                         (!c2m_np_w_full     && np_crd_avail));

  // --- LPDDR5X domain ingress gating (mem_clk) ---
  wire rsp_crd_avail;
  assign lp_in_ready = bridge_open_mem && (!m2c_w_full && rsp_crd_avail);

  // --- CXL domain egress (clk) ---
  assign cxl_out_valid = !m2c_r_empty;
  assign cxl_out_data  = m2c_rd_data;

  // --- LPDDR5X domain egress arbiter (mem_clk) ---
  // Posted-priority: when both FIFOs have data, posted (write) commands drain
  // first.  Lock the selection while a beat is in flight (valid && !ready).
  reg  arb_locked_r;
  reg  arb_sel_posted_r;

  wire arb_sel_now   = !c2m_posted_r_empty;
  wire arb_sel_final = arb_locked_r ? arb_sel_posted_r : arb_sel_now;

  always @(posedge mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n) begin
      arb_locked_r     <= 1'b0;
      arb_sel_posted_r <= 1'b0;
    end else begin
      if (arb_locked_r) begin
        if (lp_out_ready)
          arb_locked_r <= 1'b0;
      end else if (lp_out_valid && !lp_out_ready) begin
        arb_locked_r     <= 1'b1;
        arb_sel_posted_r <= arb_sel_now;
      end
    end
  end

  assign lp_out_valid = !c2m_posted_r_empty || !c2m_np_r_empty;
  assign lp_out_data  = arb_sel_final ? c2m_posted_rd_data : c2m_np_rd_data;

  wire c2m_wr        = cxl_in_valid && cxl_in_ready;
  wire c2m_posted_wr = c2m_wr &&  cxl_in_is_posted_w;
  wire c2m_np_wr     = c2m_wr && !cxl_in_is_posted_w;
  wire c2m_posted_rd = lp_out_valid && lp_out_ready &&  arb_sel_final;
  wire c2m_np_rd     = lp_out_valid && lp_out_ready && !arb_sel_final;
  wire m2c_wr        = lp_in_valid && lp_in_ready;
  wire m2c_rd        = cxl_out_ready && cxl_out_valid;

  // --- Credit counters and pulse syncs ---

  wire posted_ret_clk;
  credit_pulse_sync u_posted_ret_sync (
    .src_clk(mem_clk), .src_rst_n(mem_rst_n), .src_pulse(c2m_posted_rd),
    .dst_clk(clk),     .dst_rst_n(clk_rst_n), .dst_pulse(posted_ret_clk)
  );
  credit_counter #(.CREDITS(POSTED_CREDITS)) u_posted_crd (
    .clk(clk), .rst_n(clk_rst_n), .consume(c2m_posted_wr), .ret(posted_ret_clk),
    .available(posted_crd_avail)
  );

  wire np_ret_clk;
  credit_pulse_sync u_np_ret_sync (
    .src_clk(mem_clk), .src_rst_n(mem_rst_n), .src_pulse(c2m_np_rd),
    .dst_clk(clk),     .dst_rst_n(clk_rst_n), .dst_pulse(np_ret_clk)
  );
  credit_counter #(.CREDITS(NP_CREDITS)) u_np_crd (
    .clk(clk), .rst_n(clk_rst_n), .consume(c2m_np_wr), .ret(np_ret_clk),
    .available(np_crd_avail)
  );

  wire rsp_ret_mem;
  credit_pulse_sync u_rsp_ret_sync (
    .src_clk(clk),     .src_rst_n(clk_rst_n), .src_pulse(m2c_rd),
    .dst_clk(mem_clk), .dst_rst_n(mem_rst_n), .dst_pulse(rsp_ret_mem)
  );
  credit_counter #(.CREDITS(RSP_CREDITS)) u_rsp_crd (
    .clk(mem_clk), .rst_n(mem_rst_n), .consume(m2c_wr), .ret(rsp_ret_mem),
    .available(rsp_crd_avail)
  );

  // --- Async FIFOs ---

  async_fifo #(
    .WIDTH (WIDTH),
    .DEPTH (FIFO_DEPTH)
  ) u_c2m_posted (
    .w_clk   (clk),           .w_rst_n(clk_rst_n),
    .w_en    (c2m_posted_wr), .w_data (c2m_wr_data), .w_full (c2m_posted_w_full),
    .r_clk   (mem_clk),       .r_rst_n(mem_rst_n),
    .r_en    (c2m_posted_rd), .r_data (c2m_posted_rd_data), .r_empty(c2m_posted_r_empty)
  );

  async_fifo #(
    .WIDTH (WIDTH),
    .DEPTH (FIFO_DEPTH)
  ) u_c2m_np (
    .w_clk   (clk),       .w_rst_n(clk_rst_n),
    .w_en    (c2m_np_wr), .w_data (c2m_wr_data), .w_full (c2m_np_w_full),
    .r_clk   (mem_clk),   .r_rst_n(mem_rst_n),
    .r_en    (c2m_np_rd), .r_data (c2m_np_rd_data), .r_empty(c2m_np_r_empty)
  );

  async_fifo #(
    .WIDTH (WIDTH),
    .DEPTH (FIFO_DEPTH)
  ) u_m2c (
    .w_clk   (mem_clk), .w_rst_n(mem_rst_n),
    .w_en    (m2c_wr),  .w_data (m2c_wr_data), .w_full (m2c_w_full),
    .r_clk   (clk),     .r_rst_n(clk_rst_n),
    .r_en    (m2c_rd),  .r_data (m2c_rd_data),  .r_empty(m2c_r_empty)
  );

`ifdef FORMAL
  // Helper: checksum check for the m2c (response) direction.
  wire [63:0] f_m2c_chk_zero = {lp_in_data[63:8], 8'h00};
  wire        f_m2c_cs_ok    = (lp_in_data[7:0] == bridge_checksum(f_m2c_chk_zero));

  // Credits formal (clk domain)
  always @(*) begin
    if (clk_rst_n) begin
      if (c2m_posted_wr) assert (posted_crd_avail);
      if (c2m_np_wr)     assert (np_crd_avail);
    end
  end

  // Credits formal (mem_clk domain)
  always @(*) begin
    if (mem_rst_n) begin
      if (m2c_wr) assert (rsp_crd_avail);
    end
  end

  // Translation kind preservation (combinational, clock-agnostic).
  always @(*) begin
    if (cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_RD ||
        cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_WR ||
        cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRR ||
        cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRW)
      assert (c2m_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_CMD);
    else
      assert (c2m_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_ERROR);

    // Command sub-op selection.
    if (cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_RD) begin
      if (cxl_in_data[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_RD_OP_AUTOPRE)
        assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_RDA);
      else
        assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_RD);
    end
    if (cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_WR) begin
      if (cxl_in_data[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_AUTOPRE)
        assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_WRA);
      else if (cxl_in_data[PKT_CODE_MSB:PKT_CODE_LSB] == CXL_WR_OP_MASKED)
        assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_MWR);
      else
        assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_WR);
    end
    if (cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRR)
      assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_MRR);
    if (cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRW)
      assert (c2m_wr_data[PKT_CODE_MSB:PKT_CODE_LSB] == LP_CMD_MRW);

    // Address carried through to the bank/row field unchanged (when err_inj off).
    if (!err_inj_en_clk &&
        cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] != CXL_PKT_KIND_INVALID)
      assert (c2m_wr_data[PKT_ADDR_MSB:PKT_ADDR_LSB] ==
              cxl_in_data[PKT_ADDR_MSB:PKT_ADDR_LSB] ||
              c2m_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_ERROR);

    // Response translation kind mapping (checksum-gated).
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_RD_RSP && f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_RD_DATA);
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_WR_RSP && f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_CPL);
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_MRR_RSP && f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MRR_DATA);

    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_RD_RSP && !f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_INVALID);
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_WR_RSP && !f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_INVALID);
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_MRR_RSP && !f_m2c_cs_ok)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_INVALID);
    if (lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] != LP_PKT_KIND_RD_RSP  &&
        lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] != LP_PKT_KIND_WR_RSP  &&
        lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] != LP_PKT_KIND_MRR_RSP)
      assert (m2c_wr_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_INVALID);
  end

  // Link gating (clk domain — ingress gating is combinational).
  always @(*) begin
    if (!bridge_open) begin
      assert (cxl_in_ready  == 1'b0);
      assert (lp_in_ready   == 1'b0 || bridge_open_mem == 1'b1);
    end
  end

  // Error injection correctness (combinational).
  always @(*) begin
    if (err_inj_en_clk) begin
      assert (c2m_wr_data[0]         == ~c2m_wr_data_raw[0]);
      assert (c2m_wr_data[WIDTH-1:1] ==  c2m_wr_data_raw[WIDTH-1:1]);
    end else begin
      assert (c2m_wr_data == c2m_wr_data_raw);
    end
  end

  // Ordering domain routing (clk domain, combinational).
  always @(*) begin
    if (cxl_in_valid && cxl_in_ready) begin
      if (cxl_in_is_posted_w)
        assert (c2m_posted_wr && !c2m_np_wr);
      else
        assert (!c2m_posted_wr && c2m_np_wr);
    end
  end

  // Arbiter correctness (mem_clk domain).
  always_ff @(posedge mem_clk) begin
    if (mem_rst_n) begin
      if (lp_out_valid && lp_out_ready) begin
        assert (c2m_posted_rd == arb_sel_final);
        assert (c2m_np_rd     == !arb_sel_final);
      end
      if (!arb_locked_r && !c2m_posted_r_empty)
        assert (arb_sel_final == 1'b1);
    end
  end

  // Covers (clk domain).
  always_ff @(posedge clk) begin
    if (clk_rst_n) begin
      cover (cxl_in_valid && cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_RD);
      cover (cxl_in_valid && cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_WR);
      cover (cxl_in_valid && cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRR);
      cover (cxl_in_valid && cxl_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == CXL_PKT_KIND_MEM_MRW);
      cover (cxl_in_valid && !cxl_in_ready && !bridge_open);
      cover (cxl_in_valid && !cxl_in_ready && bridge_open && !posted_crd_avail);
      cover (err_inj_en_clk && c2m_np_wr);
      cover (drain_done);
    end
  end

  // Covers (mem_clk domain).
  always_ff @(posedge mem_clk) begin
    if (mem_rst_n) begin
      cover (lp_in_valid && !lp_in_ready && bridge_open_mem && !rsp_crd_avail);
      cover (lp_in_valid && lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_WR_RSP);
      cover (lp_in_valid && lp_in_data[PKT_KIND_MSB:PKT_KIND_LSB] == LP_PKT_KIND_MRR_RSP);
      cover (c2m_posted_rd && !c2m_np_r_empty);
    end
  end
`endif

endmodule
