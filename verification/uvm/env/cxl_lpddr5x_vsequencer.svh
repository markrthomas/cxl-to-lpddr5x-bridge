// Virtual sequencer: handles to the two agent sequencers so a virtual sequence
// can run coordinated request + response stimulus.

`ifndef CXL_LPDDR5X_VSEQUENCER_SVH
`define CXL_LPDDR5X_VSEQUENCER_SVH

class cxl_lpddr5x_vsequencer extends uvm_sequencer;
  `uvm_component_utils(cxl_lpddr5x_vsequencer)

  cxl_sequencer cxl_sqr;
  lp_sequencer  lp_sqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass

`endif
