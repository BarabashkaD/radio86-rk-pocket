import os
import sys
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'fpga', 'sim'))
import frame_compare  # noqa: E402

W, H = frame_compare.W, frame_compare.H


def frame_with(dots):
    f = [0] * (W * H)
    for x, y in dots:
        f[y * W + x] = 1
    return f


class CursorMaskTest(unittest.TestCase):
    """--cursor masks the 6 x 10 cell at x = 6 col + 6 - X0, y = 10 row; nothing else."""

    def test_difference_inside_the_cell_passes(self):
        # X0 42, column 8, row 3: the monitor's home cell, window x 12..17, y 30..39
        a = frame_with([(12, 30), (17, 39), (100, 100)])
        b = frame_with([(13, 31), (100, 100)])
        ok, message = frame_compare.compare(a, b, cursor=(8, 3), x0=42)
        self.assertTrue(ok, message)
        self.assertIn('masked cursor cell at (12, 30)', message)

    def test_difference_outside_the_cell_fails(self):
        a = frame_with([(13, 31)])
        for dot in [(11, 30), (18, 30), (12, 29), (12, 40), (200, 150)]:
            b = frame_with([(13, 31), dot])
            ok, message = frame_compare.compare(a, b, cursor=(8, 3), x0=42)
            self.assertFalse(ok, 'dot %s: %s' % (dot, message))

    def test_x0_moves_the_cell(self):
        a = frame_with([(0, 0)])
        b = frame_with([])
        self.assertTrue(frame_compare.compare(a, b, cursor=(10, 0), x0=66)[0])
        self.assertFalse(frame_compare.compare(a, b, cursor=(10, 0), x0=42)[0])

    def test_cell_clipped_to_the_window(self):
        # column 5 with X0 42: x = -6..-1, outside; column 6: x 0..5
        a = frame_with([(0, 290)])
        b = frame_with([])
        self.assertFalse(frame_compare.compare(a, b, cursor=(5, 29), x0=42)[0])
        self.assertTrue(frame_compare.compare(a, b, cursor=(6, 29), x0=42)[0])

    def test_without_cursor_one_cell_tolerance(self):
        a = frame_with([(12, 30)])
        self.assertTrue(frame_compare.compare(a, frame_with([]))[0])
        self.assertFalse(frame_compare.compare(a, frame_with([(200, 150)]))[0])

    def test_command_line(self):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, f in (('a.hex', frame_with([(12, 30)])), ('b.hex', frame_with([]))):
                path = os.path.join(d, name)
                with open(path, 'w', encoding='ascii', newline='\n') as out:
                    out.write(''.join('%x\n' % v for v in f))
                paths.append(path)
            cursor = os.path.join(d, 'cursor.txt')
            with open(cursor, 'w', encoding='ascii', newline='\n') as out:
                out.write('8 3\n')
            self.assertEqual(frame_compare.main(paths + ['--cursor', cursor, '--x0', '42']), 0)
            with open(cursor, 'w', encoding='ascii', newline='\n') as out:
                out.write('20 3\n')
            self.assertEqual(frame_compare.main(paths + ['--cursor', cursor, '--x0', '42']), 1)


if __name__ == '__main__':
    unittest.main()
