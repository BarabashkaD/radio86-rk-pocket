"""Tests of the J6 bank card model (scripts/romdisk/card_model.py) and its use in the 8080 emulator."""
import os
import sys
import unittest
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'romdisk'))
import asm8080  # noqa: E402
import card  # noqa: E402
import card_model  # noqa: E402
import emu8080  # noqa: E402
import loader  # noqa: E402
from card_model import CardPpi, fa68_copy  # noqa: E402


def image(size):
    return bytes(zlib.crc32(a.to_bytes(3, 'little')) & 0xFF for a in range(size))


IMG = image(256 * 1024)


def event(card, c_before, pb, c_after=0x7F):
    """Mode 90h, port C = c_before, port B = pb, port C = c_after."""
    card.write(3, 0x90)
    card.write(2, c_before)
    card.write(1, pb)
    card.write(2, c_after)


class CardModel(unittest.TestCase):
    def test_event_ff_to_7f(self):
        c = CardPpi(IMG)
        c.write(3, 0x90)
        c.write(2, 0xFF)
        c.write(1, 0x03)
        self.assertNotEqual(c.bank, 3)
        c.write(3, 0x0E)  # bit reset PC7
        self.assertEqual(c.bank, 3)
        self.assertEqual(c.rom_address(), 0x037F03)
        self.assertEqual(c.read_a(), IMG[0x037F03])

    def test_event_from_80_to_fe(self):
        for before, pb in ((0x80, 0x05), (0xC3, 0x09), (0xFE, 0x0C)):
            c = CardPpi(IMG)
            c.write(3, 0x90)
            c.write(2, before)
            c.write(1, pb)
            self.assertNotEqual(c.bank, pb)
            c.write(2, 0x7F)
            self.assertEqual(c.bank, pb, hex(before))

    def test_pb7_ignored(self):
        c = CardPpi(IMG)
        event(c, 0xFF, 0x83)
        self.assertEqual(c.bank, 3)

    def test_no_event(self):
        c = CardPpi(IMG)
        event(c, 0xFF, 0x02)
        self.assertEqual(c.bank, 2)
        c.write(1, 0x55)
        for _ in range(2):  # FF -> 7E: PC0 low
            c.write(2, 0xFF)
            c.write(2, 0x7E)
            self.assertEqual(c.bank, 2)
        c.write(2, 0x7F)  # 7E -> 7F: PC7 stays low
        self.assertEqual(c.bank, 2)
        c.write(2, 0x7F)  # 7F -> 7F again
        self.assertEqual(c.bank, 2)
        for after in (0x3F, 0x00):  # FF -> 3F, FF -> 00
            c.write(2, 0xFF)
            c.write(2, after)
            self.assertEqual(c.bank, 2, hex(after))
        c.write(2, 0x7E)
        c.write(2, 0x7F)  # 7E -> 7F
        self.assertEqual(c.bank, 2)
        c.write(2, 0x7F)
        c.write(3, 0x0F)  # BSR set PC7 from 7F: a rise
        self.assertEqual(c.bank, 2)
        c.write(2, 0xFF)
        c.write(3, 0x00)  # BSR reset PC0: FF -> FE
        c.write(3, 0x0E)  # BSR reset PC7 from FE: FE -> 7E, PC0 low
        self.assertEqual(c.bank, 2)
        c.write(2, 0xFF)
        c.write(3, 0x90)  # mode set from FF: ports 00
        self.assertEqual(c.bank, 2)
        c.write(1, 0x55)  # the mode set cleared port B
        c.write(2, 0x7F)  # 00 -> 7F is no fall of PC7
        self.assertEqual(c.bank, 2)
        fa68_copy(c, 0x0000, 0xFFFF)
        self.assertEqual(c.bank, 2)
        data = fa68_copy(c, 0xFFF0, 0x000F)  # wrap
        self.assertEqual(c.bank, 2)
        self.assertEqual(len(data), 32)
        self.assertEqual(data, bytes(IMG[2 << 16 | ((0xFFF0 + k) & 0xFFFF)] for k in range(32)))

    def test_bsr_event_with_pins(self):
        # Port C FF then BSR reset PC7 is the SELBK event.
        c = CardPpi(IMG)
        c.write(3, 0x90)
        c.write(2, 0xFF)
        c.write(1, 0x06)
        c.write(3, 0x0E)
        self.assertEqual(c.bank, 6)

    def test_reset_state_has_no_event(self):
        c = CardPpi(IMG)
        self.assertEqual((c.pb, c.pc, c.bank), (0xFF, 0xFF, 0))
        c.write(3, 0x9B)  # all inputs: pins stay high
        self.assertEqual((c.pb, c.pc, c.bank), (0xFF, 0xFF, 0))

    def test_mode_set_clears_latches_and_reads_back(self):
        c = CardPpi(IMG)
        c.write(3, 0x90)
        self.assertEqual((c.read(1), c.read(2), c.read(3)), (0x00, 0x00, 0xFF))
        c.write(1, 0x12)
        c.write(2, 0xA5)
        self.assertEqual((c.read(1), c.read(2)), (0x12, 0xA5))
        c.write(3, 0x9B)  # B and C inputs
        self.assertEqual((c.read(1), c.read(2)), (0xFF, 0xFF))

    def test_only_mode_0(self):
        for control in (0xA0, 0xC0, 0x94):
            with self.assertRaises(ValueError):
                CardPpi(IMG).write(3, control)

    def test_card_types(self):
        small = CardPpi(image(32768))
        small.write(3, 0x90)
        small.write(1, 0x34)
        small.write(2, 0x05)
        a, v = small.rom_address(), small.read_a()
        small.write(2, 0x85)
        self.assertEqual((small.rom_address(), small.read_a()), (a, v))
        self.assertEqual(a, 0x0534)
        edge = CardPpi(image(32769))  # the smallest image with A15 used
        edge.write(3, 0x90)
        edge.write(2, 0x85)
        self.assertEqual(edge.rom_address(), 0x8500)
        mid_image = image(40000)
        mid = CardPpi(mid_image)
        mid.write(3, 0x90)
        mid.write(2, 0x85)
        self.assertEqual(mid.rom_address(), 0x8500)
        self.assertEqual(mid.read_a(), mid_image[0x8500])
        for size in (32768, 65536, 32769):
            c = CardPpi(image(size))
            event(c, 0xFF, 0x05)
            self.assertEqual(c.bank, 0)
            self.assertLess(c.rom_address(), 65536)

    def test_card_type_boundaries(self):
        c = CardPpi(image(65536))
        event(c, 0xFF, 0x05)
        self.assertLess(c.rom_address(), 65536)
        c = CardPpi(image(65537))
        event(c, 0xFF, 0x05)
        self.assertEqual(c.bank, 5)
        c = CardPpi(image(card_model.MAX_IMAGE))
        event(c, 0xFF, 0x7F)
        self.assertEqual(c.bank, 127)
        c.write(1, 0xFF)
        c.write(2, 0x7F)
        self.assertEqual(c.rom_address(), 0x7F7FFF)
        c.write(2, 0xFF)
        self.assertEqual(c.rom_address(), 0x7FFFFF)
        self.assertEqual(c.read_a(), c.image[-1])
        with self.assertRaises(ValueError):
            CardPpi(bytes(card_model.MAX_IMAGE + 1))
        empty = CardPpi(b'')
        empty.write(3, 0x90)
        self.assertEqual(empty.read_a(), 0xFF)

    def test_card_reset(self):
        c = CardPpi(IMG)
        event(c, 0xFF, 0x04)
        self.assertEqual(c.bank, 4)
        c.card_reset()
        self.assertEqual(c.bank, 0)


class Recording(CardPpi):
    def __init__(self, image):
        super().__init__(image)
        self.log = []

    def write(self, reg, value):
        self.log.append(('w', reg, value))
        super().write(reg, value)

    def read_a(self):
        self.log.append(('r',))
        return super().read_a()


PROGRAM = '''
\tORG 7400H
\tMVI B,2
\tMVI A,90H
\tSTA 0A003H
\tMVI A,0FFH
\tSTA 0A002H
\tMOV A,B
\tSTA 0A001H
\tMVI A,0EH
\tSTA 0A003H
\tLDA 0A000H
\tSTA 3000H
\tLXI H,0
\tLXI D,1FFH
\tLXI B,1000H
\tCALL 0FA68H
\tJMP 0
'''


class EmulatorCard(unittest.TestCase):
    def test_copy_through_card(self):
        org, code, _ = asm8080.assemble(PROGRAM)
        self.assertEqual(org, 0x7400)
        ram = bytearray(65536)
        ram[0x7400:0x7400 + len(code)] = code
        card = Recording(IMG)
        res = emu8080.run_menu(b'', '', ram=ram, start=0x7400, card=card)
        self.assertEqual(res.pc, 0)
        self.assertEqual(card.bank, 2)
        self.assertEqual(res.ram[0x3000], IMG[0x027F02])
        self.assertEqual(bytes(res.ram[0x1000:0x1200]), IMG[0x20000:0x20200])
        # The SELBK writes and the LDA, then the stub: mode set, then per byte B, C, one read of port A.
        prefix = [('w', 3, 0x90), ('w', 2, 0xFF), ('w', 1, 2), ('w', 3, 0x0E), ('r',)]
        stub = [('w', 3, 0x90)]
        for a in range(512):
            stub += [('w', 1, a & 0xFF), ('w', 2, a >> 8), ('r',)]
        self.assertEqual(card.log, prefix + stub)

    def test_card_ports_are_not_ram(self):
        card = CardPpi(IMG)
        ram = emu8080.CardRam(65536)
        ram.card = card
        ram[0xA003] = 0x90
        ram[0xA001] = 0x42
        self.assertEqual(ram[0xA001], 0x42)  # port B reads its pin
        self.assertEqual(ram[0xA001:0xA002], b'\x00')  # not stored in RAM
        self.assertEqual(ram[0x9FFF], 0)

    def test_no_card_unchanged(self):
        rom = image(512)
        ram = bytearray(65536)
        res = emu8080.run_menu(rom, '', ram=ram, start=0x7400)  # zeros: NOPs run into the loader range end
        self.assertIs(type(res.ram), bytearray)


def padded(data, size):
    return bytes(data) + b'\xff' * (size - len(data))


MENU = bytes(range(256)) * 2  # any 512 bytes for the layout tests


class CardImage(unittest.TestCase):
    def test_layout(self):
        d1, d2 = image(32256), image(65536)
        menu = card.assemble_menu('TEST CARD', ['ONE', 'TWO'])[0]
        img = card.card_image(menu, [d1, d2])
        self.assertEqual(len(img), 3 * 65536)
        self.assertEqual(img[:65536], padded(menu, 65536))
        self.assertEqual(img[65536:2 * 65536], padded(d1, 32768) * 2)
        self.assertEqual(img[2 * 65536:], d2)

    def test_boundaries(self):
        d32, d32p, d64 = image(32768), image(32769), image(65536)
        img = card.card_image(MENU, [d32, d32p, d64])
        self.assertEqual(len(img), 4 * 65536)
        self.assertEqual(img[:65536], padded(MENU, 65536))
        self.assertEqual(img[65536:2 * 65536], d32 * 2)
        self.assertEqual(img[2 * 65536:3 * 65536], padded(d32p, 65536))
        self.assertEqual(img[3 * 65536:], d64)
        one = card.card_image(MENU, [b'\x01'])
        self.assertEqual(len(one), 131072)
        self.assertEqual(one[65536:], padded(b'\x01', 32768) * 2)

    def test_limits(self):
        names = ['N%d' % i for i in range(20)]
        for bad in (names, ['GAME', 'lower'], [''], ['A' * 17]):
            with self.assertRaises(ValueError, msg=repr(bad)):
                card.assemble_menu('TITLE', bad)
        with self.assertRaises(ValueError):
            card.assemble_menu('Title', ['GAME'])
        with self.assertRaises(ValueError):
            card.assemble_menu('TITLE', [])
        for menu, disks in ((MENU, [b'\x00'] * 20), (MENU, [bytes(65537)]), (MENU, []), (MENU, [b'']),
                            (MENU[:511], [b'\x00'])):
            with self.assertRaises(ValueError, msg='%d bytes menu, %d disks' % (len(menu), len(disks))):
                card.card_image(menu, disks)

    def test_fit(self):
        names = [chr(ord('A') + i) * 16 for i in range(loader.MAX_ENTRIES)]
        try:
            code, _ = card.assemble_menu('J6 BANK CARD', names)
        except ValueError:
            pass
        else:
            self.assertEqual(len(code), 512)
        code, _ = card.assemble_menu('J6 BANK CARD', ['GAMES %d' % i for i in range(1, 8)])
        self.assertEqual(len(code), 512)


def games_disk(i):
    """Disk i: the games loader with one entry (0200-020F to 1000), 16 distinct bytes, FF to 65536."""
    title = 'GAMES DISK %d' % i
    body = bytes((i * 16 + j) & 0xFF for j in range(16))
    data = loader.games_loader(title, [('GAME', 0x200, 0x20F, 0x1000)]) + body
    return title, padded(data, 65536)


class CardMenu(unittest.TestCase):
    def test_menu_fits(self):
        code, symbols = card.assemble_menu('TEST CARD', ['ONE', 'TWO', 'THREE'])
        self.assertEqual(len(code), 512)
        kw = symbols['KEYWAIT']
        self.assertTrue(0x7400 <= kw <= 0x75FF, hex(kw))
        self.assertEqual(code[kw - 0x7400:kw - 0x7400 + 3], b'\xcd\x03\xf8')  # CALL 0F803H
        # Stage 1: LXI H,0 / LXI D,1FFH / LXI B,7400H / CALL 0FA68H / JMP MAIN.
        self.assertEqual(code[:12], bytes([0x21, 0, 0, 0x11, 0xFF, 0x01, 0x01, 0x00, 0x74, 0xCD, 0x68, 0xFA]))
        self.assertEqual(code[12], 0xC3)
        self.assertEqual(code[13] | code[14] << 8, symbols['MAIN'])
        self.assertEqual(code[-1], 0xFF)

    def test_every_key_starts_its_disk_loader(self):
        names = ['FIRST', 'SECOND', 'THIRD']
        disks = [games_disk(i) for i in range(3)]
        menu = card.assemble_menu('TEST CARD', names)[0]
        img = card.card_image(menu, [d for _, d in disks])
        for i, (title, d) in enumerate(disks):
            key = loader.KEYS[i]
            c = CardPpi(img)
            r = emu8080.run_menu(img, key, card=c)
            self.assertEqual(r.pc, 0, key)
            self.assertEqual(c.bank, i + 1, key)
            self.assertEqual(bytes(r.ram[0:0x200]), d[:0x200], key)
            for k, n in enumerate(names):
                self.assertIn(('<%s>-%s' % (loader.KEYS[k], n)).encode('ascii'), r.printed)
            self.assertIn(b'TEST CARD', r.printed)
            r2 = emu8080.run_menu(img, '0', ram=r.ram, card=c)
            self.assertIn(title.encode('ascii'), r2.printed, key)
            self.assertEqual(r2.pc, 0x1000, key)
            self.assertEqual(bytes(r2.ram[0x1000:0x1010]), d[0x200:0x210], key)
            self.assertEqual(r2.copies, [(0x200, 0x20F, 0x1000)], key)

    def test_bad_key_shows_menu_again(self):
        disks = [games_disk(i)[1] for i in range(3)]
        img = card.card_image(card.assemble_menu('TEST CARD', ['A', 'B', 'C'])[0], disks)
        c = CardPpi(img)
        r = emu8080.run_menu(img, '/:@D' + chr(0x60) + chr(0x7F) + ' 3' + '0', card=c)
        self.assertEqual(r.menus, 9)
        self.assertEqual(r.pc, 0)
        self.assertEqual(c.bank, 1)
        self.assertEqual(bytes(r.ram[0:0x200]), disks[0][:0x200])


ASSETS = os.path.join(ROOT, 'build', 'assets')


def asset(name):
    path = os.path.join(ASSETS, name)
    if not os.path.exists(path):
        raise unittest.SkipTest('%s missing: run python -B scripts/fetch_assets.py' % name)
    with open(path, 'rb') as f:
        return f.read()


class CardKiselev(unittest.TestCase):
    def test_kiselev_in_a_card(self):
        kiselev = asset('romdisk.bin')
        img = card.card_image(card.assemble_menu('TEST CARD', ['KISELEV'])[0], [kiselev])
        c = CardPpi(img)
        r = emu8080.run_menu(img, '0', card=c)
        self.assertEqual(r.pc, 0)
        self.assertEqual(c.bank, 1)
        self.assertEqual(bytes(r.ram[0:0x200]), kiselev[:0x200])
        self.assertEqual(fa68_copy(c, 0x8000, 0x81FF), fa68_copy(c, 0, 0x1FF))  # the mirror
        self.assertEqual(fa68_copy(c, 0x7E00, 0x7FFF), b'\xff' * 0x200)


if __name__ == '__main__':
    unittest.main()
