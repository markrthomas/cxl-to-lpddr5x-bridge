// UVM testbench top for cxl_lpddr5x_bridge.
//
// Generates the two asynchronous clocks (CXL host `clk` 100 MHz, LPDDR5X
// `mem_clk` ~71 MHz, phase-offset so edges never coincide), instantiates the
// interfaces + DUT, publishes the virtual interfaces, and starts the UVM test.
// Build with +define+DUMP (and `xrun -access +rwc`) to emit an SHM waveform.

`timescale 1ns/1ps

module cxl_lpddr5x_tb_top;
  import uvm_pkg::*;
  import cxl_lpddr5x_uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int WIDTH = 64;

  logic clk = 1'b0;
  logic mem_clk = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz
  initial begin
    #2;                                 // phase offset vs clk
    forever #7 mem_clk = ~mem_clk;      // ~71 MHz, asynchronous to clk
  end

  cxl_if  #(WIDTH) cxl_vif  (.clk(clk));
  lp_if   #(WIDTH) lp_vif   (.mem_clk(mem_clk));
  ctrl_if          ctrl_vif (.clk(clk));

  cxl_lpddr5x_bridge #(.WIDTH(WIDTH)) dut (
    .clk          (clk),
    .mem_clk      (mem_clk),
    .rst_n        (ctrl_vif.rst_n),
    .cxl_in_valid (cxl_vif.cxl_in_valid),
    .cxl_in_data  (cxl_vif.cxl_in_data),
    .cxl_in_ready (cxl_vif.cxl_in_ready),
    .lp_out_valid (lp_vif.lp_out_valid),
    .lp_out_data  (lp_vif.lp_out_data),
    .lp_out_ready (lp_vif.lp_out_ready),
    .lp_in_valid  (lp_vif.lp_in_valid),
    .lp_in_data   (lp_vif.lp_in_data),
    .lp_in_ready  (lp_vif.lp_in_ready),
    .cxl_out_valid(cxl_vif.cxl_out_valid),
    .cxl_out_data (cxl_vif.cxl_out_data),
    .cxl_out_ready(cxl_vif.cxl_out_ready),
    .link_up      (ctrl_vif.link_up),
    .err_inj_en   (ctrl_vif.err_inj_en),
    .drain_done   (ctrl_vif.drain_done)
  );

  initial begin
    uvm_config_db#(virtual cxl_if )::set(null, "*", "cxl_vif",  cxl_vif);
    uvm_config_db#(virtual lp_if  )::set(null, "*", "lp_vif",   lp_vif);
    uvm_config_db#(virtual ctrl_if)::set(null, "*", "ctrl_vif", ctrl_vif);
    run_test();
  end

`ifdef DUMP
  initial begin
    $shm_open("waves.shm");
    $shm_probe(cxl_lpddr5x_tb_top, "AS");
  end
`endif
endmodule
