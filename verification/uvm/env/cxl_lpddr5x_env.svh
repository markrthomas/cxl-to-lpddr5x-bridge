// Top-level environment: the two agents, scoreboard, functional coverage, and a
// virtual sequencer. Wires each monitor analysis port to the scoreboard and
// coverage, and publishes cfg to all children.

`ifndef CXL_LPDDR5X_ENV_SVH
`define CXL_LPDDR5X_ENV_SVH

class cxl_lpddr5x_env extends uvm_env;
  `uvm_component_utils(cxl_lpddr5x_env)

  cxl_agent                 cxl_agt;
  lp_agent                  lp_agt;
  cxl_lpddr5x_scoreboard    sb;
  cxl_lpddr5x_coverage      cov;
  cxl_lpddr5x_vsequencer    vsqr;
  cxl_lpddr5x_cfg           cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(cxl_lpddr5x_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = cxl_lpddr5x_cfg::type_id::create("cfg");
      `uvm_info(get_type_name(), "no cfg supplied; using defaults", UVM_LOW)
    end
    uvm_config_db#(cxl_lpddr5x_cfg)::set(this, "*", "cfg", cfg);

    uvm_config_db#(uvm_active_passive_enum)::set(this, "cxl_agt", "is_active", cfg.cxl_active);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "lp_agt",  "is_active", cfg.lp_active);

    cxl_agt = cxl_agent::type_id::create("cxl_agt", this);
    lp_agt  = lp_agent::type_id::create("lp_agt", this);
    sb      = cxl_lpddr5x_scoreboard::type_id::create("sb", this);
    cov     = cxl_lpddr5x_coverage::type_id::create("cov", this);
    vsqr    = cxl_lpddr5x_vsequencer::type_id::create("vsqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // c2m
    cxl_agt.mon.req_ap.connect(sb.req_imp);
    cxl_agt.mon.req_ap.connect(cov.req_imp);
    lp_agt.mon.cmd_ap.connect(sb.cmd_imp);
    // m2c
    lp_agt.mon.rsp_ap.connect(sb.rsp_imp);
    lp_agt.mon.rsp_ap.connect(cov.rsp_imp);
    cxl_agt.mon.cpl_ap.connect(sb.cpl_imp);
    // virtual sequencer handles
    if (cfg.cxl_active == UVM_ACTIVE) vsqr.cxl_sqr = cxl_agt.sqr;
    if (cfg.lp_active  == UVM_ACTIVE) vsqr.lp_sqr  = lp_agt.sqr;
  endfunction
endclass

`endif
