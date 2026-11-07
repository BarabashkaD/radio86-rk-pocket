import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import package  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))


class PackageTest(unittest.TestCase):
    def test_bit_reverse_round_trip(self):
        data = bytes(range(256))
        self.assertEqual(package.reverse_bits(package.reverse_bits(data)), data)
        self.assertEqual(package.reverse_bits(b'\x01\x02\x96\x80'), b'\x80\x40\x69\x01')

    def test_graphic_layout(self):
        encoded = package.graphic(36, 36, 'RK', 2)
        self.assertEqual(len(encoded), 36 * 36 * 2)

    def test_definitions_within_limits(self):
        self.assertEqual(package.check_definitions(os.path.join(ROOT, 'package')), [])

    def test_interact_json_is_small(self):
        with open(os.path.join(ROOT, 'package', 'core', 'interact.json'), encoding='utf-8') as f:
            variables = json.load(f)['interact']['variables']
        self.assertLessEqual(len(variables), 16)
        self.assertLessEqual(sum(len(v['options']) for v in variables if v['type'] == 'list'), 20)
        self.assertEqual([v['name'] for v in variables],
                         ['Reset', 'Cold boot', 'Sound', 'Text colour', 'Keys', 'Keys on', 'Escape (AR2)'])
        bad = [dict(v) for v in variables]
        bad[0]['id'] = 1
        self.assertTrue(package.check_interact(bad))
        big = [dict(v) for v in variables]
        big[4]['options'] = [{'value': i, 'name': str(i)} for i in range(16)]
        self.assertTrue(package.check_interact(big))

    def test_limits_are_enforced(self):
        with open(os.path.join(ROOT, 'package', 'core', 'core.json'), encoding='utf-8') as f:
            core = json.load(f)
        core['core']['metadata']['description'] = 'x' * 64
        self.assertTrue(package.check_core(core))


if __name__ == '__main__':
    unittest.main()
