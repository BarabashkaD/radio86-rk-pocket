#!/usr/bin/env python3
"""The core's machine16 TB on the Pocket memory (pocket_memory through fpga/sim/memory/tb_rk86_mem16.v).

Runs the test machine16 of the core's src/sim/machine16/run_machine16_sim.py in place (nothing
copied) with --mem <repo>/fpga/sim/memory/tb_rk86_mem16.v <repo>/fpga/rtl/pocket_memory.v
(absolute paths), and prints its result: the boot to FE63, the board glue and the bus timing
checks, among them the sample checks (the 8275 takes the DMA byte at WR rise, after READ has
ended: the memory output must follow bus_a whatever mem_rd is). Then the fault of spec 9.1-6 on
the Pocket memory: fpga/sim/negative/memory_dropped_after_rd.patch applied with git apply to a
copy of pocket_memory.v under build/sim/core_machine/neg_memory_dropped_after_rd/, machine16 run
again with that copy in --mem; it must fail with 'ERROR: dma byte'. The fault runs only after the
first run passed (both runs write the core runner's folder).

Usage: python -B fpga/sim/run_core_machine.py [--iverilog PATH] [--frames N]
Outputs: the core's build/sim/machine16/machine16/ (ignored by the core; the core runner sets that
folder, an exception to AGENTS.md's build/ rule) and build/sim/core_machine/ (the patched copy).
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CORE_SRC = os.path.abspath(os.environ.get('RK86_CORE_DIR', os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src')))
sys.path.insert(0, os.path.join(CORE_SRC, 'sim', 'machine16'))
sys.dont_write_bytecode = True  # no __pycache__ in the core submodule
import run_machine16_sim as core  # noqa: E402

RUNNER = os.path.join(CORE_SRC, 'sim', 'machine16', 'run_machine16_sim.py')
TEST = 'machine16'
MEM_TB = os.path.join(ROOT, 'fpga', 'sim', 'memory', 'tb_rk86_mem16.v')
MEMORY = os.path.join(ROOT, 'fpga', 'rtl', 'pocket_memory.v')
MEM = [MEM_TB, MEMORY]
FAULT = 'memory_dropped_after_rd'
FAULT_EXPECTED = 'ERROR: dma byte'
FAULT_PATCH = os.path.join(ROOT, 'fpga', 'sim', 'negative', FAULT + '.patch')
FAULT_DIR = os.path.join(ROOT, 'build', 'sim', 'core_machine', 'neg_' + FAULT)


def command(iverilog, mem=MEM, frames=None):
    """The command line of one machine16 run with these --mem files (absolute paths)."""
    cmd = [sys.executable, '-B', RUNNER, '--iverilog', iverilog]
    if frames is not None:
        cmd += ['--frames', str(frames)]
    return cmd + [TEST, '--mem'] + [os.path.abspath(m) for m in mem]


def run(cmd):
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    text = res.stdout + res.stderr
    print(text.rstrip())
    return res.returncode, text


def fault_copy():
    """Copies pocket_memory.v under FAULT_DIR (its repository-relative path kept) and applies the
    fault patch to the copy. Returns the copy's path."""
    shutil.rmtree(FAULT_DIR, ignore_errors=True)
    for rel in core.patched_files(FAULT_PATCH):
        if os.path.normcase(os.path.join(ROOT, rel)) != os.path.normcase(MEMORY):
            raise ValueError('%s patches %s, not pocket_memory.v' % (FAULT_PATCH, rel))
    dst = os.path.join(FAULT_DIR, 'fpga', 'rtl', 'pocket_memory.v')
    os.makedirs(os.path.dirname(dst))
    shutil.copyfile(MEMORY, dst)
    core.apply_patch(ROOT, FAULT_DIR, FAULT_PATCH)
    return dst


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--frames', type=int)
    a = ap.parse_args()
    iverilog = shutil.which(a.iverilog)
    if not iverilog:
        print('ERROR: iverilog not found: %s' % a.iverilog)
        return 2
    print('=== %s on pocket_memory' % TEST)
    code, text = run(command(iverilog, MEM, a.frames))
    if code == 2:
        return 2
    ok = code == 0 and ('%s: PASS' % TEST) in text
    if not ok:
        print('ERROR: %s failed on pocket_memory; fault %s not run' % (TEST, FAULT))
    else:
        print('=== fault %s' % FAULT)
        try:
            copy = fault_copy()
        except (ValueError, OSError) as e:
            print('ERROR: fault %s: %s' % (FAULT, e))
            return 1
        code, text = run(command(iverilog, [MEM_TB, copy], a.frames))
        caught = code == 1 and FAULT_EXPECTED in text
        print('%s %s' % (FAULT, 'FAILED as expected' if caught else 'NOT CAUGHT (expected: %s)' % FAULT_EXPECTED))
        ok = caught
    print('run_core_machine: %s (%s on pocket_memory, fault %s)' % ('PASS' if ok else 'FAIL', TEST, FAULT))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
