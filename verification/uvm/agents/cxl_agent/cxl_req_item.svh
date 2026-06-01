// Randomized CXL.mem request flit (drives cxl_in). Weighted toward the four real
// request kinds, with a small probability of an invalid kind to exercise the
// bridge's bad-opcode -> LP ERROR path. `pre_gap` injects idle cycles before the
// driver asserts valid, so backpressure/idle patterns vary.

`ifndef CXL_REQ_ITEM_SVH
`define CXL_REQ_ITEM_SVH

class cxl_req_item extends cxl_lpddr5x_flit;
  rand bit [3:0]    pkt_kind;
  rand bit [3:0]    pkt_code;
  rand bit [7:0]    pkt_tag;
  rand bit [15:0]   pkt_addr;
  rand bit [7:0]    pkt_len;
  rand bit [7:0]    pkt_id;
  rand bit [7:0]    pkt_aux;
  rand int unsigned pre_gap;

  `uvm_object_utils_begin(cxl_req_item)
    `uvm_field_int(pkt_kind, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_code, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_tag,  UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_addr, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_len,  UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_id,   UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_aux,  UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pre_gap,  UVM_ALL_ON | UVM_DEC)
  `uvm_object_utils_end

  function new(string name = "cxl_req_item");
    super.new(name);
  endfunction

  constraint c_kind {
    pkt_kind dist {
      CXL_PKT_KIND_MEM_RD  := 30,
      CXL_PKT_KIND_MEM_WR  := 30,
      CXL_PKT_KIND_MEM_MRR := 12,
      CXL_PKT_KIND_MEM_MRW := 12,
      [4'h0:4'hF]          := 2   // small spread -> occasional invalid kind
    };
  }
  constraint c_code {
    (pkt_kind == CXL_PKT_KIND_MEM_RD) -> pkt_code inside {CXL_RD_OP_NORMAL, CXL_RD_OP_AUTOPRE};
    (pkt_kind == CXL_PKT_KIND_MEM_WR) -> pkt_code inside {CXL_WR_OP_NORMAL, CXL_WR_OP_AUTOPRE, CXL_WR_OP_MASKED};
  }
  constraint c_len { pkt_len inside {[1:16]}; }
  constraint c_gap { pre_gap inside {[0:4]}; }

  function void post_randomize();
    // Ingress flits are not checksummed (the bridge recomputes the command CRC).
    data = pack64(pkt_kind, pkt_code, pkt_tag, pkt_addr, pkt_len, pkt_id, pkt_aux, 8'h00);
  endfunction
endclass

`endif
