"""Tests of the FAT16 card sources (scripts/fatcard/).

The image tests need mtools (MTOOLS_DIR or PATH) and fail without it; they build their images in a
temporary directory and never read build/fatcard.
"""
import copy
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'romdisk'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'fatcard'))
import asm8080  # noqa: E402
import build_romdisks  # noqa: E402
import card  # noqa: E402
import emu8080  # noqa: E402
import fatcard  # noqa: E402
import tape  # noqa: E402
from card_model import CardPpi, fa68_copy  # noqa: E402

ASSETS = os.path.join(ROOT, 'build', 'assets')
PK = os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'pk')
CORE_SRC = os.path.abspath(os.environ.get('RK86_CORE_DIR', os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src')))
BIOS = os.path.join(CORE_SRC, 'roms', 'BIOS.BIN')


def asset(name):
    path = os.path.join(ASSETS, name)
    if not os.path.exists(path):
        raise unittest.SkipTest('%s missing: run python -B scripts/fetch_assets.py' % name)
    with open(path, 'rb') as f:
        return f.read()


def pk_payload(name):
    with open(os.path.join(PK, name), 'rb') as f:
        return build_romdisks.read_tape(f.read())[2]


class Tape(unittest.TestCase):
    def test_round_trip(self):
        for start, payload in ((0x0000, b'\x01'), (0x1234, bytes(range(200))), (0xFF00, b'\xe6' * 256)):
            t = tape.make_tape(start, payload)
            self.assertEqual(build_romdisks.read_tape(t), (start, start + len(payload) - 1, payload))
            self.assertEqual(t[0], 0xE6)

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            tape.make_tape(0xFFFF, b'ab')
        with self.assertRaises(ValueError):
            tape.make_tape(0, b'')

    def test_kiselev_files(self):
        rom = asset('romdisk.bin')
        files = tape.kiselev_files(rom)
        self.assertEqual([n for n, _ in files], ['BASIC.RKR', 'EDASM.RKR', 'EDDIS.RKR', 'DPDDT.RKR', 'OTHELLO.RKR'])
        expect = {'EDASM.RKR': (0x2200, 0x31FF, 0), 'EDDIS.RKR': (0x3200, 0x41FF, 0),
                  'DPDDT.RKR': (0x4200, 0x54FF, 0x6400), 'OTHELLO.RKR': (0x6000, 0x779F, 0x5800)}
        for name, data in files:
            start, end, payload = build_romdisks.read_tape(data)
            if name == 'BASIC.RKR':
                self.assertEqual((start, end), (0, 0x2117))
                self.assertEqual(payload[:0x2000], rom[0x200:0x2200])
                self.assertEqual(payload[0x2000:], bytes(0x118))
            else:
                rs, re, ram = expect[name]
                self.assertEqual((start, end), (ram, ram + re - rs))
                self.assertEqual(payload, rom[rs:re + 1])

    def test_why_xonix_and_tetris_are_left_out(self):
        rom = asset('romdisk.bin')
        self.assertEqual(pk_payload('XONIX1.RKR'), rom[0x5500:0x6000])
        self.assertEqual(pk_payload('TETRIS4.RKR'), rom[0x77A0:0x7E00])


# dummy 8080 parts: every byte non-zero, so a write outside its place shows (the boot part's 06-3D
# would overwrite the BPB if install_bank0 wrote them)
BOOT = b'\xc3\x3e\x00' + b'\xa5' * (0x1FB - 3)
MENU = bytes(range(256)) * 8
LOADER = b'\x5a' * 512
KISELEV_ON_CARD = ['BASIC.RKR', 'EDASM.RKR', 'EDDIS.RKR', 'OTHELLO.RKR']


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def raw_entries(image):
    """(slot, 32-byte entry) of the root directory up to the first entry whose name starts with 00."""
    p = fatcard.bpb(image)
    base = p['root_start'] * p['bytes_per_sector']
    result = []
    for slot in range(p['root_entries']):
        e = image[base + 32 * slot:base + 32 * slot + 32]
        if e[0] == 0:
            break
        result.append((slot, e))
    return result


def chain_of(image, name):
    return fatcard.cluster_chain(image, name)


class Tmp(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.img = os.path.join(self.tmp, 'card.img')

    def tearDown(self):
        self._tmp.cleanup()


class Tools(Tmp):
    def test_mtools_dir_takes_precedence_over_path(self):
        real = os.path.dirname(fatcard.mtools('mformat'))
        with mock.patch.dict(os.environ, {'MTOOLS_DIR': real, 'PATH': ''}):
            for tool in ('mformat', 'mcopy', 'mdel', 'mlabel'):
                found = fatcard.mtools(tool)
                self.assertEqual(os.path.normcase(os.path.dirname(found)), os.path.normcase(real))

    def test_mtools_dir_without_the_tool_is_an_error(self):
        real = os.path.dirname(fatcard.mtools('mformat'))
        nowhere = os.path.join(self.tmp, 'nowhere')
        for path in ('', real):
            with mock.patch.dict(os.environ, {'MTOOLS_DIR': nowhere, 'PATH': path}):
                with self.assertRaisesRegex(RuntimeError, 'MTOOLS_DIR'):
                    fatcard.mtools('mformat')

    def test_no_mtools_names_mtools_dir(self):
        env = {k: v for k, v in os.environ.items() if k.upper() != 'MTOOLS_DIR'}
        env['PATH'] = ''
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'MTOOLS_DIR'):
                fatcard.mtools('mformat')

    def test_run_mtools_failure_and_timeout(self):
        with self.assertRaisesRegex(RuntimeError, 'mdel'):
            fatcard.run_mtools('mdel', os.path.join(self.tmp, 'missing.img'), '::X')
        fatcard.format_image(self.img)
        fatcard.add_files(self.img, [('A.RKR', b'abc')])
        src = os.path.join(self.tmp, 'A.RKR')
        with open(src, 'wb') as f:
            f.write(b'xyz')
        # a name clash without -D: mcopy waits for an answer (seen on Windows) or gives up; either way
        # run_mtools returns within its timeout and the file stays
        try:
            fatcard.run_mtools('mcopy', self.img, 'A.RKR', '::A.RKR', timeout=3)
        except RuntimeError as e:
            self.assertIn('mcopy', str(e))
        self.assertEqual(fatcard.read_file(read(self.img), 'A.RKR'), b'abc')
        with mock.patch.object(fatcard.subprocess, 'run', side_effect=fatcard.subprocess.TimeoutExpired('mcopy', 3)):
            with self.assertRaisesRegex(RuntimeError, 'name clash'):
                fatcard.run_mtools('mcopy', self.img, 'A.RKR', '::A.RKR', timeout=3)


class Layout(Tmp):
    def test_format_image(self):
        with open(self.img, 'wb') as f:
            f.write(b'\x55' * 1000)   # an older file of another size is replaced
        fatcard.format_image(self.img)
        image = read(self.img)
        self.assertEqual(len(image), 8388608)
        self.assertEqual(image[0:3], b'\xeb\x3c\x90')
        self.assertEqual(image[0x1FE:0x200], b'\x55\xaa')
        p = fatcard.bpb(image)
        expect = {'bytes_per_sector': 512, 'sectors_per_cluster': 1, 'reserved': 128, 'fats': 1,
                  'root_entries': 512, 'sectors_per_fat': 64, 'total_sectors': 16384, 'root_sectors': 32,
                  'fat_start': 128, 'root_start': 192, 'data_start': 224, 'clusters': 16160}
        for k, v in expect.items():
            self.assertEqual(p[k], v, k)
        self.assertTrue(4085 <= p['clusters'] <= 65524)
        self.assertEqual(image[512:128 * 512], bytes(127 * 512))
        self.assertEqual(fatcard.directory(image), [])

    def test_bpb_refuses_other_layouts(self):
        fatcard.format_image(self.img)
        image = read(self.img)

        def patched(offset, fmt, value):
            b = bytearray(image)
            struct.pack_into(fmt, b, offset, value)
            return bytes(b)

        for offset, fmt, value in ((0x0B, '<H', 1024), (0x0D, 'B', 0), (0x10, 'B', 0),
                                   (0x13, '<H', 4000),      # FAT12 size
                                   (0x16, '<H', 8)):        # the FAT too small for the clusters
            with self.assertRaises(ValueError, msg='%02X' % offset):
                fatcard.bpb(patched(offset, fmt, value))
        p = fatcard.bpb(patched(0x13, '<H', 0)[:0x20] + struct.pack('<I', 16384) + image[0x24:])
        self.assertEqual(p['total_sectors'], 16384)

    def test_install_bank0(self):
        fatcard.format_image(self.img)
        before = read(self.img)
        fatcard.install_bank0(self.img, BOOT, MENU, LOADER)
        image = read(self.img)
        self.assertEqual(len(image), len(before))
        self.assertEqual(image[0:3], before[0:3])
        self.assertEqual(image[3:6], b'\xc3\x3e\x00')
        self.assertEqual(image[0x0B:0x3E], before[0x0B:0x3E])
        self.assertEqual(image[0x3E:0x1FE], BOOT[0x3B:])
        self.assertEqual(image[0x1FE:0x200], b'\x55\xaa')
        self.assertEqual(image[512:5 * 512], MENU)
        self.assertEqual(image[5 * 512:6 * 512], LOADER)
        self.assertEqual(image[6 * 512:128 * 512], bytes(122 * 512))
        self.assertEqual(image[128 * 512:], before[128 * 512:])
        # short parts are zero-padded to their sectors
        fatcard.install_bank0(self.img, BOOT, b'\x11' * 100, b'\x22' * 10)
        image = read(self.img)
        self.assertEqual(image[512:5 * 512], b'\x11' * 100 + bytes(2048 - 100))
        self.assertEqual(image[5 * 512:6 * 512], b'\x22' * 10 + bytes(502))

    def test_install_bank0_refuses(self):
        fatcard.format_image(self.img)
        before = read(self.img)
        bad = [(BOOT[:-1], MENU, LOADER), (b'\xc3\x3e\x01' + BOOT[3:], MENU, LOADER),
               (BOOT, b'', LOADER), (BOOT, MENU + b'\x01', LOADER),
               (BOOT, MENU, b''), (BOOT, MENU, LOADER + b'\x01')]
        for args in bad:
            with self.assertRaises(ValueError):
                fatcard.install_bank0(self.img, *args)
        self.assertEqual(read(self.img), before)
        short = os.path.join(self.tmp, 'short.img')
        with open(short, 'wb') as f:
            f.write(before[:131072])
        with self.assertRaises(ValueError):
            fatcard.install_bank0(short, BOOT, MENU, LOADER)
        self.assertEqual(len(read(short)), 131072)
        other = bytearray(before)
        other[0x0E] = 64   # reserved sectors
        with open(short, 'wb') as f:
            f.write(other)
        with self.assertRaises(ValueError):
            fatcard.install_bank0(short, BOOT, MENU, LOADER)
        self.assertEqual(read(short), bytes(other))

    def test_label_image(self):
        fatcard.format_image(self.img)
        fatcard.label_image(self.img, 'rk86card')
        image = read(self.img)
        self.assertEqual(image[0x2B:0x36], b'RK86CARD   ')
        labels = [e for _, e in raw_entries(image) if e[11] == 0x08]
        self.assertEqual([e[:11] for e in labels], [b'RK86CARD   '])
        self.assertEqual(fatcard.directory(image), [])
        for label in ('', 'TWELVE_CHARS', 'A+B', 'A.B'):
            with self.assertRaises(ValueError):
                fatcard.label_image(self.img, label)


class Files(Tmp):
    def test_names(self):
        fatcard.format_image(self.img)
        before = read(self.img)
        for files in ([('piton.gam', b'1'), ('PITON.GAM', b'2')], [('A+B.RKR', b'1')],
                      [('LONGNAME1.GAM', b'1')], [('A.B.C', b'1')], [('ABC.ABCD', b'1')], [('', b'1')],
                      [('.RKR', b'1')], [('A B.RKR', b'1')]):
            with self.assertRaises(ValueError, msg=repr(files)):
                fatcard.add_files(self.img, files)
        self.assertEqual(read(self.img), before)
        fatcard.add_files(self.img, [('piton.gam', b'abc'), ('NOEXT', b'de')])
        image = read(self.img)
        self.assertEqual([d['file'] for d in fatcard.directory(image)], ['PITON.GAM', 'NOEXT'])
        for _, e in raw_entries(image):
            self.assertEqual(e[0x0C], 0, e[:11])
        self.assertEqual(fatcard.read_file(image, 'piton.gam'), b'abc')
        with self.assertRaises(ValueError):
            fatcard.add_files(self.img, [('PITON.GAM', b'x')])
        self.assertEqual(read(self.img), image)

    def test_binary_safe(self):
        fatcard.format_image(self.img)
        data = bytes(range(256)) * 3 + b'\r\n\x1a'
        fatcard.add_files(self.img, [('BIN.RKR', data), ('EMPTY.RKR', b'')])
        image = read(self.img)
        self.assertEqual(fatcard.read_file(image, 'BIN.RKR'), data)
        self.assertEqual(fatcard.read_file(image, 'EMPTY.RKR'), b'')

    def test_fragmented_file(self):
        fatcard.format_image(self.img)
        data = {n: bytes([i + 1]) * size for i, (n, size) in
                enumerate((('A.RKR', 1000), ('B.RKR', 1000), ('C.RKR', 1000), ('D.RKR', 2600)))}
        for n in ('A.RKR', 'B.RKR', 'C.RKR'):
            fatcard.add_files(self.img, [(n, data[n])])
        fatcard.run_mtools('mdel', self.img, '::B.RKR')
        fatcard.add_files(self.img, [('D.RKR', data['D.RKR'])])
        image = read(self.img)
        chain = chain_of(image, 'D.RKR')
        self.assertEqual(len(chain), 6)
        self.assertTrue(any(b != a + 1 for a, b in zip(chain, chain[1:])),
                        'D.RKR is contiguous %r: the chain walk is not tested' % chain)
        for n in ('A.RKR', 'C.RKR', 'D.RKR'):
            self.assertEqual(fatcard.read_file(image, n), data[n])
        with self.assertRaises(ValueError):
            fatcard.read_file(image, 'B.RKR')
        self.assertEqual([(d['slot'], d['file']) for d in fatcard.directory(image)],
                         [(0, 'A.RKR'), (1, 'D.RKR'), (2, 'C.RKR')])

    def test_file_across_banks_1_and_2(self):
        fatcard.format_image(self.img)
        data = bytes((i * 7 + 3) & 255 for i in range(40 * 512 - 100))
        fatcard.add_files(self.img, [('BIG.RKR', data)])
        image = read(self.img)
        p = fatcard.bpb(image)
        last_of_bank1 = 2 + (255 - p['data_start']) // p['sectors_per_cluster']
        chain = chain_of(image, 'BIG.RKR')
        self.assertIn(last_of_bank1, chain)
        self.assertEqual(chain[chain.index(last_of_bank1) + 1], last_of_bank1 + 1)
        self.assertEqual((p['data_start'] + (last_of_bank1 + 1 - 2) * p['sectors_per_cluster']) >> 7, 2)
        self.assertEqual(fatcard.read_file(image, 'BIG.RKR'), data)

    def test_read_file_refuses_a_corrupt_chain(self):
        fatcard.format_image(self.img)
        fatcard.add_files(self.img, [('F.RKR', b'\x77' * 1500)])
        image = read(self.img)
        p = fatcard.bpb(image)
        self.assertEqual(chain_of(image, 'F.RKR'), [2, 3, 4])
        fat = p['fat_start'] * 512

        def with_fat(**values):
            b = bytearray(image)
            for k, v in values.items():
                struct.pack_into('<H', b, fat + 2 * int(k[1:]), v)
            return bytes(b)

        for case in (dict(c3=2), dict(c3=0xFFF7), dict(c3=0xFFF0), dict(c2=0xFFFF), dict(c2=0), dict(c2=1),
                     dict(c3=p['clusters'] + 2), dict(c4=5, c5=0xFFFF)):
            with self.assertRaises(ValueError, msg=repr(case)):
                fatcard.read_file(with_fat(**case), 'F.RKR')
        with self.assertRaises(ValueError):
            fatcard.read_file(image, 'G.RKR')
        self.assertEqual(fatcard.read_file(with_fat(c4=0xFFF8), 'F.RKR'), b'\x77' * 1500)

    def test_directory(self):
        fatcard.format_image(self.img)
        files = [('GOOD.RKR', tape.make_tape(0x0100, b'x' * 10)),
                 ('RAW.GAM', b'\x02\x00\x02\x02abc'),                    # no E6: 4-byte header
                 ('SHORT.RKR', b'\xe6\x01\x00\x01\x09abc'),              # payload longer than the file
                 ('TEXT.TXT', b'hello'),
                 ('EMPTY', b''),
                 ('OVER.RKR', tape.make_tape(0x7300, bytes(0x200))),      # overlaps the loader
                 ('HIGH.RKR', tape.make_tape(0x7F00, bytes(0x200)))]      # passes 7FFF
        fatcard.add_files(self.img, files)
        image = bytearray(read(self.img))
        d = {e['file']: e for e in fatcard.directory(bytes(image))}
        self.assertEqual(list(d), [n for n, _ in files])
        g = d['GOOD.RKR']
        self.assertEqual((g['name'], g['ext'], g['slot'], g['attr'], g['cluster'], g['size']),
                         ('GOOD', 'RKR', 0, 0x20, 2, 18))
        self.assertEqual((g['start'], g['end'], g['window']), (0x100, 0x109, 'A'))
        self.assertEqual((d['RAW.GAM']['start'], d['RAW.GAM']['end'], d['RAW.GAM']['window']), (0x200, 0x202, 'A'))
        for n in ('SHORT.RKR', 'TEXT.TXT', 'EMPTY'):
            self.assertEqual((d[n]['start'], d[n]['end'], d[n]['window']), (None, None, None), n)
        self.assertEqual(d['EMPTY']['cluster'], 0)
        self.assertEqual((d['OVER.RKR']['start'], d['OVER.RKR']['window']), (0x7300, None))
        self.assertEqual((d['HIGH.RKR']['start'], d['HIGH.RKR']['window']), (0x7F00, None))
        # listing rules: E5, hidden, system, directory skipped; nothing after a 00 entry
        p = fatcard.bpb(bytes(image))
        root = p['root_start'] * 512
        image[root + 32 * 1] = 0xE5
        image[root + 32 * 2 + 11] = 0x22
        image[root + 32 * 3 + 11] = 0x04
        image[root + 32 * 4 + 11] = 0x10
        image[root + 32 * 8:root + 32 * 9] = image[root:root + 32]    # behind the 00 entry at slot 7
        self.assertEqual([e['file'] for e in fatcard.directory(bytes(image))], ['GOOD.RKR', 'OVER.RKR', 'HIGH.RKR'])

    def test_reproducible_on_one_machine(self):
        images = []
        for n in ('one.img', 'two.img'):
            path = os.path.join(self.tmp, n)
            fatcard.build_image(path, [('A.RKR', tape.make_tape(0, b'a' * 600))], BOOT, MENU, LOADER)
            images.append(read(path))
        self.assertEqual(images[0], images[1])


class Window(unittest.TestCase):
    def test_edges(self):
        # RAM_TOP 73FF: the loader's own rule (END <= 73FFh), so the builder, the menu and the loader agree
        self.assertEqual(fatcard.RAM_TOP, 0x73FF)
        for start, end in ((0, 0x73FF), (0x7000, 0x73FF), (5, 5), (0x73FF, 0x73FF)):
            self.assertEqual(fatcard.loader_window(start, end), 'A')
        for start, end in ((0x73FF, 0x7400), (0x75FF, 0x7600), (0x7000, 0x8000), (0x7400, 0x75FF),
                           (0x7500, 0x7500), (0x0100, 0x00FF), (0, 0xFFFF), (0x7600, 0x7FFF)):
            with self.assertRaises(ValueError, msg='%04X-%04X' % (start, end)):
                fatcard.loader_window(start, end)


class Card(Tmp):
    def test_card_files(self):
        files = fatcard.card_files(PK, asset('romdisk.bin'))
        names = [n for n, _ in files]
        self.assertEqual(len(names), 52)
        self.assertEqual(names, [n.upper() for n in build_romdisks.pk_files(PK)] + KISELEV_ON_CARD)
        self.assertNotIn('DPDDT.RKR', names)
        with open(os.path.join(PK, 'PITON.GAM'), 'rb') as f:
            self.assertEqual(dict(files)['PITON.GAM'], f.read())

    def test_card_files_refuses(self):
        rom = asset('romdisk.bin')
        good = tape.make_tape(0x0100, b'g' * 20)
        for name, data in (('OVER.RKR', tape.make_tape(0x7300, bytes(0x200))),
                           ('NOTAPE.GAM', b'hello world'),
                           ('BASIC.RKR', good),            # Kiselev's BASIC has this name
                           ('LONGNAME1.GAM', good)):
            pk = os.path.join(self.tmp, name.replace('.', '_'))
            os.makedirs(pk)
            for n, d in (('GOOD.GAM', good), (name, data)):
                with open(os.path.join(pk, n), 'wb') as f:
                    f.write(d)
            with self.assertRaisesRegex(ValueError, name.replace('.', r'\.')):
                fatcard.card_files(pk, rom)

    def test_card_image(self):
        files = fatcard.card_files(PK, asset('romdisk.bin'))
        listing = fatcard.build_image(self.img, files, BOOT, MENU, LOADER)
        image = read(self.img)
        self.assertEqual(len(image), 8388608)
        self.assertEqual(image[0:3], b'\xeb\x3c\x90')
        self.assertEqual(image[3:6], b'\xc3\x3e\x00')
        self.assertEqual(image[0x1FE:0x200], b'\x55\xaa')
        self.assertEqual(image[0x2B:0x36], b'RK86CARD   ')
        self.assertEqual(image[512:6 * 512], MENU + LOADER)
        d = fatcard.directory(image)
        self.assertEqual(listing, d)
        self.assertEqual([e['file'] for e in d], [n for n, _ in files])
        for (name, data), e in zip(files, d):
            self.assertEqual(fatcard.read_file(image, name), data, name)
            start, end, _ = build_romdisks.read_tape(data)
            self.assertEqual((e['start'], e['end'], e['window']), (start, end, 'A'), name)
        entries = raw_entries(image)
        self.assertFalse([e for _, e in entries if e[11] == 0x0F], 'LFN entries')
        self.assertEqual([e[:11] for _, e in entries if e[11] == 0x08], [b'RK86CARD   '])
        self.assertEqual(sum(1 for _, e in entries if e[11] & 0x1E == 0), 52)
        for _, e in entries:
            self.assertEqual(e[0x0C], 0, e[:11])
        # the image crosses banks 1 and 2 (sectors 255, 256) inside one file
        p = fatcard.bpb(image)
        c = 2 + (255 - p['data_start']) // p['sectors_per_cluster']
        crossing = [e['file'] for e in d if c in chain_of(image, e['file']) and c + 1 in chain_of(image, e['file'])]
        self.assertEqual(len(crossing), 1)


# --- Task 3: the 8080 boot stage and loader -------------------------------------------------------

MONITOR = 0xF86C
HALT = 0x76            # RAM the loader must not write holds HLT: a stray jump into it raises
UPPER = 0x33           # 7600-7FFF before a run: the monitor's variables, its stack, the screen
# not periodic: a copy shifted by 256 bytes would not match
DUMMY_MENU = bytes((i * 7 + (i >> 8) * 13) & 0xFF for i in range(2048))


def program(text):
    """Assembles a test program; returns (the RAM with it, its symbols)."""
    org, code, sym = asm8080.assemble(text)
    ram = bytearray(65536)
    ram[org:org + len(code)] = code
    return ram, sym


def select_bank(c, bank):
    """SELBK through the card's ports (bank card spec 4.3)."""
    c.write(3, 0x90)
    c.write(2, 0xFF)
    c.write(1, bank)
    c.write(3, 0x0E)


def raw_tape(start, data, e6=True):
    """A tape without the checksum trailer: the file ends with the payload."""
    end = start + len(data) - 1
    return (b'\xe6' if e6 else b'') + bytes([start >> 8, start & 255, end >> 8, end & 255]) + bytes(data)


def pattern(n, seed):
    return bytes((i * 31 + seed * 17 + (i >> 8)) & 0xFF for i in range(n))


class Emulator(unittest.TestCase):
    def cpu(self, text):
        c = emu8080.Cpu(program(text)[0])
        c.pc = 0x100
        return c

    def test_lhld(self):
        c = self.cpu('\tORG\t100H\n\tLHLD\t200H\n')
        c.m[0x200], c.m[0x201] = 0x34, 0x12
        c.f = 0x02 | emu8080.CY | emu8080.Z
        c.step()
        self.assertEqual((c.r[4], c.r[5], c.pc, c.f), (0x12, 0x34, 0x103, 0x02 | emu8080.CY | emu8080.Z))

    def test_shld(self):
        c = self.cpu('\tORG\t100H\n\tSHLD\t2FFH\n')
        c.r[4], c.r[5] = 0xAB, 0xCD
        c.step()
        self.assertEqual((c.m[0x2FF], c.m[0x300], c.pc, c.f), (0xCD, 0xAB, 0x103, 0x02))

    def test_stop_before_executing(self):
        ram, _ = program('\tORG\t100H\n\tNOP\n\tHLT\n')
        r = emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == 0x101)
        self.assertEqual((r.pc, r.sp, r.waiting), (0x101, 0x76CF, False))
        r = emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == 0x100)
        self.assertEqual(r.pc, 0x100)
        with self.assertRaisesRegex(emu8080.EmuError, 'HLT'):
            emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: False)

    def test_waiting_and_steps(self):
        ram, _ = program('\tORG\t100H\n\tCALL\t0F803H\n\tSTA\t200H\n\tCALL\t0F803H\n\tHLT\n')
        r = emu8080.run_until(ram, 0x100, 'A', None, stop=lambda pc: False)
        self.assertTrue(r.waiting)
        self.assertEqual((r.pc, r.ram[0x200]), (0xF803, 0x41))
        with self.assertRaisesRegex(emu8080.EmuError, 'steps'):
            emu8080.run_until(program('\tORG\t100H\n\tJMP\t100H\n')[0], 0x100, '', None, stop=lambda pc: False,
                              max_steps=1000)

    def test_print_registers_and_cls(self):
        ram, sym = program('\tORG\t100H\n\tLXI\tH,TEXT\n\tLXI\tB,1234H\n\tLXI\tD,5678H\n\tCALL\t0F818H\n'
                           '\tSTA\t200H\n\tSHLD\t201H\n\tMOV\tA,B\n\tSTA\t203H\n\tMOV\tA,C\n\tSTA\t204H\n'
                           '\tMOV\tA,D\n\tSTA\t205H\n\tMOV\tA,E\n\tSTA\t206H\nSTOP:\tHLT\n'
                           'TEXT:\tDB\t"AB",1FH,"C",0\n')
        ram[0x7600:0x8000] = bytes([UPPER]) * 0xA00
        r = emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == sym['STOP'])
        self.assertEqual(r.printed, b'AB\x1fC')
        self.assertEqual(r.events, [('print', b'AB\x1fC')])
        zero = sym['TEXT'] + 4
        self.assertEqual(bytes(r.ram[0x200:0x207]), bytes([0, zero & 255, zero >> 8, 0x12, ord('C'), 0x56, 0x78]))
        self.assertEqual(bytes(r.ram[0x76D0:0x7FF5]), bytes(0x7FF5 - 0x76D0))
        self.assertEqual(bytes(r.ram[0x7FF5:0x8000]), bytes([UPPER]) * 11)
        self.assertEqual(bytes(r.ram[0x7600:0x76BD]), bytes([UPPER]) * 0xBD)

    def test_print_refuses_changed_monitor_variables(self):
        base = '\tORG\t100H\n\tLXI\tH,TEXT\n%s\tCALL\t0F818H\nSTOP:\tHLT\nTEXT:\tDB\t"X",0\n'
        for at in ('7600H', '7603H', '765FH'):
            ram, sym = program(base % ('\tMVI\tA,99H\n\tSTA\t%s\n' % at))
            with self.assertRaisesRegex(emu8080.EmuError, '7600-765F'):
                emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == sym['STOP'])
        # ordinary use of the monitor's stack (SP 76CF, calls, the stub's fill) and a store at 7660
        ram, sym = program(base % '\tMVI\tA,99H\n\tSTA\t7660H\n\tPUSH\tH\n\tCALL\t0F818H\n\tPOP\tH\n')
        r = emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == sym['STOP'])
        self.assertEqual(r.printed, b'XX')
        self.assertEqual(r.min_sp, 0x76CF - 4)

    def test_copy_registers_and_full_wrap(self):
        c = CardPpi(bytes(range(256)) * 4)
        ram, sym = program('\tORG\t100H\n\tLXI\tH,10H\n\tLXI\tD,13H\n\tLXI\tB,500H\n\tCALL\t0FA68H\n'
                           '\tJZ\tZOK\n\tHLT\nZOK:\tSTA\t200H\n\tSHLD\t201H\n\tMOV\tA,B\n\tSTA\t203H\n'
                           '\tMOV\tA,C\n\tSTA\t204H\nSTOP:\tHLT\n')
        r = emu8080.run_until(ram, 0x100, '', c, stop=lambda pc: pc == sym['STOP'])
        self.assertEqual(bytes(r.ram[0x500:0x504]), bytes([0x10, 0x11, 0x12, 0x13]))
        self.assertEqual(bytes(r.ram[0x200:0x205]), bytes([0x13, 0x13, 0, 0x05, 0x04]))
        self.assertEqual(r.events, [('copy', 0x10, 0x13, 0x500)])
        wrap, _ = program('\tORG\t100H\n\tLXI\tH,10H\n\tLXI\tD,0FH\n\tLXI\tB,500H\n\tCALL\t0FA68H\n\tHLT\n')
        with self.assertRaisesRegex(emu8080.EmuError, '65536'):
            emu8080.run_until(wrap, 0x100, '', c, stop=lambda pc: False)

    def test_other_monitor_entries_refused(self):
        # an unmodelled monitor routine would run the zero RAM at F8xx as NOPs and wrap to 0000
        for target in ('0F815H', '0F809H', '0F86CH', '0FFFFH'):
            ram, _ = program('\tORG\t100H\n\tCALL\t%s\n\tHLT\n' % target)
            with self.assertRaisesRegex(emu8080.EmuError, 'monitor'):
                emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: False)
        # a stop at the command loop still comes first (the loader's refusals)
        ram, _ = program('\tORG\t100H\n\tJMP\t0F86CH\n')
        self.assertEqual(emu8080.run_until(ram, 0x100, '', None, stop=lambda pc: pc == MONITOR).pc, MONITOR)

    def test_run_menu_unchanged(self):
        # run_menu keeps its stubs: a store to 7603 before a print is not refused there
        rom = asm8080.assemble('\tORG\t0\n\tMVI\tA,1\n\tSTA\t7603H\n\tLXI\tH,T\n\tCALL\t0F818H\n'
                               '\tJMP\t7400H\nT:\tDB\t"Q",0\n')[1]
        ram = bytearray(65536)
        ram[0:len(rom)] = rom
        ram[0x7400] = 0xC3  # JMP 0000: leaves the loader range at once
        r = emu8080.run_menu(rom, '', ram=ram, start=0)
        self.assertEqual(r.printed, b'Q')


class ScreenModel(unittest.TestCase):
    def test_text_and_controls(self):
        s = emu8080.Screen()
        s.feed(b'\x1fAB\r\nC')
        s.feed(bytes([0xC4]))                     # the monitor masks 7Fh: D
        self.assertEqual(s.lines()[:3], ['AB', 'CD', ''])
        s.feed(b'\x1bY' + bytes([0x20 + 5, 0x20 + 3]) + b'X')
        self.assertEqual(s.lines()[5], '   X')
        self.assertEqual((s.row, s.col), (5, 4))
        s.feed(b'\x1bY' + bytes([0x20, 0x20]) + b'Z')   # homes first: row 0, column 0
        self.assertEqual(s.lines()[0], 'ZB')
        s.feed(b'\x1f')
        self.assertEqual(s.lines(), [''] * 25)
        self.assertEqual((s.row, s.col), (0, 0))

    def test_wrap_after_column_63(self):
        s = emu8080.Screen()
        s.feed(b'\x1f' + b'a' * 64 + b'b')
        self.assertEqual(s.lines()[:2], ['a' * 64, 'b'])

    def test_errors(self):
        for data in (b'\x1f' + b'\r\n' * 24 + b'\n',           # LF on the last line scrolls
                     b'\x1f' + b'\r\n' * 24 + b'x' * 64,        # so does the bottom-right cell
                     b'\x07', b'\x08', b'\x0c', b'\x18', b'\x00',
                     b'\x1bX', b'\x1bY' + bytes([0x20 + 25, 0x20]),
                     b'\x1bY' + bytes([0x20, 0x20 + 64])):
            with self.subTest(data=data):
                with self.assertRaises(emu8080.EmuError):
                    emu8080.Screen().feed(data)

    def test_replay(self):
        s = emu8080.Screen()
        s.replay([('print', b'\x1fHI'), ('copy', 0, 1, 2), ('print', b'!')])
        self.assertEqual(s.lines()[0], 'HI!')


class Monitor(unittest.TestCase):
    def test_monitor_entry(self):
        with open(BIOS, 'rb') as f:
            bios = f.read()
        self.assertEqual(len(bios), 2048)
        self.assertEqual(bios[MONITOR - 0xF800:MONITOR - 0xF800 + 3], b'\x31\xcf\x76')  # LXI SP,76CF
        self.assertEqual(fatcard.loader_symbols()['MONITOR'], MONITOR)
        self.assertEqual(fatcard.boot_symbols()['MONITOR'], MONITOR)


class Assembly(unittest.TestCase):
    def test_boot(self):
        boot = fatcard.assemble_boot()
        self.assertEqual(len(boot), 0x1FB)
        self.assertEqual(boot[0:3], b'\xc3\x3e\x00')
        sym = fatcard.boot_symbols()
        self.assertEqual(sym['START'], 0x3E)
        self.assertLess(sym['BOOTEND'], 0x1FE)

    def test_loader(self):
        loader = fatcard.assemble_loader()
        sym = fatcard.loader_symbols()
        self.assertEqual([sym[k] for k in ('FATSTART', 'DATASTART', 'CLUSTER', 'SIZE', 'MAXCL')],
                         [0x7403, 0x7405, 0x7407, 0x7409, 0x740B])
        self.assertEqual(loader[0:3], bytes([0xC3, sym['ENTRY'] & 255, sym['ENTRY'] >> 8]))
        self.assertGreaterEqual(sym['ENTRY'], 0x740D)
        self.assertLessEqual(sym['CODEND'], 0x75C0)
        self.assertEqual(len(loader), sym['CODEND'] - 0x7400)
        with mock.patch.object(fatcard, 'LOADER_END', sym['CODEND'] - 1):
            with self.assertRaisesRegex(ValueError, 'loader'):
                fatcard.assemble_loader()

    def test_selbk_is_the_card_menus(self):
        menu, msym = card.assemble_menu('T', ['A'])
        loader, lsym = fatcard.assemble_loader(), fatcard.loader_symbols()
        n = 21
        a, b = msym['SELBK'] - 0x7400, lsym['SELBK'] - 0x7400
        self.assertEqual(loader[b:b + n], menu[a:a + n])
        self.assertEqual(loader[b + n - 1], 0xC9)
        fat, fsym = fatcard.assemble_menu()
        c = fsym['SELBK'] - 0x6C00
        self.assertEqual(fat[c:c + n], loader[b:b + n])

    def test_menu_shares_the_loaders_routines(self):
        # asm8080 has no INCLUDE: the menu carries the loader's tested routines as the same text
        def block(path, label):
            with open(path, encoding='ascii') as f:
                lines = f.read().split('\n')
            i = next(k for k, l in enumerate(lines) if l.startswith(label + ':'))
            j = next(k for k in range(i, len(lines)) if not lines[k].strip())
            return lines[i:j]
        menu = os.path.join(ROOT, 'scripts', 'fatcard', 'menu.asm')
        for label in ('RDCARD', 'CMPHD', 'SUBHD', 'SELBK'):
            with self.subTest(label):
                self.assertEqual(block(menu, label), block(fatcard.LOADER_SOURCE, label))

    def test_loader_params(self):
        p = {'fat_start': 128, 'data_start': 224, 'clusters': 16160}
        self.assertEqual(fatcard.loader_params(p, {'cluster': 7, 'size': 0xFFFF}), (128, 224, 7, 0xFFFF, 16161))
        with self.assertRaises(ValueError):
            fatcard.loader_params(p, {'cluster': 7, 'size': 0x10000})


def loader_ram(c, params):
    """RAM as the menu leaves it: 0000-73FF HLT, 7600-7FFF UPPER, the loader from reserved sector 5 (read
    from bank 0 through the card) at 7400, its parameter block filled."""
    ram = bytearray(65536)
    ram[0:0x7400] = bytes([HALT]) * 0x7400
    ram[0x7600:0x8000] = bytes([UPPER]) * 0xA00
    assert c.bank == 0
    ram[0x7400:0x7600] = fa68_copy(c, 0x0A00, 0x0BFF)
    struct.pack_into('<5H', ram, 0x7403, *params)
    return ram


def run_loader(c, ram):
    return emu8080.run_until(ram, 0x7400, '', c, stop=lambda pc: pc < 0x7400 or pc == MONITOR)


class LoaderCase(unittest.TestCase):
    """Builds the image in setUpClass; check_load and check_refused run the loader on it."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.path = os.path.join(cls._tmp.name, 'card.img')
        fatcard.build_image(cls.path, cls.card_files(), fatcard.assemble_boot(), DUMMY_MENU,
                            fatcard.assemble_loader())
        cls.more(cls.path)
        cls.image = read(cls.path)
        cls.bpb = fatcard.bpb(cls.image)
        cls.dir = {e['file']: e for e in fatcard.directory(cls.image)}
        cls.loader_sym = fatcard.loader_symbols()

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    @classmethod
    def more(cls, path):
        pass

    def params(self, name, **change):
        p = list(fatcard.loader_params(self.bpb, self.dir[name]))
        for k, v in change.items():
            p[('fatstart', 'datastart', 'cluster', 'size', 'maxcl').index(k)] = v
        return p

    def check_load(self, name, start, payload, image=None, **change):
        c = CardPpi(image if image is not None else self.image)
        self.assertEqual(c.kind, 'bank')
        ram = loader_ram(c, self.params(name, **change))
        select_bank(c, 5)
        self.assertEqual(c.bank, 5)
        r = run_loader(c, ram)
        end = start + len(payload) - 1
        self.assertEqual(r.pc, start)
        self.assertEqual(r.sp, 0x76CF)
        self.assertEqual(c.bank, 0)
        self.assertEqual(bytes(r.ram[start:end + 1]), payload)
        self.assertEqual(r.ram[0:start].count(HALT) + r.ram[end + 1:0x7400].count(HALT), 0x7400 - len(payload))
        self.assertEqual(bytes(r.ram[0x7600:0x76D0]), bytes([UPPER]) * 0xD0)
        self.assertEqual(bytes(r.ram[0x76D0:0x7FF5]), bytes(0x7FF5 - 0x76D0))
        self.assertEqual(bytes(r.ram[0x7FF5:0x8000]), bytes([UPPER]) * 11)
        # one CLS before the first payload byte, no monitor print after it
        prints = [i for i, e in enumerate(r.events) if e[0] == 'print']
        payload_copies = [i for i, e in enumerate(r.events) if e[0] == 'copy' and e[3] < 0x7400]
        self.assertEqual([r.events[i][1] for i in prints], [b'\x1f'])
        self.assertLess(prints[0], payload_copies[0])
        self.assertEqual(sum(e[2] - e[1] + 1 for e in r.events if e[0] == 'copy' and e[3] < 0x7400), len(payload))
        for e in r.events:
            if e[0] == 'copy':
                self.assertEqual(e[1] >> 9, e[2] >> 9, 'a copy crosses a sector: %r' % (e,))
        self.assertGreaterEqual(r.min_sp - emu8080.STUB_STACK, 0x75C0)
        return r

    def check_refused(self, name, message, image=None, **change):
        c = CardPpi(image if image is not None else self.image)
        ram = loader_ram(c, self.params(name, **change))
        select_bank(c, 5)
        r = run_loader(c, ram)
        self.assertEqual(r.pc, MONITOR)
        self.assertEqual(r.printed, b'\r\n' + message)
        self.assertEqual(c.bank, 0)
        self.assertEqual(bytes(r.ram[0:0x7400]), bytes([HALT]) * 0x7400)
        self.assertEqual(bytes(r.ram[0x7600:0x8000]), bytes([UPPER]) * 0xA00)
        self.assertFalse([e for e in r.events if e[0] == 'copy' and e[3] < 0x7400])
        return r


class Loader(LoaderCase):
    """Every file of the card through the loader."""

    @classmethod
    def card_files(cls):
        cls.tapes = fatcard.card_files(PK, asset('romdisk.bin'))
        return cls.tapes

    def test_every_file(self):
        self.assertEqual(len(self.tapes), 52)
        for name, data in self.tapes:
            with self.subTest(name):
                start, _, payload = build_romdisks.read_tape(data)
                self.check_load(name, start, payload)

    def test_a_file_across_banks(self):
        c = 2 + 255 - self.bpb['data_start']
        crossing = [n for n, _ in self.tapes if c in chain_of(self.image, n) and c + 1 in chain_of(self.image, n)]
        self.assertEqual(len(crossing), 1)


EDGES = [  # name, start, payload, form ('e6' raw, 'no' raw without E6, 'tape' with the checksum trailer)
    ('CROSS.RKR', 0x1234, 1019, 'e6'),     # sectors 255 (bank 1) and 256 (bank 2), ends at a sector edge
    ('E507.RKR', 0x0000, 507, 'e6'),       # 5 + 507 = 512
    ('E508.RKR', 0x0101, 508, 'e6'),       # one byte in a second sector
    ('E1.RKR', 0x73FF, 1, 'e6'),
    ('E1019.RKR', 0x2000, 1019, 'e6'),     # 5 + 1019 = 1024
    ('N508.RKR', 0x0000, 508, 'no'),       # 4 + 508 = 512
    ('N509.RKR', 0x3001, 509, 'no'),
    ('N1.RKR', 0x0005, 1, 'no'),
    ('N1020.RKR', 0x4000, 1020, 'no'),     # 4 + 1020 = 1024
    ('TRAIL.RKR', 0x1000, 600, 'tape'),
    ('TOP.RKR', 0x7300, 256, 'e6'),        # ends at 73FF
    ('LONG3.RKR', 0x0400, 1500, 'e6'),     # three clusters, for the chain cases
]


def edge_bytes(start, n, form, seed):
    data = pattern(n, seed)
    return tape.make_tape(start, data) if form == 'tape' else raw_tape(start, data, form == 'e6')


class LoaderEdges(LoaderCase):
    """Synthetic tapes: sector edges, both header forms, a fragmented file, banks 1 to 2, refusals."""

    @classmethod
    def card_files(cls):
        fill = b'\xff\xff\x00\x00' + bytes(31 * 512 - 4)        # clusters 2-32; end < start: not a tape
        files = [('FILL.DAT', fill)]
        files += [(n, edge_bytes(s, k, f, i)) for i, (n, s, k, f) in enumerate(EDGES)]
        files += [('OVER.RKR', raw_tape(0x7300, pattern(0x101, 1))),      # ends at 7400
                  ('HIGH.RKR', raw_tape(0x7F00, pattern(16, 2))),
                  ('SHORT4.RKR', b'\x01\x00\x01\x00'),                     # 4 < 4 + 1
                  ('HDR5.RKR', b'\xe6\x01\x00\x01\x00'),                   # 5 < 5 + 1
                  ('TRUNC.RKR', raw_tape(0x0100, pattern(100, 3))[:55]),   # 50 of 100 bytes
                  ('TEXT.TXT', b'hello world'),
                  ('EMPTY', b'')]
        return files

    @classmethod
    def more(cls, path):
        # the fragmented file: A, B, C, delete B, then D larger than B
        for n in ('FA.DAT', 'FB.DAT', 'FC.DAT'):
            fatcard.add_files(path, [(n, bytes([0x5A]) * 512)])
        fatcard.run_mtools('mdel', path, '::FB.DAT')
        fatcard.add_files(path, [('FD.RKR', raw_tape(0x0777, pattern(1500, 9)))])

    def test_edges(self):
        for i, (name, start, n, form) in enumerate(EDGES):
            with self.subTest(name):
                self.check_load(name, start, pattern(n, i))

    def test_edge_files_have_the_expected_chains(self):
        p = self.bpb
        cross = chain_of(self.image, 'CROSS.RKR')
        self.assertEqual([(p['data_start'] + c - 2) >> 7 for c in cross], [1, 2])
        self.assertEqual([len(chain_of(self.image, n)) for n in ('E507.RKR', 'E508.RKR', 'N508.RKR', 'N509.RKR',
                                                                 'E1019.RKR', 'N1020.RKR', 'LONG3.RKR')],
                         [1, 2, 1, 2, 2, 2, 3])
        self.assertGreater(self.dir['TRAIL.RKR']['size'], 5 + 600)

    def test_fragmented(self):
        chain = chain_of(self.image, 'FD.RKR')
        self.assertEqual(len(chain), 3)
        self.assertTrue(any(b != a + 1 for a, b in zip(chain, chain[1:])), chain)
        self.check_load('FD.RKR', 0x0777, pattern(1500, 9))

    def test_not_a_tape(self):
        for name in ('FILL.DAT', 'OVER.RKR', 'HIGH.RKR', 'SHORT4.RKR', 'HDR5.RKR', 'TRUNC.RKR', 'TEXT.TXT'):
            with self.subTest(name):
                self.check_refused(name, b'NOT A TAPE')

    def test_size_one_short(self):
        self.check_refused('E507.RKR', b'NOT A TAPE', size=511)
        self.check_refused('N1020.RKR', b'NOT A TAPE', size=1023)
        self.check_load('E507.RKR', 0x0000, pattern(507, 1), size=512)

    def test_bad_cluster(self):
        maxcl = self.bpb['clusters'] + 1
        self.check_refused('EMPTY', b'BAD FILE')
        self.assertEqual(self.dir['EMPTY']['cluster'], 0)
        for cluster in (0, 1, maxcl + 1, 0xFFFF):
            with self.subTest(cluster=cluster):
                self.check_refused('E1.RKR', b'BAD FILE', cluster=cluster)
        # MAXCL is the last valid cluster: a file there loads, one cluster lower refuses it
        e1 = self.dir['E1.RKR']['cluster']
        self.check_load('E1.RKR', 0x73FF, pattern(1, 3), maxcl=e1)
        self.check_refused('E1.RKR', b'BAD FILE', maxcl=e1 - 1)

    def fat_patched(self, name, index, value):
        chain = chain_of(self.image, name)
        b = bytearray(self.image)
        struct.pack_into('<H', b, self.bpb['fat_start'] * 512 + 2 * chain[index], value)
        return bytes(b)

    def test_corrupt_chain(self):
        maxcl = self.bpb['clusters'] + 1
        # the link to the last needed cluster: a copy-as-you-go loader would have written two sectors
        for value in (0, 1, 0xFFF0, 0xFFF7, 0xFFF8, 0xFFFF, maxcl + 1, 0x7000):
            with self.subTest(value='%04X' % value):
                self.check_refused('LONG3.RKR', b'BAD FILE', image=self.fat_patched('LONG3.RKR', 1, value))
        self.check_refused('LONG3.RKR', b'BAD FILE', image=self.fat_patched('LONG3.RKR', 0, 0xFFFF))

    def test_rerun_checks_before_copying(self):
        # G7400 again after a load: COPYF is left at 1 by the first run; the second run must still check
        # the whole chain before it writes a byte of RAM
        c = CardPpi(self.image)
        r = run_loader(c, loader_ram(c, self.params('LONG3.RKR')))
        self.assertEqual(r.pc, 0x0400)
        self.assertEqual(r.ram[self.loader_sym['COPYF']], 1)
        ram = bytearray(r.ram)
        ram[0:0x7400] = bytes([HALT]) * 0x7400
        bad = CardPpi(self.fat_patched('LONG3.RKR', 1, 0))
        r = run_loader(bad, ram)
        self.assertEqual(r.pc, MONITOR)
        self.assertEqual(r.printed, b'\r\nBAD FILE')
        self.assertEqual(bad.bank, 0)
        self.assertEqual(bytes(r.ram[0:0x7400]), bytes([HALT]) * 0x7400)
        self.assertFalse([e for e in r.events if e[0] == 'copy' and e[3] < 0x7400])

    def test_last_fat_entry_is_not_read(self):
        for value in (0, 1, 0xFFF7, 0x0005):
            with self.subTest(value='%04X' % value):
                self.check_load('LONG3.RKR', 0x0400, pattern(1500, 11), image=self.fat_patched('LONG3.RKR', 2, value))
                self.check_load('E507.RKR', 0x0000, pattern(507, 1), image=self.fat_patched('E507.RKR', 0, value))


class Boot(Tmp):
    def build(self):
        fatcard.build_image(self.img, [('A.RKR', tape.make_tape(0x100, b'abc'))], fatcard.assemble_boot(),
                            DUMMY_MENU, fatcard.assemble_loader())
        return read(self.img)

    def boot(self, image):
        """R0,1FF,0 (bank 0) then G0; stops at the menu or the monitor."""
        c = CardPpi(image)
        self.assertEqual((c.kind, c.bank), ('bank', 0))
        ram = bytearray(65536)
        ram[0:0x7400] = bytes([HALT]) * 0x7400
        ram[0x7400] = 0x5A
        ram[0x7600:0x8000] = bytes([UPPER]) * 0xA00
        ram[0:512] = fa68_copy(c, 0, 0x1FF)
        before = bytes(ram)
        r = emu8080.run_until(ram, 0, '', c, stop=lambda pc: pc in (0x6C00, MONITOR))
        self.assertEqual(c.bank, 0)
        return r, before

    def test_boot(self):
        r, before = self.boot(self.build())
        self.assertEqual(r.pc, 0x6C00)
        self.assertEqual(r.printed, b'')
        self.assertEqual(bytes(r.ram[0x6C00:0x7400]), DUMMY_MENU)
        self.assertEqual(bytes(r.ram[0:0x6C00]), before[0:0x6C00])
        self.assertEqual(r.ram[0x7400], 0x5A)
        self.assertEqual(r.events, [('copy', 0x200, 0x9FF, 0x6C00)])

    def test_bad_card(self):
        image = self.build()
        for offset, fmt, value in ((0x0B, '<H', 1024), (0x0B, '<H', 0x0201), (0x0D, 'B', 2), (0x0D, 'B', 0),
                                   (0x0E, '<H', 5), (0x10, 'B', 0), (0x13, '<H', 0),
                                   (0x13, '<H', 0x4001), (0x13, '<H', 0x4100), (0x13, '<H', 0xFFFF)):
            with self.subTest('%02X=%X' % (offset, value)):
                b = bytearray(image)
                struct.pack_into(fmt, b, offset, value)
                r, before = self.boot(bytes(b))
                self.assertEqual(r.pc, MONITOR)
                self.assertEqual(r.printed, b'\r\nBAD CARD')
                self.assertEqual(bytes(r.ram[0:0x7600]), before[0:0x7600])
        for offset, fmt, value in ((0x0E, '<H', 6), (0x0E, '<H', 0x100), (0x13, '<H', 0x4000), (0x13, '<H', 0x3FFF)):
            with self.subTest('%02X=%X' % (offset, value)):
                b = bytearray(image)
                struct.pack_into(fmt, b, offset, value)
                r, _ = self.boot(bytes(b))
                self.assertEqual(r.pc, 0x6C00)


# --- Task 4: the menu and the CLI --------------------------------------------------------------------

UP, DOWN, LEFT, RIGHT, CR = '\x19', '\x1a', '\x08', '\x18', '\r'
RULE = '-' * 56
FOOTER = 'UP/DOWN: MOVE   LEFT/RIGHT: PAGE   CR: RUN   Z: ZERO RAM'


def expected_screen(entries, page, line):
    """The 25 screen rows (right-stripped) of the menu at page and line (0-based) for menu_entries()."""
    n = len(entries)
    rows = ['RK86 CARD  %d FILES  PAGE %d/%d' % (n, page + 1, max(1, -(-n // 20))), RULE]
    for i in range(20):
        k = page * 20 + i
        if k < n:
            e = entries[k]
            text = '%04X-%04X' % (e['start'], e['end']) if e['runnable'] else '?'
            rows.append(('>' if i == line else ' ') + ' ' + e['shown'] + '   ' + text)
        else:
            rows.append('  NO FILES' if n == 0 and i == 0 else '')
    return [r.rstrip() for r in rows + [RULE, FOOTER, '']]


class StrictCard(CardPpi):
    """The card of the system TB: its PSRAM model refuses any address beyond the image."""

    def read_a(self):
        a = self.rom_address()
        if a >= len(self.image):
            raise emu8080.EmuError('card read at %06X beyond the image (%d bytes)' % (a, len(self.image)))
        return self.image[a]


class Machine:
    """The machine at the menu. The constructor runs R0,1FF,0 and G0 until the menu waits for a key;
    key() resumes at KEYWAIT (the menu keeps nothing on the stack there, so a restart with SP 76CF is the
    same machine) and replays the prints on a screen model. RAM 0200-6BFF holds a non-zero pattern."""

    def __init__(self, test, image, card=None):
        self.t = test
        self.card = card if card is not None else CardPpi(image)
        self.keywait = fatcard.assemble_menu()[1]['KEYWAIT']
        self.screen = emu8080.Screen()
        ram = bytearray(65536)
        ram[0x0200:0x6C00] = pattern(0x6A00, 5)
        ram[0:512] = fa68_copy(self.card, 0, 0x1FF)
        self.ram = ram
        r = self.check(emu8080.run_until(ram, 0, '', self.card, stop=lambda pc: pc == MONITOR))
        test.assertTrue(r.waiting, 'the menu does not wait for a key (pc %04X)' % r.pc)
        self.boot = r

    def check(self, r):
        self.screen.replay(r.events)
        if r.waiting:
            self.t.assertEqual(r.sp, 0x76CD)
            self.t.assertEqual(r.ram[0x76CD] | r.ram[0x76CE] << 8, self.keywait + 3)
            self.t.assertGreaterEqual(r.min_sp - emu8080.STUB_STACK, 0x7660)
            # bank 0 while the menu waits: Reset keeps the bank, so R0,1FF,0 must read the boot stage
            self.t.assertEqual(self.card.bank, 0, 'the bank at KEYWAIT')
            self.ram = bytearray(r.ram)
        return r

    def reset(self):
        """Core Settings > Reset at KEYWAIT, then R0,1FF,0 and G0: the card keeps its bank, RAM is kept,
        0000-01FF is read from the card's current bank; runs from 0000 until the menu waits again."""
        ram = bytearray(self.ram)
        ram[0:512] = fa68_copy(self.card, 0, 0x1FF)
        r = self.check(emu8080.run_until(ram, 0, '', self.card, stop=lambda pc: pc == MONITOR))
        self.t.assertTrue(r.waiting, 'the menu does not wait for a key after Reset (pc %04X)' % r.pc)
        return r

    def key(self, keys, start=None):
        """keys from KEYWAIT. With start: runs until the loader (7400-75FF) was entered and pc == start."""
        entered = [False]

        def stop(pc):
            if 0x7400 <= pc <= 0x75FF:
                entered[0] = True
            return start is not None and entered[0] and pc == start
        return self.check(emu8080.run_until(self.ram, self.keywait, keys, self.card, stop))

    def fork(self):
        m = copy.copy(self)
        m.card, m.screen, m.ram = copy.copy(self.card), copy.deepcopy(self.screen), bytearray(self.ram)
        return m


def menu_image(path, files, label=True):
    menu = fatcard.assemble_menu()[0]
    if label:
        fatcard.build_image(path, files, fatcard.assemble_boot(), menu, fatcard.assemble_loader())
    else:
        fatcard.format_image(path)
        fatcard.add_files(path, files)
        fatcard.install_bank0(path, fatcard.assemble_boot(), menu, fatcard.assemble_loader())
    return read(path)


class MenuAssembly(unittest.TestCase):
    def test_layout(self):
        code, sym = fatcard.assemble_menu()
        self.assertEqual(code[0:3], b'\x31\xcf\x76')                       # LXI SP,76CF at 6C00
        self.assertEqual(len(code), sym['MENUEND'] - 0x6C00)
        self.assertLessEqual(sym['MENUEND'], 0x7200)
        self.assertEqual(sym['DIRBUF'], 0x7200)
        kw = sym['KEYWAIT']
        self.assertTrue(0x6C00 <= kw < 0x7200)
        self.assertEqual(code[kw - 0x6C00:kw - 0x6C00 + 3], b'\xcd\x03\xf8')
        self.assertEqual(code.count(b'\xcd\x03\xf8'), 1)
        lsym = fatcard.loader_symbols()
        for k in ('FATSTART', 'DATASTART', 'CLUSTER', 'SIZE', 'MAXCL'):
            self.assertEqual(sym[k], lsym[k], k)
        self.assertEqual(sym['LOADER'], 0x7400)
        self.assertEqual([sym[k] - sym['MFAT'] for k in ('MFAT', 'MDATA', 'MCLUS', 'MSIZE', 'MMAX')],
                         [0, 2, 4, 6, 8])
        self.assertLessEqual({v for v in sym.values() if v >= 0xF800}, {0xF803, 0xF818, 0xFA68, 0xF86C})

    def test_limits(self):
        sym = fatcard.assemble_menu()[1]
        with mock.patch.object(fatcard, 'MENU_END', sym['MENUEND'] - 1):
            with self.assertRaisesRegex(ValueError, 'menu'):
                fatcard.assemble_menu()


class MenuCase(unittest.TestCase):
    """The 52-file card with the real menu, booted once; tests fork the machine at KEYWAIT."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.files = fatcard.card_files(PK, asset('romdisk.bin'))
        cls.image = menu_image(os.path.join(cls._tmp.name, 'card.img'), cls.files)
        cls.bpb = fatcard.bpb(cls.image)
        cls.entries = fatcard.menu_entries(cls.image)
        cls.dir = fatcard.directory(cls.image)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        if not hasattr(type(self), 'base'):
            type(self).base = Machine(self, self.image)
        self.m = self.base.fork()
        self.m.t = self

    def check_loader_entry(self, r, k, card):
        """Stopped at 7400: the loader from reserved sector 5 of bank 0 and its parameters for entry k."""
        self.assertEqual(r.pc, 0x7400)
        self.assertEqual(card.bank, 0)
        self.assertEqual(bytes(r.ram[0x7400:0x7403]), self.image[0x0A00:0x0A03])
        self.assertEqual(bytes(r.ram[0x740D:0x7600]), self.image[0x0A0D:0x0C00])
        self.assertEqual(bytes(r.ram[0x7403:0x740D]), struct.pack('<5H', *fatcard.loader_params(self.bpb, self.dir[k])))
        self.assertEqual(r.events[-1], ('copy', 0x0A00, 0x0BFF, 0x7400))

    def check_run(self, r, k, card):
        name, data = self.files[k]
        start, end, payload = build_romdisks.read_tape(data)
        self.assertFalse(r.waiting, name)
        self.assertEqual(r.pc, start, name)
        self.assertEqual(r.sp, 0x76CF, name)
        self.assertEqual(card.bank, 0, name)
        self.assertEqual(bytes(r.ram[start:end + 1]), payload, name)
        # the menu reads only into its own area (DIRBUF, HDR), then copies the loader once; the payload
        # comes after that
        copies = [e for e in r.events if e[0] == 'copy']
        loader = copies.index(('copy', 0x0A00, 0x0BFF, 0x7400))
        self.assertEqual(copies.count(copies[loader]), 1, name)
        self.assertTrue(all(0x6C00 <= e[3] and e[3] + e[2] - e[1] <= 0x73FF for e in copies[:loader]), name)
        self.assertEqual(sum(e[2] - e[1] + 1 for e in copies[loader + 1:] if e[3] < 0x7400), len(payload), name)


class Menu(MenuCase):
    def test_entries(self):
        self.assertEqual(len(self.entries), 52)
        self.assertEqual([e['file'] for e in self.entries], [n for n, _ in self.files])
        for e, (name, data) in zip(self.entries, self.files):
            start, end, _ = build_romdisks.read_tape(data)
            self.assertEqual((e['start'], e['end'], e['runnable']), (start, end, True), name)
            base, _, ext = name.partition('.')
            self.assertEqual(e['shown'], base.ljust(8) + ' ' + ext.ljust(3))

    def test_first_page(self):
        self.assertEqual(self.m.screen.lines(), expected_screen(self.entries, 0, 0))
        self.assertEqual(self.m.screen.lines()[0], 'RK86 CARD  52 FILES  PAGE 1/3')
        self.assertEqual(self.base.boot.printed.count(b'\x1f'), 1)

    def test_cursor_moves_only_the_marker(self):
        m = self.m
        r = m.key(DOWN)
        prints = [e[1] for e in r.events if e[0] == 'print']
        self.assertLessEqual(len(prints), 2)
        self.assertLessEqual(sum(len(p) for p in prints), 12)
        self.assertNotIn(0x1F, b''.join(prints))
        self.assertFalse([e for e in r.events if e[0] == 'copy'])
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 0, 1))
        m.key(UP)
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 0, 0))

    def test_paging(self):
        m, n = self.m, self.entries
        for keys, page, line, redraw in ((UP, 0, 0, None), (LEFT, 0, 0, None),
                                         (DOWN * 19, 0, 19, False), (DOWN, 1, 0, True),
                                         (UP, 0, 19, True), (DOWN, 1, 0, True), (DOWN * 3, 1, 3, False),
                                         (LEFT, 0, 0, True), (RIGHT, 1, 0, True), (RIGHT, 2, 0, True),
                                         (RIGHT, 2, 0, None), (DOWN * 25, 2, 11, False), (DOWN, 2, 11, None),
                                         (UP, 2, 10, False), (LEFT, 1, 0, True), (UP, 0, 19, True)):
            with self.subTest(keys=keys, page=page, line=line):
                r = m.key(keys)
                self.assertTrue(r.waiting)
                if redraw is None:
                    self.assertEqual(r.events, [])
                else:
                    self.assertEqual(b'\x1f' in r.printed, redraw)
                self.assertEqual(m.screen.lines(), expected_screen(n, page, line))
        self.assertEqual(m.screen.lines()[0], 'RK86 CARD  52 FILES  PAGE 1/3')

    def test_last_entry_cannot_be_passed(self):
        r = self.m.key(RIGHT * 5 + DOWN * 25 + CR, start=self.entries[51]['start'])
        self.check_run(r, 51, self.m.card)
        self.assertEqual(self.files[51][0], 'OTHELLO.RKR')

    def test_space_and_cr_start_the_loader(self):
        for key in (' ', CR):
            for k in (0, 23, 51):
                with self.subTest(key=key, entry=k):
                    m = self.base.fork()
                    page, line = divmod(k, 20)
                    r = m.key(RIGHT * page + DOWN * line + key, start=0x7400)
                    self.check_loader_entry(r, k, m.card)

    def test_unknown_keys_do_nothing(self):
        for key in ('\x03', 'A', '1', '\x1b', '\x7f', '\x0a'):
            with self.subTest(key=repr(key)):
                r = self.base.fork().key(key)
                self.assertTrue(r.waiting)
                self.assertEqual(r.events, [])

    def test_every_file(self):
        for k in range(len(self.entries)):
            with self.subTest(self.files[k][0]):
                m = self.base.fork()
                page, line = divmod(k, 20)
                r = m.key(RIGHT * page + DOWN * line + CR, start=self.entries[k]['start'])
                self.check_run(r, k, m.card)

    def test_zero(self):
        for key in ('Z', 'z'):
            with self.subTest(key=key):
                m = self.base.fork()
                before = bytes(m.ram)
                self.assertNotEqual(before[0x200:0x6C00], bytes(0x6A00))
                r = m.key(key)
                self.assertTrue(r.waiting)
                self.assertEqual(r.events, [])
                self.assertEqual(bytes(r.ram[0:0x6C00]), bytes(0x6C00))
                self.assertEqual(bytes(r.ram[0x6C00:0x7400]), before[0x6C00:0x7400])
                self.assertEqual(m.screen.lines(), expected_screen(self.entries, 0, 0))

    def test_reset_in_the_menu(self):
        # the menu read the root directory and the headers in bank 1; Reset at KEYWAIT keeps the bank, so
        # R0,1FF,0 and G0 reach the menu again only because the menu selected bank 0 before the key wait
        m = self.m
        m.key(RIGHT + DOWN * 2)
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 1, 2))
        r = m.reset()
        self.assertEqual(r.printed.count(b'\x1f'), 1)
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 0, 0))
        r = m.key(DOWN * 23 + CR, start=self.entries[23]['start'])
        self.check_run(r, 23, m.card)

    def test_bpb_read_once(self):
        # after Z (000B is 0) and with another valid-looking BPB at 0000, the menu still works from its copy
        m = self.m
        m.key('Z')
        m.key(RIGHT)                    # 000B-0017 all 0
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 1, 0))
        other = bytearray(self.image[0:512])
        struct.pack_into('<HBHBHHxH', other, 0x0B, 512, 1, 64, 2, 1024, 0x3000, 32)
        m.ram[0:512] = other
        m.key(LEFT + RIGHT)
        self.assertEqual(m.screen.lines(), expected_screen(self.entries, 1, 0))
        f = m.fork()
        r = f.key(DOWN * 3 + CR, start=0x7400)
        self.check_loader_entry(r, 23, f.card)
        r = m.key(DOWN * 3 + CR, start=self.entries[23]['start'])
        self.check_run(r, 23, m.card)


Q_FILES = [('GOOD.RKR', tape.make_tape(0x0100, pattern(40, 1))),
           ('TEXT.TXT', b'hello world'),
           ('EMPTY', b''),                                          # cluster 0
           ('HIGH.RKR', raw_tape(0x7F00, pattern(16, 2))),           # ends above 73FF
           ('OVER.RKR', raw_tape(0x7300, pattern(0x101, 3))),        # ends at 7400
           ('TRUNC.RKR', raw_tape(0x0100, pattern(100, 4))[:55]),    # 50 of 100 bytes
           ('BIG.RKR', raw_tape(0x0200, pattern(300, 5)))]           # its size patched to 64 KB + 305
Q_FILES += [('F%02d.RKR' % i, raw_tape(0x1000 + 0x100 * i, pattern(10 + i, 10 + i), i % 2 == 0))
            for i in range(14)]                                     # 21 files


class MenuSynthetic(Tmp):
    def machine(self, image, card=None):
        return Machine(self, image, card)

    def q_image(self):
        image = bytearray(menu_image(self.img, Q_FILES))
        p = fatcard.bpb(bytes(image))
        slot = next(e['slot'] for e in fatcard.directory(bytes(image)) if e['file'] == 'BIG.RKR')
        at = p['root_start'] * 512 + 32 * slot + 0x1C
        struct.pack_into('<I', image, at, struct.unpack_from('<I', image, at)[0] + 0x10000)
        return bytes(image)

    def test_question_marks(self):
        image = self.q_image()
        entries = fatcard.menu_entries(image)
        self.assertEqual([e['runnable'] for e in entries[:7]], [True] + [False] * 6)
        self.assertTrue(all(e['runnable'] for e in entries[7:]))
        self.assertEqual(entries[6]['start'], 0x0200)    # BIG has a valid header: only its size refuses it
        base = self.machine(image)
        self.assertEqual(base.screen.lines(), expected_screen(entries, 0, 0))
        for k in range(1, 7):
            with self.subTest(entries[k]['file']):
                m = base.fork()
                m.key(DOWN * k)
                before = bytes(m.ram)
                r = m.key(CR + ' ')
                # nothing happens: no print, no loader; the menu may read the card into its own area
                self.assertTrue(r.waiting)
                self.assertEqual(r.printed, b'')
                own = ((0x7200, 512), (fatcard.assemble_menu()[1]['HDR'], 5))   # DIRBUF, HDR
                self.assertTrue(all(e[0] == 'copy' and (e[3], e[2] - e[1] + 1) in own for e in r.events), r.events)
                self.assertEqual(bytes(r.ram[0:0x6C00]), before[0:0x6C00])
                self.assertEqual(bytes(r.ram[0x7400:0x7600]), before[0x7400:0x7600])
                self.assertEqual(m.screen.lines(), expected_screen(entries, 0, k))
        m = base.fork()
        r = m.key(CR, start=0x0100)
        self.assertEqual(bytes(r.ram[0x100:0x128]), pattern(40, 1))

    def test_21_and_20_files(self):
        image = self.q_image()
        entries = fatcard.menu_entries(image)
        self.assertEqual(len(entries), 21)
        m = self.machine(image)
        self.assertEqual(m.screen.lines()[0], 'RK86 CARD  21 FILES  PAGE 1/2')
        m.key(DOWN * 20)
        self.assertEqual(m.screen.lines(), expected_screen(entries, 1, 0))
        for key in (DOWN, RIGHT):
            self.assertEqual(m.key(key).events, [])
        m.key(UP)
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 19))
        # 20 files: a 00 name in the 21st entry's slot ends the listing
        b = bytearray(image)
        b[fatcard.bpb(image)['root_start'] * 512 + 32 * entries[20]['slot']] = 0
        entries = fatcard.menu_entries(bytes(b))
        self.assertEqual(len(entries), 20)
        m = self.machine(bytes(b))
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))
        self.assertEqual(m.screen.lines()[0], 'RK86 CARD  20 FILES  PAGE 1/1')
        self.assertEqual(m.key(RIGHT).events, [])
        m.key(DOWN * 19)
        self.assertEqual(m.key(DOWN).events, [])
        self.assertEqual(entries[19]['file'], 'F12.RKR')
        r = m.key(CR, start=0x1000 + 0x100 * 12)
        self.assertEqual(bytes(r.ram[0x1C00:0x1C00 + 22]), pattern(22, 22))

    def test_no_files(self):
        image = menu_image(self.img, [])
        self.assertEqual(fatcard.menu_entries(image), [])
        m = self.machine(image)
        self.assertEqual(m.screen.lines(), expected_screen([], 0, 0))
        self.assertEqual(m.screen.lines()[:3], ['RK86 CARD  0 FILES  PAGE 1/1', RULE, '  NO FILES'])
        for key in (UP, DOWN, LEFT, RIGHT, CR, ' '):
            self.assertEqual(m.key(key).events, [], repr(key))
        r = m.key('Z')
        self.assertEqual(bytes(r.ram[0:0x6C00]), bytes(0x6C00))

    def test_skipped_entries(self):
        # mcopy F1, a long name, F2, F3, mlabel, then mdel F2: a long-name set, an E5 slot and a label
        fatcard.format_image(self.img)
        fatcard.add_files(self.img, [('F1.RKR', raw_tape(0x0300, pattern(30, 1)))])
        with open(os.path.join(self.tmp, 'LongFileName.rkr'), 'wb') as f:
            f.write(raw_tape(0x0400, pattern(40, 2)))
        fatcard.run_mtools('mcopy', self.img, '-D', 'o', '-m', 'LongFileName.rkr', '::LongFileName.rkr')
        fatcard.add_files(self.img, [('F2.RKR', raw_tape(0x0500, pattern(50, 3)))])
        fatcard.add_files(self.img, [('F3.RKR', raw_tape(0x0600, pattern(60, 4)))])
        fatcard.label_image(self.img, 'RK86CARD')
        fatcard.run_mtools('mdel', self.img, '::F2.RKR')
        fatcard.install_bank0(self.img, fatcard.assemble_boot(), fatcard.assemble_menu()[0],
                              fatcard.assemble_loader())
        image = read(self.img)
        raw = raw_entries(image)
        self.assertTrue([e for _, e in raw if e[11] == 0x0F], 'no long-name entry')
        self.assertTrue([e for _, e in raw if e[0] == 0xE5], 'no deleted entry')
        self.assertTrue([e for _, e in raw if e[11] == 0x08], 'no label')
        entries = fatcard.menu_entries(image)
        self.assertEqual([e['file'] for e in entries], ['F1.RKR', fatcard.directory(image)[1]['file'], 'F3.RKR'])
        self.assertIn('~', entries[1]['file'])
        m = self.machine(image)
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))
        r = m.fork().key(DOWN + CR, start=0x0400)
        self.assertEqual(bytes(r.ram[0x400:0x428]), pattern(40, 2))
        r = m.fork().key(DOWN * 2 + CR, start=0x0600)
        self.assertEqual(bytes(r.ram[0x600:0x63C]), pattern(60, 4))
        # a 00 name in the deleted slot: the valid-looking F3 behind it is not listed
        b = bytearray(image)
        e5 = next(s for s, e in raw if e[0] == 0xE5)
        self.assertLess(e5, next(s for s, e in raw if e[:11] == b'F3      RKR'))
        b[fatcard.bpb(image)['root_start'] * 512 + 32 * e5] = 0
        entries = fatcard.menu_entries(bytes(b))
        self.assertEqual(len(entries), 2)
        m = self.machine(bytes(b))
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))
        m.key(DOWN)
        self.assertEqual(m.key(DOWN).events, [])                 # line 2 is the last entry
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 1))

    def test_name_bytes_outside_20_5f(self):
        image = bytearray(menu_image(self.img, [('F1.RKR', raw_tape(0x0300, pattern(30, 1))),
                                                ('F2.RKR', raw_tape(0x0400, pattern(30, 2)))]))
        root = fatcard.bpb(bytes(image))['root_start'] * 512
        slot = fatcard.directory(bytes(image))[0]['slot']
        image[root + 32 * slot:root + 32 * slot + 11] = b'\x9f\x9b\x8a\x41\x07\x60a\x20\x0d\xe5\x1f'
        entries = fatcard.menu_entries(bytes(image))
        self.assertEqual(entries[0]['shown'], '???A???  ???')
        m = self.machine(bytes(image))
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))

    def test_hidden_system_directory_skipped(self):
        files = [('F%d.RKR' % i, raw_tape(0x0300 + 0x100 * i, pattern(20, i))) for i in range(5)]
        image = bytearray(menu_image(self.img, files))
        root = fatcard.bpb(bytes(image))['root_start'] * 512
        for d, attr in zip(fatcard.directory(bytes(image))[1:4], (0x02, 0x04, 0x10)):
            image[root + 32 * d['slot'] + 11] = attr
        entries = fatcard.menu_entries(bytes(image))
        self.assertEqual([e['file'] for e in entries], ['F0.RKR', 'F4.RKR'])
        m = self.machine(bytes(image))
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))
        r = m.key(DOWN + CR, start=0x0700)
        self.assertEqual(bytes(r.ram[0x700:0x714]), pattern(20, 4))

    def test_maxcl_from_the_bpb(self):
        # MAXCL = total16 - DATASTART + 1, computed by the menu from its BPB copy: the last file's first
        # cluster is runnable when it is MAXCL, '?' one sector less (bpb() refuses such a small card, so
        # the expected screen is the full card's with that one line changed)
        image = self.q_image()
        entries = fatcard.menu_entries(image)
        p = fatcard.bpb(image)
        last = entries[19]
        self.assertEqual(fatcard.cluster_chain(image, last['file']), [last['cluster']])
        for total, runnable in ((p['data_start'] + last['cluster'] - 1, True),
                                (p['data_start'] + last['cluster'] - 2, False)):
            with self.subTest(total=total):
                b = bytearray(image)
                struct.pack_into('<H', b, 0x13, total)
                m = self.machine(bytes(b))
                want = [dict(e) for e in entries]
                want[19]['runnable'] = runnable
                self.assertEqual(m.screen.lines(), expected_screen(want, 0, 0))

    def test_card_reads_stay_in_the_image(self):
        # the system TB's card is 128 KB: banks 0 and 1 only
        image = menu_image(self.img, [('PITON.GAM', read(os.path.join(PK, 'PITON.GAM')))])[:131072]
        c = StrictCard(image)
        m = self.machine(image, c)
        r = m.key(CR, start=0x1100)
        self.assertEqual(bytes(r.ram[0x1100:0x1300]), pk_payload('PITON.GAM'))
        self.assertEqual(c.bank, 0)
        c = StrictCard(image)       # the strict card does refuse bank 2
        select_bank(c, 2)
        with self.assertRaisesRegex(emu8080.EmuError, 'beyond'):
            fa68_copy(c, 0, 0)

    def test_full_root_directory(self):
        # all 512 root entries used (the label, then 511 files), so no 00 entry ends the listing: the
        # title's 3-digit count, 26 pages, the last with the remaining 11 entries; the last file runs
        files = [('F%03d.RKR' % i, raw_tape(0x2000 + i, pattern(16, i))) for i in range(511)]
        image = menu_image(self.img, files)
        self.assertEqual(len(raw_entries(image)), 512)
        entries = fatcard.menu_entries(image)
        self.assertEqual([e['file'] for e in entries], [n for n, _ in files])
        self.assertEqual(entries[-1]['slot'], 511)
        self.assertTrue(all(e['runnable'] for e in entries))
        m = self.machine(image)
        self.assertEqual(m.screen.lines(), expected_screen(entries, 0, 0))
        self.assertEqual(m.screen.lines()[0], 'RK86 CARD  511 FILES  PAGE 1/26')
        m.key(RIGHT * 25)
        self.assertEqual(m.screen.lines(), expected_screen(entries, 25, 0))
        self.assertEqual(m.screen.lines()[0], 'RK86 CARD  511 FILES  PAGE 26/26')
        self.assertEqual([line[2:6] for line in m.screen.lines()[2:13]], ['F%03d' % i for i in range(500, 511)])
        self.assertEqual(m.screen.lines()[13:22], [''] * 9)
        self.assertEqual(m.key(RIGHT).events, [])
        m.key(DOWN * 10)
        self.assertEqual(m.key(DOWN).events, [])
        self.assertEqual(m.screen.lines(), expected_screen(entries, 25, 10))
        r = m.key(CR, start=0x2000 + 510)
        self.assertFalse(r.waiting)
        self.assertEqual(bytes(r.ram[0x2000 + 510:0x2000 + 510 + 16]), pattern(16, 510))
        self.assertEqual(m.card.bank, 0)


class Cli(Tmp):
    def test_cli(self):
        asset('romdisk.bin')
        fatcard.main(['--out', self.tmp, '--sim'])
        # the full image is a .bin: the Pocket's ROM disk slot (data.json slot 2) lists only .bin files
        self.assertEqual(sorted(os.listdir(self.tmp)),
                         ['card-sim.img', 'card-sim.json', 'fatcard.bin', 'fatcard.json'])
        with open(os.path.join(ROOT, 'package', 'core', 'data.json'), encoding='utf-8') as f:
            slot = next(s for s in json.load(f)['data']['data_slots'] if s['id'] == 2)
        self.assertIn('bin', slot['extensions'])
        image = read(os.path.join(self.tmp, 'fatcard.bin'))
        self.assertEqual(len(image), slot['size_maximum'])
        with open(os.path.join(self.tmp, 'fatcard.json'), encoding='utf-8') as f:
            meta = json.load(f)
        keywait = fatcard.assemble_menu()[1]['KEYWAIT']
        self.assertEqual(meta['keywait'], keywait)
        self.assertEqual(meta['files'], fatcard.directory(image))
        self.assertEqual(len(meta['files']), 52)
        sim = read(os.path.join(self.tmp, 'card-sim.img'))
        self.assertEqual(len(sim), 131072)
        with open(os.path.join(self.tmp, 'card-sim.json'), encoding='utf-8') as f:
            smeta = json.load(f)
        self.assertEqual(smeta, {'keywait': keywait, 'file': 'PITON.GAM', 'size': 131072,
                                 'start': 0x1100, 'length': 512, 'offset': 114693})
        self.assertEqual(sim[114693:114693 + 512], pk_payload('PITON.GAM'))
        self.assertEqual(fatcard.menu_entries(sim + bytes(8388608 - 131072))[0]['file'], 'PITON.GAM')
        # the Python twin of the system scenario fatcard: boot, CR on the first entry, PITON started
        c = StrictCard(sim)
        m = Machine(self, sim, c)
        self.assertEqual(m.keywait, smeta['keywait'])
        r = m.key(CR, start=smeta['start'])
        self.assertEqual(bytes(r.ram[0x1100:0x1300]), sim[smeta['offset']:smeta['offset'] + smeta['length']])
        self.assertEqual((r.pc, r.sp, c.bank), (0x1100, 0x76CF, 0))

    def test_repo_relative_out(self):
        self.assertEqual(fatcard.repo_path(os.path.join('build', 'fatcard')),
                         os.path.join(ROOT, 'build', 'fatcard'))
        self.assertEqual(fatcard.repo_path(self.tmp), self.tmp)


if __name__ == '__main__':
    unittest.main()
