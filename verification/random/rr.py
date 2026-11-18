#!/usr/bin/env python3
"""Random-regression driver: rr.py {run,triage,replay,promote}. See README.md."""
import argparse
import concurrent.futures as cf
import datetime
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
VVP = os.path.join(HERE, "build", "sim.vvp")
CORPUS = os.path.join(HERE, "corpus.json")
sys.path.insert(0, HERE)


def configs():
    # rr_test imports cocotb; parse the names without importing it.
    src = open(os.path.join(HERE, "rr_test.py")).read()
    return re.findall(r'^    "(\w+)":\s+dict', src, re.M)


def lib_dir():
    return subprocess.check_output(["cocotb-config", "--lib-dir"], text=True).strip()


def rel(p):
    return os.path.relpath(p, ROOT)


def signature(text, rc):
    m = re.search(r"AssertionError: (.*)", text)
    if m:
        s = m.group(1).strip()
    elif re.search(r"timed out|Timeout", text, re.I):
        s = "TIMEOUT (deadlock/no progress)"
    elif "RR OK" in text and rc == 0:
        return ""
    else:
        lines = [l for l in text.splitlines() if re.search(r"error|fail|assert", l, re.I)]
        s = lines[0].strip() if lines else f"sim exit {rc} without RR OK"
    s = re.sub(r"0x[0-9a-fA-F]+", "0xN", s)
    s = re.sub(r"\b\d+\b", "N", s)
    return re.sub(r"0xN -> got 0xN, exp 0xN", "got != exp", s)[:160]


def run_job(i, seed, config, outdir):
    jd = os.path.join(outdir, f"job{i:04d}")
    os.makedirs(jd, exist_ok=True)
    log = os.path.join(jd, "sim.log")
    env = dict(os.environ, MODULE="rr_test", TOPLEVEL="cxl_lpddr5x_bridge", TOPLEVEL_LANG="verilog",
               RR_SEED=str(seed), RANDOM_SEED=str(seed), PYTHONPATH=f"{HERE}:{HERE}/../cocotb",
               COCOTB_REDUCED_LOG_FMT="1", PYGPI_PYTHON_BIN=sys.executable)
    if config:
        env["RR_CONFIG"] = config
    for v in ("VIRTUAL_ENV", "PYTHONHOME"):
        env.pop(v, None)
    cmd = ["vvp", "-M", lib_dir(), "-m", "libcocotbvpi_icarus", VVP]
    p = subprocess.run(cmd, cwd=jd, env=env, capture_output=True, text=True)
    text = p.stdout + p.stderr
    open(log, "w").write(text)
    m = re.search(r"RR seed=\d+ config=(\w+)", text)
    cfg = m.group(1) if m else (config or "?")
    sig = signature(text, p.returncode)
    fail = bool(sig) or p.returncode != 0
    if fail and not sig:
        sig = f"sim exit {p.returncode}"
    repro = f"make rr N=1 JOBS=1 SEED={seed}" + (f" CONFIG={config}" if config else "")
    return {"job": i, "seed": seed, "config": cfg, "status": "FAIL" if fail else "PASS",
            "signature": sig, "log": rel(log), "repro": repro}


def cmd_run(a):
    if not os.path.exists(VVP):
        sys.exit("rr: sim not built; run `make rr-build`")
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    outdir = os.path.join(HERE, "runs", ts)
    os.makedirs(outdir, exist_ok=True)
    jobs = [(i, a.seed + i) for i in range(a.n)]
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        res = list(ex.map(lambda j: run_job(j[0], j[1], a.config, outdir), jobs))
    with open(os.path.join(outdir, "results.jsonl"), "w") as f:
        for r in res:
            f.write(json.dumps(r) + "\n")
    fails = sum(r["status"] == "FAIL" for r in res)
    print(f"rr run: {rel(outdir)} seed_base={a.seed} jobs={a.n} fail={fails}")
    return 1 if fails else 0


def load(run):
    d = run if os.path.isabs(run) else os.path.join(ROOT, run)
    if os.path.isdir(d):
        d = os.path.join(d, "results.jsonl")
    return [json.loads(l) for l in open(d) if l.strip()]


def cmd_triage(a):
    if not a.run:
        base = os.path.join(HERE, "runs")
        runs = sorted(os.listdir(base)) if os.path.isdir(base) else []
        if not runs:
            sys.exit("rr-triage: no runs; pass RUN=<dir>")
        a.run = os.path.join(base, runs[-1])
    res = load(a.run)
    clusters = {}
    for r in res:
        if r["status"] == "FAIL":
            clusters.setdefault(r["signature"], []).append(r)
    print(f"rr triage: {len(res)} jobs, {sum(map(len, clusters.values()))} fail, {len(clusters)} clusters")
    for sig, rs in sorted(clusters.items(), key=lambda kv: -len(kv[1])):
        cfgs = ",".join(sorted({r["config"] for r in rs}))
        print(f"  x{len(rs)} [{cfgs}] {sig} | repro: {rs[0]['repro']} | log: {rs[0]['log']}")
    return 0


def cmd_promote(a):
    corpus = json.load(open(CORPUS)) if os.path.exists(CORPUS) else []
    corpus.append({"seed": a.seed, "config": a.config or "", "signature": a.signature or "",
                   "fixed": False, "note": a.note or ""})
    json.dump(corpus, open(CORPUS, "w"), indent=2)
    print(f"promoted seed={a.seed} config={a.config or 'auto'} -> {rel(CORPUS)} (set \"fixed\": true once fixed)")
    return 0


def cmd_replay(a):
    if not os.path.exists(VVP):
        sys.exit("rr: sim not built; run `make rr-build`")
    corpus = json.load(open(CORPUS)) if os.path.exists(CORPUS) else []
    outdir = os.path.join(HERE, "runs", "replay")
    os.makedirs(outdir, exist_ok=True)
    bad = 0
    for i, e in enumerate(corpus):
        r = run_job(i, e["seed"], e.get("config") or None, outdir)
        ok = (r["status"] == "PASS") if e.get("fixed") else True
        print(f"replay seed={e['seed']} config={r['config']} fixed={bool(e.get('fixed'))} -> {r['status']}"
              + ("" if ok else f"  UNEXPECTED: {r['signature']}"))
        bad += not ok
    print(f"rr replay: {len(corpus)} entries, {bad} bad")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run")
    r.add_argument("--n", type=int, default=10)
    r.add_argument("--jobs", type=int, default=2)
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--config", default="", choices=[""] + configs())
    t = sp.add_parser("triage")
    t.add_argument("--run", default="")
    sp.add_parser("replay")
    p = sp.add_parser("promote")
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--config", default="")
    p.add_argument("--signature", default="")
    p.add_argument("--note", default="")
    a = ap.parse_args()
    sys.exit({"run": cmd_run, "triage": cmd_triage, "replay": cmd_replay, "promote": cmd_promote}[a.cmd](a))


if __name__ == "__main__":
    main()
