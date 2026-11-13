# SPDX-License-Identifier: BSD-3-Clause
"""The FAT16 card image: mtools builds it, Python reads it back.

Usage: python -B scripts/fatcard/fatcard.py [--out build/fatcard] [--sim] [--pk DIR] [--romdisk FILE]
  writes fatcard.bin (8388608 bytes: the 48 pk tapes and Kiselev's BASIC, EDASM, EDDIS, OTHELLO with
  the boot stage, menu and loader; a .bin, as the Pocket's ROM disk slot lists only .bin files) and
  fatcard.json (keywait: the menu's key wait; files: directory()); --sim also card-sim.img (the first 131072 bytes of a card with PITON.GAM only) and card-sim.json
  (keywait, file, size, start, length, offset of the payload in the image) for the system scenario.
  Relative paths are taken from the repository root. Needs mtools and build/assets/romdisk.bin.

Layout (8388608 bytes): mformat -C -T 16384 -h 1 -s 32 -R 128 -d 1 -r 32 -c 1 -L 64 -N 00000000:
512-byte sectors, 1 sector per cluster, 128 reserved sectors (bank 0 of the card), 1 FAT of 64
sectors, 512 root entries, FAT16. Bank 0: sector 0 the boot stage (03-05 and 3E-1FD written by
install_bank0, 00-02, the BPB and 55 AA as mformat writes them; mlabel writes the label at 2B-35),
sectors 1-4 the menu, sector 5 the loader, sectors 6-127 unused. The 8080 code reads the layout
from the BPB.

8080 parts (BSD-3-Clause): boot.asm (assemble_boot: the 0x1FB bytes for 03-1FD; at 003E after
R0,1FF,0 and G0 it checks the BPB, copies sectors 1-4 to 6C00-73FF and jumps there), menu.asm
(assemble_menu: ORG 6C00, code and variables by 7200, directory buffer 7200-73FF; the files of
menu_entries() 20 per page; on the run key it copies the loader from sector 5 to 7400 and fills the
five words at 7403 that loader_params gives: FATSTART, DATASTART, CLUSTER, SIZE, MAXCL) and loader.asm
(assemble_loader: ORG 7400, code and variables by 75C0).

mtools: mformat, mcopy, mdel, mlabel from MTOOLS_DIR when it is set (a missing tool there is an
error), else from PATH. Every call runs in the image's directory with relative names (mtools fails
on paths with non-ASCII characters and reads a drive-letter mcopy target as a DOS drive), stdin closed
(mcopy waits for an answer on a name clash) and a timeout.

Reproducible on one machine only: the file times come from FIXED_MTIME (mcopy -m) and the label
time from SOURCE_DATE_EPOCH, but FAT times are local time, so the bytes follow the time zone. No
test or document records a hash of an image.

Listing rules (directory, read_file, the 8080 menu): the root directory up to the first entry whose
name starts with 00; E5 (deleted), attribute 0F (long name) and attribute bits 1E (hidden, system,
volume label, directory) are skipped. The tape header rule is the 8080 loader's: optional E6, start
(hi, lo), end (hi, lo), end >= start, file size >= header + end - start + 1; no checksum.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'romdisk'))
import asm8080  # noqa: E402
import build_romdisks  # noqa: E402
import tape  # noqa: E402

IMAGE_SIZE = 8388608
MFORMAT_ARGS = ['-C', '-T', '16384', '-h', '1', '-s', '32', '-R', '128', '-d', '1', '-r', '32', '-c', '1',
                '-L', '64', '-N', '00000000']
LAYOUT = {'bytes_per_sector': 512, 'sectors_per_cluster': 1, 'reserved': 128, 'fats': 1, 'root_entries': 512,
          'total_sectors': 16384, 'sectors_per_fat': 64}
FIXED_MTIME = 946728000          # 2000-01-01 12:00 UTC: a date FAT can hold, far from 1980 and 2107
MENU_SECTOR, MENU_MAX = 1, 2048  # sectors 1-4
LOADER_SECTOR, LOADER_MAX = 5, 512
BOOT_SIZE = 0x1FB                # bytes 03-1FD of sector 0; only 03-05 and 3E-1FD are written
BOOT_JUMP = b'\xc3\x3e\x00'      # JMP 003E
LOADER_RAM = (0x7400, 0x75FF)
LOADER_END = 0x75C0              # the loader's code and variables end here; 75C0-75FF is its stack
RAM_TOP = 0x73FF                 # the loader's rule (END <= 73FFh): 7400-75FF loader, 7600-7FFF monitor
MENU_ORG = 0x6C00
MENU_END = 0x7200                # the menu's code and variables end here; 7200-73FF its directory buffer
DIRBUF = 0x7200
MENU_FILES = 520                 # the menu lists at most 26 pages of 20
MONITOR_ENTRIES = (0xF803, 0xF818, 0xFA68, 0xF86C)
PARAMS = ('FATSTART', 'DATASTART', 'CLUSTER', 'SIZE', 'MAXCL')
BOOT_SOURCE = os.path.join(HERE, 'boot.asm')
LOADER_SOURCE = os.path.join(HERE, 'loader.asm')
MENU_SOURCE = os.path.join(HERE, 'menu.asm')
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
CARD_IMAGE = 'fatcard.bin'       # the full image: the Pocket's ROM disk slot lists only .bin files
CARD_JSON = 'fatcard.json'       # its listing (keywait, files)
SIM_SIZE = 131072                # the system TB's card: banks 0 and 1
SIM_FILE = 'PITON.GAM'
NAME = re.compile(r'[A-Z0-9_-]{1,8}(\.[A-Z0-9_-]{1,3})?')
LABEL = re.compile(r'[A-Z0-9_-]{1,11}')
INSTALL_HINT = ('set MTOOLS_DIR to the directory of mformat (msys64: pacman -S mingw-w64-ucrt-x86_64-mtools; '
                'Linux: apt install mtools) or put it on PATH')
KISELEV_LEFT_OUT = ('DPDDT.RKR',)   # DP/DDT is left out of the card for now (it reaches 7600-76FF)


def mtools(tool):
    """Full path of an mtools program: MTOOLS_DIR when set (no fallback), else PATH."""
    where = os.environ.get('MTOOLS_DIR')
    if where:
        found = shutil.which(tool, path=where)
        if not found:
            raise RuntimeError('%s not found in MTOOLS_DIR (%s): %s' % (tool, where, INSTALL_HINT))
        return found
    found = shutil.which(tool)
    if not found:
        raise RuntimeError('%s not found (MTOOLS_DIR unset, not on PATH): %s' % (tool, INSTALL_HINT))
    return found


def run_mtools(tool, image, *args, timeout=60):
    """Runs `tool -i <image basename> args` in the image's directory; returns stdout."""
    image = os.path.abspath(image)
    cmd = [mtools(tool), '-i', os.path.basename(image)] + list(args)
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(FIXED_MTIME))
    try:
        r = subprocess.run(cmd, cwd=os.path.dirname(image), env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError('%s %s: no answer in %d s (a name clash makes mcopy wait for input)'
                           % (tool, ' '.join(args), timeout))
    out = r.stdout.decode('utf-8', errors='replace')
    if r.returncode != 0:
        raise RuntimeError('%s %s failed (exit %d): %s' % (tool, ' '.join(args), r.returncode,
                                                         r.stderr.decode('utf-8', errors='replace').strip()))
    return out


def bpb(image):
    """The BPB fields and the derived layout; sector numbers (fat_start, root_start, data_start)."""
    if len(image) < 512:
        raise ValueError('image shorter than one sector')
    bps, spc, reserved, fats, root_entries, total16, spf = struct.unpack_from('<HBHBHHxH', image, 0x0B)
    total = total16 or struct.unpack_from('<I', image, 0x20)[0]
    if bps != 512:
        raise ValueError('%d bytes per sector (512 expected)' % bps)
    if spc == 0 or fats == 0 or spf == 0:
        raise ValueError('BPB: sectors per cluster %d, FATs %d, sectors per FAT %d' % (spc, fats, spf))
    root_sectors = (root_entries * 32 + bps - 1) // bps
    fat_start = reserved
    root_start = fat_start + fats * spf
    data_start = root_start + root_sectors
    clusters = (total - data_start) // spc if total > data_start else 0
    if not 4085 <= clusters <= 65524:
        raise ValueError('%d clusters: not FAT16' % clusters)
    if spf * bps // 2 < clusters + 2:
        raise ValueError('a FAT of %d sectors cannot hold %d clusters' % (spf, clusters))
    return {'bytes_per_sector': bps, 'sectors_per_cluster': spc, 'reserved': reserved, 'fats': fats,
            'root_entries': root_entries, 'sectors_per_fat': spf, 'total_sectors': total,
            'root_sectors': root_sectors, 'fat_start': fat_start, 'root_start': root_start,
            'data_start': data_start, 'clusters': clusters}


def layout_problems(image):
    """What differs from the card layout (size, 00-02, 55 AA, BPB); [] when it matches."""
    problems = []
    if len(image) != IMAGE_SIZE:
        problems.append('size %d (%d expected)' % (len(image), IMAGE_SIZE))
    if image[0:3] != b'\xeb\x3c\x90':
        problems.append('bytes 00-02 %s (EB 3C 90 expected)' % image[0:3].hex(' ').upper())
    if image[0x1FE:0x200] != b'\x55\xaa':
        problems.append('no 55 AA at 1FE')
    try:
        p = bpb(image)
    except ValueError as e:
        return problems + [str(e)]
    problems += ['%s %d (%d expected)' % (k, p[k], v) for k, v in LAYOUT.items() if p[k] != v]
    return problems


def _read(path):
    with open(path, 'rb') as f:
        return f.read()


def format_image(path):
    """A new empty card image at path (an existing file is deleted first)."""
    if os.path.exists(path):
        os.remove(path)
    run_mtools('mformat', path, *MFORMAT_ARGS, '::')
    problems = layout_problems(_read(path))
    if problems:
        raise RuntimeError('mformat wrote another layout (check mformat --version): ' + '; '.join(problems))


def label_image(path, label):
    label = label.upper()
    if not LABEL.fullmatch(label):
        raise ValueError('volume label %r: 1-11 of A-Z 0-9 _ -' % label)
    run_mtools('mlabel', path, '::' + label)


def _padded(name):
    base, _, ext = name.partition('.')
    return (base.ljust(8) + ext.ljust(3)).encode('ascii')


def _listed(image):
    """(slot, entry bytes) of the listed root entries (module docstring, listing rules)."""
    p = bpb(image)
    base = p['root_start'] * p['bytes_per_sector']
    if len(image) < base + 32 * p['root_entries']:
        raise ValueError('image ends inside the root directory')
    result = []
    for slot in range(p['root_entries']):
        e = image[base + 32 * slot:base + 32 * (slot + 1)]
        if e[0] == 0:
            break
        if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x1E:
            continue
        result.append((slot, e))
    return result


def add_files(path, files):
    """Copies (name, data) pairs into the image in list order, names upper-cased. ValueError (before any
    mtools call) on a name that is not 8.3 of A-Z 0-9 _ -, a duplicate, or a name already listed."""
    names = []
    present = {e[:11] for _, e in _listed(_read(path))}
    for name, _ in files:
        n = name.upper()
        if not NAME.fullmatch(n):
            raise ValueError('%r is not an 8.3 name of A-Z 0-9 _ -' % name)
        if n in names or _padded(n) in present:
            raise ValueError('%s is already in the image or the list' % n)
        names.append(n)
    if not names:
        return
    folder = os.path.dirname(os.path.abspath(path))
    with tempfile.TemporaryDirectory(dir=folder) as tmp:
        sub = os.path.basename(tmp)
        for n, (_, data) in zip(names, files):
            src = os.path.join(tmp, n)
            with open(src, 'wb') as f:
                f.write(data)
            os.utime(src, (FIXED_MTIME, FIXED_MTIME))
        # one call, sources in list order (mcopy writes the entries in argument order; every call
        # costs about 0.4 s on an 8 MB image)
        run_mtools('mcopy', path, '-D', 'o', '-m', *[os.path.join(sub, n) for n in names], '::',
                   timeout=60 + len(names))


def install_bank0(path, boot, menu, loader):
    """Writes the boot stage (03-05 from boot[0:3], 3E-1FD from boot[3B:]), the menu (1-2048 bytes,
    sectors 1-4) and the loader (1-512 bytes, sector 5), each zero-padded; sector 6 untouched."""
    if len(boot) != BOOT_SIZE or bytes(boot[0:3]) != BOOT_JUMP:
        raise ValueError('boot: %d bytes for 03-1FD starting C3 3E 00 expected' % BOOT_SIZE)
    if not 1 <= len(menu) <= MENU_MAX:
        raise ValueError('menu: %d bytes (1-%d)' % (len(menu), MENU_MAX))
    if not 1 <= len(loader) <= LOADER_MAX:
        raise ValueError('loader: %d bytes (1-%d)' % (len(loader), LOADER_MAX))
    problems = layout_problems(_read(path))
    if problems:
        raise ValueError('%s is not a card image: %s' % (path, '; '.join(problems)))
    with open(path, 'r+b') as f:
        f.seek(3)
        f.write(bytes(boot[0:3]))
        f.seek(0x3E)
        f.write(bytes(boot[0x3B:]))
        f.seek(MENU_SECTOR * 512)
        f.write(bytes(menu) + bytes(MENU_MAX - len(menu)))
        f.seek(LOADER_SECTOR * 512)
        f.write(bytes(loader) + bytes(LOADER_MAX - len(loader)))


def loader_window(start, end):
    """'A' (the loader at 7400-75FF) when [start, end] lies in 0000-73FF (RAM_TOP, the loader's own
    END rule); else ValueError."""
    if end < start or start < 0 or end > RAM_TOP:
        raise ValueError('range %04X-%04X outside 0000-%04X' % (start, end, RAM_TOP))
    if start <= LOADER_RAM[1] and end >= LOADER_RAM[0]:
        raise ValueError('range %04X-%04X overlaps the loader %04X-%04X' % (start, end, *LOADER_RAM))
    return 'A'


def _assemble(path):
    with open(path, encoding='ascii') as f:
        text = f.read()
    try:
        return asm8080.assemble(text)
    except asm8080.AsmError as e:
        raise ValueError('%s: %s' % (os.path.basename(path), e))


def boot_symbols():
    return _assemble(BOOT_SOURCE)[2]


def loader_symbols():
    return _assemble(LOADER_SOURCE)[2]


def assemble_boot():
    """boot.asm: the 0x1FB bytes for 03-1FD of sector 0 (install_bank0 writes 03-05 and 3E-1FD)."""
    org, code, sym = _assemble(BOOT_SOURCE)
    if org != 3 or len(code) != BOOT_SIZE or code[0:3] != BOOT_JUMP or sym.get('START') != 0x3E:
        raise ValueError('boot stage: origin %04X, %d bytes (03-1FD expected, JMP 003E first)' % (org, len(code)))
    return code


def assemble_loader():
    """loader.asm at 7400: code, parameter block and variables, ending by LOADER_END (75C0)."""
    org, code, sym = _assemble(LOADER_SOURCE)
    if org != LOADER_RAM[0] or sym['CODEND'] > LOADER_END or len(code) != sym['CODEND'] - org:
        raise ValueError('loader: origin %04X, ends at %04X (code and variables by %04X)'
                         % (org, sym['CODEND'], LOADER_END))
    return code


def assemble_menu():
    """menu.asm at 6C00: (code, symbols). Code and variables end at MENUEND <= MENU_END (7200), the
    directory buffer DIRBUF is 7200, no other symbol points into MENUEND-73FF, KEYWAIT is the menu's only
    CALL 0F803H, the loader's parameter block and the menu's copy of it (MFAT .. MMAX) agree with
    loader.asm, and the only monitor addresses are F803, F818, FA68 (F86C allowed). ValueError otherwise."""
    org, code, sym = _assemble(MENU_SOURCE)
    end = sym.get('MENUEND', 0)
    if org != MENU_ORG or not org < end <= MENU_END or len(code) != end - org:
        raise ValueError('menu: origin %04X, ends at %04X (code and variables by %04X)' % (org, end, MENU_END))
    stray = sorted(k for k, v in sym.items() if end < v < LOADER_RAM[0] and k != 'DIRBUF')
    if sym.get('DIRBUF') != DIRBUF or stray:
        raise ValueError('menu: DIRBUF %04X, symbols into %04X-73FF: %s' % (sym.get('DIRBUF', 0), end, stray))
    kw = sym.get('KEYWAIT', 0)
    if not org <= kw < end or code[kw - org:kw - org + 3] != b'\xcd\x03\xf8' or code.count(b'\xcd\x03\xf8') != 1:
        raise ValueError('menu: KEYWAIT %04X is not its only CALL 0F803H' % kw)
    lsym = loader_symbols()
    if [sym.get(k) for k in PARAMS] != [lsym[k] for k in PARAMS] or sym.get('LOADER') != LOADER_RAM[0]:
        raise ValueError('menu: the loader parameter block differs from loader.asm')
    mine = [sym.get(k) for k in ('MFAT', 'MDATA', 'MCLUS', 'MSIZE', 'MMAX')]
    if None in mine or mine != list(range(mine[0], mine[0] + 10, 2)):
        raise ValueError('menu: MFAT .. MMAX are not the parameter block in its order')
    other = sorted('%s %04X' % (k, v) for k, v in sym.items() if v >= 0xF800 and v not in MONITOR_ENTRIES)
    if other:
        raise ValueError('menu: monitor addresses other than F803, F818, FA68: %s' % other)
    return code, sym


def loader_params(p, entry):
    """The loader's parameter block at 7403 for a directory() entry and bpb(): FATSTART, DATASTART,
    CLUSTER, SIZE, MAXCL (the last valid cluster). ValueError for a file of 64 KB or more."""
    if entry['size'] > 0xFFFF:
        raise ValueError('%s: %d bytes (at most 65535)' % (entry.get('file', '?'), entry['size']))
    return (p['fat_start'], p['data_start'], entry['cluster'], entry['size'], p['clusters'] + 1)


def _header(image, p, cluster, size):
    """(start, end) by the 8080 header rule, or (None, None)."""
    if not 2 <= cluster <= p['clusters'] + 1:
        return None, None
    at = (p['data_start'] + (cluster - 2) * p['sectors_per_cluster']) * p['bytes_per_sector']
    head = image[at:at + min(size, 5)]
    pos = 1 if head[:1] == b'\xe6' else 0
    if len(head) < pos + 4:
        return None, None
    start, end = struct.unpack_from('>HH', head, pos)
    if end < start or size < pos + 4 + end - start + 1:
        return None, None
    return start, end


def directory(image):
    """The listed root entries as dicts (name, ext, file, slot, attr, cluster, size, start, end, window);
    never raises for file content: start, end, window are None when the header rule or the window fails."""
    p = bpb(image)
    result = []
    for slot, e in _listed(image):
        name = e[0:8].decode('latin-1').rstrip()
        ext = e[8:11].decode('latin-1').rstrip()
        cluster, size = struct.unpack_from('<HI', e, 0x1A)
        start, end = _header(image, p, cluster, size)
        try:
            window = loader_window(start, end) if start is not None else None
        except ValueError:
            window = None
        result.append({'name': name, 'ext': ext, 'file': name + ('.' + ext if ext else ''), 'slot': slot,
                       'attr': e[11], 'cluster': cluster, 'size': size, 'start': start, 'end': end,
                       'window': window})
    return result


def _shown(raw):
    return ''.join(chr(b) if 0x20 <= b <= 0x5F else '?' for b in raw)


def menu_entries(image):
    """The menu's lines in directory order, at most MENU_FILES: dicts with file, slot, shown (the 12
    characters NAME EXT as the menu prints them: a byte outside 20h-5Fh as '?'), cluster, size, start,
    end (from directory()) and runnable: directory() gives start and end, the window is 'A' (end <=
    73FF), the size is below 64 KB and the first cluster at least 2. The menu shows SSSS-EEEE for a
    runnable entry and '?' for any other, and its run key does nothing on a '?' line."""
    out = []
    for (slot, e), d in zip(_listed(image), directory(image)):
        runnable = (d['start'] is not None and d['window'] == 'A' and d['size'] <= 0xFFFF and d['cluster'] >= 2)
        out.append({'file': d['file'], 'slot': slot, 'shown': _shown(e[0:8]) + ' ' + _shown(e[8:11]),
                    'cluster': d['cluster'], 'size': d['size'], 'start': d['start'], 'end': d['end'],
                    'runnable': runnable})
    return out[:MENU_FILES]


def _entry(image, name):
    key = _padded(name.upper())
    for _, e in _listed(image):
        if e[:11] == key:
            return e
    raise ValueError('%s not in the image' % name)


def cluster_chain(image, name):
    """The FAT chain of a listed file; ValueError on a corrupt chain or one not matching the size."""
    p = bpb(image)
    cluster, size = struct.unpack_from('<HI', _entry(image, name), 0x1A)
    need = -(-size // (p['bytes_per_sector'] * p['sectors_per_cluster']))
    if size == 0:
        if cluster != 0:
            raise ValueError('%s: empty file with cluster %d' % (name, cluster))
        return []
    fat = p['fat_start'] * p['bytes_per_sector']
    chain, cur = [], cluster
    while True:
        if not 2 <= cur <= p['clusters'] + 1:
            raise ValueError('%s: cluster %04X outside 2-%04X' % (name, cur, p['clusters'] + 1))
        if cur in chain:
            raise ValueError('%s: the chain loops at %d' % (name, cur))
        chain.append(cur)
        if len(chain) > need:
            raise ValueError('%s: the chain is longer than %d clusters' % (name, need))
        nxt = struct.unpack_from('<H', image, fat + 2 * cur)[0]
        if nxt >= 0xFFF8:
            break
        if nxt in (0, 1) or 0xFFF0 <= nxt <= 0xFFF7:
            raise ValueError('%s: FAT entry %d is %04X' % (name, cur, nxt))
        cur = nxt
    if len(chain) != need:
        raise ValueError('%s: the chain has %d clusters, %d expected' % (name, len(chain), need))
    return chain


def read_file(image, name):
    """A file's bytes through its FAT chain (ValueError: not found, corrupt chain, image too short)."""
    p = bpb(image)
    size = struct.unpack_from('<I', _entry(image, name), 0x1C)[0]
    unit = p['bytes_per_sector'] * p['sectors_per_cluster']
    data = bytearray()
    for c in cluster_chain(image, name):
        at = (p['data_start'] + (c - 2) * p['sectors_per_cluster']) * p['bytes_per_sector']
        if at + unit > len(image):
            raise ValueError('%s: cluster %d beyond the end of the image' % (name, c))
        data += image[at:at + unit]
    return bytes(data[:size])


def card_files(pk_dir, romdisk):
    """The card's files in order: the pk tapes (build_romdisks.pk_files order, bytes as they are), then
    Kiselev's programs from his ROM disk image except DP/DDT. ValueError naming the file when one does
    not parse as a tape, misses the loader window, or has a name that is not 8.3 or not unique."""
    files = []
    for n in build_romdisks.pk_files(pk_dir):
        with open(os.path.join(pk_dir, n), 'rb') as f:
            files.append((n.upper(), f.read()))
    files += [(n, d) for n, d in tape.kiselev_files(romdisk) if n not in KISELEV_LEFT_OUT]
    seen = set()
    for n, d in files:
        if not NAME.fullmatch(n):
            raise ValueError('%s: not an 8.3 name of A-Z 0-9 _ -' % n)
        if n in seen:
            raise ValueError('%s: the name is used twice' % n)
        seen.add(n)
        try:
            start, end, _ = build_romdisks.read_tape(d)
            loader_window(start, end)
        except ValueError as e:
            raise ValueError('%s: %s' % (n, e))
    return files


def build_image(path, files, boot, menu, loader, label='RK86CARD'):
    """format_image, label_image, add_files, install_bank0 (last), then the layout check; returns
    directory() of the result."""
    format_image(path)
    label_image(path, label)
    add_files(path, files)
    install_bank0(path, boot, menu, loader)
    image = _read(path)
    problems = layout_problems(image)
    if image[3:6] != BOOT_JUMP:
        problems.append('bytes 03-05 %s' % image[3:6].hex(' ').upper())
    if problems:
        raise RuntimeError('%s: %s' % (path, '; '.join(problems)))
    return directory(image)


def _write_json(path, meta):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(meta, indent=2) + '\n')


def build_card(out, pk_dir, romdisk):
    """CARD_IMAGE (the card files with the real boot stage, menu and loader) and CARD_JSON (keywait,
    files: directory()) in out; returns the CARD_JSON dict."""
    menu, sym = assemble_menu()
    os.makedirs(out, exist_ok=True)
    files = build_image(os.path.join(out, CARD_IMAGE), card_files(pk_dir, romdisk), assemble_boot(), menu,
                        assemble_loader())
    meta = {'keywait': sym['KEYWAIT'], 'files': files}
    _write_json(os.path.join(out, CARD_JSON), meta)
    return meta


def build_sim(out, pk_dir):
    """card-sim.img: the first SIM_SIZE bytes (banks 0 and 1) of a card with SIM_FILE only, and
    card-sim.json (keywait, file, size, start, length, offset: where the payload lies in the image)
    for the system scenario. RuntimeError when the payload is not one contiguous run below SIM_SIZE."""
    menu, sym = assemble_menu()
    with open(os.path.join(pk_dir, SIM_FILE), 'rb') as f:
        data = f.read()
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        full = os.path.join(tmp, 'card.img')
        build_image(full, [(SIM_FILE, data)], assemble_boot(), menu, assemble_loader())
        image = _read(full)
    p = bpb(image)
    entry = menu_entries(image)[0]
    if entry['file'] != SIM_FILE or not entry['runnable']:
        raise RuntimeError('card-sim.img: %s is not the first, runnable entry' % SIM_FILE)
    chain = cluster_chain(image, SIM_FILE)
    start, end, payload = build_romdisks.read_tape(data)
    offset = (p['data_start'] + (entry['cluster'] - 2) * p['sectors_per_cluster']) * p['bytes_per_sector']
    offset += 5 if data[0] == 0xE6 else 4
    problems = []
    if chain != list(range(chain[0], chain[0] + len(chain))):
        problems.append('the chain %s is not contiguous' % chain)
    if offset + len(payload) > SIM_SIZE or image[offset:offset + len(payload)] != payload:
        problems.append('the payload is not at %d-%d' % (offset, offset + len(payload) - 1))
    if p['data_start'] * p['bytes_per_sector'] > SIM_SIZE or any(image[SIM_SIZE:]):
        problems.append('the card uses bytes beyond %d' % SIM_SIZE)
    if problems:
        raise RuntimeError('card-sim.img: ' + '; '.join(problems))
    with open(os.path.join(out, 'card-sim.img'), 'wb') as f:
        f.write(image[:SIM_SIZE])
    meta = {'keywait': sym['KEYWAIT'], 'file': SIM_FILE, 'size': SIM_SIZE, 'start': start,
            'length': end - start + 1, 'offset': offset}
    _write_json(os.path.join(out, 'card-sim.json'), meta)
    return meta


def repo_path(path):
    """A relative path is taken from the repository root, not from the current directory."""
    return os.path.normpath(os.path.join(ROOT, path))


def main(argv=None):
    ap = argparse.ArgumentParser(description='Builds the FAT16 card image (%s, %s) and, with --sim, the '
                                             'system scenario card (card-sim.img, card-sim.json).'
                                             % (CARD_IMAGE, CARD_JSON))
    ap.add_argument('--out', default=os.path.join('build', 'fatcard'),
                    help='output directory, relative to the repository (default build/fatcard)')
    ap.add_argument('--pk', default=os.path.join('cores', 'karabas-go-core-rk86', 'pk'),
                    help='the game tapes (default: the submodule\'s pk)')
    ap.add_argument('--romdisk', default=os.path.join('build', 'assets', 'romdisk.bin'),
                    help='Kiselev\'s ROM disk image (default build/assets/romdisk.bin)')
    ap.add_argument('--sim', action='store_true', help='also card-sim.img and card-sim.json')
    args = ap.parse_args(argv)
    out, pk, romdisk = repo_path(args.out), repo_path(args.pk), repo_path(args.romdisk)
    if not os.path.isfile(romdisk):
        print('error: %s missing: run python -B scripts/fetch_assets.py' % os.path.basename(romdisk),
              file=sys.stderr)
        return 1
    with open(romdisk, 'rb') as f:
        rom = f.read()
    try:
        meta = build_card(out, pk, rom)
        sim = build_sim(out, pk) if args.sim else None
    except (ValueError, RuntimeError, OSError) as e:
        print('error: %s' % e, file=sys.stderr)
        return 1
    try:                    # only repository-relative paths in the output
        where = os.path.relpath(out, ROOT)
    except ValueError:      # another drive
        where = os.path.basename(out)
    if where.startswith('..'):
        where = os.path.basename(out)
    runnable = sum(1 for e in menu_entries(_read(os.path.join(out, CARD_IMAGE))) if e['runnable'])
    print('%s: %s (%d bytes), %s: %d files (%d runnable), keywait %04X'
          % (where, CARD_IMAGE, IMAGE_SIZE, CARD_JSON, len(meta['files']), runnable, meta['keywait']))
    if sim:
        print('%s: card-sim.img (%d bytes), card-sim.json: %s %04X-%04X, payload at image offset %d'
              % (where, sim['size'], sim['file'], sim['start'], sim['start'] + sim['length'] - 1, sim['offset']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
