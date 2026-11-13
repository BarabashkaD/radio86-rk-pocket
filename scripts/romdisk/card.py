"""Builds the card menu and card images of the J6 bank card (the ROM disk on the second 8255 with a bank latch).

Usage: python -B scripts/romdisk/card.py [--out DIR] [--title T] [--name NAME ...] [DISK ...]
  DISK     disk images, bank 1, 2, ... in this order (default build/assets/romdisk.bin, then
           build/romdisks/romdisk-1.bin .. romdisk-5.bin)
  --out    output directory (default build/card)
  --title  menu title (default J6 BANK CARD)
  --name   menu name of a disk, repeated once per disk in order (default from the file stem:
           romdisk -> KISELEV, romdisk-N -> GAMES N, any other stem uppercased)

Writes card.bin (the card image) and card.json (title, banks with key, name, file and size, the
address of the menu's key wait).

Card image: bank 0 = the card menu (card_menu.asm, 512 bytes, what R0,1FF,0 and G0 load), then FF
to 65536; bank n = disk n: a disk up to 32768 bytes padded with FF to 32768 and written twice (the
32 KB mirror), a larger one padded with FF to 65536. The menu's key KEYS[i] selects bank i + 1,
copies that bank's 0000-01FF to 0000 and jumps to 0000 (the disk's own loader). The output is
never committed.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm8080  # noqa: E402
import loader  # noqa: E402

BANK = 65536
HALF = 32768
MENU_SIZE = 512
MENU_ORG = 0x7400
MAX_NAME = 16
SOURCE = os.path.join(HERE, 'card_menu.asm')
DEFAULT_TITLE = 'J6 BANK CARD'


def assemble_menu(title, names):
    """The card menu for the disk names (key KEYS[i], bank i + 1). Returns (512 bytes, symbol table)."""
    if not 1 <= len(names) <= loader.MAX_ENTRIES:
        raise ValueError('%d names (1 to %d)' % (len(names), loader.MAX_ENTRIES))
    loader.check_text(title, 'title')
    for name in names:
        loader.check_text(name, 'name')
        if len(name) > MAX_NAME:
            raise ValueError('name longer than %d characters: %r' % (MAX_NAME, name))
    keys = loader.KEYS[:len(names)]
    lines = '\n'.join('\t\tDB\t\t0DH,0AH,"<%s>-%s"' % (k, n) for k, n in zip(keys, names))
    with open(SOURCE, encoding='ascii') as f:
        text = f.read()
    text = (text.replace('{count}', str(len(names))).replace('{keys}', keys)
            .replace('{title}', title).replace('{menu}', lines))
    try:
        org, code, symbols = asm8080.assemble(text)
    except asm8080.AsmError as e:
        raise ValueError('card menu does not fit: %s' % e)
    if org != MENU_ORG or len(code) != MENU_SIZE:
        raise ValueError('card menu does not fit: origin %04X, %d bytes' % (org, len(code)))
    return bytes(code), symbols


def card_image(menu, disks):
    """The card image: bank 0 the menu then FF, bank i + 1 disk i (see the module text)."""
    if len(menu) != MENU_SIZE:
        raise ValueError('menu of %d bytes (must be %d)' % (len(menu), MENU_SIZE))
    if not 1 <= len(disks) <= loader.MAX_ENTRIES:
        raise ValueError('%d disks (1 to %d)' % (len(disks), loader.MAX_ENTRIES))
    out = bytearray(menu) + b'\xff' * (BANK - MENU_SIZE)
    for i, disk in enumerate(disks):
        n = len(disk)
        if n == 0 or n > BANK:
            raise ValueError('disk %d: %d bytes (1 to %d)' % (i, n, BANK))
        if n <= HALF:
            out += (bytes(disk) + b'\xff' * (HALF - n)) * 2
        else:
            out += bytes(disk) + b'\xff' * (BANK - n)
    return bytes(out)


def default_name(path):
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    if stem == 'romdisk':
        return 'KISELEV'
    if stem.startswith('romdisk-') and stem[8:].isdigit():
        return 'GAMES ' + stem[8:]
    return stem.upper()


def missing_hint(path):
    base = os.path.basename(path).lower()
    if base == 'romdisk.bin':
        return 'run python -B scripts/fetch_assets.py'
    if base.startswith('romdisk-'):
        return 'run python -B scripts/romdisk/build_romdisks.py'
    return 'no such file'


def build(disks, files, names=None, title=DEFAULT_TITLE):
    """The card image and its card.json dict for the disks (bytes, bank 1, 2, ... in this order),
    their file names (for card.json and the default names) and menu names (default_name of each
    file when None). ValueError when the counts differ or a disk, a name or the title does not fit."""
    if names is None:
        names = [default_name(f) for f in files]
    if not len(disks) == len(files) == len(names):
        raise ValueError('%d disks, %d file names, %d menu names' % (len(disks), len(files), len(names)))
    menu, symbols = assemble_menu(title, names)
    image = card_image(menu, disks)
    meta = {'title': title,
            'banks': [{'bank': i + 1, 'key': loader.KEYS[i], 'name': n, 'file': os.path.basename(f),
                       'size': len(d)} for i, (n, f, d) in enumerate(zip(names, files, disks))],
            'keywait': symbols['KEYWAIT']}
    return image, meta


def main(argv=None):
    root = os.path.normpath(os.path.join(HERE, '..', '..'))
    defaults = [os.path.join(root, 'build', 'assets', 'romdisk.bin')]
    defaults += [os.path.join(root, 'build', 'romdisks', 'romdisk-%d.bin' % n) for n in range(1, 6)]
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--out', default=os.path.join(root, 'build', 'card'))
    ap.add_argument('--title', default=DEFAULT_TITLE)
    ap.add_argument('--name', action='append', default=None)
    ap.add_argument('disks', nargs='*')
    args = ap.parse_args(argv)
    paths = args.disks or defaults
    if args.name is not None and len(args.name) != len(paths):
        print('error: %d --name for %d disks' % (len(args.name), len(paths)), file=sys.stderr)
        sys.exit(1)
    disks = []
    for p in paths:
        if not os.path.isfile(p):
            print('error: %s missing: %s' % (os.path.basename(p), missing_hint(p)), file=sys.stderr)
            sys.exit(1)
        with open(p, 'rb') as f:
            disks.append(f.read())
    try:
        image, meta = build(disks, paths, args.name, args.title)
    except ValueError as e:
        print('error: %s' % e, file=sys.stderr)
        sys.exit(1)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'card.bin'), 'wb') as f:
        f.write(image)
    with open(os.path.join(args.out, 'card.json'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(meta, indent=2) + '\n')
    print('card.bin: %d bytes, %d banks' % (len(image), len(image) // BANK))
    for b in meta['banks']:
        print('  bank %d  key %s  %-16s %s (%d bytes)' % (b['bank'], b['key'], b['name'], b['file'], b['size']))


if __name__ == '__main__':
    main()
