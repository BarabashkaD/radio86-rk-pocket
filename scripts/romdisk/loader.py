"""Builds the 512-byte games loader of the ROM disk from rom_loader_games.asm."""
import os

import asm8080

KEYS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXY'
MAX_ENTRIES = 19  # the 25-row screen: header, DIR:, the entries, a blank row, the Z line
SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rom_loader_games.asm')


def check_text(text, what):
    if not text or any(not 0x20 <= ord(c) <= 0x5F or c == '"' for c in text):
        raise ValueError('%s must be uppercase ASCII 0x20-0x5F without a quote: %r' % (what, text))


def assemble_games(title, entries):
    """entries: (menu name, ROM start offset, ROM end offset inclusive, RAM address, at most MAX_ENTRIES).
    Returns (the 512 bytes of the loader, the symbol table)."""
    if len(entries) > MAX_ENTRIES:
        raise ValueError('too many entries: %d (max %d, the menu must fit the 25 rows)' % (len(entries), MAX_ENTRIES))
    check_text(title, 'title')
    table, menu = [], []
    for i, (name, start, end, ram) in enumerate(entries):
        check_text(name, 'name')
        for v in (start, end, ram):
            if not 0 <= v <= 0xFFFF:
                raise ValueError('address out of range: %r' % (v,))
        table.append('\t\tDW\t\t0%04XH,0%04XH,0%04XH\t; %s' % (start, end, ram, name))
        menu.append('\t\tDB\t\t0DH,0AH,"<%s>-%s"' % (KEYS[i], name))
    with open(SOURCE, encoding='ascii') as f:
        text = f.read()
    text = (text.replace('{apps}', str(len(entries))).replace('{table}', '\n'.join(table))
            .replace('{title}', title).replace('{menu}', '\n'.join(menu)))
    try:
        org, code, symbols = asm8080.assemble(text)
    except asm8080.AsmError as e:
        raise ValueError('loader does not fit: %s' % e)
    if org != 0x7400 or len(code) != 512:
        raise ValueError('loader does not fit: origin %04X, %d bytes' % (org, len(code)))
    return bytes(code), symbols


def games_loader(title, entries):
    """The 512 bytes of the games loader; see assemble_games."""
    return assemble_games(title, entries)[0]
