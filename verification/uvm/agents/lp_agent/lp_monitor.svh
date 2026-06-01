// Monitors the LPDDR5X (mem_clk) domain. Publishes every accepted command flit
// (lp_out handshake) on cmd_ap and every accepted response flit (lp_in handshake)
// on rsp_ap.

`ifndef LP_MONITOR_SVH
`define LP_MONITOR_SVH

class lp_monitor extends uvm_component;
  `uvm_component_utils(lp_monitor)

  virtual lp_if vif;
  uvm_analysis_port #(cxl_lpddr5x_flit) cmd_ap;   // lp_out (commands)
  uvm_analysis_port #(cxl_lpddr5x_flit) rsp_ap;   // lp_in  (responses)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cmd_ap = new("cmd_ap", this);
    rsp_ap = new("rsp_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual lp_if)::get(this, "", "lp_vif", vif))
      `uvm_fatal(get_type_name(), "no lp_vif in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    cxl_lpddr5x_flit f;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.lp_out_valid === 1'b1 && vif.mon_cb.lp_out_ready === 1'b1) begin
        f = cxl_lpddr5x_flit::type_id::create("cmd");
        f.data = vif.mon_cb.lp_out_data;
        cmd_ap.write(f);
      end
      if (vif.mon_cb.lp_in_valid === 1'b1 && vif.mon_cb.lp_in_ready === 1'b1) begin
        f = cxl_lpddr5x_flit::type_id::create("rsp");
        f.data = vif.mon_cb.lp_in_data;
        rsp_ap.write(f);
      end
    end
  endtask
endclass

`endif
