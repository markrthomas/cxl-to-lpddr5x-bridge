// Base 64-bit flit object, shared by both agents and broadcast by the monitors.
// Driver sequence items (cxl_req_item / lp_rsp_item) extend this with rand fields
// and fill `data` in post_randomize; monitors emit the base class with the
// observed `data`. Field accessors and the reference model live in the package
// (see cxl_lpddr5x_uvm_pkg.sv).

`ifndef CXL_LPDDR5X_FLIT_SVH
`define CXL_LPDDR5X_FLIT_SVH

class cxl_lpddr5x_flit extends uvm_sequence_item;
  bit [63:0] data;

  `uvm_object_utils_begin(cxl_lpddr5x_flit)
    `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "cxl_lpddr5x_flit");
    super.new(name);
  endfunction

  // Decoded field views (positions mirror cxl_lpddr5x_bridge_defs.vh).
  function bit [3:0]  kind(); return data[PKT_KIND_MSB:PKT_KIND_LSB]; endfunction
  function bit [3:0]  code(); return data[PKT_CODE_MSB:PKT_CODE_LSB]; endfunction
  function bit [7:0]  tag();  return data[PKT_TAG_MSB:PKT_TAG_LSB];   endfunction
  function bit [7:0]  misc(); return data[PKT_MISC_MSB:PKT_MISC_LSB]; endfunction

  function string convert2string();
    return $sformatf("flit=0x%016h (kind=0x%01h code=0x%01h tag=0x%02h)",
                     data, kind(), code(), tag());
  endfunction
endclass

`endif
