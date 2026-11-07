#!/usr/bin/env python3
"""Runs the iverilog testbenches of fpga/ (spec section 9).

Usage, from any directory:
    python -B fpga/sim/run_sim.py [--iverilog PATH] [--negative] [--slow] [TEST ...]
TEST: names from TESTS (default: every test that is not slow; --slow adds the slow ones).
A test passes when vvp exits 0, prints a line that starts with PASS and no line that starts with
ERROR or contains FATAL; with 'compare' the frame it writes must also pass frame_compare.py
against its golden frame. --negative also runs every fault of the test: fpga/sim/negative/<name>
.patch applied to copies under build/sim with git apply; each must fail and print its expected
text. Outputs: build/sim/<test>[_<fault>]/ (ignored by git). Core sources: RK86_CORE_DIR
(default cores/karabas-go-core-rk86/src), never copied unless a fault patches them.
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
CORE = os.path.abspath(os.environ.get('RK86_CORE_DIR', os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src')))
NEG = os.path.join(ROOT, 'fpga', 'sim', 'negative')


def rtl(*names):
    return [os.path.join(ROOT, 'fpga', 'rtl', n) for n in names]


def sim(*names):
    return [os.path.join(ROOT, 'fpga', 'sim', n) for n in names]


def core_files():
    files = []
    with open(os.path.join(CORE, 'rk86_machine.prj'), encoding='utf-8') as f:
        for line in f:
            parts = line.split('"')
            if line.startswith('verilog') and len(parts) >= 3:
                files.append(os.path.join(CORE, parts[1]))
    return files


HEX = {  # name in the run directory: (source, size)
    'monitor.hex': (lambda: os.path.join(CORE, 'roms', 'BIOS.BIN'), 2048),
    'font.hex': (lambda: os.path.join(CORE, 'roms', 'FONT.BIN'), 1024),
    'cartridge.hex': (lambda: os.path.join(ROOT, 'build', 'assets', 'romdisk.bin'), 32256),
}

TESTS = {
    'cart_ppi': dict(top='tb_cart_ppi', files=sim('unit/tb_cart_ppi.v') + rtl('pocket_cart_ppi.v')),
    'audio': dict(top='tb_native_audio', files=sim('unit/tb_native_audio.v') + rtl('pocket_audio.v')),
    'overlay': dict(top='tb_native_keyboard_overlay', hex=['font.hex'],
                    files=sim('unit/tb_native_keyboard_overlay.v') + rtl('pocket_keyboard_overlay.v')),
    'keyboard': dict(top='tb_pocket_keyboard', files=sim('unit/tb_pocket_keyboard.v') + rtl('pocket_remap.v', 'pocket_keyboard.v'),
                     negatives=[('map_ignored', 'ERROR: matrix'), ('keys_on_ignored', 'ERROR: matrix'),
                                ('escape_swapped', 'ERROR: matrix')]),
    'frame_video': dict(top='tb_frame_video', files=sim('unit/tb_frame_video.v') + rtl('pocket_frame_video.v')),
    'frame_colour': dict(top='tb_frame_colour', files=sim('unit/tb_frame_colour.v') + rtl('pocket_frame_video.v'),
                         negatives=[('colour_ignored', 'ERROR: colour ffffff, expected 00ff00')]),
    'assets': dict(top='tb_assets', hex=['monitor.hex', 'font.hex', 'cartridge.hex'],
                   files=sim('unit/tb_assets.v') + rtl('pocket_asset_store.v', 'pocket_boot_assets.v'),
                   negatives=[('rom_disk_required', 'missing ROM disk must be legal')]),
    'memory': dict(top='tb_pocket_memory', files=sim('unit/tb_pocket_memory.v') + rtl('pocket_memory.v'),
                   negatives=[('tag_not_invalidated', 'read after write'),
                              ('window_ignored', 'window: ready without'),
                              ('write_level', 'cpu_write is not one clk')]),
    'cold_clear': dict(top='tb_cold_clear', files=sim('unit/tb_cold_clear.v') + rtl('pocket_cold_clear.v', 'pocket_memory.v'),
                       negatives=[('clear_skips_last', 'clear: we count is not 32768')]),
    'window': dict(top='tb_pocket_window', files=sim('unit/tb_pocket_window.v') + rtl('pocket_window.v'),
                   negatives=[('markers_from_stream', 'ERROR: markers')]),
    'interact': dict(top='tb_pocket_interact', files=sim('unit/tb_pocket_interact.v') + rtl('pocket_interact.v'),
                     negatives=[('keys_range', 'ERROR: read 0000010c'), ('keys_on_range', 'ERROR: read 00000110'),
                                ('escape_range', 'ERROR: read 00000114')]),
    'watchdog': dict(top='tb_pll_watchdog', files=sim('unit/tb_pll_watchdog.v') + rtl('pocket_pll_watchdog.v'),
                     negatives=[('watchdog_never', 'ERROR: watchdog pulse count')]),
}


SYSTEM_RTL = rtl('pocket_asset_store.v', 'pocket_boot_assets.v', 'pocket_interact.v', 'pocket_memory.v',
                 'pocket_cold_clear.v', 'pocket_window.v', 'pocket_remap.v', 'pocket_keyboard.v',
                 'pocket_keyboard_overlay.v', 'pocket_cart_ppi.v', 'pocket_frame_video.v', 'pocket_audio.v',
                 'pocket_pll_watchdog.v', 'radio86rk_pocket.v', 'pocket_system.v')


def system(scenario, compare=None):
    return dict(top='tb_system', slow=True, plusargs=['+scenario=' + scenario], compare=compare,
                hex=['monitor.hex', 'font.hex', 'cartridge.hex'],
                files=lambda: sim('system/tb_system.v') + SYSTEM_RTL + core_files())


TESTS.update({
    'boot': system('boot', ('frame.hex', 'fpga/sim/golden/monitor-boot.hex')),
    'powerup': system('powerup', ('frame.hex', 'fpga/sim/golden/monitor-boot.hex')),
    'nocart': system('nocart'),
    'reset': system('reset'),
    'relock': system('relock'),
    'system_watchdog': system('watchdog'),
    'menu': system('menu', ('frame.hex', 'fpga/sim/golden/rom-disk-menu.hex')),
    'xonix': system('xonix'),
    'dpddt': system('dpddt'),
    'tetris': system('tetris'),
})


def write_hex(name, out):
    src, size = HEX[name]
    path = src()
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) != size:
        raise SystemExit('ERROR: %s is %d bytes, expected %d' % (path, len(data), size))
    with open(os.path.join(out, name), 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%02x\n' % b for b in data))


def run(name, test, iverilog, vvp, env, fault=None):
    out = os.path.join(ROOT, 'build', 'sim', name + ('_' + fault if fault else ''))
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    files = test['files']() if callable(test['files']) else list(test['files'])
    if fault:
        sys.path.insert(0, os.path.join(CORE, 'sim'))
        from negative import apply_patch, patched_files  # the core helper (core PR14)
        patch = os.path.join(NEG, fault + '.patch')
        copy_root = os.path.join(out, 'copy')
        for rel in patched_files(patch):
            src, dst = os.path.join(ROOT, rel), os.path.join(copy_root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            files = [dst if os.path.normcase(f) == os.path.normcase(src) else f for f in files]
        try:
            apply_patch(ROOT, copy_root, patch)
        except ValueError as e:
            return False, 'ERROR: fault %s: %s' % (fault, e)
    for h in test.get('hex', []):
        write_hex(h, out)
    exe = os.path.join(out, name + '.vvp')
    cmd = [iverilog, '-g2012', '-I', os.path.join(ROOT, 'fpga', 'rtl'), '-I', os.path.join(ROOT, 'fpga', 'sim', 'system'),
           '-s', test['top'], '-o', exe] + files
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=out, env=env)
    if res.returncode:
        return False, 'ERROR: iverilog: ' + (res.stdout + res.stderr)
    res = subprocess.run([vvp, '-n', exe] + test.get('plusargs', []), capture_output=True, text=True, cwd=out, env=env)
    text = res.stdout + res.stderr
    lines = [l.strip() for l in text.splitlines()]
    ok = (res.returncode == 0 and any(l.startswith('PASS') for l in lines)
          and not any(l.startswith('ERROR') or 'FATAL' in l for l in lines))
    if ok and test.get('compare'):
        produced, golden = test['compare']
        cmp = subprocess.run([sys.executable, '-B', os.path.join(ROOT, 'fpga', 'sim', 'frame_compare.py'),
                              os.path.join(out, produced), os.path.join(ROOT, golden)], capture_output=True, text=True)
        text += cmp.stdout + cmp.stderr
        ok = cmp.returncode == 0
    return ok, text


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--slow', action='store_true')
    ap.add_argument('tests', nargs='*')
    a = ap.parse_args()
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
    names = a.tests or [n for n, t in TESTS.items() if a.slow or not t.get('slow')]
    unknown = [n for n in names if n not in TESTS]
    if unknown:
        print('ERROR: unknown tests: %s' % ', '.join(unknown))
        return 2
    failed = 0
    for name in names:
        test = TESTS[name]
        ok, text = run(name, test, iverilog, vvp, env)
        print('%s: %s' % (name, 'PASS' if ok else 'FAIL'))
        if not ok:
            print(text.rstrip())
            failed += 1
        if a.negative:
            for fault, expected in test.get('negatives', []):
                bad, text = run(name, test, iverilog, vvp, env, fault)
                caught = not bad and expected in text
                print('%s: negative %s %s' % (name, fault, 'FAILED as expected' if caught else 'NOT CAUGHT (expected: %s)' % expected))
                if not caught:
                    print(text.rstrip())
                    failed += 1
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
