// Monitors the CXL (clk) domain. Publishes every accepted request flit
// (cxl_in handshake) on req_ap and every accepted completion flit (cxl_out
// handshake) on cpl_ap, for the scoreboard and coverage.

`ifndef CXL_MONITOR_SVH
`define CXL_MONITOR_SVH

class cxl_monitor extends uvm_component;
  `uvm_component_utils(cxl_monitor)

  virtual cxl_if vif;
  uvm_analysis_port #(cxl_lpddr5x_flit) req_ap;   // cxl_in  (requests)
  uvm_analysis_port #(cxl_lpddr5x_flit) cpl_ap;   // cxl_out (completions)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_ap = new("req_ap", this);
    cpl_ap = new("cpl_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cxl_if)::get(this, "", "cxl_vif", vif))
      `uvm_fatal(get_type_name(), "no cxl_vif in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    cxl_lpddr5x_flit f;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.cxl_in_valid === 1'b1 && vif.mon_cb.cxl_in_ready === 1'b1) begin
        f = cxl_lpddr5x_flit::type_id::create("req");
        f.data = vif.mon_cb.cxl_in_data;
        req_ap.write(f);
      end
      if (vif.mon_cb.cxl_out_valid === 1'b1 && vif.mon_cb.cxl_out_ready === 1'b1) begin
        f = cxl_lpddr5x_flit::type_id::create("cpl");
        f.data = vif.mon_cb.cxl_out_data;
        cpl_ap.write(f);
      end
    end
  endtask
endclass

`endif
