"""Directed checks: the first flit after reset (TB-vs-DUT question from verification/random/README.md).

While bootstrapping the random regression, driving the first flit in the same simulation timestep as
reset_dut() returned "lost" the first request/response. These tests settle whether the DUT or the
testbench loses it.

Each test runs an independent edge monitor that records a handshake only when valid && ready is true at
the clock edge the DUT samples (cocotb reads at RisingEdge return the pre-edge values, and testbench
writes made earlier in that timestep are not applied until the ReadWrite phase, so the monitor sees
exactly what the DUT's always @(posedge) sees). The scoreboard is fed from that monitor, not from the
producer's own bookkeeping, and the existing gold model (expect_lp_from_cxl / expect_cxl_from_lp)
checks every flit that comes out.

  test_first_flit_after_reset_*  - clean drive (half a cycle after an edge): the first flit must be
                                   accepted and delivered.  Pass = the DUT does not drop it.
  test_same_timestep_drive_*     - the racy drive the rr harness used (same timestep as the edge that
                                   ends reset, clk 10 ns / mem_clk 14 ns).  The DUT must still deliver every
                                   flit it accepted; the test also counts flits the producer *believed*
                                   accepted but the DUT never sampled (the harness race) and logs them.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from env import reset_dut
from test_cxl_lpddr5x_bridge import _rand_request, _rand_response, _Scoreboard

N = 40


async def _monitor(clk, valid, ready, data, cb, accepted):
    while True:
        await RisingEdge(clk)
        if int(valid.value) == 1 and int(ready.value) == 1:
            pkt = int(data.value)
            accepted.append(pkt)
            cb(pkt)


async def _producer(clk, valid, ready, data, pkts, believed, clean):
    for pkt in pkts:
        if clean:
            await FallingEdge(clk)          # drive mid-cycle: no same-timestep ambiguity
        data.value = pkt
        valid.value = 1
        while True:
            await RisingEdge(clk)
            if int(ready.value) == 1:
                break
        believed.append(pkt)
    if clean:
        await FallingEdge(clk)
    valid.value = 0


async def _sink(clk, valid, ready, data, cb):
    ready.value = 1                          # always ready; runs until the test kills it
    while True:
        await RisingEdge(clk)
        if int(valid.value) == 1 and int(ready.value) == 1:
            cb(int(data.value))


async def _run(dut, direction, clean, seed, mem_ns=14):
    random.seed(seed)
    # clk 10 ns / mem_clk 14 ns (the rr `bursty` config): reset_dut() returns on the mem_clk edge at
    # 140 ns, which is also a clk edge - the timestep in which the rr harness lost its first flit
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    cocotb.start_soon(Clock(dut.mem_clk, mem_ns, units="ns").start())
    await reset_dut(dut, dut.clk, dut.mem_clk)

    sb = _Scoreboard()
    accepted, believed = [], []
    if direction == "c2m":
        pkts = [_rand_request() for _ in range(N)]
        cocotb.start_soon(_monitor(dut.clk, dut.cxl_in_valid, dut.cxl_in_ready, dut.cxl_in_data,
                                   sb.on_request, accepted))
        snk = cocotb.start_soon(_sink(dut.mem_clk, dut.lp_out_valid, dut.lp_out_ready, dut.lp_out_data,
                                      sb.on_command))
        prod = _producer(dut.clk, dut.cxl_in_valid, dut.cxl_in_ready, dut.cxl_in_data, pkts, believed, clean)
        pending = lambda: sb.posted or sb.np  # noqa: E731
    else:
        pkts = [_rand_response() for _ in range(N)]
        cocotb.start_soon(_monitor(dut.mem_clk, dut.lp_in_valid, dut.lp_in_ready, dut.lp_in_data,
                                   sb.on_response, accepted))
        snk = cocotb.start_soon(_sink(dut.clk, dut.cxl_out_valid, dut.cxl_out_ready, dut.cxl_out_data,
                                      sb.on_completion))
        prod = _producer(dut.mem_clk, dut.lp_in_valid, dut.lp_in_ready, dut.lp_in_data, pkts, believed, clean)
        pending = lambda: sb.cpl  # noqa: E731

    await prod
    for _ in range(200):                     # drain: let everything accepted come out
        if not pending():
            break
        await RisingEdge(dut.clk)
    snk.kill()

    # the DUT side: every flit it accepted came out, in order, matching the gold model (asserted in sb)
    assert not pending(), f"{direction}: DUT accepted {len(accepted)} flits but did not deliver them all"
    lost = [p for p in believed if p not in accepted]
    dut._log.info(f"{direction} clean={clean}: producer believed {len(believed)} accepted, "
                  f"DUT sampled {len(accepted)}; never sampled by the DUT: {len(lost)}"
                  + (f" (first: 0x{lost[0]:016x} = pkts[{pkts.index(lost[0])}])" if lost else ""))
    return pkts, accepted, believed, lost


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_same_timestep_drive_c2m(dut):
    # Reproduces the harness race when this test starts at sim time 0 (it is first in the module for that;
    # run alone: make MODULE=test_reset_handoff TESTCASE=test_same_timestep_drive_c2m): the producer counts
    # pkts[0] as accepted at the 140 ns clk edge, but its write lands after the DUT sampled valid=0 there.
    # Later in a sim the callback order differs and the race may not occur.  The DUT side is exact either way.
    _, _, _, lost = await _run(dut, "c2m", clean=False, seed=1)
    dut._log.info("same-timestep drive: %d flit(s) lost by the TESTBENCH (race), 0 by the DUT" % len(lost))


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_first_flit_after_reset_c2m(dut):
    pkts, accepted, _, _ = await _run(dut, "c2m", clean=True, seed=1)
    assert accepted and accepted[0] == pkts[0], "c2m: first request after reset not accepted first"
    assert accepted == pkts, "c2m: a request was dropped at the input"


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_first_flit_after_reset_m2c(dut):
    pkts, accepted, _, _ = await _run(dut, "m2c", clean=True, seed=2)
    assert accepted and accepted[0] == pkts[0], "m2c: first response after reset not accepted first"
    assert accepted == pkts, "m2c: a response was dropped at the input"


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_same_timestep_drive_m2c(dut):
    _, _, _, lost = await _run(dut, "m2c", clean=False, seed=2)
    dut._log.info("same-timestep drive: %d flit(s) lost by the TESTBENCH (race), 0 by the DUT" % len(lost))
