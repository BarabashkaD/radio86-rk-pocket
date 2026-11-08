#!/usr/bin/env python3
"""Checks the K1 panel in the RGB captures of the system scenario k1 against the model.

Usage: python -B scripts/k1/check_frames.py <run dir> [--expect N]  (N captures, default 7, numbered 1..N)   (fpga/sim/run_sim.py k1: build/sim/k1)
The run dir holds k1.log (tb_system: "STATE <n> <panel state hex> <green> <what>" per capture,
the state pocket_frame_video latched for that frame) and k1_<n>.hex (the frame: 408 x 300,
one RRGGBB per pixel). For each capture the model (layout.render_panel) is rendered for the
printed state and the panel rectangle (284 x 82 at 62, 218) is compared pixel by pixel.
Exit 0 when every capture matches.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout  # noqa: E402
import render  # noqa: E402

SHOW = 5  # mismatches listed per capture


def decode_state(bus, green=0):
    """The state of layout.render_panel from the 78-bit bus (render.state_bus layout)."""
    state = dict(open=bus & 1, selected=bus >> 1 & 0x7F, rus=bus >> 8 & 1, sh=bus >> 9 & 1,
                 ct=bus >> 10 & 1, rus_line=bus >> 11 & 1, palette=bus >> 76 & 3, green=green,
                 pulled={i for i in range(64) if bus >> (12 + i) & 1})
    if render.state_bus(state) != bus:
        raise ValueError('state %x does not round-trip' % bus)
    return state


def read_states(path):
    states = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            parts = line.split()
            if parts and parts[0] == 'STATE':
                states.append((int(parts[1]), int(parts[2], 16), int(parts[3]), ' '.join(parts[4:])))
    return states


def read_pixels(path):
    with open(path, encoding='ascii') as f:
        px = [int(l.strip(), 16) for l in f if l.strip() and not l.lstrip().startswith('//')]
    if len(px) != layout.WIDTH * layout.HEIGHT:
        raise ValueError('%s: %d pixels, expected %d' % (path, len(px), layout.WIDTH * layout.HEIGHT))
    return px


def check(run_dir, expect=7):
    states = read_states(os.path.join(run_dir, 'k1.log'))
    if not states:
        print('ERROR: no STATE lines in %s' % os.path.join(run_dir, 'k1.log'))
        return 1
    nums = [n for n, _, _, _ in states]
    if nums != list(range(1, expect + 1)):
        print('ERROR: captures %s, expected exactly %d numbered 1..%d' % (nums, expect, expect))
        return 1
    x0, y0, pw, ph = layout.PANEL
    bad = 0
    for n, bus, green, what in states:
        state = decode_state(bus, green)
        px = read_pixels(os.path.join(run_dir, 'k1_%d.hex' % n))
        model = layout.render_panel(state)
        diffs = [(x, y, px[y * layout.WIDTH + x], model[y][x])
                 for y in range(y0, y0 + ph) for x in range(x0, x0 + pw)
                 if px[y * layout.WIDTH + x] != model[y][x]]
        desc = 'open %d sel %d rus %d sh %d ct %d rus_line %d pulled %s palette %d' % (
            state['open'], state['selected'], state['rus'], state['sh'], state['ct'], state['rus_line'],
            sorted(state['pulled']) or '-', state['palette'])
        if diffs:
            bad += 1
            print('FAIL capture %d (%s; %s): %d of %d panel pixels differ' % (n, what, desc, len(diffs), pw * ph))
            for x, y, got, exp in diffs[:SHOW]:
                print('  x %d y %d: frame %06x, model %06x' % (x, y, got, exp))
        else:
            print('PASS capture %d (%s; %s): %d panel pixels match' % (n, what, desc, pw * ph))
    if bad:
        print('ERROR: %d of %d captures differ from the model' % (bad, len(states)))
        return 1
    print('PASS k1 frames: %d captures, the panel matches the model' % len(states))
    return 0


def main():
    args = sys.argv[1:]
    expect = 7
    if len(args) == 3 and args[1] == '--expect' and args[2].isdigit():
        expect = int(args[2])
        args = args[:1]
    if len(args) != 1:
        print(__doc__.strip())
        return 2
    return check(args[0], expect)


if __name__ == '__main__':
    sys.exit(main())
