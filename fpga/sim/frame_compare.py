#!/usr/bin/env python3
"""Compares two 408 x 300 one-bit frames written by $writememh (spec 9.7).

Usage: python -B fpga/sim/frame_compare.py <frame.hex> <golden.hex>
Passes (exit 0) when the frames are equal, or differ only inside one character cell of the
monitor text (6 x 10 window dots: the blinking cursor). Text column c is h_cnt 24 + 6c, so window
x = 6c - 36; text row k is v_cnt 20k, window y = 10k (rk86_video_stream geometry).
"""
import sys

W, H = 408, 300


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


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    diff = [i for i in range(W * H) if a[i] != b[i]]
    if not diff:
        print('PASS frames identical')
        return 0
    cells = {((i % W + 36) // 6, (i // W) // 10) for i in diff}
    if len(cells) == 1:
        print('PASS frames equal outside one character cell %s (%d dots differ)' % (cells.pop(), len(diff)))
        return 0
    print('ERROR: frames differ in %d dots over %d character cells, first %s' % (len(diff), len(cells), sorted(cells)[:8]))
    return 1


if __name__ == '__main__':
    sys.exit(main())
