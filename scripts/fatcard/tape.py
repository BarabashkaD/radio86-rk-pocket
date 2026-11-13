# SPDX-License-Identifier: BSD-3-Clause
"""Tape files for the FAT16 card and Kiselev's ROM disk programs as tapes.

make_tape(start, payload): the tape image the monitor and the card loader read: E6, start (hi, lo),
end (hi, lo), the payload, E6, the checksum (build_romdisks.checksum; read_tape reads it back).
kiselev_files(rom): the programs of Kiselev's 32 KB ROM disk image as (8.3 name, tape) pairs, from
the table of his loader (ROM start, ROM end, RAM start). XONIX and TETRIS of that table are
byte-identical to the pk tapes XONIX1.RKR and TETRIS4.RKR and are left out. The extracted programs
stay GPL-3.0 (see LICENSES.md).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'romdisk'))
import build_romdisks  # noqa: E402

KISELEV = [  # name, ROM start, ROM end, RAM start
    ('BASIC.RKR', 0x0200, 0x21FF, 0x0000),
    ('EDASM.RKR', 0x2200, 0x31FF, 0x0000),
    ('EDDIS.RKR', 0x3200, 0x41FF, 0x0000),
    ('DPDDT.RKR', 0x4200, 0x54FF, 0x6400),
    ('OTHELLO.RKR', 0x6000, 0x779F, 0x5800),
]
BASIC_END = 0x2117  # Kiselev's loader clears 2117h; the file runs to it with zeros


def make_tape(start, payload):
    if not payload:
        raise ValueError('empty payload')
    end = start + len(payload) - 1
    if not 0 <= start <= end <= 0xFFFF:
        raise ValueError('tape range %04X-%04X outside 0000-FFFF' % (start, end))
    cs = build_romdisks.checksum(payload)
    return (bytes([0xE6, start >> 8, start & 255, end >> 8, end & 255]) + bytes(payload) +
            bytes([0xE6, cs >> 8, cs & 255]))


def kiselev_files(rom):
    files = []
    for name, rs, re, ram in KISELEV:
        payload = bytes(rom[rs:re + 1])
        if name == 'BASIC.RKR':
            payload += bytes(BASIC_END + 1 - ram - len(payload))
        files.append((name, make_tape(ram, payload)))
    return files
