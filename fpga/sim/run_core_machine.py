#!/usr/bin/env python3
"""The machine16 TB of retroMachines (machines/rk86) on the Pocket memory (pocket_memory through
fpga/sim/memory/tb_rk86_mem16.v).

Runs simrun (scripts/simrun.py) on machines/rk86 at tier standard, nothing copied, with
--replace <retroMachines>/machines/rk86/tb/tb_rk86_mem16.v=<repo>/fpga/sim/memory/tb_rk86_mem16.v,
<repo>/fpga/rtl/pocket_memory.v (absolute paths), and prints its result. The tier also holds the
machine's quick TBs (clocks16, video16; they do not compile the memory); the result is machine16's:
the boot to FE63, the board glue and the bus timing checks, among them the sample checks (the 8275
takes the DMA byte at WR rise, after READ has ended: the memory output must follow bus_a whatever
mem_rd is). Then the fault of spec 9.1-6 on the Pocket memory:
fpga/sim/negative/memory_dropped_after_rd.patch applied with git apply (retroICs' simrun.negative) to
a copy of pocket_memory.v under build/sim/core_machine/neg_memory_dropped_after_rd/, the same run
again with that copy in --replace; machine16 must fail with 'ERROR: dma byte'. The fault runs only
after the first run passed.

Usage: python -B fpga/sim/run_core_machine.py [--iverilog PATH] [--frames N]
--frames: simrun's --param FRAMES=N (the machine TB's frame count; default the manifest's).
Outputs: build/sim/core_machine/ (simrun's run folders, the patched copy).
"""
import argparse
import importlib.util
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SIMRUN = os.path.join(ROOT, 'scripts', 'simrun.py')
COMPONENT = 'machines/rk86'
TIER = 'standard'
TEST = 'machine16'
MACHINE_MEM = 'machines/rk86/tb/tb_rk86_mem16.v'   # in retroMachines: the file --replace replaces
MEM_TB = os.path.join(ROOT, 'fpga', 'sim', 'memory', 'tb_rk86_mem16.v')
MEMORY = os.path.join(ROOT, 'fpga', 'rtl', 'pocket_memory.v')
MEM = [MEM_TB, MEMORY]
OUT = os.path.join(ROOT, 'build', 'sim', 'core_machine')
FAULT = 'memory_dropped_after_rd'
FAULT_EXPECTED = 'ERROR: dma byte'
FAULT_PATCH = os.path.join(ROOT, 'fpga', 'sim', 'negative', FAULT + '.patch')
FAULT_DIR = os.path.join(OUT, 'neg_' + FAULT)


def layout():
    """scripts/layout.py under its own module name (scripts/k1/layout.py is the K1 tools' layout)."""
    name = 'rk86_repo_layout'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, 'scripts', 'layout.py'))
        sys.modules[name] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sys.modules[name])
    return sys.modules[name]


def negative():
    """(apply_patch, patched_files) of retroICs' simrun.negative."""
    tools = str(layout().retro_ics_tools())
    if tools not in sys.path:
        sys.path.insert(0, tools)
    sys.dont_write_bytecode = True   # no __pycache__ in the submodule
    from simrun.negative import apply_patch, patched_files
    return apply_patch, patched_files


def machine_mem():
    """The memory model of the machine TB in the retroMachines checkout in use."""
    return os.path.join(str(layout().retro_machines_dir()), *MACHINE_MEM.split('/'))


def command(iverilog, mem=MEM, frames=None):
    """The command line of one simrun run of machines/rk86 with the machine TB's memory replaced by
    these files (absolute paths)."""
    cmd = [sys.executable, '-B', SIMRUN, 'run', COMPONENT, '--tier', TIER, '--iverilog', iverilog,
           '--out', OUT, '--replace', '%s=%s' % (machine_mem(), ','.join(os.path.abspath(m) for m in mem))]
    if frames is not None:
        cmd += ['--param', 'FRAMES=%d' % frames]
    return cmd


def run(cmd):
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    text = res.stdout + res.stderr
    print(text.rstrip())
    return res.returncode, text


def fault_copy():
    """Copies pocket_memory.v under FAULT_DIR (its repository-relative path kept) and applies the
    fault patch to the copy. Returns the copy's path."""
    apply_patch, patched_files = negative()
    shutil.rmtree(FAULT_DIR, ignore_errors=True)
    for rel in patched_files(FAULT_PATCH):
        if os.path.normcase(os.path.join(ROOT, rel)) != os.path.normcase(MEMORY):
            raise ValueError('%s patches %s, not pocket_memory.v' % (FAULT_PATCH, rel))
    dst = os.path.join(FAULT_DIR, 'fpga', 'rtl', 'pocket_memory.v')
    os.makedirs(os.path.dirname(dst))
    shutil.copyfile(MEMORY, dst)
    apply_patch(ROOT, FAULT_DIR, FAULT_PATCH)
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
    try:
        cmd = command(iverilog, MEM, a.frames)
    except layout().LayoutError as e:
        print('ERROR: %s' % e)
        return 2
    print('=== %s on pocket_memory' % TEST)
    code, text = run(cmd)
    if code == 2:
        return 2
    ok = code == 0 and ('%s:%s: PASS' % (COMPONENT, TEST)) in text
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
        caught = code == 1 and ('%s:%s: FAIL' % (COMPONENT, TEST)) in text and FAULT_EXPECTED in text
        print('%s %s' % (FAULT, 'FAILED as expected' if caught else 'NOT CAUGHT (expected: %s)' % FAULT_EXPECTED))
        ok = caught
    print('run_core_machine: %s (%s on pocket_memory, fault %s)' % ('PASS' if ok else 'FAIL', TEST, FAULT))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
