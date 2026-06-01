// Shared packet/command-field definitions for the CXL <-> LPDDR5X bridge.
//
// Upstream  (host side):  64-bit CXL.mem request and completion flits.
// Downstream (memory side): 64-bit LPDDR5X DRAM-command and response flits
//                           (a DFI-style command-channel abstraction).
//
// A CXL.mem request is decoded into a single LPDDR5X command flit:
//   MEM_RD  -> RD  / RDA  (auto-precharge)
//   MEM_WR  -> WR  / WRA  (auto-precharge) / MWR (masked write)
//   MEM_MRR -> MRR  (mode-register read)
//   MEM_MRW -> MRW  (mode-register write)
// The 16-bit CXL byte-address is carried through unchanged in the ADDR field;
// downstream it is interpreted as {BANK[15:12], ROW[11:0]} (column/burst come
// from the LEN field), so the mapping is reversible for end-to-end checking.

`ifndef CXL_LPDDR5X_BRIDGE_DEFS_VH
`define CXL_LPDDR5X_BRIDGE_DEFS_VH

// ---- CXL.mem packet kinds [63:60] ----
localparam [3:0] CXL_PKT_KIND_MEM_RD     = 4'h1; // read request           (non-posted)
localparam [3:0] CXL_PKT_KIND_MEM_WR     = 4'h2; // write request          (posted)
localparam [3:0] CXL_PKT_KIND_MEM_MRR    = 4'h3; // mode-register read req  (non-posted)
localparam [3:0] CXL_PKT_KIND_MEM_MRW    = 4'h4; // mode-register write req (posted)
localparam [3:0] CXL_PKT_KIND_MEM_RD_DATA = 4'h8; // read-data completion
localparam [3:0] CXL_PKT_KIND_MEM_CPL    = 4'h9; // write completion
localparam [3:0] CXL_PKT_KIND_MRR_DATA   = 4'ha; // mode-register read data
localparam [3:0] CXL_PKT_KIND_INVALID    = 4'hf;

// ---- CXL read opcodes (PKT_CODE of MEM_RD) ----
localparam [3:0] CXL_RD_OP_NORMAL        = 4'h0;
localparam [3:0] CXL_RD_OP_AUTOPRE       = 4'h1; // read with auto-precharge

// ---- CXL write opcodes (PKT_CODE of MEM_WR) ----
localparam [3:0] CXL_WR_OP_NORMAL        = 4'h0;
localparam [3:0] CXL_WR_OP_AUTOPRE       = 4'h1; // write with auto-precharge
localparam [3:0] CXL_WR_OP_MASKED        = 4'h2; // masked (partial) write

// ---- CXL completion status (PKT_CODE of *_DATA / *_CPL) ----
localparam [3:0] CXL_CPL_SC              = 4'h1; // Successful Completion
localparam [3:0] CXL_CPL_UR              = 4'h2; // Unsupported Request
localparam [3:0] CXL_CPL_CA              = 4'h3; // Completer Abort (e.g. ECC/parity)

// ---- LPDDR5X downstream packet kinds [63:60] ----
localparam [3:0] LP_PKT_KIND_CMD         = 4'h8; // DRAM command (op in PKT_CODE)
localparam [3:0] LP_PKT_KIND_RD_RSP      = 4'ha; // read-data response   (upstream)
localparam [3:0] LP_PKT_KIND_WR_RSP      = 4'hb; // write-ack response    (upstream)
localparam [3:0] LP_PKT_KIND_MRR_RSP     = 4'hc; // mode-register response (upstream)
localparam [3:0] LP_PKT_KIND_ERROR       = 4'he;

// ---- LPDDR5X command sub-ops (PKT_CODE of LP_PKT_KIND_CMD) ----
localparam [3:0] LP_CMD_RD               = 4'h1; // read
localparam [3:0] LP_CMD_RDA              = 4'h2; // read,  auto-precharge
localparam [3:0] LP_CMD_WR               = 4'h3; // write
localparam [3:0] LP_CMD_WRA              = 4'h4; // write, auto-precharge
localparam [3:0] LP_CMD_MWR              = 4'h5; // masked write
localparam [3:0] LP_CMD_MRW              = 4'h6; // mode-register write
localparam [3:0] LP_CMD_MRR              = 4'h7; // mode-register read

// ---- LPDDR5X response status (PKT_CODE of *_RSP) ----
localparam [3:0] LP_RSP_OK               = 4'h1;
localparam [3:0] LP_RSP_ERR              = 4'h2; // uncorrectable / abort

// ---- 64-bit packet field bit-ranges (shared by both directions) ----
localparam integer PKT_KIND_MSB          = 63;
localparam integer PKT_KIND_LSB          = 60;
localparam integer PKT_CODE_MSB          = 59;
localparam integer PKT_CODE_LSB          = 56;
localparam integer PKT_TAG_MSB           = 55;
localparam integer PKT_TAG_LSB           = 48;
localparam integer PKT_ADDR_MSB          = 47;  // {BANK[15:12], ROW[11:0]} downstream
localparam integer PKT_ADDR_LSB          = 32;
localparam integer PKT_LEN_MSB           = 31;  // burst length / column group
localparam integer PKT_LEN_LSB           = 24;
localparam integer PKT_ID_MSB            = 23;
localparam integer PKT_ID_LSB            = 16;
localparam integer PKT_AUX_MSB           = 15;  // attributes (channel/rank/etc.)
localparam integer PKT_AUX_LSB           = 8;
localparam integer PKT_MISC_MSB          = 7;   // CRC-8 checksum on the command channel
localparam integer PKT_MISC_LSB          = 0;

// ---- CXL.mem request pack helpers ----

function automatic [63:0] pack_cxl_mem_rd;
  input [3:0]  opcode;
  input [7:0]  tag;
  input [15:0] addr16;
  input [7:0]  length;
  input [7:0]  requester_id;
  input [7:0]  attr;
  begin
    pack_cxl_mem_rd = {CXL_PKT_KIND_MEM_RD, opcode, tag, addr16,
                       length, requester_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_cxl_mem_wr;
  input [3:0]  opcode;
  input [7:0]  tag;
  input [15:0] addr16;
  input [7:0]  length;
  input [7:0]  requester_id;
  input [7:0]  attr;
  begin
    pack_cxl_mem_wr = {CXL_PKT_KIND_MEM_WR, opcode, tag, addr16,
                       length, requester_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_cxl_mem_mrr;
  input [3:0]  opcode;
  input [7:0]  tag;
  input [15:0] addr16;
  input [7:0]  length;
  input [7:0]  requester_id;
  input [7:0]  attr;
  begin
    pack_cxl_mem_mrr = {CXL_PKT_KIND_MEM_MRR, opcode, tag, addr16,
                        length, requester_id, attr, 8'h00};
  end
endfunction

function automatic [63:0] pack_cxl_mem_mrw;
  input [3:0]  opcode;
  input [7:0]  tag;
  input [15:0] addr16;
  input [7:0]  length;
  input [7:0]  requester_id;
  input [7:0]  attr;
  begin
    pack_cxl_mem_mrw = {CXL_PKT_KIND_MEM_MRW, opcode, tag, addr16,
                        length, requester_id, attr, 8'h00};
  end
endfunction

// ---- CXL.mem completion pack helpers ----

function automatic [63:0] pack_cxl_rd_data;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  completer_id;
  input [7:0]  lower_addr;
  begin
    pack_cxl_rd_data = {CXL_PKT_KIND_MEM_RD_DATA, status, tag, byte_count,
                        length, completer_id, lower_addr, 8'h00};
  end
endfunction

function automatic [63:0] pack_cxl_mem_cpl;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  completer_id;
  input [7:0]  lower_addr;
  begin
    pack_cxl_mem_cpl = {CXL_PKT_KIND_MEM_CPL, status, tag, byte_count,
                        length, completer_id, lower_addr, 8'h00};
  end
endfunction

function automatic [63:0] pack_cxl_mrr_data;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  completer_id;
  input [7:0]  lower_addr;
  begin
    pack_cxl_mrr_data = {CXL_PKT_KIND_MRR_DATA, status, tag, byte_count,
                         length, completer_id, lower_addr, 8'h00};
  end
endfunction

// ---- LPDDR5X command / response pack helpers ----

function automatic [63:0] pack_lp_cmd;
  input [3:0]  lp_op;
  input [7:0]  tag;
  input [15:0] bank_row;   // {bank[3:0], row[11:0]}
  input [7:0]  col_burst;
  input [7:0]  src_id;
  input [7:0]  attr;
  input [7:0]  checksum;
  begin
    pack_lp_cmd = {LP_PKT_KIND_CMD, lp_op, tag, bank_row,
                   col_burst, src_id, attr, checksum};
  end
endfunction

function automatic [63:0] pack_lp_rd_rsp;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  src_id;
  input [7:0]  lower_addr;
  input [7:0]  checksum;
  begin
    pack_lp_rd_rsp = {LP_PKT_KIND_RD_RSP, status, tag, byte_count,
                      length, src_id, lower_addr, checksum};
  end
endfunction

function automatic [63:0] pack_lp_wr_rsp;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  src_id;
  input [7:0]  lower_addr;
  input [7:0]  checksum;
  begin
    pack_lp_wr_rsp = {LP_PKT_KIND_WR_RSP, status, tag, byte_count,
                      length, src_id, lower_addr, checksum};
  end
endfunction

function automatic [63:0] pack_lp_mrr_rsp;
  input [3:0]  status;
  input [7:0]  tag;
  input [15:0] byte_count;
  input [7:0]  length;
  input [7:0]  src_id;
  input [7:0]  lower_addr;
  input [7:0]  checksum;
  begin
    pack_lp_mrr_rsp = {LP_PKT_KIND_MRR_RSP, status, tag, byte_count,
                       length, src_id, lower_addr, checksum};
  end
endfunction

// ---- Checksum ----
// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8] (7 bytes).
// Caller must zero the misc byte [7:0] before calling; that byte is not read here.
/* verilator lint_off UNUSEDSIGNAL */
function automatic [7:0] bridge_checksum;
  input [63:0] p; // packet_wo_checksum
  reg [7:0] c;     // crc
  begin
    c = 8'h00;
    c = crc8_step(c ^ p[63:56]);
    c = crc8_step(c ^ p[55:48]);
    c = crc8_step(c ^ p[47:40]);
    c = crc8_step(c ^ p[39:32]);
    c = crc8_step(c ^ p[31:24]);
    c = crc8_step(c ^ p[23:16]);
    c = crc8_step(c ^ p[15:8]);
    bridge_checksum = c;
  end
endfunction

// Combinational single-byte CRC-8/CCITT step (8 shift iterations).
function automatic [7:0] crc8_step;
  input [7:0] b;
  reg [7:0] c0, c1, c2, c3, c4, c5, c6, c7;
  begin
    c0 = b[7] ? ((b << 1) ^ 8'h07) : (b << 1);
    c1 = c0[7] ? ((c0 << 1) ^ 8'h07) : (c0 << 1);
    c2 = c1[7] ? ((c1 << 1) ^ 8'h07) : (c1 << 1);
    c3 = c2[7] ? ((c2 << 1) ^ 8'h07) : (c2 << 1);
    c4 = c3[7] ? ((c3 << 1) ^ 8'h07) : (c3 << 1);
    c5 = c4[7] ? ((c4 << 1) ^ 8'h07) : (c4 << 1);
    c6 = c5[7] ? ((c5 << 1) ^ 8'h07) : (c5 << 1);
    c7 = c6[7] ? ((c6 << 1) ^ 8'h07) : (c6 << 1);
    crc8_step = c7;
  end
endfunction
/* verilator lint_on UNUSEDSIGNAL */

`endif
