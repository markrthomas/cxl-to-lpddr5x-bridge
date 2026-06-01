// LPDDR5X-side agent: sequencer + driver (lp_in responses), command-egress
// responder (lp_out_ready / memory sink), and monitor. Active by default.

`ifndef LP_AGENT_SVH
`define LP_AGENT_SVH

typedef uvm_sequencer #(lp_rsp_item) lp_sequencer;

class lp_agent extends uvm_agent;
  `uvm_component_utils(lp_agent)

  lp_sequencer     sqr;
  lp_driver        drv;
  lp_out_responder rsp;
  lp_monitor       mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = lp_monitor::type_id::create("mon", this);
    rsp = lp_out_responder::type_id::create("rsp", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = lp_sequencer::type_id::create("sqr", this);
      drv = lp_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

`endif
