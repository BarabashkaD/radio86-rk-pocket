#!/usr/bin/env python3
"""K1 on-screen keyboard: the key table, the labels and the golden panel model (single source).

The 67 keys of the real Radio-86RK keyboard, their caps
on the 408 x 300 picture, the label of each cap from the monitor's own decoder (monitor_decoder.py
runs FE72 from the ROM), the navigation helpers and render_panel(), the picture the RTL must draw.
gen_verilog.py turns this file into fpga/rtl/pocket_k1_layout.vh; render.py writes PNG / GIF.
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import monitor_decoder  # noqa: E402

ROOT = monitor_decoder.ROOT
FONT_VH = os.path.join(ROOT, 'fpga', 'rtl', 'native_font.vh')

WIDTH, HEIGHT = 408, 300
PANEL = (62, 218, 284, 82)              # x0, y0, width, height
MARGIN, PX4, ROW_H, CAP_H = 2, 5, 13, 12  # PX4: pixels per quarter key unit
ROWS, QUARTERS = 6, 56
ROLES = 'asefchp'                       # 0 a alpha, 1 s special, 2 e accent, 3 f F-keys, 4 c cursor, 5 h HM/СТР, 6 p space
SHIFT_LINE, CTRL_LINE, RUS_LINE, SPACE_LINE = 64, 65, 66, 63
F_LINES = range(3, 8)

Key = collections.namedtuple('Key', 'id row x w role line')


def _letter(c):
    return 33 + ord(c) - ord('A')


def _keys():
    t = [(0, 0, 4, 'e', 2)]
    t += [(0, x, 4, 'f', 3 + i) for i, x in enumerate((4, 8, 12, 16, 20))]
    t += [(0, 48, 4, 'h', 0), (0, 52, 4, 'h', 1)]
    t += [(1, 4 * i, 4, 'a', m) for i, m in enumerate((27, 17, 18, 19, 20, 21, 22, 23, 24, 25, 16, 29))]
    t += [(1, 48, 4, 's', 8), (1, 52, 4, 's', 11)]
    row2 = [_letter(c) for c in 'JCUKENG'] + [59, 61] + [_letter(c) for c in 'ZH'] + [26]
    t += [(2, 2 + 4 * i, 4, 'a', m) for i, m in enumerate(row2)] + [(2, 50, 6, 'a', 60)]
    row3 = [_letter(c) for c in 'FYWAPROLDV'] + [30]
    t += [(3, 3 + 4 * i, 4, 'a', m) for i, m in enumerate(row3)] + [(3, 47, 9, 'e', 10)]
    row4 = [_letter('Q'), 62] + [_letter(c) for c in 'SMITXB'] + [32, 28, 31]
    t += [(4, 0, 4, 'e', RUS_LINE)] + [(4, 4 + 4 * i, 4, 'a', m) for i, m in enumerate(row4)]
    t += [(4, 48, 4, 'c', 13), (4, 52, 4, 's', 9)]
    t += [(5, 0, 5, 's', CTRL_LINE), (5, 5, 5, 's', SHIFT_LINE), (5, 13, 26, 'p', SPACE_LINE),
          (5, 44, 4, 'c', 12), (5, 48, 4, 'c', 15), (5, 52, 4, 'c', 14)]
    return tuple(Key(i, *k) for i, k in enumerate(t))


KEYS = _keys()
KEY_BY_LINE = {k.line: k for k in KEYS}


# --- geometry and navigation ----------------------------------------------------------------
def cap_rect(key):
    """(cx, cy, cw, ch) of the cap in picture pixels."""
    x0, y0 = PANEL[:2]
    return (x0 + MARGIN + key.x * PX4, y0 + MARGIN + key.row * ROW_H,
            (key.x + key.w) * PX4 - key.x * PX4 - 1, CAP_H)


def row_keys(row):
    return [k for k in KEYS if k.row == row]


def centre_xq(id_):
    k = KEYS[id_]
    return k.x + k.w // 2


def key_at(row, xq):
    """The key under quarter position xq of a row; a gap goes to the nearest key centre
    (distance from xq to x + w/2), ties to the left."""
    keys = row_keys(row)
    for k in keys:
        if k.x <= xq < k.x + k.w:
            return k.id
    return min(keys, key=lambda k: (abs(2 * xq - (2 * k.x + k.w)), k.x)).id


def neighbour(id_, direction, remembered_xq):
    """The key after one D-pad step: left/right wrap within the row; up/down wrap the rows and
    take key_at(new row, remembered_xq)."""
    k = KEYS[id_]
    if direction in ('left', 'right'):
        keys = row_keys(k.row)
        i = keys.index(k) + (1 if direction == 'right' else -1)
        return keys[i % len(keys)].id
    row = (k.row + (1 if direction == 'down' else -1)) % ROWS
    return key_at(row, remembered_xq)


# --- labels ---------------------------------------------------------------------------------
CYRILLIC = 'ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧ'     # the monitor's codes 60h..7Eh
ARROW_LEFT, ARROW_RIGHT = 0x08, 0x18             # 6x8 label codes of the two new glyphs
ARROW_UP, ARROW_DOWN = 0x0B, 0x0F                # the font's own 6x8 arrows
HOME = 0x0C                                      # 4x6 code of the ↖ glyph


def char_code(c):
    """The monitor's character code of a label character (KOI-7: Cyrillic at 60h..7Eh)."""
    if c in CYRILLIC:
        return 0x60 + CYRILLIC.index(c)
    if c == '↖':
        return HOME
    if 0x20 <= ord(c) < 0x60:
        return ord(c)
    raise ValueError('no code for %r' % c)


def _codes(text):
    return tuple(char_code(c) for c in text)


def _name(text):
    if text in ('←', '→', '↑', '↓'):
        return '8', ({'←': ARROW_LEFT, '→': ARROW_RIGHT, '↑': ARROW_UP, '↓': ARROW_DOWN}[text],)
    return ('8' if len(text) <= 2 and text != '↖' else '4'), _codes(text)


FUNCTION_NAMES = {  # code: (RUS, LAT)
    0x08: ('←', '←'), 0x18: ('→', '→'), 0x19: ('↑', '↑'), 0x1A: ('↓', '↓'), 0x0C: ('↖', '↖'),
    0x1F: ('СТР', 'CLS'), 0x1B: ('АР2', 'ESC'), 0x09: ('ТАБ', 'TAB'), 0x0A: ('ПС', 'LF'),
    0x0D: ('ВК', 'CR'), 0x7F: ('ЗБ', 'BS'),
}
MODIFIER_NAMES = {SHIFT_LINE: ('СС', 'SHF'), CTRL_LINE: ('УС', 'CTL'), RUS_LINE: ('РУС', 'LAT')}


def monitor_char(line, rus, sh, ct):
    """The code the monitor's FE72 returns for matrix key `line` (0..63) with these modifiers."""
    return monitor_decoder.table()[line][monitor_decoder.combo(int(bool(rus)), int(bool(sh)), int(bool(ct)))]


def label(key, rus, sh, ct):
    """(font, codes): font '8' (6x8, native glyph codes; 08h / 18h are the new ← → glyphs),
    '4' (4x6, small-font codes) or None (Space: no label)."""
    lang = 0 if rus else 1
    if key.line in MODIFIER_NAMES:
        return _name(MODIFIER_NAMES[key.line][lang])
    code = monitor_char(key.line, rus, sh, ct)
    if code == 0x20:
        return None, ()
    if 0x20 < code <= 0x7E:
        return '8', (code,)
    if code in FUNCTION_NAMES:
        return _name(FUNCTION_NAMES[code][lang])
    if key.line in F_LINES:
        return '8', _codes('F%d' % (key.line - 2))
    own = monitor_char(key.line, rus, sh, 0)
    if not 0x20 < own <= 0x7E:
        raise ValueError('key %d: no label for code %02X' % (key.id, code))
    return '8', (own,)


def lit_by_ctrl(key, rus, sh):
    """With УС held this matrix cap is lit: Ctrl changes what the key produces."""
    return key.line < 64 and monitor_char(key.line, rus, sh, 1) != monitor_char(key.line, rus, sh, 0)


# --- glyphs ---------------------------------------------------------------------------------
def _rows(*rows, width):
    v = 0
    for r in rows:
        assert len(r) == width
        for c in r:
            v = v << 1 | (c == '#')
    return v


_A = ('.#..', '#.#.', '###.', '#.#.', '#.#.', '....')
_C = ('.##.', '#...', '#...', '#...', '.##.', '....')
_T = ('###.', '.#..', '.#..', '.#..', '.#..', '....')
SMALL_GLYPHS = {  # 4x6 code: 24 bits, MSB first, row by row (shapes of the reference render of the K1 keyboard)
    HOME: _rows('###.', '##..', '#.#.', '...#', '....', '....', width=4),
    0x32: _rows('##..', '..#.', '.#..', '#...', '###.', '....', width=4),                   # 2
    0x41: _rows(*_A, width=4), 0x61: _rows(*_A, width=4),                                     # A А
    0x42: _rows('##..', '#.#.', '##..', '#.#.', '##..', '....', width=4),                   # B (В)
    0x43: _rows(*_C, width=4), 0x73: _rows(*_C, width=4),                                     # C С
    0x45: _rows('###.', '#...', '##..', '#...', '###.', '....', width=4),                   # E
    0x46: _rows('###.', '#...', '##..', '#...', '#...', '....', width=4),                   # F
    0x48: _rows('#.#.', '#.#.', '###.', '#.#.', '#.#.', '....', width=4),                   # H
    0x4C: _rows('#...', '#...', '#...', '#...', '###.', '....', width=4),                   # L
    0x53: _rows('.##.', '#...', '.#..', '..#.', '##..', '....', width=4),                   # S
    0x54: _rows(*_T, width=4), 0x74: _rows(*_T, width=4),                                     # T Т
    0x62: _rows('###.', '#...', '##..', '#.#.', '##..', '....', width=4),                   # Б
    0x72: _rows('##..', '#.#.', '##..', '#...', '#...', '....', width=4),                   # Р
    0x75: _rows('#.#.', '#.#.', '.##.', '..#.', '##..', '....', width=4),                   # У
}
# The two new 6x8 glyphs, in the style of the font's ↑ (0Bh) and ↓ (0Fh): a 3-step head
# (2, 4, 6 dots) and a 2-dot shaft. native_glyph is blank at 08h and 18h, so RTL may OR them.
ARROW_GLYPHS = {
    ARROW_LEFT: _rows('......', '..#...', '.##...', '######', '######', '.##...', '..#...', '......', width=6),
    ARROW_RIGHT: _rows('......', '...#..', '...##.', '######', '######', '...##.', '...#..', '......', width=6),
}


def native_font(path=FONT_VH):
    font = {}
    with open(path, encoding='utf-8') as f:
        for m in re.finditer(r"7'd(\d+):native_glyph=48'b([01]{48})", f.read()):
            font[int(m.group(1))] = int(m.group(2), 2)
    return font


_FONT = None


def glyph8(code):
    """48 bits of a 6x8 label glyph (MSB first, row by row)."""
    global _FONT
    if _FONT is None:
        _FONT = native_font()
    return _FONT.get(code, 0) | ARROW_GLYPHS.get(code, 0)


# --- palettes and drawing -------------------------------------------------------------------
PALETTES = (
    dict(name='v1.1', pcb=0xC8841A, edge=0x5A3A08,
         sets=dict(A=(0xB0308F, 0xD458B4, 0x6E1A58, 0xFFFFFF), S=(0x5638C0, 0x7C60E0, 0x2E1D70, 0xFFFFFF),
                   F=(0xEE86BA, 0xFBB8DA, 0xA8507E, 0xFFFFFF)),
         roles=dict(a='A', s='S', e='S', f='F', c='F', h='F', p='F')),
    dict(name='v1.4', pcb=0x1E56C8, edge=0x0A2A70,
         sets=dict(A=(0xC9C9C4, 0xECECE8, 0x8A8A86, 0x202020), S=(0x5D646E, 0x808892, 0x363A40, 0xFFFFFF),
                   F=(0xE2492F, 0xF57A60, 0x962C1A, 0xFFFFFF)),
         roles=dict(a='A', s='S', e='F', f='A', c='F', h='S', p='A')),
    dict(name='mono'),
)
SELECTED = (0xFFE040, 0xFFF4A0, 0xA08000, 0x000000)
MONO = 2


def text_colour(green):
    return 0x00FF00 if green else 0xFFFFFF


def cap_lit(key, state):
    pulled = set(state.get('pulled', ()))
    held = {SHIFT_LINE: state.get('sh'), CTRL_LINE: state.get('ct'), RUS_LINE: state.get('rus_line')}
    if key.line in pulled or held.get(key.line):
        return True
    return bool(state.get('ct')) and lit_by_ctrl(key, state.get('rus'), state.get('sh'))


def _fill(img, x, y, w, h, c):
    for j in range(y, y + h):
        img[j][x:x + w] = [c] * w


def _draw_glyph(img, x, y, bits, w, h, c):
    for r in range(h):
        for col in range(w):
            if bits >> ((h - 1 - r) * w + (w - 1 - col)) & 1:
                img[y + r][x + col] = c


def draw_cap(img, key, state):
    cx, cy, cw, ch = cap_rect(key)
    selected, lit = key.id == state.get('selected'), cap_lit(key, state)
    pal = state.get('palette', 0)
    if pal == MONO:
        t = text_colour(state.get('green'))
        if lit:
            _fill(img, cx, cy, cw, ch, t)
            fg = 0x000000
        else:
            _fill(img, cx, cy, cw, ch, 0x000000)
            for i in range(cx, cx + cw):
                img[cy][i] = img[cy + ch - 1][i] = t
            for j in range(cy, cy + ch):
                img[j][cx] = img[j][cx + cw - 1] = t
            fg = t
        if selected:  # inner frame: columns at inset 2, rows at inset 1 (clear of the 6x8 label)
            for i in range(cx + 2, cx + cw - 2):
                img[cy + 1][i] = img[cy + ch - 2][i] = fg
            for j in range(cy + 1, cy + ch - 1):
                img[j][cx + 2] = img[j][cx + cw - 3] = fg
    else:
        p = PALETTES[pal]
        face, hi, sh, fg = SELECTED if selected else p['sets'][p['roles'][key.role]]
        if lit:
            face, hi, fg = fg, fg, face
        _fill(img, cx, cy, cw, ch, face)
        for i in range(cx, cx + cw):
            img[cy][i] = hi
            img[cy + ch - 1][i] = img[cy + ch - 2][i] = sh
        for j in range(cy, cy + ch - 2):
            img[j][cx] = hi
            img[j][cx + cw - 1] = sh
    font, codes = label(key, state.get('rus'), state.get('sh'), state.get('ct'))
    mid, n = cx + cw // 2, len(codes)
    if font == '8':
        x = mid - 3 if n == 1 else mid - n * 6 // 2 + 1
        for c in codes:
            _draw_glyph(img, x, cy + 2, glyph8(c), 6, 8, fg)
            x += 6
    elif font == '4':
        x = mid - (4 * n - 1) // 2
        for c in codes:
            _draw_glyph(img, x, cy + 3, SMALL_GLYPHS[c], 4, 6, fg)
            x += 4


def render_panel(state, frame=None):
    """The 408 x 300 picture (rows of 0xRRGGBB): the background bit frame (122400 bits, 1 = text
    colour) and, when state['open'], the panel over it. state: open, selected (key id), rus, sh,
    ct (the СС / УС lines), rus_line (the РУС line), pulled (lines 0..66 pulled now), palette
    (0 v1.1, 1 v1.4, 2 mono), green (Text colour Green)."""
    t = text_colour(state.get('green'))
    bits = frame if frame is not None else [0] * (WIDTH * HEIGHT)
    if len(bits) != WIDTH * HEIGHT:
        raise ValueError('frame has %d bits, expected %d' % (len(bits), WIDTH * HEIGHT))
    img = [[t if bits[y * WIDTH + x] else 0x000000 for x in range(WIDTH)] for y in range(HEIGHT)]
    if state.get('open'):
        x0, y0, pw, ph = PANEL
        pal = state.get('palette', 0)
        pcb, edge = (0x000000, t) if pal == MONO else (PALETTES[pal]['pcb'], PALETTES[pal]['edge'])
        _fill(img, x0, y0, pw, ph, pcb)
        for i in range(x0, x0 + pw):
            img[y0][i] = img[y0 + ph - 1][i] = edge
        for j in range(y0, y0 + ph):
            img[j][x0] = img[j][x0 + pw - 1] = edge
        for k in KEYS:
            draw_cap(img, k, state)
    return img


def read_frame(path):
    """A bit frame: one 0/1 per line, // comments (fpga/sim/golden/*.hex)."""
    with open(path, encoding='ascii') as f:
        return [int(l.strip(), 16) & 1 for l in f if l.strip() and not l.lstrip().startswith('//')]
