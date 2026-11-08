#!/usr/bin/env python3
"""The CI subset of the core's machine TB on the Pocket memory (pocket_memory through
fpga/sim/memory/tb_rk86_mem.v): the runs g, stall, stall_realign and stall_frac of the core's
src/sim/machine/run_machine_sim.py, called in place (nothing copied), then its stall comparisons.

Usage: python -B fpga/sim/run_core_machine.py [--iverilog PATH] [--frames 12] [--jobs 4] [--seed 1]
Not run here (the full command in AGENTS.md section 6, weekly in CI): frac and random (ce gating
without stalls, compared with g line by line) and the freeze check in frames 0-2 of stall_frac
(FREEZE_FRAMES 0 here; the last frame keeps it). Outputs: the core's build/sim/machine/ (ignored
by the core; the core runner sets that folder, an exception to AGENTS.md's build/ rule).
"""
import argparse
import concurrent.futures
import os
import shutil
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CORE_SRC = os.path.abspath(os.environ.get('RK86_CORE_DIR', os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src')))
sys.path.insert(0, os.path.join(CORE_SRC, 'sim', 'machine'))
sys.dont_write_bytecode = True  # no __pycache__ in the core submodule
import run_machine_sim as core  # noqa: E402

MEM = [os.path.join(ROOT, 'fpga', 'sim', 'memory', 'tb_rk86_mem.v'), os.path.join(ROOT, 'fpga', 'rtl', 'pocket_memory.v')]
SUBSET = ('g', 'stall', 'stall_realign', 'stall_frac')
EXTRA = {'stall_frac': {'FREEZE_FRAMES': 0}}


def runs():
    return {name: dict(core.RUNS[name], **EXTRA.get(name, {})) for name in SUBSET}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--frames', type=int, default=12)
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    if a.frames < 11:
        print('ERROR: --frames must be 11 or more (the stall comparison needs FE63 before frame FRAMES-4)')
        return 2
    iverilog = shutil.which(a.iverilog)
    if not iverilog:
        print('ERROR: iverilog not found: %s' % a.iverilog)
        return 2
    bindir = os.path.dirname(os.path.abspath(iverilog))
    vvp = shutil.which('vvp', path=bindir)
    if not vvp:
        print('ERROR: vvp not found next to %s' % iverilog)
        return 2
    env = dict(os.environ)
    env['PATH'] = bindir + os.pathsep + env.get('PATH', '')
    tools = (iverilog, vvp, env)
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(core.build_and_run, tools, n, p, a.frames, a.seed, None, None, MEM) for n, p in runs().items()]
        for fu in concurrent.futures.as_completed(futs):
            name, ok, text = fu.result()
            results[name] = ok
            print('=== %s: %s' % (name, 'BUILD FAILED' if ok is None else ('PASS' if ok else 'FAIL')))
            print(text)
    if any(v is None for v in results.values()):
        print('run_core_machine: BUILD FAILED')
        return 2
    ok = all(results.values())
    if ok:
        print('=== comparisons')
        for name in ('stall', 'stall_realign', 'stall_frac'):
            ok = core.compare_stall(name, a.frames) and ok
    else:
        print('ERROR: a run failed; no comparison')
    print('run_core_machine: %s (runs %s, frames %d, seed %d)' % ('PASS' if ok else 'FAIL', ', '.join(SUBSET), a.frames, a.seed))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
