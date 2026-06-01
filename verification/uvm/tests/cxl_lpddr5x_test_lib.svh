// Test library.
//   cxl_lpddr5x_base_test : builds env + cfg, drives reset/link, runs a vseq,
//                           drains, and lets the scoreboard check_phase fire.
//   smoke / random / err_inj tests specialize cfg and the vseq.

`ifndef CXL_LPDDR5X_TEST_LIB_SVH
`define CXL_LPDDR5X_TEST_LIB_SVH

class cxl_lpddr5x_base_test extends uvm_test;
  `uvm_component_utils(cxl_lpddr5x_base_test)

  cxl_lpddr5x_env  env;
  cxl_lpddr5x_cfg  cfg;
  virtual ctrl_if  ctrl_vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Derived tests override to tweak the config.
  virtual function void configure_cfg();
  endfunction

  // Derived tests override to choose the stimulus.
  virtual function cxl_lpddr5x_vseq new_vseq();
    return cxl_lpddr5x_vseq::type_id::create("vseq");
  endfunction

  // Derived tests override to drive extra control activity in parallel with
  // traffic (e.g. err_inj windows). Must return when traffic-independent.
  virtual task drive_controls();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = cxl_lpddr5x_cfg::type_id::create("cfg");
    configure_cfg();
    uvm_config_db#(cxl_lpddr5x_cfg)::set(this, "env", "cfg", cfg);
    env = cxl_lpddr5x_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual ctrl_if)::get(this, "", "ctrl_vif", ctrl_vif))
      `uvm_fatal(get_type_name(), "no ctrl_vif in config_db")
  endfunction

  task do_reset();
    ctrl_vif.rst_n      = 1'b0;
    ctrl_vif.link_up    = 1'b0;
    ctrl_vif.err_inj_en = 1'b0;
    repeat (8) @(ctrl_vif.mon_cb);
    ctrl_vif.rst_n = 1'b1;
    repeat (4) @(ctrl_vif.mon_cb);
    ctrl_vif.link_up = 1'b1;
    repeat (6) @(ctrl_vif.mon_cb);
  endtask

  // Let in-flight traffic drain across both clock domains before checking.
  task drain();
    repeat (2000) @(ctrl_vif.mon_cb);
  endtask

  task run_phase(uvm_phase phase);
    cxl_lpddr5x_vseq vseq;
    phase.raise_objection(this, "running test");
    do_reset();
    vseq = new_vseq();
    vseq.n_req = cfg.num_reqs;
    vseq.n_rsp = cfg.num_rsps;
    fork
      drive_controls();
    join_none
    vseq.start(env.vsqr);
    drain();
    phase.drop_objection(this, "test complete");
  endtask
endclass

// ---- Smoke: every request opcode + a short response burst ----
class cxl_lpddr5x_smoke_test extends cxl_lpddr5x_base_test;
  `uvm_component_utils(cxl_lpddr5x_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure_cfg();
    cfg.num_reqs = 8;     // cxl_all_ops_seq ignores n; this sizes the response burst
    cfg.num_rsps = 24;
    cfg.cxl_out_bp_pct = 10;
    cfg.lp_out_bp_pct  = 10;
  endfunction
  function cxl_lpddr5x_vseq new_vseq();
    return cxl_lpddr5x_smoke_vseq::type_id::create("vseq");
  endfunction
endclass

// ---- Random soak with heavy backpressure ----
class cxl_lpddr5x_random_test extends cxl_lpddr5x_base_test;
  `uvm_component_utils(cxl_lpddr5x_random_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure_cfg();
    cfg.num_reqs = 600;
    cfg.num_rsps = 600;
    cfg.cxl_out_bp_pct = 30;
    cfg.lp_out_bp_pct  = 30;
  endfunction
endclass

// ---- Error injection: random err_inj windows; scoreboard masks the c2m LSB ----
class cxl_lpddr5x_err_inj_test extends cxl_lpddr5x_base_test;
  `uvm_component_utils(cxl_lpddr5x_err_inj_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure_cfg();
    cfg.num_reqs    = 400;
    cfg.num_rsps    = 400;
    cfg.mask_c2m_lsb = 1'b1;   // err_inj flips bit 0 of the c2m command
  endfunction
  task drive_controls();
    // Pulse err_inj_en in short windows for the duration of the run.
    forever begin
      repeat ($urandom_range(120, 40)) @(ctrl_vif.mon_cb);
      ctrl_vif.err_inj_en = 1'b1;
      repeat ($urandom_range(20, 5))   @(ctrl_vif.mon_cb);
      ctrl_vif.err_inj_en = 1'b0;
    end
  endtask
endclass

`endif
