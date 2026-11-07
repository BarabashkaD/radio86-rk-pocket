#!/usr/bin/env python3
"""Downloads the pinned ROM disk and its licence into build/assets and checks them (spec 7).

Usage: python -B scripts/fetch_assets.py [--record-licence]
Every asset with an https source is fetched once (kept when its SHA256 already matches) and
checked by size, CRC32 and SHA256 from package/assets.json. --record-licence writes the SHA256
of a licence whose value is still empty into assets.json (once, when it is first fetched).
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.request
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
OUT = os.path.join(ROOT, 'build', 'assets')
TABLE = os.path.join(ROOT, 'package', 'assets.json')


def fetch(url, path):
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    with open(path, 'wb') as f:
        f.write(data)
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--record-licence', action='store_true')
    a = ap.parse_args()
    with open(TABLE, encoding='utf-8') as f:
        table = json.load(f)
    os.makedirs(OUT, exist_ok=True)
    for asset in table['assets']:
        if not asset['source'].startswith('https://'):
            continue
        path = os.path.join(OUT, asset['name'])
        data = open(path, 'rb').read() if os.path.exists(path) else b''
        if hashlib.sha256(data).hexdigest() != asset['sha256']:
            data = fetch(asset['source'], path)
        if (len(data) != asset['size'] or '%08X' % zlib.crc32(data) != asset['crc32']
                or hashlib.sha256(data).hexdigest() != asset['sha256']):
            print('ERROR: %s does not match package/assets.json' % asset['name'])
            return 1
        print('PASS %s: %d bytes, CRC32 %s' % (asset['name'], len(data), asset['crc32']))
    changed = False
    for lic in table['licences']:
        path = os.path.join(OUT, lic['name'])
        data = fetch(lic['source'], path)
        digest = hashlib.sha256(data).hexdigest()
        if not lic['sha256'] and a.record_licence:
            lic['sha256'] = digest
            changed = True
        if lic['sha256'] != digest:
            print('ERROR: %s SHA256 %s, expected %s' % (lic['name'], digest, lic['sha256'] or '(not recorded)'))
            return 1
        print('PASS %s: SHA256 %s' % (lic['name'], digest))
    if changed:
        with open(TABLE, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(table, f, indent=2)
            f.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
