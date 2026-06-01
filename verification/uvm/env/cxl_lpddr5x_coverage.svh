// Functional coverage on the request and response streams: opcode mix, response
// status, valid/corrupt CRC, and the request-kind x opcode cross. Reuses the
// _req / _rsp analysis-imp suffixes declared in the scoreboard.

`ifndef CXL_LPDDR5X_COVERAGE_SVH
`define CXL_LPDDR5X_COVERAGE_SVH

class cxl_lpddr5x_coverage extends uvm_component;
  `uvm_component_utils(cxl_lpddr5x_coverage)

  uvm_analysis_imp_req #(cxl_lpddr5x_flit, cxl_lpddr5x_coverage) req_imp;
  uvm_analysis_imp_rsp #(cxl_lpddr5x_flit, cxl_lpddr5x_coverage) rsp_imp;

  bit [3:0] cg_kind, cg_code;
  bit       cg_crc_ok;

  covergroup cg_req;
    option.per_instance = 1;
    kind_cp: coverpoint cg_kind {
      bins rd      = {CXL_PKT_KIND_MEM_RD};
      bins wr      = {CXL_PKT_KIND_MEM_WR};
      bins mrr     = {CXL_PKT_KIND_MEM_MRR};
      bins mrw     = {CXL_PKT_KIND_MEM_MRW};
      bins invalid = default;
    }
    code_cp: coverpoint cg_code { bins op[] = {[0:3]}; }
    kind_x_code: cross kind_cp, code_cp;
  endgroup

  covergroup cg_rsp;
    option.per_instance = 1;
    rkind_cp: coverpoint cg_kind {
      bins rd_rsp  = {LP_PKT_KIND_RD_RSP};
      bins wr_rsp  = {LP_PKT_KIND_WR_RSP};
      bins mrr_rsp = {LP_PKT_KIND_MRR_RSP};
      bins error   = {LP_PKT_KIND_ERROR};
      bins other   = default;
    }
    status_cp: coverpoint cg_code { bins ok = {LP_RSP_OK}; bins err = {LP_RSP_ERR}; bins other = default; }
    crc_cp:    coverpoint cg_crc_ok { bins good = {1}; bins bad = {0}; }
    rkind_x_crc: cross rkind_cp, crc_cp;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
    cg_req  = new();
    cg_rsp  = new();
  endfunction

  function void write_req(cxl_lpddr5x_flit t);
    cg_kind = t.kind();
    cg_code = t.code();
    cg_req.sample();
  endfunction

  function void write_rsp(cxl_lpddr5x_flit t);
    cg_kind   = t.kind();
    cg_code   = t.code();
    cg_crc_ok = (bridge_checksum(t.data & ~64'hFF) == t.misc());
    cg_rsp.sample();
  endfunction
endclass

`endif
