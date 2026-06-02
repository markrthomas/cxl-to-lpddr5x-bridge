// Environment configuration: backpressure rates, transaction counts, agent
// activeness, and the err_inj LSB-mask knob (the err_inj test flips bit 0 of the
// c2m command, so the scoreboard masks that bit while injection is enabled).

`ifndef CXL_LPDDR5X_CFG_SVH
`define CXL_LPDDR5X_CFG_SVH

class cxl_lpddr5x_cfg extends uvm_object;
  // Sink backpressure, percent of cycles ready is deasserted [0..100].
  int unsigned cxl_out_bp_pct = 25;
  int unsigned lp_out_bp_pct  = 25;
  // Maximum consecutive stall cycles.
  int unsigned cxl_out_max_stall = 10;
  int unsigned lp_out_max_stall  = 10;
  // Stimulus volume for the random sequences.
  int unsigned num_reqs = 300;
  int unsigned num_rsps = 300;
  // Tolerate the err_inj bit-0 flip on c2m command compares.
  bit mask_c2m_lsb = 1'b0;
  // Agent activeness.
  uvm_active_passive_enum cxl_active = UVM_ACTIVE;
  uvm_active_passive_enum lp_active  = UVM_ACTIVE;

  `uvm_object_utils_begin(cxl_lpddr5x_cfg)
    `uvm_field_int(cxl_out_bp_pct, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(lp_out_bp_pct,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(num_reqs,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(num_rsps,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(mask_c2m_lsb,   UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "cxl_lpddr5x_cfg");
    super.new(name);
  endfunction
endclass

`endif
