// Scoreboard: end-to-end data/translation checker against the pure-function
// reference model in the package (expect_lp_from_cxl / expect_cxl_from_lp).
//
// c2m: every accepted request (cxl_in) produces exactly one command (lp_out).
//   The bridge has separate posted (WR/MRW) and non-posted (RD/MRR/invalid)
//   FIFOs merged by a posted-priority arbiter, so order is preserved *within*
//   each class but the two classes interleave. We therefore keep two ordered
//   expected queues and match each observed command against its class queue.
// m2c: a single completion FIFO, so responses->completions are strictly ordered;
//   one expected queue.
//
// err_inj flips bit 0 of the c2m command; when cfg.mask_c2m_lsb is set we compare
// with bit 0 masked.

`ifndef CXL_LPDDR5X_SCOREBOARD_SVH
`define CXL_LPDDR5X_SCOREBOARD_SVH

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_cmd)
`uvm_analysis_imp_decl(_rsp)
`uvm_analysis_imp_decl(_cpl)

class cxl_lpddr5x_scoreboard extends uvm_component;
  `uvm_component_utils(cxl_lpddr5x_scoreboard)

  uvm_analysis_imp_req #(cxl_lpddr5x_flit, cxl_lpddr5x_scoreboard) req_imp;
  uvm_analysis_imp_cmd #(cxl_lpddr5x_flit, cxl_lpddr5x_scoreboard) cmd_imp;
  uvm_analysis_imp_rsp #(cxl_lpddr5x_flit, cxl_lpddr5x_scoreboard) rsp_imp;
  uvm_analysis_imp_cpl #(cxl_lpddr5x_flit, cxl_lpddr5x_scoreboard) cpl_imp;

  cxl_lpddr5x_cfg cfg;

  // Expected queues.
  bit [63:0] exp_posted[$];
  bit [63:0] exp_np[$];
  bit [63:0] exp_cpl[$];

  // Stats.
  int unsigned n_req, n_cmd, n_rsp, n_cpl, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    cmd_imp = new("cmd_imp", this);
    rsp_imp = new("rsp_imp", this);
    cpl_imp = new("cpl_imp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(cxl_lpddr5x_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no cfg in config_db")
  endfunction

  // ---- c2m: request observed on cxl_in -> expected command enqueued by class ----
  function void write_req(cxl_lpddr5x_flit t);
    bit [63:0] exp = expect_lp_from_cxl(t.data);
    n_req++;
    if (is_posted_kind(t.kind())) exp_posted.push_back(exp);
    else                          exp_np.push_back(exp);
  endfunction

  // ---- c2m: command observed on lp_out -> pop its class queue and compare ----
  function void write_cmd(cxl_lpddr5x_flit t);
    bit [63:0] exp, got, mask;
    bit posted = cmd_is_posted(t.data);
    n_cmd++;
    mask = cfg.mask_c2m_lsb ? ~64'h1 : ~64'h0;
    if (posted) begin
      if (exp_posted.size() == 0) begin
        `uvm_error("SB/C2M", $sformatf("unexpected POSTED command 0x%016h (no pending request)", t.data))
        n_err++; return;
      end
      exp = exp_posted.pop_front();
    end else begin
      if (exp_np.size() == 0) begin
        `uvm_error("SB/C2M", $sformatf("unexpected NON-POSTED command 0x%016h (no pending request)", t.data))
        n_err++; return;
      end
      exp = exp_np.pop_front();
    end
    got = t.data;
    if ((got & mask) !== (exp & mask)) begin
      `uvm_error("SB/C2M", $sformatf("command mismatch: got 0x%016h exp 0x%016h (mask=0x%016h)", got, exp, mask))
      n_err++;
    end
  endfunction

  // ---- m2c: response observed on lp_in -> expected completion enqueued ----
  function void write_rsp(cxl_lpddr5x_flit t);
    n_rsp++;
    exp_cpl.push_back(expect_cxl_from_lp(t.data));
  endfunction

  // ---- m2c: completion observed on cxl_out -> pop and compare ----
  function void write_cpl(cxl_lpddr5x_flit t);
    bit [63:0] exp;
    n_cpl++;
    if (exp_cpl.size() == 0) begin
      `uvm_error("SB/M2C", $sformatf("unexpected completion 0x%016h (no pending response)", t.data))
      n_err++; return;
    end
    exp = exp_cpl.pop_front();
    if (t.data !== exp) begin
      `uvm_error("SB/M2C", $sformatf("completion mismatch: got 0x%016h exp 0x%016h", t.data, exp))
      n_err++;
    end
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (exp_posted.size() || exp_np.size())
      `uvm_error("SB/C2M", $sformatf("at end of test, %0d posted + %0d non-posted commands never appeared on lp_out",
                 exp_posted.size(), exp_np.size()))
    if (exp_cpl.size())
      `uvm_error("SB/M2C", $sformatf("at end of test, %0d completions never appeared on cxl_out", exp_cpl.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(),
      $sformatf("checked c2m: %0d req / %0d cmd | m2c: %0d rsp / %0d cpl | errors=%0d",
                n_req, n_cmd, n_rsp, n_cpl, n_err), UVM_LOW)
  endfunction
endclass

`endif
