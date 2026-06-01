// CXL-side agent: sequencer + driver (cxl_in requests), completion-egress
// responder (cxl_out_ready), and monitor. Active by default.

`ifndef CXL_AGENT_SVH
`define CXL_AGENT_SVH

typedef uvm_sequencer #(cxl_req_item) cxl_sequencer;

class cxl_agent extends uvm_agent;
  `uvm_component_utils(cxl_agent)

  cxl_sequencer     sqr;
  cxl_driver        drv;
  cxl_out_responder rsp;
  cxl_monitor       mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = cxl_monitor::type_id::create("mon", this);
    rsp = cxl_out_responder::type_id::create("rsp", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = cxl_sequencer::type_id::create("sqr", this);
      drv = cxl_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

`endif
