// SystemVerilog interfaces for the cxl_lpddr5x_bridge UVM environment.
//
//   cxl_if  : CXL host side, `clk` domain
//             - cxl_in_*  request ingress  (TB is producer / driver)
//             - cxl_out_* completion egress (TB is consumer / drives ready)
//   lp_if   : LPDDR5X side, `mem_clk` domain
//             - lp_out_*  command egress    (TB is consumer / drives ready)
//             - lp_in_*   response ingress  (TB is producer / driver)
//   ctrl_if : async control sampled into both domains by the DUT
//             - rst_n, link_up, err_inj_en (TB drives), drain_done (TB monitors)
//
// Drivers/monitors use clocking blocks with a 1step input skew (preponed sample)
// and a small output skew, which keeps the valid/ready handshake race-free under
// Xcelium and matches the protocol the directed/cocotb/SVA suites assume.

`ifndef CXL_LPDDR5X_IF_SV
`define CXL_LPDDR5X_IF_SV

interface cxl_if #(parameter int WIDTH = 64) (input logic clk);
  logic             cxl_in_valid;
  logic [WIDTH-1:0] cxl_in_data;
  logic             cxl_in_ready;
  logic             cxl_out_valid;
  logic [WIDTH-1:0] cxl_out_data;
  logic             cxl_out_ready;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output cxl_in_valid, cxl_in_data;
    input  cxl_in_ready;
    output cxl_out_ready;
    input  cxl_out_valid, cxl_out_data;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input cxl_in_valid, cxl_in_data, cxl_in_ready;
    input cxl_out_valid, cxl_out_data, cxl_out_ready;
  endclocking

  modport drv (clocking drv_cb);
  modport mon (clocking mon_cb);
endinterface

interface lp_if #(parameter int WIDTH = 64) (input logic mem_clk);
  logic             lp_out_valid;
  logic [WIDTH-1:0] lp_out_data;
  logic             lp_out_ready;
  logic             lp_in_valid;
  logic [WIDTH-1:0] lp_in_data;
  logic             lp_in_ready;

  clocking drv_cb @(posedge mem_clk);
    default input #1step output #1;
    output lp_in_valid, lp_in_data;
    input  lp_in_ready;
    output lp_out_ready;
    input  lp_out_valid, lp_out_data;
  endclocking

  clocking mon_cb @(posedge mem_clk);
    default input #1step;
    input lp_out_valid, lp_out_data, lp_out_ready;
    input lp_in_valid, lp_in_data, lp_in_ready;
  endclocking

  modport drv (clocking drv_cb);
  modport mon (clocking mon_cb);
endinterface

interface ctrl_if (input logic clk);
  // Driven asynchronously by the test; the DUT synchronizes them internally.
  // Initialized here so there is no X on the control inputs before the test
  // starts driving (the bridge holds in reset until rst_n rises anyway).
  logic rst_n      = 1'b0;
  logic link_up    = 1'b0;
  logic err_inj_en = 1'b0;
  logic drain_done;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, link_up, err_inj_en, drain_done;
  endclocking
endinterface

`endif
