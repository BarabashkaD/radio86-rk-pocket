#!/usr/bin/env python3
"""Runs the iverilog testbenches of fpga/ (spec section 9).

Usage, from any directory:
    python -B fpga/sim/run_sim.py [--iverilog PATH] [--negative] [--slow] [TEST ...]
TEST: names from TESTS (default: every test that is not slow; --slow adds the slow ones; a test with
'skip' runs only when named).
A test passes when vvp exits 0, prints a line that starts with PASS and no line that starts with
ERROR or contains FATAL; with 'compare' the frame it writes must also pass frame_compare.py
against its golden frame. --negative also runs every fault of the test: fpga/sim/negative/<name>
.patch applied to copies under build/sim with git apply; each must fail and print its expected
text. Outputs: build/sim/<test>[_<fault>]/ (ignored by git). Core sources: RK86_CORE_DIR
(default cores/karabas-go-core-rk86/src), never copied unless a fault patches them (a patch names a
core file as cores/karabas-go-core-rk86/src/<path>; the copy is taken from RK86_CORE_DIR).
"""
import argparse
import json
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


def core_files(prj='rk86_machine.prj', only=None):
    """The core sources of a .prj in RK86_CORE_DIR; only: keep the files with these base names."""
    files = []
    with open(os.path.join(CORE, prj), encoding='utf-8') as f:
        for line in f:
            parts = line.split('"')
            if line.startswith('verilog') and len(parts) >= 3:
                files.append(os.path.join(CORE, parts[1]))
    if only is not None:
        files = [p for p in files if os.path.basename(p) in only]
        missing = set(only) - {os.path.basename(p) for p in files}
        if missing:
            raise SystemExit('ERROR: %s not in %s' % (', '.join(sorted(missing)), os.path.join(CORE, prj)))
    return files


HEX = {  # name in the run directory: (source, accepted sizes, written size: the rest FF)
    'monitor.hex': (lambda: os.path.join(CORE, 'roms', 'BIOS.BIN'), (2048,), 2048),
    'font.hex': (lambda: os.path.join(CORE, 'roms', 'FONT.BIN'), (1024,), 1024),
    # Kiselev's ROM disk, or a 64 KB game disk (tb_system: +cart_size=65536)
    'cartridge.hex': (lambda: os.path.join(ROOT, 'build', 'assets', 'romdisk.bin'), (32256, 65536), 65536),
    # game: the 64 KB game disk the scenario reloads into the ROM disk slot (build_romdisks.py builds it)
    'cartridge2.hex': (lambda: os.path.join(ROOT, 'build', 'romdisks', 'romdisk-2.bin'), (65536,), 65536),
}

TESTS = {
    'cart_ppi': dict(top='tb_cart_ppi',
                     files=lambda: sim('unit/tb_cart_ppi.v') + rtl('pocket_cart_ppi.v')
                     + core_files('rk86_machine16.prj', only=('k580vv55.v',)),
                     negatives=[('cart_pc7_ignored', 'ERROR: cart_ppi: pc7'),
                                ('cart_wide_no_a15', 'ERROR: cart_ppi: wide reset: rom address'),
                                ('cart_wide_pc7_off', 'ERROR: cart_ppi: wide reset: port A')]),
    'audio': dict(top='tb_native_audio', files=sim('unit/tb_native_audio.v') + rtl('pocket_audio.v')),
    'bus_cdc': dict(top='tb_bus_cdc', files=sim('unit/tb_bus_cdc.v') + rtl('pocket_bus_cdc.v'),
                    negatives=[('bus_cdc/copy_without_req', 'ERROR: copied a held value')]),
    'keyboard': dict(top='tb_pocket_keyboard', files=sim('unit/tb_pocket_keyboard.v') + rtl('pocket_remap.v', 'pocket_keyboard.v'),
                     negatives=[('keyboard/map_ignored', 'ERROR: matrix'), ('keyboard/keys_on_ignored', 'ERROR: matrix'),
                                ('keyboard/escape_swapped', 'ERROR: matrix'),
                                ('keyboard/chord_leaks_rus', 'ERROR: chord: RUS'),
                                ('keyboard/tap_sends_ctrl', 'ERROR: delayed Ctrl')]),
    'frame_video': dict(top='tb_frame_video', files=sim('unit/tb_frame_video.v') + rtl('pocket_frame_video.v', 'pocket_k1_panel.v')),
    'frame_colour': dict(top='tb_frame_colour', files=sim('unit/tb_frame_colour.v') + rtl('pocket_frame_video.v', 'pocket_k1_panel.v'),
                         negatives=[('colour_ignored', 'ERROR: colour ffffff, expected 00ff00')]),
    'k1_panel': dict(top='tb_k1_panel', inputs=lambda out: k1_panel_inputs(out),
                     files=sim('unit/tb_k1_panel.v') + rtl('pocket_frame_video.v', 'pocket_k1_panel.v'),
                     negatives=[('k1_panel/labels_ignore_sh', 'ERROR: pixel')]),
    'slot_loader': dict(top='tb_slot_loader', files=sim('unit/tb_slot_loader.v') + rtl('pocket_slot_loader.v', 'pocket_rom8.v'),
                        negatives=[('slot_loader/size_not_limited', 'byte beyond the size written'),
                                   ('slot_loader/lane_order', 'byte order'),
                                   ('slot_loader/romdisk_32k_only', 'ERROR: slot 2 size 32769'),
                                   ('slot_loader/wide_at_32k', 'romdisk_64k at 32768 bytes')]),
    'memory': dict(top='tb_pocket_memory', files=sim('unit/tb_pocket_memory.v') + rtl('pocket_memory.v'),
                   negatives=[('write_level', 'cpu_write is not one clk'),
                              ('write_during_aen', 'RAM changed during aen'),
                              ('write_during_rom', 'RAM changed during rom'),
                              ('memory_dropped_after_rd', 'output dropped')]),
    'cold_clear': dict(top='tb_cold_clear', files=sim('unit/tb_cold_clear.v') + rtl('pocket_cold_clear.v', 'pocket_memory.v'),
                       negatives=[('clear_skips_last', 'clear: we count is not 32768')]),
    'window': dict(top='tb_pocket_window', files=sim('unit/tb_pocket_window.v') + rtl('pocket_window.v'),
                   negatives=[('markers_from_stream', 'ERROR: markers')]),
    'interact': dict(top='tb_pocket_interact', files=sim('unit/tb_pocket_interact.v') + rtl('pocket_interact.v'),
                     negatives=[('keys_range', 'ERROR: read 0000010c'), ('keys_on_range', 'ERROR: read 00000110'),
                                ('escape_range', 'ERROR: read 00000114'), ('palette_range', 'ERROR: read 00000118')]),
    'raster': dict(top='tb_pocket_raster', files=sim('unit/tb_pocket_raster.v') + rtl('pocket_raster.v'),
                   negatives=[('raster_rising_edge', 'ERROR: raster: h_cnt'),
                              ('raster_no_h_reset', 'ERROR: raster: h_cnt'),
                              ('raster_no_plausibility', 'ERROR: raster: frame start on an implausible raster')]),
    'watchdog': dict(top='tb_pll_watchdog', files=sim('unit/tb_pll_watchdog.v') + rtl('pocket_pll_watchdog.v'),
                     negatives=[('watchdog_never', 'ERROR: watchdog pulse count')]),
    # rk86_machine16 with the CPU test program in place of the monitor, on the Pocket memory (pocket_memory
    # through fpga/sim/memory/tb_rk86_mem16.v, the ports of the fork's model); about 8 native frames: slow
    'cpu16': dict(top='tb_cpu16', slow=True, inputs=lambda out: cpu16_inputs(out), plusargs=['+bios=cpu_test.hex'],
                  incdirs=lambda: [os.path.join(CORE, 'sim', 'machine16')],   # cpu_power_up.vh
                  files=lambda: sim('unit/tb_cpu16.v', 'memory/tb_rk86_mem16.v') + rtl('pocket_memory.v')
                  + core_files('rk86_machine16.prj'),
                  negatives=[('cpu16_bus_bit', 'ERROR: cpu16: phase 1 case 1'),
                             ('cpu16_startup_decode', 'ERROR: cpu16: device written during start-up'),
                             # review A I2: during AEN the monitor ROM is not selected (the old glue): phase 7's
                             # DMA bytes from F800-FFFF come from RAM
                             ('cpu16_dma_rom_from_ram', 'ERROR: cpu16: phase 7 DMA byte')]),
}


SYSTEM_RTL = rtl('pocket_slot_loader.v', 'pocket_rom8.v', 'pocket_interact.v', 'pocket_memory.v',
                 'pocket_cold_clear.v', 'pocket_raster.v', 'pocket_window.v', 'pocket_remap.v', 'pocket_keyboard.v',
                 'pocket_bus_cdc.v', 'pocket_cart_ppi.v', 'pocket_frame_video.v', 'pocket_k1_panel.v', 'pocket_audio.v',
                 'pocket_pll_watchdog.v', 'radio86rk_pocket.v', 'pocket_system.v')

# The first h_cnt of the 408 x 300 window (pocket_window.v X0): frame_compare.py places the cursor cell
# of cursor.txt with it. Both change together.
WINDOW_X0 = 42


def system(scenario, compare=None, cart=None, extra=None, negatives=()):
    return dict(top='tb_system', slow=True, plusargs=['+scenario=' + scenario], compare=compare, cart=cart, extra=extra,
                hex=['monitor.hex', 'font.hex', 'cartridge.hex'], negatives=list(negatives),
                incdirs=lambda: [os.path.join(CORE, 'sim', 'machine16')],   # cpu_power_up.vh (power_up.vh)
                files=lambda: sim('system/tb_system.v') + SYSTEM_RTL + core_files('rk86_machine16.prj'))


def game_plusargs(disk=2, file='XONIX1.RKR'):
    path = os.path.join(ROOT, 'build', 'romdisks', 'romdisks.json')
    if not os.path.exists(path):
        raise ValueError('%s missing' % path)
    with open(path, encoding='utf-8') as f:
        e = next((e for d in json.load(f) if d['disk'] == disk for e in d['entries'] if e['file'] == file), None)
    if e is None:
        raise ValueError('entry %s of disk %d not found in %s' % (file, disk, path))
    return ['+game_key=%d' % ord(e['key']), '+game_ram=%d' % e['ram'], '+game_rom=%d' % e['rom'], '+game_len=%d' % e['length']]


TESTS.update({
    'boot': system('boot', ('frame.hex', 'fpga/sim/golden/monitor-boot.hex'),
                   negatives=[('beeper_pc0_xor', 'beeper does not follow INTE')]),
    'powerup': system('powerup', ('frame.hex', 'fpga/sim/golden/monitor-boot.hex')),
    'nocart': system('nocart'),
    'reset': system('reset'),
    'relock': system('relock'),
    'system_watchdog': system('watchdog'),
    # kept, skipped unless named: xonix captures the same menu frame before its program (the maintainer, 2026-11-11)
    'menu': dict(system('menu', ('frame.hex', 'fpga/sim/golden/rom-disk-menu.hex')),
                 skip='xonix captures the same menu frame first; run it by name'),
    # the ROM disk menu frame (vs rom-disk-menu.hex), then XONIX from the menu
    'xonix': system('xonix', ('frame.hex', 'fpga/sim/golden/rom-disk-menu.hex')),
    # local only (slow; the disks are built by scripts/romdisk/build_romdisks.py, not fetched)
    # boots with Kiselev's romdisk.bin, then reloads the ROM disk slot with disk 2 (cartridge2.hex): XONIX1
    # above 8000h (the 64 KB wiring, PC7 = ROM A15)
    'game': dict(system('game', extra=game_plusargs), hex=['monitor.hex', 'font.hex', 'cartridge.hex', 'cartridge2.hex']),
    # kept, skipped unless named: xonix covers the same ROM disk path (the maintainer, 2026-11-11)
    'dpddt': dict(system('dpddt'), skip='xonix covers the same ROM disk path; run it by name'),
    # kept, but skipped unless named: the D-pad control of this TETRIS has a known problem (the maintainer,
    # 2026-11-11); run it with: python -B fpga/sim/run_sim.py tetris
    'tetris': dict(system('tetris'), skip='known D-pad control problem of this TETRIS; run it by name'),
    # an 80 ms and a 1 ms button tap reach the monitor (pocket_keyboard on real milliseconds)
    'keytap': system('keytap', negatives=[('keytap/min_hold_short', 'ERROR: keytap: the 1 ms tap')]),
    'k1': system('k1'),  # writes k1_<n>.hex and k1.log: python -B scripts/k1/check_frames.py build/sim/k1
    # the panel with the machine frozen; CI: python -B scripts/k1/check_frames.py build/sim/system_k1_panel --expect 3
    'system_k1_panel': system('k1_panel'),
})


def write_hex(name, out, path=None):
    src, sizes, written = HEX[name]
    path = path or src()
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) not in sizes:
        raise SystemExit('ERROR: %s is %d bytes, expected %s' % (path, len(data), ' or '.join(map(str, sizes))))
    data += b'\xff' * (written - len(data))
    with open(os.path.join(out, name), 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%02x\n' % b for b in data))


# K1 panel states of tb_k1_panel: (render_panel state, diagnostic error). Lines: G 39, V 54 (Ж in RUS);
# ids: G 28, ВК 46, СС 62, АР2 0, F2 5. green is the Text colour input.
K1_PANEL_STATES = [
    (dict(open=1, selected=28, palette=0), 0),                                         # a: LAT
    (dict(open=1, rus=1, sh=1, selected=46, pulled=[54], palette=1), 0),               # b: RUS + Shift, v1.4
    (dict(open=1, rus=1, sh=1, ct=1, rus_line=1, selected=62, palette=2, green=1), 0), # c: mono green
    (dict(open=0, rus=1, sh=1, selected=5, pulled=[39], palette=1), 0),                # d: closed
    (dict(open=1, ct=1, selected=0, pulled=[12, 63], palette=1), 1),                   # e: error frame
    (dict(open=1, sh=1, selected=28, pulled=[39], palette=0), 0),                      # f: selected and lit
    (dict(open=1, ct=1, selected=28, pulled=[39], palette=2), 0),                      # g: mono, selected and lit
]


def k1_panel_inputs(out):
    """tb_k1_panel inputs: the background bits, the states ({error, green, bus}) and the frames
    the model expects (scripts/k1/render.py)."""
    sys.path.insert(0, os.path.join(ROOT, 'scripts', 'k1'))
    import layout
    import render
    frame = layout.read_frame(os.path.join(ROOT, 'fpga', 'sim', 'golden', 'rom-disk-menu.hex'))
    with open(os.path.join(out, 'k1_panel_bg.hex'), 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%d\n' % b for b in frame))
    with open(os.path.join(out, 'k1_panel_states.hex'), 'w', encoding='ascii', newline='\n') as f:
        for state, error in K1_PANEL_STATES:
            f.write('%020x\n' % (error << 79 | int(bool(state.get('green'))) << 78 | render.state_bus(state)))
    for n, (state, error) in enumerate(K1_PANEL_STATES):
        render.write_rgb_hex(os.path.join(out, 'k1_panel_exp_%d.hex' % n), render.picture(state, frame, error))


def cpu16_inputs(out):
    """tb_cpu16 input: fpga/sim/cpu16/cpu_test.asm assembled at F800, padded to 2048 bytes with FF."""
    sys.path.insert(0, os.path.join(ROOT, 'scripts', 'romdisk'))
    import asm8080
    with open(os.path.join(ROOT, 'fpga', 'sim', 'cpu16', 'cpu_test.asm'), encoding='utf-8') as f:
        origin, code, _ = asm8080.assemble(f.read())
    if origin != 0xF800 or len(code) > 2048:
        raise SystemExit('ERROR: cpu_test.asm: origin %04X, %d bytes (expected F800, at most 2048)' % (origin, len(code)))
    with open(os.path.join(out, 'cpu_test.hex'), 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%02x\n' % b for b in code + bytes([0xFF] * (2048 - len(code)))))


# A fault patch names a core file by its path in the default submodule checkout; it is read from
# RK86_CORE_DIR, so a fault of a core file also works with another core directory.
CORE_REL = 'cores/karabas-go-core-rk86/src/'


def fault_source(rel):
    if rel.startswith(CORE_REL):
        return os.path.join(CORE, rel[len(CORE_REL):])
    return os.path.join(ROOT, rel)


def run(name, test, iverilog, vvp, env, fault=None):
    out = os.path.join(ROOT, 'build', 'sim', name + ('_' + fault if fault else ''))
    try:
        cart = test['cart']() if test.get('cart') else None
        if cart and not os.path.exists(cart):
            raise ValueError('%s missing' % cart)
        extra = test['extra']() if test.get('extra') else []
    except ValueError as e:
        return False, 'ERROR: %s: run python -B scripts/romdisk/build_romdisks.py' % e
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    files = test['files']() if callable(test['files']) else list(test['files'])
    if fault:
        sys.path.insert(0, os.path.join(CORE, 'sim'))
        sys.dont_write_bytecode = True  # no __pycache__ in the core submodule
        from negative import apply_patch, patched_files  # the core helper (core PR14)
        patch = os.path.join(NEG, fault + '.patch')
        copy_root = os.path.join(out, 'copy')
        for rel in patched_files(patch):
            src, dst = fault_source(rel), os.path.join(copy_root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            files = [dst if os.path.normcase(f) == os.path.normcase(src) else f for f in files]
        try:
            apply_patch(ROOT, copy_root, patch)
        except ValueError as e:
            return False, 'ERROR: fault %s: %s' % (fault, e)
    for h in test.get('hex', []):
        write_hex(h, out, cart if h == 'cartridge.hex' else None)
    if test.get('inputs'):
        test['inputs'](out)
    exe = os.path.join(out, name + '.vvp')
    incdirs = [os.path.join(ROOT, 'fpga', 'rtl'), os.path.join(ROOT, 'fpga', 'sim', 'system')]
    incdirs += test['incdirs']() if test.get('incdirs') else []
    cmd = [iverilog, '-g2012'] + [arg for d in incdirs for arg in ('-I', d)] + ['-s', test['top'], '-o', exe] + files
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=out, env=env)
    if res.returncode:
        return False, 'ERROR: iverilog: ' + (res.stdout + res.stderr)
    plusargs = test.get('plusargs', []) + extra
    res = subprocess.run([vvp, '-n', exe] + plusargs, capture_output=True, text=True, cwd=out, env=env)
    text = res.stdout + res.stderr
    with open(os.path.join(out, 'vvp.log'), 'w', encoding='utf-8', newline='\n') as f:   # the INFO lines of a pass
        f.write(text)
    lines = [l.strip() for l in text.splitlines()]
    ok = (res.returncode == 0 and any(l.startswith('PASS') for l in lines)
          and not any(l.startswith('ERROR') or 'FATAL' in l for l in lines))
    if ok and test.get('compare'):
        produced, golden = test['compare']
        cursor = os.path.join(out, 'cursor.txt')
        mask = ['--cursor', cursor, '--x0', str(WINDOW_X0)] if os.path.exists(cursor) else []
        cmp = subprocess.run([sys.executable, '-B', os.path.join(ROOT, 'fpga', 'sim', 'frame_compare.py'),
                              os.path.join(out, produced), os.path.join(ROOT, golden)] + mask, capture_output=True, text=True)
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
    names = a.tests or [n for n, t in TESTS.items() if (a.slow or not t.get('slow')) and not t.get('skip')]
    if not a.tests and a.slow:
        for n, t in TESTS.items():
            if t.get('skip'):
                print('%s: skipped (%s)' % (n, t['skip']))
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
