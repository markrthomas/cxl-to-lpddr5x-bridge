// Sequence library: per-agent request/response sequences plus virtual sequences
// that coordinate them on the virtual sequencer.

`ifndef CXL_LPDDR5X_SEQ_LIB_SVH
`define CXL_LPDDR5X_SEQ_LIB_SVH

// ---- CXL request sequences (run on cxl_sequencer) ----

class cxl_random_seq extends uvm_sequence #(cxl_req_item);
  `uvm_object_utils(cxl_random_seq)
  rand int unsigned n = 300;
  function new(string name = "cxl_random_seq"); super.new(name); endfunction
  task body();
    cxl_req_item it;
    repeat (n) begin
      it = cxl_req_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_error(get_type_name(), "randomize failed")
      finish_item(it);
    end
  endtask
endclass

// One request of every kind/opcode, including an invalid kind.
class cxl_all_ops_seq extends uvm_sequence #(cxl_req_item);
  `uvm_object_utils(cxl_all_ops_seq)
  function new(string name = "cxl_all_ops_seq"); super.new(name); endfunction

  task one(bit [3:0] k, bit [3:0] c);
    cxl_req_item it = cxl_req_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with { pkt_kind == k; pkt_code == c; pre_gap == 1; })
      `uvm_error(get_type_name(), "randomize failed")
    finish_item(it);
  endtask

  task body();
    one(CXL_PKT_KIND_MEM_RD,  CXL_RD_OP_NORMAL);
    one(CXL_PKT_KIND_MEM_RD,  CXL_RD_OP_AUTOPRE);
    one(CXL_PKT_KIND_MEM_WR,  CXL_WR_OP_NORMAL);
    one(CXL_PKT_KIND_MEM_WR,  CXL_WR_OP_AUTOPRE);
    one(CXL_PKT_KIND_MEM_WR,  CXL_WR_OP_MASKED);
    one(CXL_PKT_KIND_MEM_MRR, 4'h0);
    one(CXL_PKT_KIND_MEM_MRW, 4'h0);
    one(4'h0,                 4'h0);   // invalid kind -> LP ERROR
  endtask
endclass

// ---- LPDDR5X response sequence (run on lp_sequencer) ----

class lp_random_rsp_seq extends uvm_sequence #(lp_rsp_item);
  `uvm_object_utils(lp_random_rsp_seq)
  rand int unsigned n = 300;
  function new(string name = "lp_random_rsp_seq"); super.new(name); endfunction
  task body();
    lp_rsp_item it;
    repeat (n) begin
      it = lp_rsp_item::type_id::create("it");
      start_item(it);
      if (!it.randomize()) `uvm_error(get_type_name(), "randomize failed")
      finish_item(it);
    end
  endtask
endclass

// ---- Virtual sequences ----

class cxl_lpddr5x_vseq extends uvm_sequence;
  `uvm_object_utils(cxl_lpddr5x_vseq)
  `uvm_declare_p_sequencer(cxl_lpddr5x_vsequencer)
  int unsigned n_req = 300;
  int unsigned n_rsp = 300;
  function new(string name = "cxl_lpddr5x_vseq"); super.new(name); endfunction

  task body();
    cxl_random_seq    cseq = cxl_random_seq::type_id::create("cseq");
    lp_random_rsp_seq lseq = lp_random_rsp_seq::type_id::create("lseq");
    cseq.n = n_req;
    lseq.n = n_rsp;
    fork
      cseq.start(p_sequencer.cxl_sqr);
      lseq.start(p_sequencer.lp_sqr);
    join
  endtask
endclass

// Directed smoke: every request opcode + a short response burst.
class cxl_lpddr5x_smoke_vseq extends cxl_lpddr5x_vseq;
  `uvm_object_utils(cxl_lpddr5x_smoke_vseq)
  function new(string name = "cxl_lpddr5x_smoke_vseq"); super.new(name); endfunction

  task body();
    cxl_all_ops_seq   cseq = cxl_all_ops_seq::type_id::create("cseq");
    lp_random_rsp_seq lseq = lp_random_rsp_seq::type_id::create("lseq");
    lseq.n = n_rsp;
    fork
      cseq.start(p_sequencer.cxl_sqr);
      lseq.start(p_sequencer.lp_sqr);
    join
  endtask
endclass

`endif
