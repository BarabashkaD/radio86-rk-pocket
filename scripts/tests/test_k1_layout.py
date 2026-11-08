"""K1 key table, monitor decoder, generated Verilog and panel model.

The Verilog checks need iverilog: IVERILOG (the path of iverilog) or iverilog on PATH.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'k1'))
import gen_verilog  # noqa: E402
import layout  # noqa: E402
import monitor_decoder  # noqa: E402
import render  # noqa: E402

ROOT = layout.ROOT
RTL = os.path.join(ROOT, 'fpga', 'rtl')
K = {k.line: k for k in layout.KEYS}


def letter(c):
    return K[33 + ord(c) - ord('A')]


class KeyTableTest(unittest.TestCase):
    def test_keys(self):
        self.assertEqual(len(layout.KEYS), 67)
        self.assertEqual([k.id for k in layout.KEYS], list(range(67)))
        self.assertEqual(sorted(k.line for k in layout.KEYS), list(range(67)))
        self.assertEqual([k.row for k in layout.KEYS], sorted(k.row for k in layout.KEYS))

    def test_rows_left_to_right_without_overlap(self):
        for r in range(layout.ROWS):
            keys = layout.row_keys(r)
            for a, b in zip(keys, keys[1:]):
                self.assertLessEqual(a.x + a.w, b.x, (a, b))
            self.assertGreaterEqual(keys[0].x, 0)
            self.assertLessEqual(keys[-1].x + keys[-1].w, layout.QUARTERS)

    def test_caps_inside_panel(self):
        x0, y0, pw, ph = layout.PANEL
        for k in layout.KEYS:
            cx, cy, cw, ch = layout.cap_rect(k)
            self.assertTrue(x0 < cx and cx + cw < x0 + pw - 1 and y0 < cy and cy + ch < y0 + ph - 1, k)
        self.assertEqual(layout.cap_rect(K[63]), (62 + 2 + 65, 218 + 2 + 65, 129, 12))

    def test_navigation(self):
        g = letter('G').id
        self.assertEqual(layout.neighbour(layout.row_keys(1)[0].id, 'left', 0), layout.row_keys(1)[-1].id)
        self.assertEqual(layout.neighbour(layout.row_keys(1)[-1].id, 'right', 0), layout.row_keys(1)[0].id)
        self.assertEqual(layout.neighbour(K[2].id, 'up', 2), layout.key_at(5, 2))      # АР2 up wraps to УС
        self.assertEqual(layout.key_at(5, 2), K[65].id)
        self.assertEqual(layout.neighbour(K[65].id, 'down', 2), K[2].id)
        self.assertEqual(layout.key_at(2, layout.centre_xq(g)), g)
        self.assertEqual(layout.key_at(0, 36), K[7].id)       # gap, tie: to the left (F5)
        self.assertEqual(layout.key_at(0, 37), K[0].id)       # nearer ↖
        self.assertEqual(layout.key_at(5, 39), K[12].id)      # centre distance: ← (46) beats Space (26)
        self.assertEqual(layout.key_at(2, 0), letter('J').id)
        self.assertEqual(layout.centre_xq(K[63].id), 26)


class MonitorDecoderTest(unittest.TestCase):
    def test_special_results(self):
        self.assertEqual(monitor_decoder.decode(None, 0, 0, 0), 0xFF)
        self.assertEqual(monitor_decoder.decode(None, 1, 1, 1), 0xFF)
        self.assertEqual(monitor_decoder.decode(39, 0, 0, 0, rus_line=True), 0xFE)

    def test_spot_codes(self):
        mc = layout.monitor_char
        g = letter('G').line
        self.assertEqual(mc(g, 0, 0, 0), ord('G'))
        self.assertEqual(mc(g, 1, 0, 0), 0x67)             # Г
        self.assertEqual(mc(g, 0, 1, 0), 0x67)
        self.assertEqual(mc(g, 1, 1, 0), ord('G'))
        self.assertEqual(mc(g, 1, 1, 1), 0x07)
        self.assertEqual(mc(11, 0, 1, 0), 0x5F)            # Shift + ЗБ = _
        self.assertEqual(mc(11, 1, 1, 0), 0x5F)
        self.assertEqual(mc(11, 0, 0, 1), 0x1F)
        self.assertEqual(mc(17, 0, 1, 0), ord('!'))
        self.assertEqual(mc(17, 0, 1, 1), ord('1'))        # Ctrl cancels Shift on digits
        self.assertEqual(mc(63, 1, 1, 1), 0x20)


def iverilog():
    path = os.environ.get('IVERILOG') or shutil.which('iverilog')
    return path if path and os.path.isfile(path) else shutil.which(path or 'iverilog')


TB = r'''
module tb_k1_layout;
`include "pocket_key_defs.vh"
`include "pocket_k1_layout.vh"
integer k, c, r, x;
initial begin
    for (k = 0; k < 64; k = k + 1)
        for (c = 0; c < 8; c = c + 1)
            $display("nc %0d %0d %0d", k, c, native_character(k, c[2], c[1], c[0]));
    for (k = 0; k < 67; k = k + 1) begin
        $display("key %0d %0d %0d %0d %0d %0d %0d %0d %0d", k, k1_row(k), k1_x(k), k1_w(k), k1_role(k), k1_line(k),
                 k1_cap_x(k), k1_cap_w(k), k1_centre(k));
        for (c = 0; c < 8; c = c + 1) $display("label %0d %0d %0d", k, c, k1_label(k, c[2], c[1], c[0]));
        for (c = 0; c < 4; c = c + 1) $display("lit %0d %0d %0d", k, c, k1_lit_ctrl(k, c[1], c[0]));
    end
    for (r = 0; r < 6; r = r + 1) begin
        $display("row %0d %0d %0d", r, k1_row_first(r), k1_row_last(r));
        for (x = 0; x < 64; x = x + 1) $display("at %0d %0d %0d", r, x, k1_key_at(r, x));
    end
    for (c = 0; c < 128; c = c + 1) $display("glyph %0d %0d %0d", c, k1_small_glyph(c), k1_arrow_glyph(c));
    $finish;
end
endmodule
'''


def expected_tb_lines():
    out = []
    for k in range(64):
        for c in range(8):
            out.append('nc %d %d %d' % (k, c, monitor_decoder.table()[k][c]))
    for k in layout.KEYS:
        cx, _, cw, _ = layout.cap_rect(k)
        out.append('key %d %d %d %d %d %d %d %d %d' % (k.id, k.row, k.x, k.w, layout.ROLES.index(k.role), k.line,
                                                       cx - layout.PANEL[0], cw, layout.centre_xq(k.id)))
        for c in range(8):
            out.append('label %d %d %d' % (k.id, c, gen_verilog.label_word(*layout.label(k, c >> 2 & 1, c >> 1 & 1, c & 1))))
        for c in range(4):
            out.append('lit %d %d %d' % (k.id, c, int(layout.lit_by_ctrl(k, c >> 1 & 1, c & 1))))
    for r in range(6):
        keys = layout.row_keys(r)
        out.append('row %d %d %d' % (r, keys[0].id, keys[-1].id))
        for x in range(64):
            out.append('at %d %d %d' % (r, x, layout.key_at(r, x)))
    for c in range(128):
        out.append('glyph %d %d %d' % (c, layout.SMALL_GLYPHS.get(c, 0), layout.ARROW_GLYPHS.get(c, 0)))
    return out


class VerilogTest(unittest.TestCase):
    def test_generated_vh_up_to_date(self):
        with open(gen_verilog.OUT, encoding='utf-8', newline='') as f:
            self.assertEqual(f.read(), gen_verilog.generate(), 'run python -B scripts/k1/gen_verilog.py')

    def test_verilog_matches_model(self):
        iv = iverilog()
        if not iv:
            self.skipTest('iverilog not found (set IVERILOG)')
        vvp = shutil.which('vvp', path=os.path.dirname(os.path.abspath(iv)))
        work = os.path.join(ROOT, 'build', 'k1', 'test')
        os.makedirs(work, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=work) as d:
            src, exe = os.path.join(d, 'tb_k1_layout.v'), os.path.join(d, 'tb.vvp')
            with open(src, 'w', encoding='ascii', newline='\n') as f:
                f.write(TB)
            env = dict(os.environ, PATH=os.path.dirname(os.path.abspath(iv)) + os.pathsep + os.environ.get('PATH', ''))
            res = subprocess.run([iv, '-g2012', '-I', RTL, '-o', exe, src], capture_output=True, text=True, env=env)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            res = subprocess.run([vvp, '-n', exe], capture_output=True, text=True, env=env)
        got = [l.strip() for l in res.stdout.splitlines() if l.strip() and not l.startswith('VCD')]
        got = [l for l in got if l.split()[0] in ('nc', 'key', 'label', 'lit', 'row', 'at', 'glyph')]
        want = expected_tb_lines()
        bad = [(g, w) for g, w in zip(got, want) if g != w]
        self.assertEqual(len(got), len(want))
        self.assertFalse(bad, 'first differences: %s' % bad[:5])


class LabelTest(unittest.TestCase):
    def test_spot_labels(self):
        g = letter('G')
        self.assertEqual(layout.label(g, 0, 0, 0), ('8', (ord('G'),)))
        self.assertEqual(layout.label(g, 1, 0, 0), ('8', (0x67,)))           # Г
        self.assertEqual(layout.label(K[11], 0, 1, 0), ('8', (0x5F,)))       # Shift on ЗБ: _
        self.assertEqual(layout.label(K[11], 1, 0, 0), ('8', (0x7A, 0x62)))  # ЗБ
        self.assertEqual(layout.label(K[11], 0, 0, 0), ('8', (ord('B'), ord('S'))))
        m = letter('M')
        self.assertEqual(layout.label(m, 1, 0, 1), ('8', (0x77, 0x6B)))      # Ctrl+M: ВК
        self.assertEqual(layout.label(m, 0, 0, 1), ('8', (ord('C'), ord('R'))))
        self.assertTrue(layout.lit_by_ctrl(m, 0, 0))
        self.assertEqual(layout.label(letter('A'), 0, 0, 1), ('8', (ord('A'),)))  # 01h: own glyph
        self.assertEqual(layout.label(K[3], 0, 0, 0), ('8', (ord('F'), ord('1'))))
        self.assertEqual(layout.label(K[1], 1, 0, 0), ('4', (0x73, 0x74, 0x72)))  # СТР
        self.assertEqual(layout.label(K[0], 0, 0, 0), ('4', (layout.HOME,)))
        self.assertEqual(layout.label(K[12], 0, 0, 0), ('8', (layout.ARROW_LEFT,)))
        self.assertEqual(layout.label(K[13], 0, 0, 0), ('8', (layout.ARROW_UP,)))
        self.assertEqual(layout.label(K[63], 0, 0, 0), (None, ()))
        self.assertEqual(layout.label(K[66], 0, 0, 0), ('4', (ord('L'), ord('A'), ord('T'))))
        self.assertEqual(layout.label(K[64], 1, 0, 0), ('8', (0x73, 0x73)))      # СС
        self.assertFalse(layout.lit_by_ctrl(K[64], 0, 0))
        self.assertTrue(layout.lit_by_ctrl(K[17], 0, 1))                       # Shift+1 vs Ctrl: 1
        self.assertFalse(layout.lit_by_ctrl(K[17], 0, 0))

    def test_every_label_has_glyphs(self):
        for k in layout.KEYS:
            for c in range(8):
                font, codes = layout.label(k, c >> 2 & 1, c >> 1 & 1, c & 1)
                self.assertIn(len(codes), (0, 1, 2, 3) if font else (0,))
                for code in codes:
                    if font == '4':
                        self.assertIn(code, layout.SMALL_GLYPHS, (k, c))
                    else:
                        self.assertNotEqual(layout.glyph8(code), 0, (k, c, code))
                if font == '8':
                    self.assertLessEqual(len(codes), 2)


def gif_frames(data):
    """A minimal GIF decoder for the writer's own files: the list of index frames."""
    pos = 13 + 3 * (2 << (data[10] & 7))
    frames = []
    while data[pos] != 0x3B:
        if data[pos] == 0x21:
            pos += 2
            while data[pos]:
                pos += data[pos] + 1
            pos += 1
            continue
        w, h = struct.unpack('<HH', data[pos + 5:pos + 9])
        min_size, pos, blocks = data[pos + 10], pos + 11, b''
        while data[pos]:
            blocks += data[pos + 1:pos + 1 + data[pos]]
            pos += data[pos] + 1
        pos += 1
        clear, end = 1 << min_size, (1 << min_size) + 1
        acc = nbits = i = 0
        out, prev = [], None
        width = min_size + 1
        table = None
        while True:
            while nbits < width:
                acc |= blocks[i] << nbits
                i, nbits = i + 1, nbits + 8
            code, acc, nbits = acc & ((1 << width) - 1), acc >> width, nbits - width
            if code == clear:
                table, width, prev = [[j] for j in range(clear)] + [None, None], min_size + 1, None
                continue
            if code == end:
                break
            entry = table[code] if code < len(table) else table[prev] + [table[prev][0]]
            out += entry
            if prev is not None and len(table) < 4096:
                table.append(table[prev] + [entry[0]])
            if len(table) == 1 << width and width < 12:
                width += 1
            prev = code
        frames.append((w, h, out))
    return frames


class RenderTest(unittest.TestCase):
    def test_png_round_trip(self):
        img = [[(x * 37 + y * 101) & 0xFFFFFF for x in range(7)] for y in range(5)]
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, 'a.png')
            render.write_png(p, img)
            self.assertEqual(render.read_png(p), img)

    def test_gif_round_trip(self):
        a = [[(x * y) % 7 * 0x112233 for x in range(90)] for y in range(70)]
        b = [[0xFFFFFF if (x ^ y) & 4 else 0 for x in range(90)] for y in range(70)]
        data = render.gif_bytes([a, b])
        colours = sorted({c for f in (a, b) for row in f for c in row})
        frames = gif_frames(data)
        self.assertEqual(len(frames), 2)
        for f, (w, h, idx) in zip((a, b), frames):
            self.assertEqual((w, h), (90, 70))
            self.assertEqual([colours[i] for i in idx], [c for row in f for c in row])
        seed, noise = 1, []
        for _ in range(150 * 150):                                    # fills the 4096-code table
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            noise.append(seed >> 16 & 0xFF)
        n = [[c * 0x010101 for c in noise[y * 150:(y + 1) * 150]] for y in range(150)]
        colours = sorted({c for row in n for c in row})
        (w, h, idx), = gif_frames(render.gif_bytes([n]))
        self.assertEqual([colours[i] for i in idx], [c for row in n for c in row])

    def test_closed_panel_is_background(self):
        frame = [(i // 3) & 1 for i in range(layout.WIDTH * layout.HEIGHT)]
        img = layout.render_panel(dict(open=False, green=True), frame)
        self.assertEqual(img[0][:6], [0, 0, 0, 0x00FF00, 0x00FF00, 0x00FF00])
        img = layout.render_panel(dict(open=True, palette=2, selected=None), frame)
        self.assertEqual(img[218][62], 0xFFFFFF)                      # mono edge = text colour
        self.assertEqual(img[217][62:65], [0xFFFFFF if (217 * 408 + x) // 3 & 1 else 0 for x in range(62, 65)])


if __name__ == '__main__':
    unittest.main()
