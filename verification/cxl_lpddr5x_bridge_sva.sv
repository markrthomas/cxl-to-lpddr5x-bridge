// Concurrent SystemVerilog Assertions (SVA) for the cxl_lpddr5x_bridge
// valid/ready stream interfaces. Bound to the DUT (see the `bind` at the bottom)
// and exercised at runtime by Verilator `--assert` via the sim/sim_main.cpp
// stimulus (`make sva`). Icarus is NOT used for this file — its concurrent-SVA
// support is insufficient; the equivalent properties are proved formally in the
// `ifdef FORMAL block of cxl_lpddr5x_bridge.v (Yosys-supported immediate style).
//
// Protocol contract checked on every valid/ready interface (producer drives
// valid+data, consumer drives ready):
//   * valid, once asserted, holds until the cycle after a handshake
//     (valid must not be withdrawn before being accepted);
//   * data is held stable while a transfer is stalled (valid && !ready);
//   * cover goals record that each interface both handshakes and stalls.
//
// Domain map: cxl_in / cxl_out are in the `clk` domain;
//             lp_out  / lp_in  are in the `mem_clk` domain.

module cxl_lpddr5x_bridge_sva #(
  parameter integer WIDTH = 64
) (
  input logic              clk,
  input logic              mem_clk,
  input logic              rst_n,
  // CXL request ingress (clk)
  input logic              cxl_in_valid,
  input logic [WIDTH-1:0]  cxl_in_data,
  input logic              cxl_in_ready,
  // LPDDR5X command egress (mem_clk)
  input logic              lp_out_valid,
  input logic [WIDTH-1:0]  lp_out_data,
  input logic              lp_out_ready,
  // LPDDR5X response ingress (mem_clk)
  input logic              lp_in_valid,
  input logic [WIDTH-1:0]  lp_in_data,
  input logic              lp_in_ready,
  // CXL completion egress (clk)
  input logic              cxl_out_valid,
  input logic [WIDTH-1:0]  cxl_out_data,
  input logic              cxl_out_ready
);

  // ---- CXL request ingress (clk domain) ----
  cxl_in_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (cxl_in_valid && !cxl_in_ready) |=> cxl_in_valid);
  cxl_in_data_stable:  assert property (@(posedge clk) disable iff (!rst_n)
    (cxl_in_valid && !cxl_in_ready) |=> $stable(cxl_in_data));
  cxl_in_handshake:    cover  property (@(posedge clk) disable iff (!rst_n)
    cxl_in_valid && cxl_in_ready);
  cxl_in_stall:        cover  property (@(posedge clk) disable iff (!rst_n)
    cxl_in_valid && !cxl_in_ready);

  // ---- LPDDR5X command egress (mem_clk domain) ----
  lp_out_valid_stable: assert property (@(posedge mem_clk) disable iff (!rst_n)
    (lp_out_valid && !lp_out_ready) |=> lp_out_valid);
  lp_out_data_stable:  assert property (@(posedge mem_clk) disable iff (!rst_n)
    (lp_out_valid && !lp_out_ready) |=> $stable(lp_out_data));
  lp_out_handshake:    cover  property (@(posedge mem_clk) disable iff (!rst_n)
    lp_out_valid && lp_out_ready);
  lp_out_stall:        cover  property (@(posedge mem_clk) disable iff (!rst_n)
    lp_out_valid && !lp_out_ready);

  // ---- LPDDR5X response ingress (mem_clk domain) ----
  lp_in_valid_stable:  assert property (@(posedge mem_clk) disable iff (!rst_n)
    (lp_in_valid && !lp_in_ready) |=> lp_in_valid);
  lp_in_data_stable:   assert property (@(posedge mem_clk) disable iff (!rst_n)
    (lp_in_valid && !lp_in_ready) |=> $stable(lp_in_data));
  lp_in_handshake:     cover  property (@(posedge mem_clk) disable iff (!rst_n)
    lp_in_valid && lp_in_ready);
  lp_in_stall:         cover  property (@(posedge mem_clk) disable iff (!rst_n)
    lp_in_valid && !lp_in_ready);

  // ---- CXL completion egress (clk domain) ----
  cxl_out_valid_stable: assert property (@(posedge clk) disable iff (!rst_n)
    (cxl_out_valid && !cxl_out_ready) |=> cxl_out_valid);
  cxl_out_data_stable:  assert property (@(posedge clk) disable iff (!rst_n)
    (cxl_out_valid && !cxl_out_ready) |=> $stable(cxl_out_data));
  cxl_out_handshake:    cover  property (@(posedge clk) disable iff (!rst_n)
    cxl_out_valid && cxl_out_ready);
  cxl_out_stall:        cover  property (@(posedge clk) disable iff (!rst_n)
    cxl_out_valid && !cxl_out_ready);

endmodule

// Bind the checker into every cxl_lpddr5x_bridge instance.
bind cxl_lpddr5x_bridge cxl_lpddr5x_bridge_sva #(.WIDTH(WIDTH)) u_sva (.*);
