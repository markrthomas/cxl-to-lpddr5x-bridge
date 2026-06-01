"""
cocotb tests for cxl_lpddr5x_bridge (OSS UVM-equivalent regression).

Mirrors the directed test scenarios from tb_cxl_lpddr5x_bridge.v:
  c2m — CXL.mem RD/WR/MRR/MRW requests -> LPDDR5X RD/WR/MRR/MRW commands
  m2c — LPDDR5X RD/WR/MRR responses    -> CXL read-data / completion / MRR-data
  CRC — a corrupted LPDDR5X response maps to a CXL INVALID completion

The gold model (expect_lp_from_cxl / expect_cxl_from_lp) in env.py is a pure
Python port of the translate_* functions in the bridge RTL.
"""

import cocotb
from cocotb.clock import Clock

from env import (
    CXLDriver, LPDriver, reset_dut,
    # Packet helpers
    pack_cxl_mem_rd, pack_cxl_mem_wr, pack_cxl_mem_mrr, pack_cxl_mem_mrw,
    pack_lp_rd_rsp, pack_lp_wr_rsp, pack_lp_mrr_rsp,
    # Opcodes / constants
    CXL_RD_OP_NORMAL, CXL_RD_OP_AUTOPRE,
    CXL_WR_OP_NORMAL, CXL_WR_OP_AUTOPRE, CXL_WR_OP_MASKED,
    LP_RSP_OK, LP_RSP_ERR, CXL_PKT_KIND_INVALID,
    # Gold models
    expect_lp_from_cxl, expect_cxl_from_lp, with_checksum, bridge_checksum,
)

# Both clocks 100 MHz (10 ns) for a 1:1 ratio matching the first TB phase.
CXL_CLK_NS = 10
MEM_CLK_NS = 10


def _start_clocks(dut):
    cocotb.start_soon(Clock(dut.clk,     CXL_CLK_NS, units="ns").start())
    cocotb.start_soon(Clock(dut.mem_clk, MEM_CLK_NS, units="ns").start())


@cocotb.test()
async def test_c2m_mem_rd(dut):
    """CXL.mem RD is translated to an LPDDR5X RD command with correct CRC."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_rd(CXL_RD_OP_NORMAL, 0x3C, 0xBEEF, 0x04, 0xA1, 0x0F)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mem_rd_autopre(dut):
    """CXL.mem RD with auto-precharge maps to LPDDR5X RDA."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_rd(CXL_RD_OP_AUTOPRE, 0x11, 0x2000, 0x08, 0xD4, 0xF5)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mem_wr(dut):
    """CXL.mem WR (posted) is translated to an LPDDR5X WR command."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_wr(CXL_WR_OP_NORMAL, 0x22, 0x4000, 0x04, 0xE5, 0xA3)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mem_wr_autopre(dut):
    """CXL.mem WR with auto-precharge maps to LPDDR5X WRA."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_wr(CXL_WR_OP_AUTOPRE, 0x23, 0x4100, 0x04, 0xE6, 0xA4)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mem_wr_masked(dut):
    """CXL.mem masked write maps to LPDDR5X MWR."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_wr(CXL_WR_OP_MASKED, 0x24, 0x4200, 0x04, 0xE7, 0xA5)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mrr(dut):
    """CXL.mem mode-register read maps to LPDDR5X MRR."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_mrr(0x0, 0x33, 0x0008, 0x01, 0xF6, 0x77)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_c2m_mrw(dut):
    """CXL.mem mode-register write (posted) maps to LPDDR5X MRW."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = pack_cxl_mem_mrw(0x0, 0x44, 0x000C, 0x01, 0xA7, 0x5B)
    await cxl.send(pkt)
    got = await lp.recv()

    exp = expect_lp_from_cxl(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_m2c_rd_rsp(dut):
    """LPDDR5X RD_RSP is translated to a CXL read-data completion."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = with_checksum(pack_lp_rd_rsp(LP_RSP_OK, 0x3C, 0x0040, 0x04, 0xC3, 0x18))
    await lp.send(pkt)
    got = await cxl.recv()

    exp = expect_cxl_from_lp(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_m2c_wr_rsp(dut):
    """LPDDR5X WR_RSP is translated to a CXL write completion."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = with_checksum(pack_lp_wr_rsp(LP_RSP_OK, 0x22, 0x0040, 0x04, 0xE5, 0xA3))
    await lp.send(pkt)
    got = await cxl.recv()

    exp = expect_cxl_from_lp(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_m2c_mrr_rsp(dut):
    """LPDDR5X MRR_RSP is translated to a CXL mode-register read-data completion."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = with_checksum(pack_lp_mrr_rsp(LP_RSP_OK, 0x33, 0x0001, 0x01, 0xF6, 0x77))
    await lp.send(pkt)
    got = await cxl.recv()

    exp = expect_cxl_from_lp(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_m2c_rd_rsp_err(dut):
    """LPDDR5X RD_RSP carrying ERR status is forwarded as a read-data completion (ERR)."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    pkt = with_checksum(pack_lp_rd_rsp(LP_RSP_ERR, 0x5A, 0x0040, 0x04, 0xC3, 0x18))
    await lp.send(pkt)
    got = await cxl.recv()

    exp = expect_cxl_from_lp(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"


@cocotb.test()
async def test_m2c_bad_crc_invalid(dut):
    """A corrupted-CRC LPDDR5X response is dropped to a CXL INVALID completion."""
    _start_clocks(dut)
    await reset_dut(dut, dut.clk, dut.mem_clk)
    cxl = CXLDriver(dut, dut.clk)
    lp  = LPDriver(dut, dut.mem_clk)

    base = pack_lp_rd_rsp(LP_RSP_OK, 0x77, 0x0040, 0x04, 0xC3, 0x18)
    pkt  = (base & ~0xFF) | (bridge_checksum(base & ~0xFF) ^ 0xFF)  # corrupt CRC byte
    await lp.send(pkt)
    got = await cxl.recv()

    exp = expect_cxl_from_lp(pkt)
    assert got == exp, f"Expected 0x{exp:016x}, got 0x{got:016x}"
    assert (got >> 60) & 0xF == CXL_PKT_KIND_INVALID, \
        f"Bad-CRC response should map to INVALID, got kind {(got >> 60) & 0xF:#x}"
