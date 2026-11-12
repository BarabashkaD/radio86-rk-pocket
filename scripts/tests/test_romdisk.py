"""Tests of scripts/romdisk: the 8080 assembler, the loaders, the emulator, the disk build."""
import hashlib
import os
import sys
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'romdisk'))
import asm8080  # noqa: E402
import build_romdisks  # noqa: E402
import emu8080  # noqa: E402
import loader  # noqa: E402

ASSETS = os.path.join(ROOT, 'build', 'assets')
PK = os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'pk')
KISELEV_LOADER_SHA256 = 'f46be1e22c06e39a0cd1bdeb56bcd28f4356cce505d7e13571fc6c992a82b044'


def asset(name):
    path = os.path.join(ASSETS, name)
    if not os.path.exists(path):
        raise unittest.SkipTest('%s missing: run python -B scripts/fetch_assets.py' % name)
    with open(path, 'rb') as f:
        return f.read()


class Assembler(unittest.TestCase):
    def test_kiselev_loader_is_byte_exact(self):
        org, code, _ = asm8080.assemble(asset('rom_loader.asm').decode('ascii'))
        self.assertEqual(org, 0x7400)
        self.assertEqual(len(code), 512)
        self.assertEqual(hashlib.sha256(code).hexdigest(), KISELEV_LOADER_SHA256)
        self.assertEqual(code, asset('romdisk.bin')[:512])

    def test_encodings(self):
        src = '\tORG 100H\nX:\tLXI SP,76CFH\n\tMVI M,0\n\tJNC X\n\tDB "AB",0DH,\'Z\'\n\tDW X,X-1\n'
        org, code, sym = asm8080.assemble(src)
        self.assertEqual(org, 0x100)
        self.assertEqual(sym['X'], 0x100)
        self.assertEqual(code.hex(), '31cf763600d20001' + '41420d5a' + '0001ff00')

    def test_errors(self):
        for bad in ('\tORG 0\n\tFOO A\n', '\tORG 0\n\tJMP NOWHERE\n', '\tORG 0\n\tMVI A,100H\n',
                    '\tORG 10H\n\tNOP\n\tORG 0\n\tNOP\n\tNOP\n\tNOP\n\tORG 10H\n\tNOP\n'):
            with self.assertRaises(asm8080.AsmError):
                asm8080.assemble(bad)


def fake_rom(entries_bytes):
    """A ROM disk with the games loader and the given (name, ram, payload) entries from 0200H."""
    entries, body, at = [], b'', 0x200
    for name, ram, data in entries_bytes:
        entries.append((name, at, at + len(data) - 1, ram))
        body += data
        at += len(data)
    rom = loader.games_loader('ROM-DISK/32K GAMES 9/9', entries) + body
    return rom + b'\xff' * (32256 - len(rom)), entries


class GamesLoader(unittest.TestCase):
    def setUp(self):
        self.games = [('G%d' % i, 0x1000 * (i % 7), bytes([(i * 7 + k) & 0xff for k in range(40 + i)]))
                      for i in range(13)]
        self.rom, self.entries = fake_rom(self.games)

    def test_size_and_prefix(self):
        code = loader.games_loader('T', [('A', 0x200, 0x2ff, 0)])
        self.assertEqual(len(code), 512)
        self.assertEqual(code[0x1c:0x1f], bytes([0xcd, 0x03, 0xf8]))  # CALL GETCH at 741C (system TB to_menu)

    def test_every_key_loads_and_starts_its_game(self):
        for i, (name, ram, data) in enumerate(self.games):
            r = emu8080.run_menu(self.rom, loader.KEYS[i])
            self.assertEqual(r.pc, ram, name)
            self.assertEqual(bytes(r.ram[ram:ram + len(data)]), data, name)
            self.assertEqual(r.copies, [(self.entries[i][1], self.entries[i][2], ram)])
            self.assertTrue(r.printed.endswith(b'\x1f'), name)

    def test_menu_text(self):
        with self.assertRaises(emu8080.WaitKey):
            emu8080.run_menu(self.rom, '')
        r = emu8080.run_menu(self.rom, '0')
        text = r.printed.decode('ascii')
        self.assertIn('ROM-DISK/32K GAMES 9/9', text)
        self.assertIn('<9>-G9\r\n<A>-G10', text)
        self.assertIn('<C>-G12\r\n\r\n<Z>-ZERO RAM', text)

    def test_other_keys_show_the_menu_again(self):
        r = emu8080.run_menu(self.rom, '/:@D' + chr(0x60) + chr(0x7f) + ' 3')
        self.assertEqual(r.menus, 8)  # the first menu and 7 refused keys
        self.assertEqual(r.pc, self.games[3][1])

    def test_zero_ram_then_game(self):
        r = emu8080.run_menu(self.rom, 'Z1')
        g = self.games[1]
        self.assertEqual(r.pc, g[1])
        self.assertTrue(all(b == 0 for b in r.ram[g[1] + len(g[2]):0x7400]))
        self.assertEqual(r.menus, 2)

    def test_menu_again_after_a_game(self):
        # Reset keeps the RAM; G7416 shows the menu of the loader left at 7400. The copy and the CLS print run on
        # the monitor's stack (76CF), so the table is intact: the same entry and the one before it load again.
        for i, (name, ram, data) in enumerate(self.games):
            after = emu8080.run_menu(self.rom, loader.KEYS[i]).ram
            self.assertEqual(bytes(after[0x7400:0x7600]), self.rom[:512], name)
            for j in (i, i - 1) if i else (i,):
                r = emu8080.run_menu(self.rom, loader.KEYS[j], ram=after, start=emu8080.LOADER_MENU)
                self.assertEqual(r.copies, [(self.entries[j][1], self.entries[j][2], self.games[j][1])], name)
                self.assertEqual(r.pc, self.games[j][1], name)

    def test_game_starts_with_the_monitor_stack(self):
        code, symbols = loader.assemble_games('T', [('A', 0x200, 0x2ff, 0)])
        run = symbols['RUN'] - 0x7400
        self.assertEqual(code[run:run + 8], bytes([0xf9, 0xe1, 0xd1, 0xc1, 0x31, 0xcf, 0x76, 0xc5]))

    def test_menu_length(self):
        entry = ('N', 0x200, 0x200, 0)
        self.assertEqual(len(loader.games_loader('T', [entry] * loader.MAX_ENTRIES)), 512)
        with self.assertRaises(ValueError):
            loader.games_loader('T', [entry] * (loader.MAX_ENTRIES + 1))
        self.assertEqual(loader.MAX_ENTRIES, 19)

    def test_limits(self):
        with self.assertRaises(ValueError):
            loader.games_loader('T', [('N', 0x200, 0x200, 0)] * 36)
        with self.assertRaises(ValueError):
            loader.games_loader('T', [('NAME-%02d-LONG-NAME' % i, 0x200, 0x200, 0) for i in range(30)])
        with self.assertRaises(ValueError):
            loader.games_loader('t', [('A', 0x200, 0x200, 0)])

    def test_kiselev_loader_in_the_emulator(self):
        rom = asset('romdisk.bin')
        r = emu8080.run_menu(rom, '6')  # TETRIS: ROM 77A0-7DFF to 3000, started at 3000
        self.assertEqual(r.pc, 0x3000)
        self.assertEqual(bytes(r.ram[0x3000:0x3660]), rom[0x77a0:0x7e00])


def tape(start, payload, gam=False):
    s = 0
    for b in payload[:-1]:
        s = (s + b + (b << 8)) & 0xffff
    s = (s & 0xff00) | ((s + payload[-1]) & 0xff)
    end = start + len(payload) - 1
    head = bytes([0xe6]) if gam else b''
    return head + bytes([start >> 8, start & 0xff, end >> 8, end & 0xff]) + payload + bytes([0, 0, 0xe6, s >> 8, s & 0xff])


class Build(unittest.TestCase):
    def test_read_tape(self):
        p = bytes(range(1, 200))
        self.assertEqual(build_romdisks.read_tape(tape(0x1100, p)), (0x1100, 0x1100 + len(p) - 1, p))
        self.assertEqual(build_romdisks.read_tape(tape(0, p, gam=True))[2], p)
        bad = bytearray(tape(0, p))
        bad[10] ^= 1
        with self.assertRaises(ValueError):
            build_romdisks.read_tape(bytes(bad))
        with self.assertRaises(ValueError):
            build_romdisks.read_tape(tape(0, p)[:-3])

    def test_the_five_disks(self):
        if not os.path.isdir(PK):
            self.skipTest('core submodule not checked out')
        disks = build_romdisks.build(PK)
        self.assertEqual(len(disks), 5)
        files = sorted(e['file'] for d in disks for e in d['entries'])
        self.assertEqual(len(files), 48)
        self.assertEqual(len(set(files)), 48)
        for d in disks:
            self.assertEqual(len(d['image']), 65536)
            self.assertIn(b'ROM-DISK/64K GAMES %d/5' % d['disk'], d['image'][:0x200])
            for i, e in enumerate(d['entries']):
                self.assertEqual(e['key'], loader.KEYS[i])
                with open(os.path.join(PK, e['file']), 'rb') as f:
                    raw = f.read()
                start, end, payload = build_romdisks.read_tape(raw)
                self.assertEqual(d['image'][e['rom']:e['end'] + 1], payload)
                self.assertEqual(e['ram'], start)
                r = emu8080.run_menu(d['image'], e['key'])
                self.assertEqual(r.pc, start, e['file'])
                self.assertEqual(bytes(r.ram[start:start + len(payload)]), payload, e['file'])
        # every disk uses its upper 32 KB (the 64 KB wiring, PC7 = ROM A15)
        self.assertTrue(all(any(e['end'] >= 0x8000 for e in d['entries']) for d in disks))
        names2 = [e['name'] for e in disks[1]['entries']]
        self.assertIn('KRESTNO.GAM', names2)
        self.assertIn('KRESTNO.RKR', names2)
        # the system scenario game (fpga/sim/run_sim.py): XONIX1 on disk 2, above 8000h
        xonix1 = next(e for e in disks[1]['entries'] if e['file'] == 'XONIX1.RKR')
        self.assertGreaterEqual(xonix1['rom'], 0x8000)

    def test_readme_game_list_is_current(self):
        if not os.path.isdir(PK):
            self.skipTest('core submodule not checked out')
        meta = build_romdisks.metadata(build_romdisks.build(PK), build_romdisks.descriptions(PK))
        with open(os.path.join(ROOT, 'README.md'), encoding='utf-8') as f:
            text = f.read()
        begin, end = text.find(build_romdisks.README_BEGIN), text.find(build_romdisks.README_END)
        self.assertTrue(0 <= begin < end, 'README.md: game-disk markers missing')
        section = text[begin + len(build_romdisks.README_BEGIN):end].strip('\n')
        self.assertEqual(section, build_romdisks.readme_list(meta),
                         'README.md game list is stale: python -B scripts/romdisk/build_romdisks.py --readme')


if __name__ == '__main__':
    unittest.main()
