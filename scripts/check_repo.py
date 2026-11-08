#!/usr/bin/env python3
"""Repository rules on the tracked files (AGENTS.md section 4, "Files" and "Privacy and
portability"; docs/ is private): LF line endings and a final newline in text files, no links into
docs/ from public Markdown, no absolute local paths.

Usage: python -B scripts/check_repo.py      (checks `git ls-files` of this repository; exit 1 on findings)
The LF and final-newline rule skips the APF template (EXEMPT_PREFIXES: kept byte for byte) and
allows, for each file in LEGACY, the one defect it has today. Normalising a LEGACY file is a
separate change the maintainer approves (it touches RTL, the golden frames and the fault patch
rom_disk_required.patch, which must match its CRLF target byte for byte); remove its entry in that
change (scripts/tests/test_check_repo.py fails while a fixed or removed file is still listed).
The privacy and docs/ rules apply to every tracked text file outside docs/.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
BINARY = ('.png', '.jpeg', '.jpg', '.gif', '.bin', '.rbf', '.rbf_r', '.zip', '.ico')
EXEMPT_PREFIXES = ('fpga/apf/', 'fpga/core/')   # the APF template files, byte for byte
LEGACY = {   # path -> its line-ending defect on 2026-11-08 (pocket-v1 65b1ebf)
    'fpga/quartus/ap_core.qsf': 'CR',
    'fpga/rtl/native_font.vh': 'CR',
    'fpga/rtl/pocket_asset_store.v': 'CR',
    'fpga/rtl/pocket_boot_assets.v': 'CR',
    'fpga/rtl/pocket_remap.v': 'CR',
    'fpga/sim/golden/README.md': 'no final newline',
    'fpga/sim/golden/monitor-boot.hex': 'CR',
    'fpga/sim/golden/rom-disk-menu.hex': 'CR',
    'fpga/sim/negative/rom_disk_required.patch': 'CR',
    'fpga/sim/unit/tb_cold_clear.v': 'no final newline',
    'scripts/build.ps1': 'no final newline',
    'scripts/check_build.py': 'no final newline',
}
# a drive-letter path (with either separator), a UNC path (two backslashes, host, share), a Linux,
# macOS or WSL user or mount folder (home, Users, mnt/<drive>); a path with a placeholder such as
# <name> does not match
LOCAL_PATH = re.compile(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]+(?![^\s`\'"]*<)[A-Za-z0-9_.$-]'
                        r'|\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9_.$-]'
                        r'|/(home|Users|mnt/[a-z])/[A-Za-z0-9_.-]+')
# an inline link, a reference definition, or a GitHub URL of this repository into docs/
DOCS_LINK = re.compile(r'\]\((?:\.{1,2}/|/)*docs/'
                       r'|^ {0,3}\[[^\]]+\]:\s*<?(?:\.{1,2}/|/)*docs/'
                       r'|(?i:github\.com/BarabashkaD/radio86-rk-pocket/(?:blob|tree|raw)/[^/\s]+/docs/)', re.M)


def line_defects(data):
    defects = []
    if b'\r' in data:
        defects.append('CR')
    if data and not data.endswith(b'\n'):
        defects.append('no final newline')
    return defects


def check_text(name, data):
    errors = []
    if not name.startswith(EXEMPT_PREFIXES):
        errors += ['%s: %s (LF with a final newline expected)' % (name, d)
                   for d in line_defects(data) if d != LEGACY.get(name)]
    text = data.decode('utf-8', errors='replace')
    if name.endswith('.md') and not name.startswith('docs/') and DOCS_LINK.search(text):
        errors.append('%s: a link into docs/ (private)' % name)
    m = LOCAL_PATH.search(text)
    if m:
        errors.append('%s: an absolute local path %r' % (name, m.group(0)))
    return errors


def tracked():
    out = subprocess.run(['git', '-C', ROOT, 'ls-files', '-z'], capture_output=True, check=True).stdout
    return [n for n in out.decode('utf-8').split('\0') if n]


def main():
    errors, count = [], 0
    for name in tracked():
        path = os.path.join(ROOT, name)
        if name.startswith('docs/') or name.lower().endswith(BINARY) or not os.path.isfile(path):
            continue   # private docs, binaries, the submodule's gitlink
        count += 1
        with open(path, 'rb') as f:
            errors += check_text(name, f.read())
    for e in errors:
        print('ERROR: %s' % e)
    print('%s check_repo: %d tracked text files' % ('FAIL' if errors else 'PASS', count))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
