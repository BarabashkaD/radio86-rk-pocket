"""Builds the 48 Karabas game tape images into 5 ROM disks of 65536 bytes (the 64 KB wiring).

Usage: python -B scripts/romdisk/build_romdisks.py [--pk DIR] [--out DIR]
  --pk   directory with the .GAM/.RKR tape images (default cores/karabas-go-core-rk86/pk)
  --out  output directory (default build/romdisks)

Writes romdisk-<n>.bin (n = 1..5), romdisks.json (with each game's title from the pk
directory's DESCRIPT.ION, or '') and romdisks.txt.

Rules: DISKS is a fixed table (menu order = the file name order). Every
.GAM/.RKR/.RK file of the pk directory except bios.rk is in exactly one disk and
every table name exists. The menu name is the file stem, or the whole file name
when two files of one disk share a stem. The title is "ROM-DISK/64K GAMES <n>/5".
The payloads start at offset 0200H in menu order, behind the games loader
(loader.games_loader); the rest is FF. The RAM address is the tape start address.
A payload ending beyond FFFFH, or a RAM range overlapping 7400H-75FFH (the loader)
or passing FFFFH, is an error. A disk is more than 32 KB: the core reads it with the
64 KB ROM disk wiring (port B and port C the ROM address A0-A15); Kiselev's 32 KB wiring
cannot read it.

The output is never committed. scripts/package.py builds the same disks itself (build, metadata)
and puts them in the package next to Kiselev's romdisk.bin.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import loader  # noqa: E402

DISK_SIZE = 65536
PAYLOAD_START = 0x200
PAYLOAD_LIMIT = 0x10000
LOADER_RAM = (0x7400, 0x75FF)
EXTENSIONS = ('.gam', '.rkr', '.rk')
EXCLUDED = ('bios.rk',)

DISKS = [
    ['CHERV.RKR', 'CHESS.GAM', 'KROK.GAM', 'SKACHKI.GAM', 'SKVOTCH.RKR', 'SOS1.GAM', 'SOS2.GAM', 'TENNIS.GAM',
     'UDAW.GAM'],
    ['KRESTNO.GAM', 'KRESTNO.RKR', 'MAZE.GAM', 'PACMAN1.GAM', 'PAKET2.RKR', 'PITON.GAM', 'TETRIS1.RKR', 'UTKA.GAM',
     'VOLCANO.RKR', 'XONIX1.RKR'],
    ['DIVERSE.GAM', 'LABYRINT.GAM', 'LEST.RKR', 'PACMAN.RKR', 'PINGPONG.RKR', 'PVO.RKR', 'SLAMS.RKR', 'SPITON.GAM',
     'STRANGER.GAM', 'TOCHKI.RKR'],
    ['BOMBER.GAM', 'CIRCUS.RKR', 'GFIRE.GAM', 'GLASS1.GAM', 'GLASS2.GAM', 'PAKET.RKR', 'XONIX.RKR', 'XONIXZM.GAM',
     'ZMEI.RKR'],
    ['LESTN1.RKR', 'LORUNNER.GAM', 'PACMAN.GAM', 'PUSHER.GAM', 'RIKOSHET.RKR', 'SDEMISE.GAM', 'TAPPER.GAM',
     'TETR2.RKR', 'TETRIS4.RKR', 'ZAGIB.RKR'],
]


def checksum(payload):
    s = 0
    for b in payload[:-1]:
        s = (s + b + (b << 8)) & 0xFFFF
    return (s & 0xFF00) | ((s + payload[-1]) & 0xFF)


def read_tape(data):
    """Returns (start, end, payload) of a tape image; ValueError on a bad one."""
    pos = 1 if data[:1] == b'\xe6' else 0
    if len(data) < pos + 4:
        raise ValueError('tape image too short')
    start = data[pos] << 8 | data[pos + 1]
    end = data[pos + 2] << 8 | data[pos + 3]
    if end < start:
        raise ValueError('tape image end %04X < start %04X' % (end, start))
    pos += 4
    n = end - start + 1
    payload = bytes(data[pos:pos + n])
    if len(payload) < n:
        raise ValueError('tape image too short for its payload')
    pos += n
    while pos < len(data) and data[pos] == 0:
        pos += 1
    if pos + 3 > len(data) or data[pos] != 0xE6:
        raise ValueError('tape image has no checksum block')
    if (data[pos + 1] << 8 | data[pos + 2]) != checksum(payload):
        raise ValueError('tape image checksum mismatch')
    return start, end, payload


def pk_files(pk_dir):
    return sorted(n for n in os.listdir(pk_dir)
                  if n.lower().endswith(EXTENSIONS) and n.lower() not in EXCLUDED)


def build(pk_dir):
    present = pk_files(pk_dir)
    table = [n for disk in DISKS for n in disk]
    for n in table:
        if n not in present:
            raise ValueError('%s of the disk table is not in %s' % (n, pk_dir))
    for n in present:
        if table.count(n) != 1:
            raise ValueError('%s is in %d disks (must be exactly 1)' % (n, table.count(n)))
    disks = []
    for number, names in enumerate(DISKS, 1):
        stems = [os.path.splitext(n)[0].upper() for n in names]
        entries, pos = [], PAYLOAD_START
        image = bytearray(b'\xff' * DISK_SIZE)
        for i, fname in enumerate(names):
            with open(os.path.join(pk_dir, fname), 'rb') as f:
                try:
                    start, end, payload = read_tape(f.read())
                except ValueError as e:
                    raise ValueError('%s: %s' % (fname, e))
            name = fname.upper() if stems.count(stems[i]) > 1 else stems[i]
            if pos + len(payload) > PAYLOAD_LIMIT:
                raise ValueError('%s: disk %d payloads end beyond %04X' % (fname, number, PAYLOAD_LIMIT))
            if end > 0xFFFF or not (end < LOADER_RAM[0] or start > LOADER_RAM[1]):
                raise ValueError('%s: RAM range %04X-%04X overlaps the loader or passes FFFF' % (fname, start, end))
            image[pos:pos + len(payload)] = payload
            entries.append({'key': loader.KEYS[i], 'name': name, 'file': fname, 'rom': pos,
                            'end': pos + len(payload) - 1, 'ram': start, 'length': len(payload)})
            pos += len(payload)
        head = loader.games_loader('ROM-DISK/64K GAMES %d/%d' % (number, len(DISKS)),
                                   [(e['name'], e['rom'], e['end'], e['ram']) for e in entries])
        if len(head) != PAYLOAD_START:
            raise ValueError('games loader is %d bytes' % len(head))
        image[:PAYLOAD_START] = head
        disks.append({'disk': number, 'image': bytes(image), 'entries': entries})
    return disks


def descriptions(pk_dir):
    path = os.path.join(pk_dir, 'DESCRIPT.ION')
    result = {}
    if os.path.exists(path):
        with open(path, 'rb') as f:
            for line in f.read().decode('cp866', errors='replace').splitlines():
                name, _, text = line.strip().partition(' ')
                if name and text.strip():
                    result[name.upper()] = text.strip()
    return result


def metadata(disks, desc):
    """The romdisks.json list: per disk its file name and entries, each with its title (or '')."""
    return [{'disk': d['disk'], 'file': 'romdisk-%d.bin' % d['disk'],
             'entries': [dict(e, title=desc.get(e['file'].upper(), '')) for e in d['entries']]}
            for d in disks]


def write_text(path, text):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def main():
    root = os.path.normpath(os.path.join(HERE, '..', '..'))
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--pk', default=os.path.join(root, 'cores', 'karabas-go-core-rk86', 'pk'))
    ap.add_argument('--out', default=os.path.join(root, 'build', 'romdisks'))
    args = ap.parse_args()
    disks = build(args.pk)
    desc = descriptions(args.pk)
    os.makedirs(args.out, exist_ok=True)
    listing, meta = [], metadata(disks, desc)
    for d, m in zip(disks, meta):
        fname = m['file']
        with open(os.path.join(args.out, fname), 'wb') as f:
            f.write(d['image'])
        listing.append('Disk %d (%s)' % (d['disk'], fname))
        for e in d['entries']:
            line = '  %s  %-12s %-12s %04X-%04X' % (e['key'], e['name'], e['file'], e['ram'],
                                                    e['ram'] + e['length'] - 1)
            if e['file'].upper() in desc:
                line += '  ' + desc[e['file'].upper()]
            listing.append(line)
        listing.append('')
        free = DISK_SIZE - (PAYLOAD_START + sum(e['length'] for e in d['entries']))
        print('%s: %d games, %d bytes free' % (fname, len(d['entries']), free))
    write_text(os.path.join(args.out, 'romdisks.json'), json.dumps(meta, indent=2) + '\n')
    write_text(os.path.join(args.out, 'romdisks.txt'), '\n'.join(listing))


if __name__ == '__main__':
    main()
