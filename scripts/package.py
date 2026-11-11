#!/usr/bin/env python3
"""Builds the SD package of the core from a Quartus build (spec 7).

Usage: python -B scripts/package.py --version 0.5.0 --date YYYY-MM-DD [--build build/quartus]
       [--output build/package]
Checks the definitions against the openFPGA limits, bit-reverses the RBF (round trip checked),
checks every shipped asset against package/assets.json, draws the icon and platform image,
writes Cores/, Assets/ and Platforms/ and the zip BarabashkaD.Radio86RK_<version>_<date>.zip, then checks the zip as the openFPGA library's updater reads it.
The Assets folder also gets the 5 game disks romdisk-1.bin to romdisk-5.bin (64 KB each), built from the core's
pk/ folder by scripts/romdisk/build_romdisks.py, next to Kiselev's romdisk.bin, and romdisks.txt
(package/romdisks.txt: how to run and change the ROM disk, the programs of romdisk.bin, the games
of each game disk). info.txt (shown on the Pocket) also lists the games by menu key and name.
"""
import argparse
import datetime
import functools
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
CORE_ID = 'BarabashkaD.Radio86RK'
PLATFORM = 'radio86rk'
CORE_SRC = os.path.abspath(os.environ.get('RK86_CORE_DIR', os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src')))
PK_DIR = os.path.join(os.path.dirname(CORE_SRC), 'pk')     # the core's game tape images
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'romdisk'))
import build_romdisks  # noqa: E402
GLYPHS = {
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'K': ['10001', '10010', '10100', '11000', '10100', '10010', '10001'],
    '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
    '6': ['01110', '10000', '10000', '11110', '10001', '10001', '01110'],
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'],
    'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'],
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'],
    '-': ['00000', '00000', '00000', '11111', '00000', '00000', '00000'],
}
ICON = (36, 36, 'RK', 2)                     # width, height, text, glyph scale
BANNER = (521, 165, 'RADIO-86RK', 7)         # the platform image


def reverse_bits(data):
    return bytes(int('{:08b}'.format(b)[::-1], 2) for b in data)


BACKGROUND = (24, 112)           # the background's grey at the top and at the bottom row
SHADOW = 0                       # the text's drop shadow, down and right of it


@functools.lru_cache(maxsize=None)
def graphic(width, height, text, scale):
    """The POC image format that worked on the Pocket: 16-bit pixels, intensity in the upper
    byte, stored rotated 90 degrees counter-clockwise. 8-bit greyscale: the frame and the text
    at full brightness, the text with a drop shadow, on a vertical grey gradient (BACKGROUND),
    so the image has more than 16 grey levels and the openFPGA library stores the PNG it makes
    from it as 8-bit greyscale (its chunky_png picks the bit depth from the number of levels)."""
    pixels = [[BACKGROUND[0] + (BACKGROUND[1] - BACKGROUND[0]) * y // max(1, height - 1)] * width
              for y in range(height)]
    border = 3 if width == 36 else 8
    for y in range(border, height - border):
        for x in range(border, width - border):
            if x in (border, width - border - 1) or y in (border, height - border - 1):
                pixels[y][x] = 255
    left = (width - ((len(text) * 6 - 1) * scale)) // 2
    top = (height - 7 * scale) // 2
    shadow = max(1, scale // 3)
    for offset, level in ((shadow, SHADOW), (0, 255)):
        for index, letter in enumerate(text):
            for gy, row in enumerate(GLYPHS[letter]):
                for gx, value in enumerate(row):
                    if value == '1':
                        for dy in range(scale):
                            for dx in range(scale):
                                pixels[top + gy * scale + dy + offset][left + (index * 6 + gx) * scale + dx + offset] = level
    encoded = bytes(c for y in range(width) for x in range(height) for c in (pixels[x][width - 1 - y], 0))
    for y in range(height):                       # the POC's self-check of the rotation and byte layout
        for x in range(width):
            index = ((width - 1 - x) * height + y) * 2
            if encoded[index] != pixels[y][x] or encoded[index + 1] != 0:
                raise ValueError('graphic rotation/byte layout')
    return encoded


# Pocket OS 2.7 did not start a core whose interact.json lists held 97 options in total, and
# started one with 66: an undocumented limit between the two, measured on the hardware
# (fpga/README.md, "Core Settings size limit"). Keep far below it.
MAX_LIST_OPTIONS = 20


def is_iso_date(s):
    """A real calendar date as YYYY-MM-DD (the library's post generator parses it without a rescue)."""
    try:
        return (isinstance(s, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', s) is not None
                and datetime.date.fromisoformat(s) is not None)
    except (ValueError, TypeError):
        return False


def is_string_list(v):
    return isinstance(v, list) and bool(v) and all(isinstance(p, str) for p in v)


def check_core(core):
    m, errors = core['core']['metadata'], []
    for key, limit in (('shortname', 31), ('description', 63), ('author', 31), ('url', 63), ('version', 31)):
        if len(m[key]) > limit:
            errors.append('core.json %s longer than %d' % (key, limit))
    if not is_iso_date(m['date_release']):
        errors.append('core.json date_release is not YYYY-MM-DD')
    if not is_string_list(m['platform_ids']):
        errors.append('core.json platform_ids must be a non-empty list of strings')
    elif len(m['platform_ids']) > 4 or any(not re.fullmatch(r'[a-z0-9_]{1,15}', p) or p.startswith('_') for p in m['platform_ids']):
        errors.append('core.json platform_ids')
    if m['author'] + '.' + m['shortname'] != CORE_ID:
        errors.append('core.json author.shortname is not %s' % CORE_ID)
    return errors


def check_interact(variables):
    """The measured Pocket limit (fpga/README.md, "Core Settings size limit"): 97 list options in total fail, 66 load."""
    errors = []
    if len(variables) > 16:
        errors.append('interact.json: more than 16 items')
    if sum(len(v['options']) for v in variables if v['type'] == 'list') > MAX_LIST_OPTIONS:
        errors.append('interact.json: more than %d list options in total' % MAX_LIST_OPTIONS)
    ids = [v['id'] for v in variables]
    if len(set(ids)) != len(ids) or any(i in (0, 1, 2) for i in ids):
        errors.append('interact.json: ids must be unique and not 0-2 (the data slots)')
    return errors


# updaters.json is read by the openFPGA library and the updater tools (pupdate, Pocket Sync), not
# by the Pocket. Only declare_ai is allowed: "license" would make the updaters ask the user for a
# licence file, "previous" is for a core whose id changed.
UPDATERS_KEYS = ('declare_ai',)


def check_updaters(updaters):
    if not isinstance(updaters, dict) or set(updaters) - set(UPDATERS_KEYS):
        return ['updaters.json: only %s allowed' % ', '.join(UPDATERS_KEYS)]
    ai = updaters.get('declare_ai')
    if not isinstance(ai, list) or not ai or any(not isinstance(t, str) or not t.strip() for t in ai):
        return ['updaters.json: declare_ai must be a non-empty list of tool names']
    return []


def check_definitions(package_dir):
    load = lambda *p: json.load(open(os.path.join(package_dir, *p), encoding='utf-8'))
    errors = check_core(load('core', 'core.json'))
    for slot in load('core', 'data.json')['data']['data_slots']:
        if len(slot['name']) > 15 or len(slot['filename']) > 31 or len(slot['extensions']) > 4 or any(len(e) > 7 for e in slot['extensions']):
            errors.append('data.json slot %s' % slot['name'])
    variables = load('core', 'interact.json')['interact']['variables']
    if sum(1 for v in variables if v['type'] != 'list') > 16:
        errors.append('interact.json: more than 16 entries that are not lists')
    for v in variables:
        if len(v['name']) > 23 or (v['type'] == 'list' and (len(v['options']) > 16 or any(len(o['name']) > 23 for o in v['options']))):
            errors.append('interact.json %s' % v['name'])
    errors += check_interact(variables)
    mappings = load('core', 'input.json')['input']['controllers'][0]['mappings']
    if len(mappings) > 8 or any(len(x['name']) > 19 for x in mappings):
        errors.append('input.json mappings')
    plat = load('platform', PLATFORM + '.json')['platform']
    if any(len(plat[k]) > 31 for k in ('category', 'name', 'manufacturer')):
        errors.append('platform json field longer than 31')
    errors += check_updaters(load('core', 'updaters.json'))
    return errors


# What the openFPGA library's updater reads from a release zip (openfpga-library/analogue-pocket,
# .github/workflows/updater/lib/analogue/*.rb, read 2026-11-08). The schema checks mirror the
# updater: a failure means the release is silently not listed, the author gets no notice. The
# icon/image size, the single core folder, the https url and the updaters key rule are stricter
# than the updater on purpose (so the icon and the platform image render, and the updaters do
# not ask for a licence file).
LIBRARY_ICON_SIZE = 36 * 36 * 2
LIBRARY_IMAGE_SIZE = 521 * 165 * 2


def check_library_zip(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        names = set(z.namelist())
        load = lambda name: json.loads(z.read(name).decode('utf-8'))
        cores = sorted({n.split('/')[1] for n in names if n.startswith('Cores/') and n.count('/') >= 2})
        if cores != [CORE_ID]:
            return ['library: Cores/ must hold only %s, found %s' % (CORE_ID, cores)]
        base = 'Cores/%s/' % CORE_ID
        errors = ['library: %s missing' % (base + n) for n in ('core.json', 'data.json', 'icon.bin')
                  if base + n not in names]
        if errors:
            return errors
        core = load(base + 'core.json').get('core', {})
        m, fw = core.get('metadata', {}), core.get('framework', {})
        for key in ('platform_ids', 'shortname', 'description', 'author', 'url', 'version', 'date_release'):
            if key not in m:
                errors.append('library: core.json metadata.%s missing' % key)
        if not str(m.get('url', '')).startswith('https://'):
            errors.append('library: core.json url is not an https URI')
        if not is_iso_date(m.get('date_release')):
            errors.append('library: core.json date_release is not a date')
        if not is_string_list(m.get('platform_ids')):
            errors.append('library: core.json platform_ids must be a non-empty list of strings')
        if '%s.%s' % (m.get('author'), m.get('shortname')) != CORE_ID:
            errors.append('library: core.json author.shortname is not %s' % CORE_ID)
        dock, hardware = fw.get('dock', {}), fw.get('hardware', {})
        if not (isinstance(fw.get('version_required'), str) and isinstance(fw.get('sleep_supported'), bool)
                and isinstance(dock.get('supported'), bool) and isinstance(dock.get('analog_output'), bool)
                and isinstance(hardware.get('link_port'), bool)):
            errors.append('library: core.json framework (version_required, sleep_supported, dock, link_port)')
        for slot in load(base + 'data.json')['data']['data_slots']:
            parameters = slot.get('parameters')
            if not (isinstance(slot.get('name'), str) and isinstance(slot.get('required'), bool)
                    and isinstance(parameters, (int, str)) and not isinstance(parameters, bool)):
                errors.append('library: data.json slot %s (name, required, parameters)' % slot.get('name'))
        if base + 'updaters.json' in names:
            errors += ['library: ' + e for e in check_updaters(load(base + 'updaters.json'))]
        if len(z.read(base + 'icon.bin')) != LIBRARY_ICON_SIZE:
            errors.append('library: icon.bin is not 36 x 36')
        for pid in (m['platform_ids'] if is_string_list(m.get('platform_ids')) else []):
            plat, image = 'Platforms/%s.json' % pid, 'Platforms/_images/%s.bin' % pid
            if plat not in names:
                errors.append('library: %s missing' % plat)
                continue
            p = load(plat).get('platform', {})
            if not (isinstance(p.get('name'), str) and isinstance(p.get('manufacturer'), str)
                    and isinstance(p.get('year'), int) and not isinstance(p.get('year'), bool)):
                errors.append('library: %s needs name, manufacturer and an integer year' % plat)
            if image not in names or len(z.read(image)) != LIBRARY_IMAGE_SIZE:
                errors.append('library: %s missing or not 521 x 165' % image)
    return errors


GUIDE_MARKER = '@GAME_DISKS@'
ROMDISK_MAX = 65536                 # data.json size_maximum of the ROM disk slot


def romdisk_guide(template, disks):
    """romdisks.txt of the Assets folder: the template with its marker line replaced by the game
    disks (the romdisks.json list of build_romdisks.py)."""
    if template.count(GUIDE_MARKER) != 1:
        raise ValueError('package/romdisks.txt needs exactly one %s line' % GUIDE_MARKER)
    games = sum(len(d['entries']) for d in disks)
    lines = ['Game disks: the %d games of the Karabas core on %d disks' % (games, len(disks)),
             'Load one from the Pocket menu as above, then type R0,1FF,0 and G0: its menu lists the',
             'games with the keys 0 to 9, then A to Y; Z clears the memory 0000-73FF. To choose',
             'another game, use Core Settings > Reset, then R0,1FF,0 and G0 again; G7416 alone shows',
             'the menu again too, unless the game has overwritten the loader at 7400-75FF.',
             'Each game disk is 64 KB: it needs this core (0.8.2 or later); an older core refuses',
             'the file, and the ROM disk then reads FF.']
    for d in disks:
        lines += ['', '%s (disk %d)' % (d['file'], d['disk'])]
        for e in d['entries']:
            title = e.get('title', '')
            lines.append(('  %s  %-12s %s' % (e['key'], e['name'], title)).rstrip())
    return template.replace(GUIDE_MARKER, '\n'.join(lines))


def info_with_games(info, disks):
    """info.txt (shown on the Pocket) with the menu keys and names of the game disks before its
    Credits line; ASCII only (the titles, in Russian, stay in romdisks.txt)."""
    lines = info.split('\n')
    credits = [i for i, line in enumerate(lines) if line.startswith('Credits:')]
    if len(credits) != 1:
        raise ValueError('package/core/info.txt needs exactly one Credits: line')
    games = sum(len(d['entries']) for d in disks)
    add = ["* Game disks (%d games): load one from the core's menu, then R0,1FF,0 and G0; "
           "its menu keys:" % games]
    for d in disks:
        add.append('* %s: %s' % (d['file'], ', '.join('%s %s' % (e['key'], e['name']) for e in d['entries'])))
    return '\n'.join(lines[:credits[0]] + add + lines[credits[0]:])


def game_disks(pk_dir, reserved):
    """The 5 game disks built from the core's tape images by build_romdisks.py:
    (the romdisks.json list, {file name: bytes}). A name of another asset is an error."""
    try:
        built = build_romdisks.build(pk_dir)
    except (OSError, ValueError) as e:
        raise SystemExit('ERROR: game disks: %s' % e)
    disks = build_romdisks.metadata(built, build_romdisks.descriptions(pk_dir))
    files = {}
    for d, b in zip(disks, built):
        if d['file'] in reserved or not 0 < len(b['image']) <= ROMDISK_MAX:
            raise SystemExit('ERROR: game disk %s (%d bytes)' % (d['file'], len(b['image'])))
        files[d['file']] = b['image']
    return disks, files


def asset_bytes(asset, assets_dir):
    """core:src/<path> comes from the core submodule, everything else from build/assets."""
    src = asset['source']
    if src.startswith('core:src/'):
        path = os.path.join(CORE_SRC, src[len('core:src/'):])
    else:
        path = os.path.join(assets_dir, asset['name'])
    with open(path, 'rb') as f:
        data = f.read()
    if (len(data) != asset['size'] or '%08X' % zlib.crc32(data) != asset['crc32']
            or hashlib.sha256(data).hexdigest() != asset['sha256']):
        raise SystemExit('ERROR: asset %s does not match package/assets.json' % asset['name'])
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--version', required=True)
    ap.add_argument('--date', required=True)
    ap.add_argument('--build', default=os.path.join(ROOT, 'build', 'quartus'))
    ap.add_argument('--assets', default=os.path.join(ROOT, 'build', 'assets'))
    ap.add_argument('--output', default=os.path.join(ROOT, 'build', 'package'))
    a = ap.parse_args()
    pkg = os.path.join(ROOT, 'package')
    errors = check_definitions(pkg)
    if errors:
        for e in errors:
            print('ERROR: %s' % e)
        return 1
    sd = os.path.join(a.output, 'sd')
    shutil.rmtree(a.output, ignore_errors=True)
    core_dir = os.path.join(sd, 'Cores', CORE_ID)
    asset_dir = os.path.join(sd, 'Assets', PLATFORM, CORE_ID)
    for d in (core_dir, asset_dir, os.path.join(sd, 'Platforms', '_images')):
        os.makedirs(d)
    for name in ('data', 'video', 'audio', 'input', 'interact', 'variants', 'updaters'):
        shutil.copyfile(os.path.join(pkg, 'core', name + '.json'), os.path.join(core_dir, name + '.json'))
    core = json.load(open(os.path.join(pkg, 'core', 'core.json'), encoding='utf-8'))
    core['core']['metadata'].update(version=a.version, date_release=a.date)
    if check_core(core):
        print('ERROR: %s' % check_core(core))
        return 1
    with open(os.path.join(core_dir, 'core.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(core, f, indent=2)
        f.write('\n')
    raw = open(os.path.join(a.build, 'output_files', 'ap_core.rbf'), 'rb').read()
    rev = reverse_bits(raw)
    if reverse_bits(rev) != raw:
        print('ERROR: bit reversal round trip')
        return 1
    open(os.path.join(core_dir, 'bitstream.rbf_r'), 'wb').write(rev)
    open(os.path.join(core_dir, 'icon.bin'), 'wb').write(graphic(*ICON))
    open(os.path.join(sd, 'Platforms', '_images', PLATFORM + '.bin'), 'wb').write(graphic(*BANNER))
    shutil.copyfile(os.path.join(pkg, 'platform', PLATFORM + '.json'), os.path.join(sd, 'Platforms', PLATFORM + '.json'))
    table = json.load(open(os.path.join(pkg, 'assets.json'), encoding='utf-8'))
    for asset in table['assets']:
        open(os.path.join(asset_dir, asset['name']), 'wb').write(asset_bytes(asset, a.assets))
    disks, disk_files = game_disks(PK_DIR, {x['name'] for x in table['assets']})
    for name, data in disk_files.items():
        open(os.path.join(asset_dir, name), 'wb').write(data)
    with open(os.path.join(pkg, 'core', 'info.txt'), encoding='utf-8') as f:
        info = info_with_games(f.read(), disks)
    with open(os.path.join(core_dir, 'info.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(info)
    with open(os.path.join(pkg, 'romdisks.txt'), encoding='utf-8') as f:
        guide = romdisk_guide(f.read(), disks)
    with open(os.path.join(asset_dir, 'romdisks.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(guide)
    shutil.copyfile(os.path.join(ROOT, 'LICENSE'), os.path.join(core_dir, 'LICENSE.txt'))
    shutil.copyfile(os.path.join(CORE_SRC, 'LICENSE.TXT'), os.path.join(core_dir, 'LICENSE-karabas-core.txt'))
    shutil.copyfile(os.path.join(a.assets, 'romdisk-LICENSE.txt'), os.path.join(core_dir, 'LICENSE-romdisk.txt'))
    apf = open(os.path.join(ROOT, 'fpga', 'apf', 'apf_top.v'), encoding='utf-8', errors='replace').read()
    with open(os.path.join(core_dir, 'APF-NOTICE.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(apf[:apf.index('module apf_top')])
    zip_path = os.path.join(a.output, '%s_%s_%s.zip' % (CORE_ID, a.version, a.date))
    outside = None
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for base, _, files in os.walk(sd):
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, sd).replace(os.sep, '/')
                if rel.split('/')[0] not in ('Cores', 'Assets', 'Platforms'):
                    outside = rel
                    break
                z.write(full, rel)
            if outside:
                break
    if outside:
        print('ERROR: %s outside Cores/Assets/Platforms' % outside)
        os.remove(zip_path)
        return 1
    errors = check_library_zip(zip_path)
    if errors:
        for e in errors:
            print('ERROR: %s' % e)
        os.remove(zip_path)
        return 1
    print('PASS package: %s (%s)' % (os.path.relpath(zip_path, ROOT), hashlib.sha256(open(zip_path, 'rb').read()).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
