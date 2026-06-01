// Verilator coverage harness for cxl_lpddr5x_bridge.
//
// Dual-clock: host side clk = 10 time-units period, LPDDR5X mem_clk = 14
// (an asynchronous ~1.4:1 ratio, to exercise the Gray-code async FIFOs / CDC).
// This driver does not self-check (the cocotb + directed TBs own correctness);
// its job is to walk the RTL through every opcode, both flow-control FIFOs to
// full and back to empty, the CRC-mismatch INVALID path, the error-injection
// window, and a link-down drain so `make coverage` emits meaningful coverage.
//
// Run from the Verilator --Mdir (cwd holds coverage.dat); the root Makefile
// then feeds coverage.dat to verilator_coverage --write-info.

#include "Vcxl_lpddr5x_bridge.h"
#include "verilated.h"
#include "verilated_cov.h"

#include <cstdint>
#include <cstdio>

// ---- packet kinds / opcodes (mirror src/cxl_lpddr5x_bridge_defs.vh) ----
enum {
    KIND_MEM_RD = 0x1, KIND_MEM_WR = 0x2, KIND_MEM_MRR = 0x3, KIND_MEM_MRW = 0x4,
    KIND_RD_RSP = 0xa, KIND_WR_RSP = 0xb, KIND_MRR_RSP = 0xc, KIND_LP_ERROR = 0xe,
};
enum { RD_NORMAL = 0x0, RD_AUTOPRE = 0x1 };
enum { WR_NORMAL = 0x0, WR_AUTOPRE = 0x1, WR_MASKED = 0x2 };
enum { RSP_OK = 0x1, RSP_ERR = 0x2 };

static uint64_t pack(uint8_t kind, uint8_t code, uint8_t tag, uint16_t addr,
                     uint8_t len, uint8_t id, uint8_t aux, uint8_t misc) {
    return ((uint64_t)(kind & 0xF) << 60) | ((uint64_t)(code & 0xF) << 56) |
           ((uint64_t)tag << 48) | ((uint64_t)addr << 32) | ((uint64_t)len << 24) |
           ((uint64_t)id << 16) | ((uint64_t)aux << 8) | (uint64_t)misc;
}

// CRC-8/CCITT (poly 0x07, init 0x00) over header bytes [63:8]; matches
// bridge_checksum / crc8_step in the defs header and the cocotb gold model.
static uint8_t crc8_step(uint8_t b) {
    for (int i = 0; i < 8; ++i) b = (b & 0x80) ? ((b << 1) ^ 0x07) : (b << 1);
    return b;
}
static uint64_t with_checksum(uint64_t p) {
    p &= ~0xFFull;
    uint8_t c = 0;
    for (int sh = 56; sh >= 8; sh -= 8) c = crc8_step(c ^ (uint8_t)((p >> sh) & 0xFF));
    return p | c;
}

// c2m request stimulus: every kind + opcode, plus an invalid kind (0x0).
static const uint64_t C2M[] = {
    pack(KIND_MEM_RD, RD_NORMAL,  0x10, 0x1000, 0x04, 0xA1, 0x00, 0),
    pack(KIND_MEM_RD, RD_AUTOPRE, 0x11, 0x1040, 0x04, 0xA2, 0x01, 0),
    pack(KIND_MEM_WR, WR_NORMAL,  0x12, 0x2000, 0x08, 0xB1, 0x00, 0),
    pack(KIND_MEM_WR, WR_AUTOPRE, 0x13, 0x2080, 0x08, 0xB2, 0x01, 0),
    pack(KIND_MEM_WR, WR_MASKED,  0x14, 0x20C0, 0x02, 0xB3, 0x0F, 0),
    pack(KIND_MEM_MRR, 0x0,       0x15, 0x0003, 0x00, 0xC1, 0x00, 0),
    pack(KIND_MEM_MRW, 0x0,       0x16, 0x0003, 0x5A, 0xC2, 0x00, 0),
    pack(0x0,          0x0,       0x17, 0x0000, 0x00, 0x00, 0x00, 0), // invalid kind
};
static const int N_C2M = sizeof(C2M) / sizeof(C2M[0]);

// m2c response stimulus: ok/err for each response kind, an ERROR flit, plus a
// deliberately CRC-corrupted flit (last) to drive the INVALID-completion path.
static const uint64_t M2C[] = {
    with_checksum(pack(KIND_RD_RSP,  RSP_OK,  0x10, 0x0040, 0x04, 0xA1, 0x00, 0)),
    with_checksum(pack(KIND_WR_RSP,  RSP_OK,  0x12, 0x0040, 0x08, 0xB1, 0x00, 0)),
    with_checksum(pack(KIND_MRR_RSP, RSP_OK,  0x15, 0x0002, 0x00, 0xC1, 0x00, 0)),
    with_checksum(pack(KIND_RD_RSP,  RSP_ERR, 0x11, 0x0040, 0x04, 0xA2, 0x00, 0)),
    with_checksum(pack(KIND_LP_ERROR, 0x0,    0x13, 0x0000, 0x00, 0x00, 0x00, 0)),
    with_checksum(pack(KIND_RD_RSP,  RSP_OK,  0x14, 0x0040, 0x02, 0xB3, 0x00, 0)) ^ 0xAB, // bad CRC
};
static const int N_M2C = sizeof(M2C) / sizeof(M2C[0]);

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vcxl_lpddr5x_bridge* dut = new Vcxl_lpddr5x_bridge;

    dut->rst_n = 0;
    dut->clk = 0;
    dut->mem_clk = 0;
    dut->link_up = 0;
    dut->err_inj_en = 0;
    dut->cxl_in_valid = 0;
    dut->cxl_in_data = 0;
    dut->lp_in_valid = 0;
    dut->lp_in_data = 0;
    dut->lp_out_ready = 1;
    dut->cxl_out_ready = 1;
    dut->eval();

    const int CLK_H = 5;       // clk half-period (period 10)
    const int MEM_H = 7;       // mem_clk half-period (period 14, async to clk)
    const uint64_t T_END = 200000;

    int prev_clk = 0, prev_mem = 0;
    long clk_cyc = 0, mem_cyc = 0;
    int c2m_i = 0, m2c_i = 0;

    for (uint64_t t = 1; t < T_END && !Verilated::gotFinish(); ++t) {
        int clk = (int)((t / CLK_H) & 1);
        int mem = (int)((t / MEM_H) & 1);

        // Async control sequencing, keyed on host-clock cycles.
        if (clk_cyc >= 20)  dut->rst_n = 1;
        if (clk_cyc >= 40)  dut->link_up = 1;
        dut->err_inj_en = (clk_cyc >= 1500 && clk_cyc < 1600) ? 1 : 0;
        if (clk_cyc >= 3000 && clk_cyc < 3300) dut->link_up = 0; // drain window
        else if (clk_cyc >= 3300)              dut->link_up = 1; // bring link back

        dut->clk = clk;
        dut->mem_clk = mem;
        dut->eval();

        int clk_rise = (clk == 1 && prev_clk == 0);
        int mem_rise = (mem == 1 && prev_mem == 0);

        if (clk_rise) {
            ++clk_cyc;
            // Backpressure the c2m output (lp_out) hard for a window so the
            // posted / non-posted FIFOs fill and cxl_in_ready deasserts.
            dut->lp_out_ready = (clk_cyc >= 500 && clk_cyc < 700) ? 0
                              : ((clk_cyc & 3) != 0);
            // Drive / advance the upstream request stream.
            if (dut->cxl_in_valid && dut->cxl_in_ready) c2m_i = (c2m_i + 1) % N_C2M;
            int active = (clk_cyc >= 50);
            dut->cxl_in_valid = active && ((clk_cyc % 5) != 4); // periodic gaps
            dut->cxl_in_data = C2M[c2m_i];
        }

        if (mem_rise) {
            ++mem_cyc;
            // Backpressure the m2c output (cxl_out) for a window so the
            // completion FIFO fills and lp_in_ready deasserts.
            dut->cxl_out_ready = (mem_cyc >= 900 && mem_cyc < 1100) ? 0
                               : ((mem_cyc & 3) != 0);
            if (dut->lp_in_valid && dut->lp_in_ready) m2c_i = (m2c_i + 1) % N_M2C;
            int active = (mem_cyc >= 40);
            dut->lp_in_valid = active && ((mem_cyc % 4) != 3);
            dut->lp_in_data = M2C[m2c_i];
        }

        prev_clk = clk;
        prev_mem = mem;
    }

    dut->final();
    VerilatedCov::write("coverage.dat");
    printf("[sim_cov] done: %ld clk cycles, %ld mem_clk cycles\n", clk_cyc, mem_cyc);
    delete dut;
    return 0;
}
