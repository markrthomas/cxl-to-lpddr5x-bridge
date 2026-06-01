// Drives the LPDDR5X response ingress (lp_in_*) on the mem_clk domain. Same
// protocol-legal producer discipline as the CXL driver.

`ifndef LP_DRIVER_SVH
`define LP_DRIVER_SVH

class lp_driver extends uvm_driver #(lp_rsp_item);
  `uvm_component_utils(lp_driver)

  virtual lp_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual lp_if)::get(this, "", "lp_vif", vif))
      `uvm_fatal(get_type_name(), "no lp_vif in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    vif.drv_cb.lp_in_valid <= 1'b0;
    vif.drv_cb.lp_in_data  <= '0;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.pre_gap) @(vif.drv_cb);
      vif.drv_cb.lp_in_valid <= 1'b1;
      vif.drv_cb.lp_in_data  <= req.data;
      @(vif.drv_cb);
      while (vif.drv_cb.lp_in_ready !== 1'b1) @(vif.drv_cb);
      vif.drv_cb.lp_in_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask
endclass

`endif
