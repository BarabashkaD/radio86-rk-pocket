"""A small Intel 8080 emulator with Radio-86RK monitor stubs, to test the ROM disk loaders.

Stubs: F818 print string at HL, F803 get a key, FA68 copy ROM disk HL..DE to RAM at BC. Each stub fills the
16 bytes below its return address with A5, as deep as the real monitor's calls push (PRINT via F922, FCBA,
FE01, FE72: 18 bytes with the return address).

run_menu: the ROM disk menus (its stubs set only HL and BC after FA68 and A after F803).
run_until: runs until stop(pc) is true, with stubs closer to the monitor (BIOS.BIN): F818 returns A = 0,
HL = the 0 byte, C = the last character printed, models CLS (1Fh) as zeroing 76D0-7FF4, and refuses
(EmuError) when the monitor's variables 7600-765F changed since the run started; FA68 returns A = E,
Z set, HL = DE, BC + count, and refuses a request of 65536 bytes (DE = HL - 1); any other address in
F800-FFFF reached without a stop is EmuError (an unmodelled monitor routine).
Screen: the monitor's 64 x 25 text screen, replaying run_until's print events (the menu tests).
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
    def __init__(self, pc, ram, printed, menus, copies, sp=None, events=None, waiting=False, min_sp=None):
        self.pc, self.ram, self.printed, self.menus, self.copies = pc, ram, printed, menus, copies
        self.sp, self.events, self.waiting, self.min_sp = sp, events, waiting, min_sp


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
        elif op == 0x2A:  # LHLD
            a = self.fetch16()
            self.r[5], self.r[4] = self.m[a], self.m[(a + 1) & 0xFFFF]
        elif op == 0x22:  # SHLD
            a = self.fetch16()
            self.m[a], self.m[(a + 1) & 0xFFFF] = self.r[5], self.r[4]
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


MONITOR_VARS = (0x7600, 0x7660)   # cleared by the cold start (F841-F849): the monitor's variables
CLS_AREA = (0x76D0, 0x7FF5)       # what the monitor's CLS (1Fh) zeroes


def run_until(ram, start, keys, card, stop, max_steps=5_000_000):
    """Runs from start with SP 76CF (as the monitor's G) until stop(pc) is true; stop is checked at every
    instruction boundary before a stub runs, so the instruction at the stop address never runs. Returns a
    Result with pc, sp, min_sp, ram, printed, events (('print', bytes), ('copy', hl, de, bc) in order),
    copies and waiting (True when F803 finds no key left). EmuError after max_steps. With card (a
    card_model.CardPpi), A000-BFFF is the card's ports and FA68 reads the card; without, FA68 is an error."""
    ram = bytearray(ram)
    if card is not None:
        ram = CardRam(ram)
        ram.card = card
    cpu = Cpu(ram)
    cpu.sp = 0x76CF
    cpu.pc = start
    keys = [ord(k) for k in keys]
    printed, copies, events = [], [], []
    lo, hi = MONITOR_VARS
    snap = bytearray(ram[lo:hi])
    min_sp = cpu.sp

    def result(waiting=False):
        return Result(cpu.pc, ram, b''.join(printed), 0, copies, sp=cpu.sp, events=events, waiting=waiting,
                      min_sp=min_sp)

    for _ in range(max_steps):
        pc = cpu.pc
        min_sp = min(min_sp, cpu.sp)
        if stop(pc):
            return result()
        if pc in STUBS:
            if pc == PRINT and ram[lo:hi] != snap:
                k = next(i for i in range(hi - lo) if ram[lo + i] != snap[i])
                raise EmuError('the monitor variables 7600-765F changed (%04X) before the print at %04X'
                               % (lo + k, cpu.m[cpu.sp] | cpu.m[(cpu.sp + 1) & 0xFFFF] << 8))
            for k in range(1, STUB_STACK + 1):
                a = (cpu.sp - k) & 0xFFFF
                ram[a] = 0xA5
                if lo <= a < hi:
                    snap[a - lo] = 0xA5
            if pc == PRINT:
                hl = cpu.hl()
                end = hl
                while ram[end]:
                    end += 1
                text = bytes(ram[hl:end])
                printed.append(text)
                events.append(('print', text))
                if 0x1F in text:
                    ram[CLS_AREA[0]:CLS_AREA[1]] = bytes(CLS_AREA[1] - CLS_AREA[0])
                cpu.r[7] = 0
                if text:
                    cpu.r[1] = text[-1]
                cpu.set_pair(2, end)
            elif pc == GETCH:
                if not keys:
                    return result(waiting=True)
                cpu.r[7] = keys.pop(0)
            else:
                hl, de, bc = cpu.hl(), cpu.pair(1), cpu.pair(0)
                if card is None:
                    raise EmuError('FA68 without a card')
                if de == (hl - 1) & 0xFFFF:
                    raise EmuError('FA68 of 65536 bytes (HL %04X, DE %04X)' % (hl, de))
                copies.append((hl, de, bc))
                events.append(('copy', hl, de, bc))
                data = fa68_copy(card, hl, de)
                for k in range(len(data)):
                    ram[(bc + k) & 0xFFFF] = data[k]
                cpu.set_pair(2, de)
                cpu.set_pair(0, bc + len(data))
                cpu.r[7] = cpu.r[3]
                cpu.f = 0x02 | Z   # the last CMP E of F990 with A = L = E
            cpu.pc = cpu.pop()
            continue
        if pc >= 0xF800:
            raise EmuError('monitor entry %04X is not modelled (only F803, F818, FA68)' % pc)
        cpu.step()
    raise EmuError('too many steps')


class Screen:
    """The monitor's text screen (64 x 25) as far as the card menu uses it, replaying F818 prints: the
    monitor masks every byte with 7Fh; 1Fh clears and homes; CR goes to column 0; LF one line down;
    ESC Y (1Bh, 'Y', 20h + row 0-24, 20h + column 0-63) places the cursor; any other byte below 20h
    is not modelled (EmuError). A character advances the column and wraps after column 63. Anything
    that would scroll (LF on the last line, a character in the bottom-right cell) is EmuError: the
    menu's layout must never scroll."""

    COLS, ROWS = 64, 25

    def __init__(self):
        self.esc = None
        self.clear()

    def clear(self):
        self.cells = [[' '] * self.COLS for _ in range(self.ROWS)]
        self.row = self.col = 0

    def feed(self, data):
        for b in data:
            self.put(b & 0x7F)

    def replay(self, events):
        for e in events:
            if e[0] == 'print':
                self.feed(e[1])

    def put(self, b):
        if self.esc is not None:
            self.esc.append(b)
            if self.esc[0] != ord('Y'):
                raise EmuError('ESC %02X: only ESC Y is modelled' % self.esc[0])
            if len(self.esc) == 3:
                row, col = self.esc[1] - 0x20, self.esc[2] - 0x20
                self.esc = None
                if not (0 <= row < self.ROWS and 0 <= col < self.COLS):
                    raise EmuError('ESC Y to row %d, column %d' % (row, col))
                self.row, self.col = row, col
            return
        if b == 0x1B:
            self.esc = []
        elif b == 0x1F:
            self.clear()
        elif b == 0x0D:
            self.col = 0
        elif b == 0x0A:
            if self.row == self.ROWS - 1:
                raise EmuError('LF on the last line scrolls the screen')
            self.row += 1
        elif b < 0x20:
            raise EmuError('control code %02X is not modelled' % b)
        else:
            if self.row == self.ROWS - 1 and self.col == self.COLS - 1:
                raise EmuError('a character in the bottom-right cell scrolls the screen')
            self.cells[self.row][self.col] = chr(b)
            self.col += 1
            if self.col == self.COLS:
                self.row, self.col = self.row + 1, 0

    def lines(self):
        return [''.join(r).rstrip() for r in self.cells]
