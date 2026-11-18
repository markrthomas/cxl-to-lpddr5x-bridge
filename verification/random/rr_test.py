"""Random-regression cocotb test for cxl_lpddr5x_bridge.

Drives the existing cocotb scoreboard (verification/cocotb: _Scoreboard + env.py gold
model + _rand_request/_rand_response) - no new checker. Only stimulus knobs are varied,
selected by RR_CONFIG, seeded by RR_SEED. Deterministic per (seed, config).
"""
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cocotb"))
import test_cxl_lpddr5x_bridge as base  # noqa: E402  (module import: its tests are not collected)
from env import reset_dut  # noqa: E402

# name: clk_ns, mem_clk_ns, max idle gap (cycles), sink ready probability, n_req, n_rsp
CONFIGS = {
    "base":      dict(clk=10, mem=14, gap=3,  rdy=0.75, n_req=500, n_rsp=300),
    "ratio_1_1": dict(clk=10, mem=10, gap=3,  rdy=0.75, n_req=500, n_rsp=300),
    "mem_fast":  dict(clk=14, mem=10, gap=2,  rdy=0.75, n_req=500, n_rsp=300),
    "mem_slow":  dict(clk=10, mem=30, gap=2,  rdy=0.75, n_req=400, n_rsp=300),
    "bp_heavy":  dict(clk=10, mem=14, gap=1,  rdy=0.20, n_req=400, n_rsp=300),
    "bursty":    dict(clk=10, mem=14, gap=0,  rdy=0.90, n_req=800, n_rsp=500),
    "sparse":    dict(clk=10, mem=14, gap=12, rdy=0.60, n_req=200, n_rsp=150),
}
NAMES = list(CONFIGS)


async def cxl_in(dut, n, sb, k):
    await RisingEdge(dut.clk)  # drive only right after our own clock edge (see test_rr)
    for _ in range(n):
        for _ in range(random.randint(0, k["gap"])):
            dut.cxl_in_valid.value = 0
            await RisingEdge(dut.clk)
        pkt = base._rand_request()
        dut.cxl_in_data.value = pkt
        dut.cxl_in_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.cxl_in_ready.value) == 1:
                break
        sb.on_request(pkt)
    dut.cxl_in_valid.value = 0


async def lp_in(dut, n, sb, k):
    await RisingEdge(dut.mem_clk)  # drive only right after our own clock edge (see test_rr)
    for _ in range(n):
        for _ in range(random.randint(0, k["gap"])):
            dut.lp_in_valid.value = 0
            await RisingEdge(dut.mem_clk)
        pkt = base._rand_response()
        dut.lp_in_data.value = pkt
        dut.lp_in_valid.value = 1
        while True:
            await RisingEdge(dut.mem_clk)
            if int(dut.lp_in_ready.value) == 1:
                break
        sb.on_response(pkt)
    dut.lp_in_valid.value = 0


async def sink(dut, n, clk, valid, ready, data, cb, k):
    seen = 0
    while seen < n:
        ready.value = 1 if random.random() < k["rdy"] else 0
        await RisingEdge(clk)
        if int(valid.value) == 1 and int(ready.value) == 1:
            cb(int(data.value))
            seen += 1
    ready.value = 1


@cocotb.test(timeout_time=50, timeout_unit="ms")
async def test_rr(dut):
    seed = int(os.environ["RR_SEED"])
    name = os.environ.get("RR_CONFIG") or NAMES[seed % len(NAMES)]
    k = CONFIGS[name]
    random.seed(seed)
    dut._log.info(f"RR seed={seed} config={name} knobs={k}")
    cocotb.start_soon(Clock(dut.clk, k["clk"], units="ns").start())
    cocotb.start_soon(Clock(dut.mem_clk, k["mem"], units="ns").start())
    await reset_dut(dut, dut.clk, dut.mem_clk)
    # NOTE: each producer first waits for its own clock edge before driving. reset_dut() returns
    # on a mem_clk edge; driving in that timestep (possibly coincident with a clk edge) loses the
    # first request/response (8/8 'bursty' seeds and ratio_1_1 failed that way). See README.
    sb = base._Scoreboard()
    if os.environ.get("RR_TRACE"):  # log every request/response/command/completion (debug only)
        for m in ("on_request", "on_command", "on_response", "on_completion"):
            def wrap(f, m=m):
                def g(x):
                    dut._log.info(f"TRACE {m} 0x{x:016x}")
                    return f(x)
                return g
            setattr(sb, m, wrap(getattr(sb, m)))
    n_req, n_rsp = k["n_req"], k["n_rsp"]
    tasks = [
        cocotb.start_soon(cxl_in(dut, n_req, sb, k)),
        cocotb.start_soon(lp_in(dut, n_rsp, sb, k)),
        cocotb.start_soon(sink(dut, n_req, dut.mem_clk, dut.lp_out_valid, dut.lp_out_ready,
                               dut.lp_out_data, sb.on_command, k)),
        cocotb.start_soon(sink(dut, n_rsp, dut.clk, dut.cxl_out_valid, dut.cxl_out_ready,
                               dut.cxl_out_data, sb.on_completion, k)),
    ]
    for t in tasks:
        await t
    assert not sb.posted and not sb.np, \
        f"leftover c2m expected (posted={len(sb.posted)}, np={len(sb.np)})"
    assert not sb.cpl, f"leftover m2c expected ({len(sb.cpl)})"
    dut._log.info(f"RR OK cmds={sb.n_cmd} cpls={sb.n_cpl}")
