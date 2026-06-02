// Drives cxl_out_ready (the CXL completion-egress consumer). Random backpressure
// at cfg.cxl_out_bp_pct so completions drain at a varying rate -- this also paces
// the m2c response-credit return, which is the real throttle on the m2c path.

`ifndef CXL_OUT_RESPONDER_SVH
`define CXL_OUT_RESPONDER_SVH

class cxl_out_responder extends uvm_component;
  `uvm_component_utils(cxl_out_responder)

  virtual cxl_if      vif;
  cxl_lpddr5x_cfg     cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cxl_if)::get(this, "", "cxl_vif", vif))
      `uvm_fatal(get_type_name(), "no cxl_vif in config_db")
    if (!uvm_config_db#(cxl_lpddr5x_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal(get_type_name(), "no cfg in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned stall_cnt = 0;
    vif.drv_cb.cxl_out_ready <= 1'b1;
    forever begin
      @(vif.drv_cb);
      if (stall_cnt > 0) begin
        vif.drv_cb.cxl_out_ready <= 1'b0;
        stall_cnt--;
      end else begin
        if ($urandom_range(99) < cfg.cxl_out_bp_pct) begin
          vif.drv_cb.cxl_out_ready <= 1'b0;
          stall_cnt = $urandom_range(cfg.cxl_out_max_stall, 1);
        end else begin
          vif.drv_cb.cxl_out_ready <= 1'b1;
        end
      end
    end
  endtask
endclass

`endif
