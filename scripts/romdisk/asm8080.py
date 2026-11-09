"""A small Intel 8080 assembler (Python 3 standard library only).

It assembles the syntax of Sergey Kiselev's ROM disk loader (rom_loader.asm) and of its port for
games, and reproduces the loader byte for byte. Input may use CR LF line ends and tabs.

Syntax (case-insensitive for mnemonics, registers and symbols):
  line         [label[:]] [mnemonic operands] [; comment]
  label        the first token when it ends with ':' or when the line does not start with white
               space and the token is not a mnemonic or a directive
  directives   ORG expr | name[:] EQU expr | DB item,... | DW expr,... | END
  DB items     "text" (ASCII bytes), 'c' (a char), expressions 0..255
  DW items     expressions 0..65535, little endian
  expressions  terms joined by + and -; a term is a symbol, $ (the current address), a decimal
               number, a hex number with the H suffix (0F818H; it starts with a digit) or 'c'
  registers    A B C D E H L M; pairs B D H SP PSW, with BC DE HL as aliases of B D H
  mnemonics    the full Intel 8080 set

assemble(text) -> (origin, code, symbols): the origin of the first ORG, the bytes from the lowest
to the highest written address (gaps left by ORG are 0xFF), the symbol table. AsmError
("line N: ...") is raised on an unknown mnemonic, a bad operand, an undefined symbol, a value out
of range or an address written twice (an ORG that goes back over written bytes).
"""
import re


class AsmError(Exception):
    pass


REGS = {'B': 0, 'C': 1, 'D': 2, 'E': 3, 'H': 4, 'L': 5, 'M': 6, 'A': 7}
PAIRS = {'B': 0, 'BC': 0, 'D': 1, 'DE': 1, 'H': 2, 'HL': 2, 'SP': 3, 'PSW': 3}
CONDS = ['NZ', 'Z', 'NC', 'C', 'PO', 'PE', 'P', 'M']

# mnemonic -> (opcode, operand kind); kinds: '' none, 'r' register in bits 5..3, 'rs' register in
# bits 2..0, 'rr' two registers (MOV), 'p' pair in bits 5..4, 'pp' pair for PUSH/POP, 'px' BC or DE
# (LDAX/STAX), 'b' 8-bit immediate, 'w' 16-bit address/immediate, 'n' RST number, 'rb' reg + byte,
# 'pw' pair + word
OPS = {
    'NOP': (0x00, ''), 'HLT': (0x76, ''), 'XCHG': (0xEB, ''), 'DAA': (0x27, ''),
    'CMA': (0x2F, ''), 'STC': (0x37, ''), 'CMC': (0x3F, ''), 'RLC': (0x07, ''),
    'RRC': (0x0F, ''), 'RAL': (0x17, ''), 'RAR': (0x1F, ''), 'RET': (0xC9, ''),
    'PCHL': (0xE9, ''), 'SPHL': (0xF9, ''), 'XTHL': (0xE3, ''), 'EI': (0xFB, ''),
    'DI': (0xF3, ''),
    'MOV': (0x40, 'rr'), 'MVI': (0x06, 'rb'), 'LXI': (0x01, 'pw'),
    'LDA': (0x3A, 'w'), 'STA': (0x32, 'w'), 'LHLD': (0x2A, 'w'), 'SHLD': (0x22, 'w'),
    'LDAX': (0x0A, 'px'), 'STAX': (0x02, 'px'),
    'ADD': (0x80, 'rs'), 'ADC': (0x88, 'rs'), 'SUB': (0x90, 'rs'), 'SBB': (0x98, 'rs'),
    'ANA': (0xA0, 'rs'), 'XRA': (0xA8, 'rs'), 'ORA': (0xB0, 'rs'), 'CMP': (0xB8, 'rs'),
    'ADI': (0xC6, 'b'), 'ACI': (0xCE, 'b'), 'SUI': (0xD6, 'b'), 'SBI': (0xDE, 'b'),
    'ANI': (0xE6, 'b'), 'XRI': (0xEE, 'b'), 'ORI': (0xF6, 'b'), 'CPI': (0xFE, 'b'),
    'INR': (0x04, 'r'), 'DCR': (0x05, 'r'),
    'INX': (0x03, 'p'), 'DCX': (0x0B, 'p'), 'DAD': (0x09, 'p'),
    'PUSH': (0xC5, 'pp'), 'POP': (0xC1, 'pp'),
    'JMP': (0xC3, 'w'), 'CALL': (0xCD, 'w'), 'RST': (0xC7, 'n'),
    'IN': (0xDB, 'b'), 'OUT': (0xD3, 'b'),
}
for _i, _c in enumerate(CONDS):
    OPS['J' + _c] = (0xC2 | _i << 3, 'w')
    OPS['C' + _c] = (0xC4 | _i << 3, 'w')
    OPS['R' + _c] = (0xC0 | _i << 3, '')
DIRECTIVES = {'ORG', 'EQU', 'DB', 'DW', 'END'}
SIZES = {'': 1, 'r': 1, 'rs': 1, 'rr': 1, 'p': 1, 'pp': 1, 'px': 1, 'n': 1,
         'b': 2, 'rb': 2, 'w': 3, 'pw': 3}
NAME = re.compile(r'[A-Za-z_?@.][A-Za-z0-9_?@.]*$')


def strip_comment(line):
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
        elif ch == ';':
            return line[:i]
    return line


def split_commas(text):
    items, cur, quote = [], '', None
    for ch in text:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
            cur += ch
        elif ch == ',':
            items.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip() or items:
        items.append(cur.strip())
    return items


def parse_line(raw):
    """Returns (label, mnemonic, operand string); label and mnemonic may be None."""
    line = strip_comment(raw.replace('\r', '').replace('\t', ' ')).rstrip()
    if not line.strip():
        return None, None, ''
    starts_blank = line[0] == ' '
    parts = line.strip().split(None, 1)
    first = parts[0]
    rest = parts[1] if len(parts) > 1 else ''
    label = None
    if first.endswith(':'):
        label, first = first[:-1], None
    elif not starts_blank and first.upper() not in OPS and first.upper() not in DIRECTIVES:
        label, first = first, None
    elif ':' in first and not first.startswith(("'", '"')):
        label, _, tail = first.partition(':')
        first = tail or None
        if first:
            rest = first + (' ' + rest if rest else '')
            first = None
    if first is None:
        parts = rest.split(None, 1)
        first = parts[0] if parts else None
        rest = parts[1] if len(parts) > 1 else ''
    return label, (first.upper() if first else None), rest.strip()


class Assembler:
    def __init__(self):
        self.sym = {}
        self.lineno = 0

    def err(self, msg):
        return AsmError('line %d: %s' % (self.lineno, msg))

    def term(self, t, pc):
        t = t.strip()
        if not t:
            raise self.err('empty expression')
        if t == '$':
            return pc
        if len(t) == 3 and t[0] == "'" and t[2] == "'":
            return ord(t[1])
        if t[0].isdigit():
            try:
                if t[-1] in 'Hh':
                    return int(t[:-1], 16)
                return int(t, 10)
            except ValueError:
                raise self.err('bad number %r' % t)
        if NAME.match(t):
            key = t.upper()
            if key not in self.sym:
                raise self.err('undefined symbol %r' % t)
            return self.sym[key]
        raise self.err('bad term %r' % t)

    def expr(self, text, pc):
        pieces = re.split(r"('.'|[+-])", text.strip())
        total, sign, expect_term = 0, 1, True
        for p in pieces:
            p = p.strip()
            if not p:
                continue
            if p in '+-' and len(p) == 1:
                sign = sign * (1 if p == '+' else -1) if expect_term else (1 if p == '+' else -1)
                expect_term = True
                continue
            total += sign * self.term(p, pc)
            sign, expect_term = 1, False
        if expect_term:
            raise self.err('bad expression %r' % text)
        return total

    def byte(self, text, pc):
        v = self.expr(text, pc)
        if not 0 <= v <= 0xFF:
            raise self.err('byte value out of range: %r' % text)
        return v

    def word(self, text, pc):
        v = self.expr(text, pc)
        if not 0 <= v <= 0xFFFF:
            raise self.err('word value out of range: %r' % text)
        return v

    def reg(self, text):
        r = REGS.get(text.strip().upper())
        if r is None:
            raise self.err('bad register %r' % text)
        return r

    def pair(self, text, push=False, only_bd=False):
        k = text.strip().upper()
        if k not in PAIRS or (push and k == 'SP') or (not push and k == 'PSW'):
            raise self.err('bad register pair %r' % text)
        if only_bd and k not in ('B', 'BC', 'D', 'DE'):
            raise self.err('bad register pair %r' % text)
        return PAIRS[k]

    def need(self, ops, n, mnem):
        if len(ops) != n:
            raise self.err('%s takes %d operand(s)' % (mnem, n))

    def encode(self, mnem, ops, pc):
        opcode, kind = OPS[mnem]
        if kind == '':
            self.need(ops, 0, mnem)
            return [opcode]
        if kind == 'r':
            self.need(ops, 1, mnem)
            return [opcode | self.reg(ops[0]) << 3]
        if kind == 'rs':
            self.need(ops, 1, mnem)
            return [opcode | self.reg(ops[0])]
        if kind == 'rr':
            self.need(ops, 2, mnem)
            d, s = self.reg(ops[0]), self.reg(ops[1])
            if d == 6 and s == 6:
                raise self.err('MOV M,M is HLT')
            return [opcode | d << 3 | s]
        if kind in ('p', 'pp', 'px'):
            self.need(ops, 1, mnem)
            return [opcode | self.pair(ops[0], push=kind == 'pp', only_bd=kind == 'px') << 4]
        if kind == 'b':
            self.need(ops, 1, mnem)
            return [opcode, self.byte(ops[0], pc)]
        if kind == 'w':
            self.need(ops, 1, mnem)
            w = self.word(ops[0], pc)
            return [opcode, w & 0xFF, w >> 8]
        if kind == 'n':
            self.need(ops, 1, mnem)
            n = self.expr(ops[0], pc)
            if not 0 <= n <= 7:
                raise self.err('RST number out of range')
            return [opcode | n << 3]
        if kind == 'rb':
            self.need(ops, 2, mnem)
            return [opcode | self.reg(ops[0]) << 3, self.byte(ops[1], pc)]
        if kind == 'pw':
            self.need(ops, 2, mnem)
            w = self.word(ops[1], pc)
            return [opcode | self.pair(ops[0]) << 4, w & 0xFF, w >> 8]
        raise self.err('internal: kind %r' % kind)

    def db_bytes(self, ops, pc):
        out = []
        for item in ops:
            if len(item) >= 2 and item[0] == '"' and item[-1] == '"':
                try:
                    out.extend(item[1:-1].encode('ascii'))
                except UnicodeEncodeError:
                    raise self.err('non-ASCII string')
            else:
                out.append(self.byte(item, pc + len(out)))
        return out

    def size_of(self, mnem, ops, pc):
        if mnem == 'DB':
            n = 0
            for item in ops:
                n += len(item) - 2 if len(item) >= 2 and item[0] == '"' and item[-1] == '"' else 1
            return n
        if mnem == 'DW':
            return 2 * len(ops)
        return SIZES[OPS[mnem][1]]

    def run(self, text):
        lines = text.split('\n')
        parsed = [parse_line(l) for l in lines]
        # pass 1: addresses of labels and EQU values
        pc, origin, started = 0, None, False
        for n, (label, mnem, rest) in enumerate(parsed, 1):
            self.lineno = n
            ops = split_commas(rest) if rest else []
            if mnem == 'EQU':
                if not label or not NAME.match(label):
                    raise self.err('EQU needs a name')
                self.define(label, self.expr(rest, pc))
                continue
            if label:
                if not NAME.match(label):
                    raise self.err('bad label %r' % label)
                self.define(label, pc)
            if mnem is None:
                continue
            if mnem == 'END':
                break
            if mnem == 'ORG':
                pc = self.word(rest, pc)
                if label:
                    self.sym[label.upper()] = pc
                if not started:
                    origin, started = pc, True
                continue
            if mnem not in OPS and mnem not in ('DB', 'DW'):
                raise self.err('unknown mnemonic %r' % mnem)
            if not started:
                raise self.err('code before ORG')
            pc += self.size_of(mnem, ops, pc)
        # pass 2: the bytes
        mem, pc = {}, 0
        for n, (label, mnem, rest) in enumerate(parsed, 1):
            self.lineno = n
            if mnem == 'END':
                break
            if mnem is None or mnem == 'EQU':
                continue
            ops = split_commas(rest) if rest else []
            if mnem == 'ORG':
                pc = self.word(rest, pc)
                continue
            if mnem == 'DB':
                data = self.db_bytes(ops, pc)
            elif mnem == 'DW':
                data = []
                for item in ops:
                    w = self.word(item, pc + len(data))
                    data += [w & 0xFF, w >> 8]
            else:
                data = self.encode(mnem, ops, pc)
            for b in data:
                if pc > 0xFFFF:
                    raise self.err('address beyond FFFFH')
                if pc in mem:
                    raise self.err('address %04XH written twice' % pc)
                mem[pc] = b
                pc += 1
        if not mem:
            return (origin or 0), b'', self.sym
        lo, hi = min(mem), max(mem)
        return origin, bytes(mem.get(a, 0xFF) for a in range(lo, hi + 1)), self.sym

    def define(self, name, value):
        key = name.upper()
        if key in self.sym:
            raise self.err('symbol %r defined twice' % name)
        self.sym[key] = value


def assemble(text):
    return Assembler().run(text)
