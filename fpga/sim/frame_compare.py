#!/usr/bin/env python3
"""Compares two 408 x 300 one-bit frames written by $writememh (spec 9.7).

Usage: python -B fpga/sim/frame_compare.py <frame.hex> <golden.hex> [--cursor FILE --x0 N]
Text column c of the 8275 has its six dots at h_cnt 6c + 6 (pocket_raster), so window x = 6c + 6 - X0,
X0 being the window's first h_cnt (pocket_window.v); text row k is window y = 10k.
With --cursor (a file "<col> <row>", the cursor cell the system TB wrote as cursor.txt) the 6 x 10
cell of the cursor is masked in both frames (clipped to the window) and the rest must be equal.
Without it the frames pass when they are equal, or differ only inside one character cell of the
monitor text (the blinking cursor).
"""
import argparse
import sys

W, H = 408, 300
DEFAULT_X0 = 42


def load(path):
    values = []
    with open(path, encoding='ascii') as f:
        for line in f:
            text = line.split('//')[0].strip()
            if not text or text.startswith('@'):
                continue
            values.extend(int(t, 16) for t in text.split())
    if len(values) != W * H:
        raise SystemExit('ERROR: %s has %d values, expected %d' % (path, len(values), W * H))
    return values


def cursor_cell(col, row, x0):
    """The window rectangle (x, y, x_end, y_end) of text cell (col, row), clipped; None if outside."""
    x, y = 6 * col + 6 - x0, 10 * row
    xa, ya, xb, yb = max(x, 0), max(y, 0), min(x + 6, W), min(y + 10, H)
    return (x, y, xa, ya, xb, yb) if xa < xb and ya < yb else (x, y, None, None, None, None)


def mask(frame, xa, ya, xb, yb):
    out = list(frame)
    for yy in range(ya, yb):
        for xx in range(xa, xb):
            out[yy * W + xx] = 0
    return out


def compare(a, b, cursor=None, x0=DEFAULT_X0):
    """(ok, message). cursor: (col, row) or None."""
    if cursor is not None:
        x, y, xa, ya, xb, yb = cursor_cell(cursor[0], cursor[1], x0)
        note = 'masked cursor cell at (%d, %d)' % (x, y)
        if xa is not None:
            a, b = mask(a, xa, ya, xb, yb), mask(b, xa, ya, xb, yb)
        else:
            note += ', outside the window'
        diff = [i for i in range(W * H) if a[i] != b[i]]
        if not diff:
            return True, 'PASS frames equal (%s)' % note
        cells = sorted({((i % W + x0 - 6) // 6, (i // W) // 10) for i in diff})
        return False, 'ERROR: frames differ in %d dots over %d character cells, first %s (%s)' % (
            len(diff), len(cells), cells[:8], note)
    diff = [i for i in range(W * H) if a[i] != b[i]]
    if not diff:
        return True, 'PASS frames identical'
    cells = {((i % W + x0 - 6) // 6, (i // W) // 10) for i in diff}
    if len(cells) == 1:
        return True, 'PASS frames equal outside one character cell %s (%d dots differ)' % (cells.pop(), len(diff))
    return False, 'ERROR: frames differ in %d dots over %d character cells, first %s' % (len(diff), len(cells), sorted(cells)[:8])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('frame')
    ap.add_argument('golden')
    ap.add_argument('--cursor', help='file "<col> <row>": the cursor cell to mask')
    ap.add_argument('--x0', type=int, default=DEFAULT_X0, help='the window\'s first h_cnt (pocket_window.v X0)')
    a = ap.parse_args(argv)
    cursor = None
    if a.cursor:
        with open(a.cursor, encoding='ascii') as f:
            fields = f.read().split()
        if len(fields) != 2:
            raise SystemExit('ERROR: %s: expected "<col> <row>"' % a.cursor)
        cursor = (int(fields[0]), int(fields[1]))
    ok, message = compare(load(a.frame), load(a.golden), cursor, a.x0)
    print(message)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
