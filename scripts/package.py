#!/usr/bin/env python3
"""Builds the SD package of the core from a Quartus build (spec 7).

Usage: python -B scripts/package.py --version 0.5.0 --date YYYY-MM-DD [--build build/quartus]
       [--output build/package]
Checks the definitions against the openFPGA limits, bit-reverses the RBF (round trip checked),
checks every shipped asset against package/assets.json, draws the icon and platform image, and
writes Cores/, Assets/ and Platforms/ and the zip BarabashkaD.Radio86RK_<version>_<date>.zip.
"""
import argparse
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
GLYPHS = {
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'K': ['10001', '10010', '10100', '11000', '10100', '10010', '10001'],
    '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
    '6': ['01110', '10000', '10000', '11110', '10001', '10001', '01110'],
}


def reverse_bits(data):
    return bytes(int('{:08b}'.format(b)[::-1], 2) for b in data)


def graphic(width, height, text, scale):
    """The POC image format that worked on the Pocket: 16-bit pixels, intensity in the upper
    byte, stored rotated 90 degrees counter-clockwise."""
    pixels = [[0] * width for _ in range(height)]
    border = 3 if width == 36 else 8
    for y in range(border, height - border):
        for x in range(border, width - border):
            if x in (border, width - border - 1) or y in (border, height - border - 1):
                pixels[y][x] = 255
    left = (width - ((len(text) * 6 - 1) * scale)) // 2
    top = (height - 7 * scale) // 2
    for index, letter in enumerate(text):
        for gy, row in enumerate(GLYPHS[letter]):
            for gx, value in enumerate(row):
                if value == '1':
                    for dy in range(scale):
                        for dx in range(scale):
                            pixels[top + gy * scale + dy][left + (index * 6 + gx) * scale + dx] = 255
    encoded = bytes(c for y in range(width) for x in range(height) for c in (pixels[x][width - 1 - y], 0))
    for y in range(height):                       # the POC's self-check of the rotation and byte layout
        for x in range(width):
            index = ((width - 1 - x) * height + y) * 2
            if encoded[index] != pixels[y][x] or encoded[index + 1] != 0:
                raise ValueError('graphic rotation/byte layout')
    return encoded


MAX_LIST_OPTIONS = 20  # far below the measured failure at 97 (README, "Measured Pocket limit")


def check_core(core):
    m, errors = core['core']['metadata'], []
    for key, limit in (('shortname', 31), ('description', 63), ('author', 31), ('url', 63), ('version', 31)):
        if len(m[key]) > limit:
            errors.append('core.json %s longer than %d' % (key, limit))
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', m['date_release']):
        errors.append('core.json date_release is not YYYY-MM-DD')
    if len(m['platform_ids']) > 4 or any(not re.fullmatch(r'[a-z0-9_]{1,15}', p) or p.startswith('_') for p in m['platform_ids']):
        errors.append('core.json platform_ids')
    if m['author'] + '.' + m['shortname'] != CORE_ID:
        errors.append('core.json author.shortname is not %s' % CORE_ID)
    return errors


def check_interact(variables):
    """The measured Pocket limit (README): Pocket OS 2.7 fails on 97 list options in total, loads 66."""
    errors = []
    if len(variables) > 16:
        errors.append('interact.json: more than 16 items')
    if sum(len(v['options']) for v in variables if v['type'] == 'list') > MAX_LIST_OPTIONS:
        errors.append('interact.json: more than %d list options in total' % MAX_LIST_OPTIONS)
    ids = [v['id'] for v in variables]
    if len(set(ids)) != len(ids) or any(i in (0, 1, 2) for i in ids):
        errors.append('interact.json: ids must be unique and not 0-2 (the data slots)')
    return errors

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
    return errors


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
    for name in ('data', 'video', 'audio', 'input', 'interact', 'variants'):
        shutil.copyfile(os.path.join(pkg, 'core', name + '.json'), os.path.join(core_dir, name + '.json'))
    core = json.load(open(os.path.join(pkg, 'core', 'core.json'), encoding='utf-8'))
    core['core']['metadata'].update(version=a.version, date_release=a.date)
    if check_core(core):
        print('ERROR: %s' % check_core(core))
        return 1
    with open(os.path.join(core_dir, 'core.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(core, f, indent=2)
        f.write('\n')
    shutil.copyfile(os.path.join(pkg, 'core', 'info.txt'), os.path.join(core_dir, 'info.txt'))
    raw = open(os.path.join(a.build, 'output_files', 'ap_core.rbf'), 'rb').read()
    rev = reverse_bits(raw)
    if reverse_bits(rev) != raw:
        print('ERROR: bit reversal round trip')
        return 1
    open(os.path.join(core_dir, 'bitstream.rbf_r'), 'wb').write(rev)
    open(os.path.join(core_dir, 'icon.bin'), 'wb').write(graphic(36, 36, 'RK', 2))
    open(os.path.join(sd, 'Platforms', '_images', PLATFORM + '.bin'), 'wb').write(graphic(521, 165, 'RK86', 12))
    shutil.copyfile(os.path.join(pkg, 'platform', PLATFORM + '.json'), os.path.join(sd, 'Platforms', PLATFORM + '.json'))
    table = json.load(open(os.path.join(pkg, 'assets.json'), encoding='utf-8'))
    for asset in table['assets']:
        open(os.path.join(asset_dir, asset['name']), 'wb').write(asset_bytes(asset, a.assets))
    shutil.copyfile(os.path.join(ROOT, 'LICENSE'), os.path.join(core_dir, 'LICENSE.txt'))
    shutil.copyfile(os.path.join(CORE_SRC, 'LICENSE.TXT'), os.path.join(core_dir, 'LICENSE-karabas-core.txt'))
    shutil.copyfile(os.path.join(a.assets, 'romdisk-LICENSE.txt'), os.path.join(core_dir, 'LICENSE-romdisk.txt'))
    apf = open(os.path.join(ROOT, 'fpga', 'apf', 'apf_top.v'), encoding='utf-8', errors='replace').read()
    with open(os.path.join(core_dir, 'APF-NOTICE.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(apf[:apf.index('module apf_top')])
    zip_path = os.path.join(a.output, '%s_%s_%s.zip' % (CORE_ID, a.version, a.date))
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for base, _, files in os.walk(sd):
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, sd).replace(os.sep, '/')
                if rel.split('/')[0] not in ('Cores', 'Assets', 'Platforms'):
                    print('ERROR: %s outside Cores/Assets/Platforms' % rel)
                    return 1
                z.write(full, rel)
    print('PASS package: %s (%s)' % (os.path.relpath(zip_path, ROOT), hashlib.sha256(open(zip_path, 'rb').read()).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
