"""A small Intel 8080 emulator with Radio-86RK monitor stubs, to test the ROM disk loaders.

Stubs: F818 print string at HL, F803 get a key, FA68 copy ROM disk HL..DE to RAM at BC. Each stub fills the
16 bytes below its return address with A5, as deep as the real monitor's calls push (PRINT via F922, FCBA,
FE01, FE72: 18 bytes with the return address).
"""

from card_model import fa68_copy

PRINT, GETCH, COPY = 0xF818, 0xF803, 0xFA68
STUBS = (PRINT, GETCH, COPY)
STUB_STACK = 16
LOADER_MENU = 0x7416  # MPRINT of the relocated loader: G7416 shows the menu again


class EmuError(Exception):
    pass


class WaitKey(Exception):
    pass


class Result:
    def __init__(self, pc, ram, printed, menus, copies):
        self.pc, self.ram, self.printed, self.menus, self.copies = pc, ram, printed, menus, copies


S, Z, CY = 0x80, 0x40, 0x01
CONDS = (lambda f: not f & Z, lambda f: bool(f & Z), lambda f: not f & CY, lambda f: bool(f & CY),
         None, None, lambda f: not f & S, lambda f: bool(f & S))


class Cpu:
    def __init__(self, ram):
        self.m = ram
        self.r = [0] * 8  # B C D E H L M(unused) A
        self.sp = self.pc = 0
        self.f = 0x02

    def pair(self, p):
        if p == 3:
            return self.sp
        return self.r[2 * p] << 8 | self.r[2 * p + 1]

    def set_pair(self, p, v):
        v &= 0xFFFF
        if p == 3:
            self.sp = v
        else:
            self.r[2 * p], self.r[2 * p + 1] = v >> 8, v & 0xFF

    def hl(self):
        return self.r[4] << 8 | self.r[5]

    def get(self, i):
        return self.m[self.hl()] if i == 6 else self.r[i]

    def put(self, i, v):
        if i == 6:
            self.m[self.hl()] = v & 0xFF
        else:
            self.r[i] = v & 0xFF

    def fetch(self):
        v = self.m[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        lo = self.fetch()
        return lo | self.fetch() << 8

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.m[self.sp], self.m[(self.sp + 1) & 0xFFFF] = v & 0xFF, v >> 8

    def pop(self):
        v = self.m[self.sp] | self.m[(self.sp + 1) & 0xFFFF] << 8
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def szf(self, v):
        self.f = (self.f & CY) | 0x02 | (S if v & 0x80 else 0) | (Z if v == 0 else 0)

    def alu(self, op, b):
        a = self.r[7]
        if op in (0, 1, 2, 3, 7):  # ADD ADC SUB SBB CMP
            c = 1 if op in (1, 3) and self.f & CY else 0
            if op in (0, 1):
                t = a + b + c
            else:
                t = a - b - c
            res = t & 0xFF
            self.szf(res)
            self.f = (self.f & ~CY) | (CY if t > 0xFF or t < 0 else 0)
            if op != 7:
                self.r[7] = res
        else:  # ANA XRA ORA
            res = (a & b, a ^ b, a | b)[op - 4]
            self.r[7] = res
            self.szf(res)
            self.f &= ~CY

    def jump_cond(self, c):
        fn = CONDS[c]
        if fn is None:
            raise EmuError('parity condition at %04X' % ((self.pc - 1) & 0xFFFF))
        return fn(self.f)

    def step(self):
        at = self.pc
        op = self.fetch()
        hi, lo = op >> 6, op & 7
        if hi == 1:
            if op == 0x76:
                raise EmuError('HLT at %04X' % at)
            self.put((op >> 3) & 7, self.get(lo))
        elif hi == 2:
            self.alu((op >> 3) & 7, self.get(lo))
        elif op == 0x00:
            pass
        elif lo == 0 and hi == 3:  # Rcc
            if self.jump_cond((op >> 3) & 7):
                self.pc = self.pop()
        elif lo == 1 and hi == 0 and op & 8 == 0:  # LXI
            self.set_pair((op >> 4) & 3, self.fetch16())
        elif lo == 1 and hi == 3:
            if op & 0x08 == 0:  # POP
                p = (op >> 4) & 3
                v = self.pop()
                if p == 3:
                    self.r[7], self.f = v >> 8, (v & 0xFF) | 0x02
                else:
                    self.set_pair(p, v)
            elif op == 0xC9:
                self.pc = self.pop()
            elif op == 0xE9:  # PCHL
                self.pc = self.hl()
            elif op == 0xF9:  # SPHL
                self.sp = self.hl()
            else:
                raise EmuError('opcode %02X at %04X' % (op, at))
        elif lo == 2 and hi == 3:  # Jcc
            a = self.fetch16()
            if self.jump_cond((op >> 3) & 7):
                self.pc = a
        elif lo == 3 and hi == 3:
            if op == 0xC3:
                self.pc = self.fetch16()
            elif op == 0xEB:  # XCHG
                self.r[2], self.r[4] = self.r[4], self.r[2]
                self.r[3], self.r[5] = self.r[5], self.r[3]
            else:
                raise EmuError('opcode %02X at %04X' % (op, at))
        elif lo == 4 and hi == 3:  # Ccc
            a = self.fetch16()
            if self.jump_cond((op >> 3) & 7):
                self.push(self.pc)
                self.pc = a
        elif lo == 5 and hi == 3:
            if op & 0x08 == 0:  # PUSH
                p = (op >> 4) & 3
                self.push((self.r[7] << 8 | (self.f & 0xD7 | 0x02)) if p == 3 else self.pair(p))
            elif op == 0xCD:
                a = self.fetch16()
                self.push(self.pc)
                self.pc = a
            else:
                raise EmuError('opcode %02X at %04X' % (op, at))
        elif lo == 6 and hi == 3:  # ADI .. CPI
            self.alu((op >> 3) & 7, self.fetch())
        elif lo == 6 and hi == 0:  # MVI
            self.put((op >> 3) & 7, self.fetch())
        elif lo == 4 and hi == 0:  # INR
            i = (op >> 3) & 7
            v = (self.get(i) + 1) & 0xFF
            self.put(i, v)
            self.szf(v)
        elif lo == 5 and hi == 0:  # DCR
            i = (op >> 3) & 7
            v = (self.get(i) - 1) & 0xFF
            self.put(i, v)
            self.szf(v)
        elif lo == 3 and hi == 0:  # INX DCX
            p = (op >> 4) & 3
            self.set_pair(p, self.pair(p) + (1 if op & 8 == 0 else -1))
        elif op & 0xCF == 0x09:  # DAD
            t = self.hl() + self.pair((op >> 4) & 3)
            self.f = (self.f & ~CY) | (CY if t > 0xFFFF else 0)
            self.set_pair(2, t)
        elif op == 0x0A or op == 0x1A:  # LDAX
            self.r[7] = self.m[self.pair((op >> 4) & 1)]
        elif op == 0x02 or op == 0x12:  # STAX
            self.m[self.pair((op >> 4) & 1)] = self.r[7]
        elif op == 0x3A:
            self.r[7] = self.m[self.fetch16()]
        elif op == 0x32:
            self.m[self.fetch16()] = self.r[7]
        else:
            raise EmuError('opcode %02X at %04X' % (op, at))


class CardRam(bytearray):
    """RAM of a machine with the ROM disk card: integer indexes A000-BFFF go to the card, not to the RAM."""

    card = None

    def __getitem__(self, i):
        if isinstance(i, int) and 0xA000 <= i <= 0xBFFF:
            return self.card.read(i & 3)
        return super().__getitem__(i)

    def __setitem__(self, i, v):
        if isinstance(i, int) and 0xA000 <= i <= 0xBFFF:
            self.card.write(i & 3, v)
        else:
            super().__setitem__(i, v)


def run_menu(rom, keys, max_steps=5_000_000, ram=None, start=0, card=None):
    """Runs G<start> with SP 76CF, as the monitor's G does, with the ROM disk rom: by default G0 on a RAM holding
    the ROM's first 512 bytes; with ram (for example the RAM after an earlier run, as after Reset) and
    start=LOADER_MENU, G7416. With card (a card_model.CardPpi), A000-BFFF is the card's ports and the FA68
    stub reads the card as the monitor does; rom is then used only for the default first 512 bytes."""
    if ram is None:
        ram = bytearray(65536)
        ram[0:512] = rom[0:512]
    else:
        ram = bytearray(ram)
    if card is not None:
        ram = CardRam(ram)
        ram.card = card
    cpu = Cpu(ram)
    cpu.sp = 0x76CF
    cpu.pc = start
    keys = [ord(k) for k in keys]
    printed, copies = [], []
    menu_addr, menus = None, 0
    in_loader = False
    for _ in range(max_steps):
        pc = cpu.pc
        if pc in STUBS:
            for k in range(1, STUB_STACK + 1):
                ram[(cpu.sp - k) & 0xFFFF] = 0xA5
            if pc == PRINT:
                hl = cpu.hl()
                if menu_addr is None:
                    menu_addr = hl
                if hl == menu_addr:
                    menus += 1
                end = hl
                while ram[end]:
                    end += 1
                printed.append(bytes(ram[hl:end]))
            elif pc == GETCH:
                if not keys:
                    raise WaitKey()
                cpu.r[7] = keys.pop(0)
            else:
                hl, de, bc = cpu.hl(), cpu.pair(1), cpu.pair(0)
                copies.append((hl, de, bc))
                n = de - hl + 1
                if card is not None:
                    data = fa68_copy(card, hl, de)
                    n = len(data)
                    for k in range(n):
                        ram[(bc + k) & 0xFFFF] = data[k]
                else:
                    for k in range(n):
                        o = hl + k
                        ram[(bc + k) & 0xFFFF] = rom[o] if o < len(rom) else 0xFF
                cpu.set_pair(2, de)
                cpu.set_pair(0, bc + n)
            cpu.pc = cpu.pop()
            continue
        if 0x7400 <= pc <= 0x75FF:
            in_loader = True
        elif in_loader:
            return Result(pc, ram, b''.join(printed), menus, copies)
        cpu.step()
    raise EmuError('too many steps')
