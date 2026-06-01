// Randomized LPDDR5X response flit (drives lp_in). Responses carry a valid CRC by
// default; `corrupt_crc` flips one header bit so the checksum fails, exercising
// the bridge's response-CRC -> CXL INVALID-completion path. m2c flow is credit-
// gated (not tag-matched), so random tags are fine for checking the translation.

`ifndef LP_RSP_ITEM_SVH
`define LP_RSP_ITEM_SVH

class lp_rsp_item extends cxl_lpddr5x_flit;
  rand bit [3:0]    pkt_kind;
  rand bit [3:0]    pkt_code;   // status (OK / ERR)
  rand bit [7:0]    pkt_tag;
  rand bit [15:0]   pkt_addr;   // byte_count
  rand bit [7:0]    pkt_len;
  rand bit [7:0]    pkt_id;
  rand bit [7:0]    pkt_aux;    // lower_addr
  rand int unsigned pre_gap;
  rand bit          corrupt_crc;
  rand bit [5:0]    corrupt_bit;  // which header bit to flip (8..55) when corrupting

  `uvm_object_utils_begin(lp_rsp_item)
    `uvm_field_int(pkt_kind,    UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_code,    UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_tag,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_addr,    UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_len,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_id,      UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pkt_aux,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(pre_gap,     UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(corrupt_crc, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "lp_rsp_item");
    super.new(name);
  endfunction

  constraint c_kind {
    pkt_kind dist {
      LP_PKT_KIND_RD_RSP  := 30,
      LP_PKT_KIND_WR_RSP  := 30,
      LP_PKT_KIND_MRR_RSP := 20,
      LP_PKT_KIND_ERROR   := 6,
      [4'h0:4'hF]         := 2
    };
  }
  constraint c_code    { pkt_code inside {LP_RSP_OK, LP_RSP_ERR}; }
  constraint c_len     { pkt_len inside {[1:16]}; }
  constraint c_gap     { pre_gap inside {[0:4]}; }
  constraint c_corrupt { corrupt_crc dist {1'b0 := 88, 1'b1 := 12}; }
  constraint c_cbit    { corrupt_bit inside {[0:47]}; }  // bit (8+corrupt_bit) in [8:55]

  function void post_randomize();
    bit [63:0] p;
    p = pack64(pkt_kind, pkt_code, pkt_tag, pkt_addr, pkt_len, pkt_id, pkt_aux, 8'h00);
    p = with_checksum(p);
    if (corrupt_crc) p[8 + corrupt_bit] = ~p[8 + corrupt_bit];
    data = p;
  endfunction
endclass

`endif
