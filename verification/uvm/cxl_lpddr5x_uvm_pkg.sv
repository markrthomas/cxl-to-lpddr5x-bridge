// UVM package for the cxl_lpddr5x_bridge environment.
//
// Self-contained: the packet constants, field positions, CRC-8, pack helper, and
// the two translation reference models below are SV ports of
// src/cxl_lpddr5x_bridge_defs.vh and the translate_* functions in the RTL. Kept
// here (rather than `include of the .vh) so the verification package compiles
// standalone under any UVM simulator.

`ifndef CXL_LPDDR5X_UVM_PKG_SV
`define CXL_LPDDR5X_UVM_PKG_SV

package cxl_lpddr5x_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---- CXL.mem packet kinds [63:60] ----
  localparam bit [3:0] CXL_PKT_KIND_MEM_RD      = 4'h1;
  localparam bit [3:0] CXL_PKT_KIND_MEM_WR      = 4'h2;
  localparam bit [3:0] CXL_PKT_KIND_MEM_MRR     = 4'h3;
  localparam bit [3:0] CXL_PKT_KIND_MEM_MRW     = 4'h4;
  localparam bit [3:0] CXL_PKT_KIND_MEM_RD_DATA = 4'h8;
  localparam bit [3:0] CXL_PKT_KIND_MEM_CPL     = 4'h9;
  localparam bit [3:0] CXL_PKT_KIND_MRR_DATA    = 4'hA;
  localparam bit [3:0] CXL_PKT_KIND_INVALID     = 4'hF;

  // ---- CXL read / write opcodes ----
  localparam bit [3:0] CXL_RD_OP_NORMAL  = 4'h0;
  localparam bit [3:0] CXL_RD_OP_AUTOPRE = 4'h1;
  localparam bit [3:0] CXL_WR_OP_NORMAL  = 4'h0;
  localparam bit [3:0] CXL_WR_OP_AUTOPRE = 4'h1;
  localparam bit [3:0] CXL_WR_OP_MASKED  = 4'h2;

  // ---- LPDDR5X downstream packet kinds [63:60] ----
  localparam bit [3:0] LP_PKT_KIND_CMD     = 4'h8;
  localparam bit [3:0] LP_PKT_KIND_RD_RSP  = 4'hA;
  localparam bit [3:0] LP_PKT_KIND_WR_RSP  = 4'hB;
  localparam bit [3:0] LP_PKT_KIND_MRR_RSP = 4'hC;
  localparam bit [3:0] LP_PKT_KIND_ERROR   = 4'hE;

  // ---- LPDDR5X command sub-ops (PKT_CODE of LP_PKT_KIND_CMD) ----
  localparam bit [3:0] LP_CMD_RD  = 4'h1;
  localparam bit [3:0] LP_CMD_RDA = 4'h2;
  localparam bit [3:0] LP_CMD_WR  = 4'h3;
  localparam bit [3:0] LP_CMD_WRA = 4'h4;
  localparam bit [3:0] LP_CMD_MWR = 4'h5;
  localparam bit [3:0] LP_CMD_MRW = 4'h6;
  localparam bit [3:0] LP_CMD_MRR = 4'h7;

  // ---- LPDDR5X response status ----
  localparam bit [3:0] LP_RSP_OK  = 4'h1;
  localparam bit [3:0] LP_RSP_ERR = 4'h2;

  // ---- 64-bit packet field bit-ranges ----
  localparam int PKT_KIND_MSB = 63, PKT_KIND_LSB = 60;
  localparam int PKT_CODE_MSB = 59, PKT_CODE_LSB = 56;
  localparam int PKT_TAG_MSB  = 55, PKT_TAG_LSB  = 48;
  localparam int PKT_ADDR_MSB = 47, PKT_ADDR_LSB = 32;
  localparam int PKT_LEN_MSB  = 31, PKT_LEN_LSB  = 24;
  localparam int PKT_ID_MSB   = 23, PKT_ID_LSB   = 16;
  localparam int PKT_AUX_MSB  = 15, PKT_AUX_LSB  = 8;
  localparam int PKT_MISC_MSB = 7,  PKT_MISC_LSB = 0;

  // ---- helpers / reference model (declared before the classes that use them) ----

  function automatic bit [63:0] pack64(bit [3:0] kind, bit [3:0] code, bit [7:0] tag,
                                       bit [15:0] addr, bit [7:0] len, bit [7:0] id,
                                       bit [7:0] aux, bit [7:0] misc);
    return {kind, code, tag, addr, len, id, aux, misc};
  endfunction

  // One byte through 8 iterations of CRC-8/CCITT (poly 0x07).
  function automatic bit [7:0] crc8_step(bit [7:0] b);
    bit [7:0] c = b;
    for (int i = 0; i < 8; i++)
      c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
    return c;
  endfunction

  // CRC-8 over header bytes [63:8]; caller zeroes byte [7:0].
  function automatic bit [7:0] bridge_checksum(bit [63:0] p);
    bit [7:0] c = 8'h00;
    c = crc8_step(c ^ p[63:56]);
    c = crc8_step(c ^ p[55:48]);
    c = crc8_step(c ^ p[47:40]);
    c = crc8_step(c ^ p[39:32]);
    c = crc8_step(c ^ p[31:24]);
    c = crc8_step(c ^ p[23:16]);
    c = crc8_step(c ^ p[15:8]);
    return c;
  endfunction

  function automatic bit [63:0] with_checksum(bit [63:0] p);
    bit [63:0] q = {p[63:8], 8'h00};
    return {q[63:8], bridge_checksum(q)};
  endfunction

  function automatic bit is_posted_kind(bit [3:0] kind);
    return (kind == CXL_PKT_KIND_MEM_WR) || (kind == CXL_PKT_KIND_MEM_MRW);
  endfunction

  // Classify an observed lp_out command into the posted (WR/MRW) or non-posted
  // (RD/MRR/ERROR) FIFO, matching the bridge's is_posted() routing.
  function automatic bit cmd_is_posted(bit [63:0] f);
    bit [3:0] k = f[PKT_KIND_MSB:PKT_KIND_LSB];
    bit [3:0] op = f[PKT_CODE_MSB:PKT_CODE_LSB];
    if (k == LP_PKT_KIND_CMD)
      return (op == LP_CMD_WR) || (op == LP_CMD_WRA) || (op == LP_CMD_MWR) || (op == LP_CMD_MRW);
    return 1'b0;  // ERROR (from invalid kind) is routed via the non-posted FIFO
  endfunction

  // Expected LPDDR5X command for a CXL request (mirror of translate_cxl_to_lp).
  function automatic bit [63:0] expect_lp_from_cxl(bit [63:0] c);
    bit [3:0]  k    = c[PKT_KIND_MSB:PKT_KIND_LSB];
    bit [3:0]  code = c[PKT_CODE_MSB:PKT_CODE_LSB];
    bit [7:0]  tag  = c[PKT_TAG_MSB:PKT_TAG_LSB];
    bit [15:0] addr = c[PKT_ADDR_MSB:PKT_ADDR_LSB];
    bit [7:0]  len  = c[PKT_LEN_MSB:PKT_LEN_LSB];
    bit [7:0]  id   = c[PKT_ID_MSB:PKT_ID_LSB];
    bit [7:0]  aux  = c[PKT_AUX_MSB:PKT_AUX_LSB];
    bit [7:0]  misc = c[PKT_MISC_MSB:PKT_MISC_LSB];
    bit [7:0]  attr = aux ^ misc;
    bit [3:0]  op;
    case (k)
      CXL_PKT_KIND_MEM_RD: begin
        op = (code == CXL_RD_OP_AUTOPRE) ? LP_CMD_RDA : LP_CMD_RD;
        return with_checksum(pack64(LP_PKT_KIND_CMD, op, tag, addr, len, id, attr, 8'h00));
      end
      CXL_PKT_KIND_MEM_WR: begin
        op = (code == CXL_WR_OP_AUTOPRE) ? LP_CMD_WRA :
             (code == CXL_WR_OP_MASKED)  ? LP_CMD_MWR : LP_CMD_WR;
        return with_checksum(pack64(LP_PKT_KIND_CMD, op, tag, addr, len, id, attr, 8'h00));
      end
      CXL_PKT_KIND_MEM_MRR:
        return with_checksum(pack64(LP_PKT_KIND_CMD, LP_CMD_MRR, tag, addr, len, id, attr, 8'h00));
      CXL_PKT_KIND_MEM_MRW:
        return with_checksum(pack64(LP_PKT_KIND_CMD, LP_CMD_MRW, tag, addr, len, id, attr, 8'h00));
      default:
        return with_checksum(pack64(LP_PKT_KIND_ERROR, 4'h0, tag, 16'h0, 8'h0, id, 8'h0, 8'h00));
    endcase
  endfunction

  // Expected CXL completion for an LPDDR5X response (mirror of translate_lp_to_cxl).
  function automatic bit [63:0] expect_cxl_from_lp(bit [63:0] r);
    bit [3:0]  k    = r[PKT_KIND_MSB:PKT_KIND_LSB];
    bit [3:0]  code = r[PKT_CODE_MSB:PKT_CODE_LSB];
    bit [7:0]  tag  = r[PKT_TAG_MSB:PKT_TAG_LSB];
    bit [15:0] addr = r[PKT_ADDR_MSB:PKT_ADDR_LSB];
    bit [7:0]  len  = r[PKT_LEN_MSB:PKT_LEN_LSB];
    bit [7:0]  id   = r[PKT_ID_MSB:PKT_ID_LSB];
    bit [7:0]  aux  = r[PKT_AUX_MSB:PKT_AUX_LSB];
    bit [7:0]  misc = r[PKT_MISC_MSB:PKT_MISC_LSB];
    bit        ok   = (bridge_checksum({r[63:8], 8'h00}) == misc);
    bit [63:0] invalid = pack64(CXL_PKT_KIND_INVALID, 4'h0, tag, 16'h0, 8'h0, id, 8'h0, 8'h00);
    case (k)
      LP_PKT_KIND_RD_RSP:  return ok ? pack64(CXL_PKT_KIND_MEM_RD_DATA, code, tag, addr, len, id, aux, 8'h00) : invalid;
      LP_PKT_KIND_WR_RSP:  return ok ? pack64(CXL_PKT_KIND_MEM_CPL,     code, tag, addr, len, id, aux, 8'h00) : invalid;
      LP_PKT_KIND_MRR_RSP: return ok ? pack64(CXL_PKT_KIND_MRR_DATA,    code, tag, addr, len, id, aux, 8'h00) : invalid;
      default:             return invalid;
    endcase
  endfunction

  // ---- environment sources (order matters) ----
  `include "cxl_lpddr5x_flit.svh"
  `include "env/cxl_lpddr5x_cfg.svh"
  `include "agents/cxl_agent/cxl_req_item.svh"
  `include "agents/lp_agent/lp_rsp_item.svh"
  `include "agents/cxl_agent/cxl_driver.svh"
  `include "agents/cxl_agent/cxl_out_responder.svh"
  `include "agents/cxl_agent/cxl_monitor.svh"
  `include "agents/cxl_agent/cxl_agent.svh"
  `include "agents/lp_agent/lp_driver.svh"
  `include "agents/lp_agent/lp_out_responder.svh"
  `include "agents/lp_agent/lp_monitor.svh"
  `include "agents/lp_agent/lp_agent.svh"
  `include "env/cxl_lpddr5x_scoreboard.svh"
  `include "env/cxl_lpddr5x_coverage.svh"
  `include "env/cxl_lpddr5x_vsequencer.svh"
  `include "env/cxl_lpddr5x_env.svh"
  `include "seq/cxl_lpddr5x_seq_lib.svh"
  `include "tests/cxl_lpddr5x_test_lib.svh"
endpackage

`endif
