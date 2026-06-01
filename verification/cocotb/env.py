"""
Shared packet helpers, gold models, and drivers for cxl_lpddr5x_bridge cocotb tests.

Mirrors the Verilog pack helpers, bridge_checksum, expect_lp_from_cxl, and
expect_cxl_from_lp functions from cxl_lpddr5x_bridge_defs.vh / the directed TB.

CXLDriver  : drives cxl_in_* (clk domain) and reads cxl_out_* (clk domain).
LPDriver   : drives lp_in_* (mem_clk domain) and reads lp_out_* (mem_clk domain).
reset_dut  : asserts rst_n=0 for 6 clk cycles, then releases with link_up=1.
"""

from cocotb.triggers import RisingEdge

# ---- CXL.mem packet kinds [63:60] ----
CXL_PKT_KIND_MEM_RD      = 0x1
CXL_PKT_KIND_MEM_WR      = 0x2
CXL_PKT_KIND_MEM_MRR     = 0x3
CXL_PKT_KIND_MEM_MRW     = 0x4
CXL_PKT_KIND_MEM_RD_DATA = 0x8
CXL_PKT_KIND_MEM_CPL     = 0x9
CXL_PKT_KIND_MRR_DATA    = 0xA
CXL_PKT_KIND_INVALID     = 0xF

# ---- CXL read / write opcodes (PKT_CODE) ----
CXL_RD_OP_NORMAL  = 0x0
CXL_RD_OP_AUTOPRE = 0x1
CXL_WR_OP_NORMAL  = 0x0
CXL_WR_OP_AUTOPRE = 0x1
CXL_WR_OP_MASKED  = 0x2

# ---- CXL completion status ----
CXL_CPL_SC = 0x1
CXL_CPL_UR = 0x2
CXL_CPL_CA = 0x3

# ---- LPDDR5X downstream packet kinds [63:60] ----
LP_PKT_KIND_CMD     = 0x8
LP_PKT_KIND_RD_RSP  = 0xA
LP_PKT_KIND_WR_RSP  = 0xB
LP_PKT_KIND_MRR_RSP = 0xC
LP_PKT_KIND_ERROR   = 0xE

# ---- LPDDR5X command sub-ops (PKT_CODE of LP_PKT_KIND_CMD) ----
LP_CMD_RD  = 0x1
LP_CMD_RDA = 0x2
LP_CMD_WR  = 0x3
LP_CMD_WRA = 0x4
LP_CMD_MWR = 0x5
LP_CMD_MRW = 0x6
LP_CMD_MRR = 0x7

# ---- LPDDR5X response status ----
LP_RSP_OK  = 0x1
LP_RSP_ERR = 0x2

# ---- Packet field bit positions ----
PKT_KIND_MSB, PKT_KIND_LSB =  63, 60
PKT_CODE_MSB, PKT_CODE_LSB =  59, 56
PKT_TAG_MSB,  PKT_TAG_LSB  =  55, 48
PKT_ADDR_MSB, PKT_ADDR_LSB =  47, 32
PKT_LEN_MSB,  PKT_LEN_LSB  =  31, 24
PKT_ID_MSB,   PKT_ID_LSB   =  23, 16
PKT_AUX_MSB,  PKT_AUX_LSB  =  15,  8
PKT_MISC_MSB, PKT_MISC_LSB =   7,  0


def _pack64(kind, code, tag, addr, length, id_, aux, misc):
    return (
        ((kind   & 0xF)    << 60) |
        ((code   & 0xF)    << 56) |
        ((tag    & 0xFF)   << 48) |
        ((addr   & 0xFFFF) << 32) |
        ((length & 0xFF)   << 24) |
        ((id_    & 0xFF)   << 16) |
        ((aux    & 0xFF)   <<  8) |
        (misc    & 0xFF)
    )


def _get_field(pkt, msb, lsb):
    return (pkt >> lsb) & ((1 << (msb - lsb + 1)) - 1)


# ---- CXL.mem request pack helpers ----

def pack_cxl_mem_rd(opcode, tag, addr16, length, req_id, attr):
    return _pack64(CXL_PKT_KIND_MEM_RD, opcode, tag, addr16, length, req_id, attr, 0)

def pack_cxl_mem_wr(opcode, tag, addr16, length, req_id, attr):
    return _pack64(CXL_PKT_KIND_MEM_WR, opcode, tag, addr16, length, req_id, attr, 0)

def pack_cxl_mem_mrr(opcode, tag, addr16, length, req_id, attr):
    return _pack64(CXL_PKT_KIND_MEM_MRR, opcode, tag, addr16, length, req_id, attr, 0)

def pack_cxl_mem_mrw(opcode, tag, addr16, length, req_id, attr):
    return _pack64(CXL_PKT_KIND_MEM_MRW, opcode, tag, addr16, length, req_id, attr, 0)


# ---- CXL.mem completion pack helpers ----

def pack_cxl_rd_data(status, tag, byte_count, length, completer_id, lower_addr):
    return _pack64(CXL_PKT_KIND_MEM_RD_DATA, status, tag, byte_count, length, completer_id, lower_addr, 0)

def pack_cxl_mem_cpl(status, tag, byte_count, length, completer_id, lower_addr):
    return _pack64(CXL_PKT_KIND_MEM_CPL, status, tag, byte_count, length, completer_id, lower_addr, 0)

def pack_cxl_mrr_data(status, tag, byte_count, length, completer_id, lower_addr):
    return _pack64(CXL_PKT_KIND_MRR_DATA, status, tag, byte_count, length, completer_id, lower_addr, 0)


# ---- LPDDR5X command / response pack helpers ----

def pack_lp_cmd(lp_op, tag, bank_row, col_burst, src_id, attr, checksum=0):
    return _pack64(LP_PKT_KIND_CMD, lp_op, tag, bank_row, col_burst, src_id, attr, checksum)

def pack_lp_rd_rsp(status, tag, byte_count, length, src_id, lower_addr, checksum=0):
    return _pack64(LP_PKT_KIND_RD_RSP, status, tag, byte_count, length, src_id, lower_addr, checksum)

def pack_lp_wr_rsp(status, tag, byte_count, length, src_id, lower_addr, checksum=0):
    return _pack64(LP_PKT_KIND_WR_RSP, status, tag, byte_count, length, src_id, lower_addr, checksum)

def pack_lp_mrr_rsp(status, tag, byte_count, length, src_id, lower_addr, checksum=0):
    return _pack64(LP_PKT_KIND_MRR_RSP, status, tag, byte_count, length, src_id, lower_addr, checksum)


# ---- Checksum ----

def _crc8_step(b):
    """One byte through 8 iterations of CRC-8/CCITT (poly=0x07). Matches Verilog crc8_step."""
    b &= 0xFF
    for _ in range(8):
        b = ((b << 1) ^ 0x07) & 0xFF if (b & 0x80) else (b << 1) & 0xFF
    return b


def bridge_checksum(pkt_64):
    """CRC-8/CCITT over bytes [63:8] of a 64-bit packet (byte [7:0] must be 0)."""
    c = 0
    for shift in (56, 48, 40, 32, 24, 16, 8):
        c = _crc8_step(c ^ ((pkt_64 >> shift) & 0xFF))
    return c


def with_checksum(pkt_64):
    """Set the MISC byte [7:0] to the CRC-8 checksum of the other 7 bytes."""
    return (pkt_64 & ~0xFF) | bridge_checksum(pkt_64 & ~0xFF)


# ---- Gold models (mirror translate_* functions in bridge RTL) ----

def expect_lp_from_cxl(cxl_pkt):
    """Expected LPDDR5X command flit for a given CXL request packet."""
    kind = _get_field(cxl_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    code = _get_field(cxl_pkt, PKT_CODE_MSB, PKT_CODE_LSB)
    tag  = _get_field(cxl_pkt, PKT_TAG_MSB,  PKT_TAG_LSB)
    addr = _get_field(cxl_pkt, PKT_ADDR_MSB, PKT_ADDR_LSB)
    ln   = _get_field(cxl_pkt, PKT_LEN_MSB,  PKT_LEN_LSB)
    id_  = _get_field(cxl_pkt, PKT_ID_MSB,   PKT_ID_LSB)
    aux  = _get_field(cxl_pkt, PKT_AUX_MSB,  PKT_AUX_LSB)
    misc = _get_field(cxl_pkt, PKT_MISC_MSB, PKT_MISC_LSB)
    attr = (aux ^ misc) & 0xFF

    if kind == CXL_PKT_KIND_MEM_RD:
        op = LP_CMD_RDA if code == CXL_RD_OP_AUTOPRE else LP_CMD_RD
        return with_checksum(pack_lp_cmd(op, tag, addr, ln, id_, attr))
    elif kind == CXL_PKT_KIND_MEM_WR:
        op = LP_CMD_WRA if code == CXL_WR_OP_AUTOPRE else \
             LP_CMD_MWR if code == CXL_WR_OP_MASKED else LP_CMD_WR
        return with_checksum(pack_lp_cmd(op, tag, addr, ln, id_, attr))
    elif kind == CXL_PKT_KIND_MEM_MRR:
        return with_checksum(pack_lp_cmd(LP_CMD_MRR, tag, addr, ln, id_, attr))
    elif kind == CXL_PKT_KIND_MEM_MRW:
        return with_checksum(pack_lp_cmd(LP_CMD_MRW, tag, addr, ln, id_, attr))
    else:
        raw = (LP_PKT_KIND_ERROR << 60) | (tag << 48) | (id_ << 16)
        return with_checksum(raw)


def expect_cxl_from_lp(lp_pkt):
    """Expected CXL completion for a given LPDDR5X response flit."""
    kind = _get_field(lp_pkt, PKT_KIND_MSB, PKT_KIND_LSB)
    code = _get_field(lp_pkt, PKT_CODE_MSB, PKT_CODE_LSB)
    tag  = _get_field(lp_pkt, PKT_TAG_MSB,  PKT_TAG_LSB)
    addr = _get_field(lp_pkt, PKT_ADDR_MSB, PKT_ADDR_LSB)
    ln   = _get_field(lp_pkt, PKT_LEN_MSB,  PKT_LEN_LSB)
    id_  = _get_field(lp_pkt, PKT_ID_MSB,   PKT_ID_LSB)
    aux  = _get_field(lp_pkt, PKT_AUX_MSB,  PKT_AUX_LSB)
    misc = _get_field(lp_pkt, PKT_MISC_MSB, PKT_MISC_LSB)

    valid_chk = bridge_checksum(lp_pkt & ~0xFF) == misc
    invalid   = _pack64(CXL_PKT_KIND_INVALID, 0, tag, 0, 0, id_, 0, 0)

    if kind == LP_PKT_KIND_RD_RSP:
        return pack_cxl_rd_data(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    elif kind == LP_PKT_KIND_WR_RSP:
        return pack_cxl_mem_cpl(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    elif kind == LP_PKT_KIND_MRR_RSP:
        return pack_cxl_mrr_data(code, tag, addr, ln, id_, aux) if valid_chk else invalid
    else:
        return invalid


# ---- Reset ----

async def reset_dut(dut, clk, mem_clk):
    """Assert rst_n=0 for 6 clk cycles, release with link_up=1, settle both domains."""
    dut.rst_n.value         = 0
    dut.link_up.value       = 0
    dut.err_inj_en.value    = 0
    dut.cxl_in_valid.value  = 0
    dut.cxl_in_data.value   = 0
    dut.lp_out_ready.value  = 0
    dut.lp_in_valid.value   = 0
    dut.lp_in_data.value    = 0
    dut.cxl_out_ready.value = 0

    for _ in range(6):
        await RisingEdge(clk)

    dut.rst_n.value   = 1
    dut.link_up.value = 1

    for _ in range(4):
        await RisingEdge(clk)
    for _ in range(4):
        await RisingEdge(mem_clk)


# ---- CXL-domain driver ----

class CXLDriver:
    """Drives cxl_in_* and reads cxl_out_* on the CXL host (clk) domain."""

    def __init__(self, dut, clk):
        self.dut = dut
        self.clk = clk

    async def send(self, pkt, timeout=64):
        dut = self.dut
        clk = self.clk
        dut.cxl_in_data.value  = pkt
        dut.cxl_in_valid.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.cxl_in_ready.value) == 1:
                dut.cxl_in_valid.value = 0
                return
        raise AssertionError(f"Timeout on cxl_in handshake (pkt=0x{pkt:016x})")

    async def recv(self, timeout=64):
        dut = self.dut
        clk = self.clk
        dut.cxl_out_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.cxl_out_valid.value) == 1:
                data = int(dut.cxl_out_data.value)
                dut.cxl_out_ready.value = 0
                return data
        raise AssertionError("Timeout waiting for cxl_out_valid")


# ---- LPDDR5X-domain driver ----

class LPDriver:
    """Drives lp_in_* and reads lp_out_* on the LPDDR5X (mem_clk) domain."""

    def __init__(self, dut, mem_clk):
        self.dut     = dut
        self.mem_clk = mem_clk

    async def send(self, pkt, timeout=64):
        dut = self.dut
        clk = self.mem_clk
        dut.lp_in_data.value  = pkt
        dut.lp_in_valid.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.lp_in_ready.value) == 1:
                dut.lp_in_valid.value = 0
                return
        raise AssertionError(f"Timeout on lp_in handshake (pkt=0x{pkt:016x})")

    async def recv(self, timeout=64):
        dut = self.dut
        clk = self.mem_clk
        dut.lp_out_ready.value = 1
        for _ in range(timeout):
            await RisingEdge(clk)
            if int(dut.lp_out_valid.value) == 1:
                data = int(dut.lp_out_data.value)
                dut.lp_out_ready.value = 0
                return data
        raise AssertionError("Timeout waiting for lp_out_valid")
