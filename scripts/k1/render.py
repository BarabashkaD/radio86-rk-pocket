#!/usr/bin/env python3
"""Renders the K1 panel model (layout.render_panel) to PNG, and frames to an animated GIF.

Usage:
    python -B scripts/k1/render.py --frame <bit hex> --state <json> --out <png>
    python -B scripts/k1/render.py --gif <out.gif> [--delay-cs N] <png or rgb-hex files...>
    python -B scripts/k1/render.py --png-dir <folder> <rgb-hex files...>
--frame: one bit per line, // comments (fpga/sim/golden/monitor-boot.hex, rom-disk-menu.hex).
--state: a JSON object or a JSON file (keys of layout.render_panel; pulled is a list).
The PNG is the 408 x 300 picture at 2x, nearest. GIF inputs: PNG files (8-bit RGB / RGBA, as this
script writes them) or rgb-hex files (one RRGGBB per pixel, // comments, 408 x 300, scaled 2x);
GIF89a, global palette, loops forever, DELAY_CS (or --delay-cs) hundredths of a second per frame.
"""
import argparse
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout  # noqa: E402

SCALE = 2
DELAY_CS = 120  # 1.2 s


def scale(img, n=SCALE):
    out = []
    for row in img:
        wide = [c for c in row for _ in range(n)]
        out += [wide] * n
    return out


# --- PNG ------------------------------------------------------------------------------------
def _chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)


def png_bytes(img):
    h, w = len(img), len(img[0])
    raw = bytearray()
    for row in img:
        raw.append(0)
        for c in row:
            raw += bytes((c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF))
    return (b'\x89PNG\r\n\x1a\n' + _chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + _chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + _chunk(b'IEND', b''))


def write_png(path, img):
    with open(path, 'wb') as f:
        f.write(png_bytes(img))


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('%s: not a PNG' % path)
    pos, idat = 8, b''
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError('%s: only 8-bit RGB / RGBA, not interlaced' % path)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    bpp = 3 if ctype == 2 else 4
    raw, stride, prev, img, i = zlib.decompress(idat), w * bpp, bytearray(w * bpp), [], 0
    for _ in range(h):
        ft, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b, c = prev[x], prev[x - bpp] if x >= bpp else 0
            line[x] = (line[x] + [0, a, b, (a + b) // 2, _paeth(a, b, c)][ft]) & 0xFF
        img.append([line[x] << 16 | line[x + 1] << 8 | line[x + 2] for x in range(0, stride, bpp)])
        prev = line
    return img


def read_rgb_hex(path):
    with open(path, encoding='ascii') as f:
        px = [int(l.strip(), 16) for l in f if l.strip() and not l.lstrip().startswith('//')]
    if len(px) != layout.WIDTH * layout.HEIGHT:
        raise ValueError('%s: %d pixels, expected %d' % (path, len(px), layout.WIDTH * layout.HEIGHT))
    return scale([px[y * layout.WIDTH:(y + 1) * layout.WIDTH] for y in range(layout.HEIGHT)])


# --- GIF ------------------------------------------------------------------------------------
def lzw(indices, min_size):
    """GIF LZW: variable code width up to 12 bits, clear code when the table is full."""
    clear, end = 1 << min_size, (1 << min_size) + 1
    out, acc, nbits = bytearray(), 0, 0

    def emit(code, width):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += width
        while nbits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            nbits -= 8

    width, table, nxt = min_size + 1, {}, end + 1
    emit(clear, width)
    w = None
    for k in indices:
        if w is None:
            w = k
            continue
        if (w, k) in table:
            w = table[(w, k)]
            continue
        emit(w, width)
        if nxt < 4096:
            table[(w, k)] = nxt
            nxt += 1
            if nxt > 1 << width and width < 12:
                width += 1
        else:
            emit(clear, width)
            table, nxt, width = {}, end + 1, min_size + 1
        w = k
    if w is not None:
        emit(w, width)
    emit(end, width)
    if nbits:
        out.append(acc & 0xFF)
    return bytes(out)


def gif_bytes(frames, delay_cs=DELAY_CS):
    h, w = len(frames[0]), len(frames[0][0])
    colours = sorted({c for f in frames for row in f for c in row})
    if len(colours) > 256:
        raise ValueError('%d colours, a GIF palette holds 256' % len(colours))
    bits = max(1, (len(colours) - 1).bit_length())
    index = {c: i for i, c in enumerate(colours)}
    palette = b''.join(bytes((c >> 16, c >> 8 & 0xFF, c & 0xFF)) for c in colours)
    palette += b'\0' * (3 * (1 << bits) - len(palette))
    out = bytearray(b'GIF89a' + struct.pack('<HHBBB', w, h, 0x80 | (bits - 1), 0, 0) + palette)
    out += b'\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00'
    min_size = max(2, bits)
    for f in frames:
        if len(f) != h or len(f[0]) != w:
            raise ValueError('frames differ in size')
        out += b'\x21\xf9\x04\x04' + struct.pack('<H', delay_cs) + b'\x00\x00'
        out += b'\x2c' + struct.pack('<HHHHB', 0, 0, w, h, 0) + bytes((min_size,))
        data = lzw([index[c] for row in f for c in row], min_size)
        for i in range(0, len(data), 255):
            out += bytes((len(data[i:i + 255]),)) + data[i:i + 255]
        out += b'\x00'
    return bytes(out + b'\x3b')


# --- the RTL side ---------------------------------------------------------------------------
ERROR_RGB = 0x600000  # pocket_frame_video: the picture while the diagnostic error shows


def state_bus(state):
    """The 78-bit panel state bus of pocket_k1_panel.v: [0] open, [7:1] selected, [8] rus, [9] sh,
    [10] ct, [11] rus_line, [75:12] pulled matrix lines 0..63, [77:76] palette."""
    v = int(bool(state.get('open'))) | (state.get('selected', 0) & 0x7F) << 1
    for i, name in enumerate(('rus', 'sh', 'ct', 'rus_line')):
        v |= int(bool(state.get(name))) << (8 + i)
    for line in state.get('pulled', ()):
        if not 0 <= line < 64:
            raise ValueError('pulled line %d is not a matrix line' % line)
        v |= 1 << (12 + line)
    return v | (state.get('palette', 0) & 3) << 76


def picture(state, frame=None, error=False):
    """What pocket_frame_video shows: render_panel, with the error colour under the panel when
    error (the open panel covers its whole rectangle)."""
    img = layout.render_panel(state, frame)
    if error:
        x0, y0, pw, ph = layout.PANEL
        for y, row in enumerate(img):
            for x in range(len(row)):
                if not (state.get('open') and x0 <= x < x0 + pw and y0 <= y < y0 + ph):
                    row[x] = ERROR_RGB
    return img


def write_rgb_hex(path, img):
    with open(path, 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%06x\n' % c for row in img for c in row))


def read_image(path):
    with open(path, 'rb') as f:
        magic = f.read(8)
    return read_png(path) if magic == b'\x89PNG\r\n\x1a\n' else read_rgb_hex(path)


def load_state(text):
    if os.path.isfile(text):
        with open(text, encoding='utf-8') as f:
            text = f.read()
    state = json.loads(text)
    state['pulled'] = set(state.get('pulled', ()))
    return state


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--frame', help='background bit frame (hex, one bit per line)')
    ap.add_argument('--state', help='panel state: JSON text or a JSON file')
    ap.add_argument('--out', help='PNG to write')
    ap.add_argument('--gif', help='GIF to write from the input files')
    ap.add_argument('--delay-cs', type=int, default=DELAY_CS, help='GIF frame time, 1/100 s (default %d)' % DELAY_CS)
    ap.add_argument('--png-dir', help='write each input (rgb-hex) as <name>.png into this folder')
    ap.add_argument('inputs', nargs='*')
    a = ap.parse_args()
    if a.png_dir:
        os.makedirs(a.png_dir, exist_ok=True)
        for p in a.inputs:
            out = os.path.join(a.png_dir, os.path.splitext(os.path.basename(p))[0] + '.png')
            write_png(out, read_image(p))
            print('wrote %s' % out)
        return 0
    if a.gif:
        if not a.inputs:
            ap.error('--gif needs input files')
        with open(a.gif, 'wb') as f:
            f.write(gif_bytes([read_image(p) for p in a.inputs], a.delay_cs))
        print('wrote %s' % a.gif)
        return 0
    if not (a.state and a.out):
        ap.error('--state and --out are required (or --gif)')
    frame = layout.read_frame(a.frame) if a.frame else None
    write_png(a.out, scale(layout.render_panel(load_state(a.state), frame)))
    print('wrote %s' % a.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
