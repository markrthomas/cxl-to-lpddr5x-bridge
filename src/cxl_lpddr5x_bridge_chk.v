// Simulation-only checks for cxl_lpddr5x_bridge egress ready/valid stability.
// lp_out_* checks run on mem_clk; cxl_out_* checks run on clk.

module cxl_lpddr5x_bridge_chk #(
  parameter integer WIDTH = 64
) (
  input wire                  clk,
  input wire                  mem_clk,
  input wire                  rst_n,
  input wire                  lp_out_valid,
  input wire [WIDTH-1:0]      lp_out_data,
  input wire                  lp_out_ready,
  input wire                  cxl_out_valid,
  input wire [WIDTH-1:0]      cxl_out_data,
  input wire                  cxl_out_ready
);

  // LPDDR5X command egress checks — sample on mem_clk
  reg                 prev_lv, prev_lr;
  reg [WIDTH-1:0]     prev_ld;

  always @(posedge mem_clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_lv <= 1'b0;
      prev_lr <= 1'b0;
      prev_ld <= {WIDTH{1'b0}};
    end else begin
      if (prev_lv && !prev_lr) begin
        if (!lp_out_valid) begin
          $display("ASSERT: lp_out_valid dropped while sink not ready");
          $finish(1);
        end
        if (lp_out_data !== prev_ld) begin
          $display("ASSERT: lp_out_data changed while valid && !ready");
          $finish(1);
        end
      end
      prev_lv <= lp_out_valid;
      prev_lr <= lp_out_ready;
      prev_ld <= lp_out_data;
    end
  end

  // CXL egress checks — sample on clk
  reg                 prev_cv, prev_cr;
  reg [WIDTH-1:0]     prev_cd;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_cv <= 1'b0;
      prev_cr <= 1'b0;
      prev_cd <= {WIDTH{1'b0}};
    end else begin
      if (prev_cv && !prev_cr) begin
        if (!cxl_out_valid) begin
          $display("ASSERT: cxl_out_valid dropped while sink not ready");
          $finish(1);
        end
        if (cxl_out_data !== prev_cd) begin
          $display("ASSERT: cxl_out_data changed while valid && !ready");
          $finish(1);
        end
      end
      prev_cv <= cxl_out_valid;
      prev_cr <= cxl_out_ready;
      prev_cd <= cxl_out_data;
    end
  end

endmodule
