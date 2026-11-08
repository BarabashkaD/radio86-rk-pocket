#!/usr/bin/env python3
"""Runs the Radio-86RK monitor's keyboard decoder (FE72, the F81B entry) from the real ROM.

A minimal 8080 interpreter executes the routine for each of the 64 matrix keys and the 8
combinations of the RUS mode (byte 7606h), the СС (Shift) and the УС (Ctrl) line, with a modelled
PPI at 8000h-8003h: port A (8000h) drives the rows low, port B (8001h) returns the columns of the
one pressed key (low), port C (8002h) returns the modifier lines (bit 5 СС, bit 6 УС, bit 7 РУС,
low = pressed). Only the opcodes the routine runs are implemented; any other raises.

Usage: python -B scripts/k1/monitor_decoder.py   (prints the 64 x 8 table)
"""
import functools
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
ROM = os.path.join(ROOT, 'cores', 'karabas-go-core-rk86', 'src', 'roms', 'BIOS.BIN')
ROM_BASE = 0xF800
ENTRY = 0xFE72          # the decoder: returns the key code in A (FFh no key, FEh РУС pressed)
RUS_BYTE = 0x7606       # 00h LAT, nonzero (the monitor stores FFh) RUS
STEP_LIMIT = 10000
SHIFT_BIT, CTRL_BIT, RUS_BIT = 0x20, 0x40, 0x80


class Cpu8080:
    """Just the 8080 subset of the monitor's keyboard routine."""
    REGS = 'BCDEHLMA'

    def __init__(self, mem, io_read, io_write):
        self.mem, self.io_read, self.io_write = mem, io_read, io_write
        self.r = dict.fromkeys('BCDEHLA', 0)
        self.pc = self.sp = 0
        self.fs = self.fz = self.fp = self.fcy = False

    def rd(self, a):
        return self.io_read(a) if 0x8000 <= a <= 0x8003 else self.mem[a]

    def wr(self, a, v):
        if 0x8000 <= a <= 0x8003:
            self.io_write(a, v)
        elif a < ROM_BASE:
            self.mem[a] = v
        else:
            raise RuntimeError('write to ROM %04X' % a)

    def get(self, i):
        return self.rd(self.hl()) if i == 6 else self.r[self.REGS[i]]

    def put(self, i, v):
        if i == 6:
            self.wr(self.hl(), v)
        else:
            self.r[self.REGS[i]] = v & 0xFF

    def hl(self):
        return self.r['H'] << 8 | self.r['L']

    def fetch(self):
        v = self.mem[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        lo = self.fetch()
        return self.fetch() << 8 | lo

    def szp(self, v):
        self.fs, self.fz, self.fp = bool(v & 0x80), v == 0, bin(v).count('1') % 2 == 0

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.wr(self.sp, v & 0xFF)
        self.wr(self.sp + 1, v >> 8)

    def pop(self):
        v = self.mem[self.sp] | self.mem[self.sp + 1] << 8
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def cond(self, c):
        return [not self.fz, self.fz, not self.fcy, self.fcy, not self.fp, self.fp, not self.fs, self.fs][c]

    def alu(self, op, v):
        a = self.r['A']
        if op in (0, 1):            # ADD, ADC
            res = a + v + (1 if op == 1 and self.fcy else 0)
            self.fcy = res > 0xFF
        elif op in (2, 3, 7):       # SUB, SBB, CMP
            res = a - v - (1 if op == 3 and self.fcy else 0)
            self.fcy = res < 0
        else:                       # ANA, XRA, ORA
            res = [a & v, a ^ v, a | v][op - 4]
            self.fcy = False
        res &= 0xFF
        self.szp(res)
        if op != 7:
            self.r['A'] = res

    def step(self):
        pc, op = self.pc, self.fetch()
        if 0x40 <= op <= 0x7F and op != 0x76:                   # MOV d,s
            self.put(op >> 3 & 7, self.get(op & 7))
        elif 0x80 <= op <= 0xBF:                                # ALU A,r
            self.alu(op >> 3 & 7, self.get(op & 7))
        elif op & 0xC7 == 0xC6:                                 # ALU A,imm
            self.alu(op >> 3 & 7, self.fetch())
        elif op & 0xC7 == 0x06:                                 # MVI r,imm
            self.put(op >> 3 & 7, self.fetch())
        elif op & 0xC6 == 0x04:                                 # INR / DCR (CY unchanged)
            v = (self.get(op >> 3 & 7) + (1 if op & 1 == 0 else -1)) & 0xFF
            self.put(op >> 3 & 7, v)
            self.szp(v)
        elif op == 0x07:                                        # RLC
            a = self.r['A']
            self.fcy = bool(a & 0x80)
            self.r['A'] = (a << 1 | a >> 7) & 0xFF
        elif op == 0x0F:                                        # RRC
            a = self.r['A']
            self.fcy = bool(a & 1)
            self.r['A'] = (a >> 1 | a << 7) & 0xFF
        elif op == 0x2F:                                        # CMA
            self.r['A'] ^= 0xFF
        elif op == 0x21:                                        # LXI H
            v = self.fetch16()
            self.r['H'], self.r['L'] = v >> 8, v & 0xFF
        elif op == 0x3A:                                        # LDA
            self.r['A'] = self.rd(self.fetch16())
        elif op == 0x32:                                        # STA
            self.wr(self.fetch16(), self.r['A'])
        elif op == 0xC3:                                        # JMP
            self.pc = self.fetch16()
        elif op & 0xC7 == 0xC2:                                 # Jcc
            a = self.fetch16()
            if self.cond(op >> 3 & 7):
                self.pc = a
        elif op == 0xCD:                                        # CALL
            a = self.fetch16()
            self.push(self.pc)
            self.pc = a
        elif op == 0xC9:                                        # RET
            self.pc = self.pop()
        elif op & 0xC7 == 0xC0:                                 # Rcc
            if self.cond(op >> 3 & 7):
                self.pc = self.pop()
        elif op == 0xE5:                                        # PUSH H
            self.push(self.hl())
        elif op == 0xE1:                                        # POP H
            v = self.pop()
            self.r['H'], self.r['L'] = v >> 8, v & 0xFF
        else:
            raise NotImplementedError('opcode %02X at %04X' % (op, pc))


def load_rom(path=ROM):
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) != 0x800:
        raise ValueError('%s: %d bytes, expected 2048' % (path, len(data)))
    return data


def decode(key, rus, sh, ct, rus_line=False, rom=None):
    """The code FE72 returns with matrix key `key` (0..63, or None for no key) pressed."""
    mem = bytearray(0x10000)
    mem[ROM_BASE:] = rom or load_rom()
    mem[RUS_BYTE] = 0xFF if rus else 0x00
    port_a = [0xFF]
    mods = 0xFF & ~((SHIFT_BIT if sh else 0) | (CTRL_BIT if ct else 0) | (RUS_BIT if rus_line else 0))

    def io_read(a):
        if a == 0x8001:
            if key is not None and not port_a[0] >> (key >> 3) & 1:
                return 0xFF & ~(1 << (key & 7))
            return 0xFF
        if a == 0x8002:
            return mods
        return 0xFF

    def io_write(a, v):
        if a == 0x8000:
            port_a[0] = v

    cpu = Cpu8080(mem, io_read, io_write)
    cpu.sp = 0x7600
    cpu.push(0x0000)                    # return address: the end of the run
    cpu.pc = ENTRY
    for _ in range(STEP_LIMIT):
        cpu.step()
        if cpu.pc == 0x0000:
            if cpu.sp != 0x7600:
                raise RuntimeError('stack not balanced')
            return cpu.r['A']
    raise RuntimeError('step limit: key %s rus %d sh %d ct %d' % (key, rus, sh, ct))


def combo(rus, sh, ct):
    """The column of the table: bit 2 rus, bit 1 sh, bit 0 ct."""
    return rus << 2 | sh << 1 | ct


@functools.lru_cache(maxsize=None)
def table():
    """table()[key][combo(rus, sh, ct)]: the code for the 64 keys x 8 combinations."""
    rom = load_rom()
    return tuple(tuple(decode(k, c >> 2 & 1, c >> 1 & 1, c & 1, rom=rom) for c in range(8)) for k in range(64))


def main():
    rom = load_rom()
    print('// FE72 codes; columns: rus sh ct = 000 001 010 011 100 101 110 111')
    for k, row in enumerate(table()):
        print('%2d: %s' % (k, ' '.join('%02X' % v for v in row)))
    print('no key: %02X (all combinations: %s)' % (
        decode(None, 0, 0, 0, rom=rom), ' '.join('%02X' % decode(None, c >> 2 & 1, c >> 1 & 1, c & 1, rom=rom) for c in range(8))))
    print('РУС line low: %02X' % decode(35, 0, 0, 0, rus_line=True, rom=rom))


if __name__ == '__main__':
    main()
