// Drives lp_out_ready (the LPDDR5X command-egress consumer / "memory" sink).
// Random backpressure at cfg.lp_out_bp_pct so the c2m command FIFOs fill and
// drain at a varying rate.

`ifndef LP_OUT_RESPONDER_SVH
`define LP_OUT_RESPONDER_SVH

class lp_out_responder extends uvm_component;
  `uvm_component_utils(lp_out_responder)

  virtual lp_if   vif;
  cxl_lpddr5x_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual lp_if)::get(this, "", "lp_vif", vif))
      `uvm_fatal(get_type_name(), "no lp_vif in config_db")
    if (!uvm_config_db#(cxl_lpddr5x_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no cfg in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    vif.drv_cb.lp_out_ready <= 1'b1;
    forever begin
      @(vif.drv_cb);
      vif.drv_cb.lp_out_ready <= (($urandom_range(99) >= cfg.lp_out_bp_pct) ? 1'b1 : 1'b0);
    end
  endtask
endclass

`endif
