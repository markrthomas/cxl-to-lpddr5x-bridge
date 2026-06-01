// Drives the CXL request ingress (cxl_in_*). Protocol-legal producer: optional
// idle gap, then assert valid + hold data stable until the handshake completes
// (valid is never withdrawn before acceptance).

`ifndef CXL_DRIVER_SVH
`define CXL_DRIVER_SVH

class cxl_driver extends uvm_driver #(cxl_req_item);
  `uvm_component_utils(cxl_driver)

  virtual cxl_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cxl_if)::get(this, "", "cxl_vif", vif))
      `uvm_fatal(get_type_name(), "no cxl_vif in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    vif.drv_cb.cxl_in_valid <= 1'b0;
    vif.drv_cb.cxl_in_data  <= '0;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.pre_gap) @(vif.drv_cb);
      vif.drv_cb.cxl_in_valid <= 1'b1;
      vif.drv_cb.cxl_in_data  <= req.data;
      @(vif.drv_cb);
      while (vif.drv_cb.cxl_in_ready !== 1'b1) @(vif.drv_cb);
      vif.drv_cb.cxl_in_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask
endclass

`endif
