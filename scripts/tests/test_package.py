import json
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import package  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))


class PackageTest(unittest.TestCase):
    def test_bit_reverse_round_trip(self):
        data = bytes(range(256))
        self.assertEqual(package.reverse_bits(package.reverse_bits(data)), data)
        self.assertEqual(package.reverse_bits(b'\x01\x02\x96\x80'), b'\x80\x40\x69\x01')

    def test_graphic_layout(self):
        encoded = package.graphic(*package.ICON)
        self.assertEqual(len(encoded), 36 * 36 * 2)
        self.assertEqual(package.ICON[:2], (36, 36))
        self.assertEqual(package.BANNER[:2], (521, 165))

    def test_banner_text_fits_inside_the_frame(self):
        width, height, text, scale = package.BANNER
        border = 8
        shadow = max(1, scale // 3)
        self.assertLessEqual((len(text) * 6 - 1) * scale + shadow, width - 2 * (border + 1))
        self.assertLessEqual(7 * scale + shadow, height - 2 * (border + 1))

    def test_graphic_is_8_bit_greyscale(self):
        # more than 16 grey levels: the openFPGA library (chunky_png) then stores the PNG it makes
        # from the image as 8-bit greyscale, not 1-bit
        for width, height, text, scale in (package.ICON, package.BANNER):
            encoded = package.graphic(width, height, text, scale)
            self.assertEqual(len(encoded), width * height * 2)
            levels = set(encoded[0::2])
            self.assertGreater(len(levels), 16, (width, height))
            self.assertIn(255, levels)                    # the frame and the text at full brightness
            self.assertEqual(set(encoded[1::2]), {0})     # the second byte of each pixel stays 0

    def test_definitions_within_limits(self):
        self.assertEqual(package.check_definitions(os.path.join(ROOT, 'package')), [])

    def test_interact_json_is_small(self):
        with open(os.path.join(ROOT, 'package', 'core', 'interact.json'), encoding='utf-8') as f:
            variables = json.load(f)['interact']['variables']
        self.assertLessEqual(len(variables), 16)
        self.assertLessEqual(sum(len(v['options']) for v in variables if v['type'] == 'list'), 20)
        self.assertEqual([v['name'] for v in variables],
                         ['Reset', 'Cold boot', 'Sound', 'Text colour', 'Keys', 'Keys on', 'Escape (AR2)',
                          'Keyboard colours'])
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

    def test_core_dates_and_platform_ids(self):
        with open(os.path.join(ROOT, 'package', 'core', 'core.json'), encoding='utf-8') as f:
            core = json.load(f)
        m = core['core']['metadata']
        m['date_release'] = '2026-11-08'
        self.assertEqual(package.check_core(core), [])
        for bad in ('2026-11-31', '2026-13-45', '2026-W45-1'):
            m['date_release'] = bad
            self.assertTrue(package.check_core(core), bad)
        m['date_release'] = '2026-11-08'
        m['platform_ids'] = []
        self.assertTrue(package.check_core(core))

    def library_zip(self, folder, change=None):
        """A zip laid out as package.py writes it, with only the files the library reads
        (no bitstream, no assets). change(files) may edit the dict; a value None drops the file."""
        pkg = os.path.join(ROOT, 'package')
        files = {}
        for name in ('core', 'data', 'updaters'):
            path = os.path.join(pkg, 'core', name + '.json')
            if os.path.exists(path):
                with open(path, 'rb') as f:
                    files['Cores/%s/%s.json' % (package.CORE_ID, name)] = f.read()
        with open(os.path.join(pkg, 'platform', package.PLATFORM + '.json'), 'rb') as f:
            files['Platforms/%s.json' % package.PLATFORM] = f.read()
        files['Cores/%s/icon.bin' % package.CORE_ID] = package.graphic(*package.ICON)
        files['Platforms/_images/%s.bin' % package.PLATFORM] = package.graphic(*package.BANNER)
        if change:
            change(files)
        path = os.path.join(folder, 'library.zip')
        with zipfile.ZipFile(path, 'w') as z:
            for name, data in files.items():
                if data is not None:
                    z.writestr(name, data)
        return path

    @staticmethod
    def edit_json(name, fn):
        def change(files):
            obj = json.loads(files[name].decode('utf-8'))
            fn(obj)
            files[name] = json.dumps(obj).encode('utf-8')
        return change

    def test_library_accepts_the_package(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(package.check_library_zip(self.library_zip(d)), [])

    def test_library_rejects(self):
        core_json = 'Cores/%s/core.json' % package.CORE_ID
        plat_json = 'Platforms/%s.json' % package.PLATFORM
        cases = {
            'year not an integer': self.edit_json(plat_json, lambda o: o['platform'].update(year='1986')),
            'url not https': self.edit_json(core_json, lambda o: o['core']['metadata'].update(url='github.com/x')),
            'metadata field missing': self.edit_json(core_json, lambda o: o['core']['metadata'].pop('description')),
            'framework field missing': self.edit_json(core_json, lambda o: o['core']['framework']['dock'].pop('analog_output')),
            'slot without required': self.edit_json('Cores/%s/data.json' % package.CORE_ID,
                                                    lambda o: o['data']['data_slots'][0].pop('required')),
            'icon size': lambda f: f.update({'Cores/%s/icon.bin' % package.CORE_ID: b'\0' * 100}),
            'platform image missing': lambda f: f.update({'Platforms/_images/%s.bin' % package.PLATFORM: None}),
            'second core': lambda f: f.update({'Cores/Other.Core/core.json': b'{}'}),
            'impossible date': self.edit_json(core_json, lambda o: o['core']['metadata'].update(date_release='2026-02-30')),
            'empty platform_ids': self.edit_json(core_json, lambda o: o['core']['metadata'].update(platform_ids=[])),
            'platform_ids not a list': self.edit_json(core_json, lambda o: o['core']['metadata'].update(platform_ids='radio86rk')),
            'author.shortname mismatch': self.edit_json(core_json, lambda o: o['core']['metadata'].update(shortname='Other')),
        }
        with tempfile.TemporaryDirectory() as d:
            for label, change in cases.items():
                self.assertTrue(package.check_library_zip(self.library_zip(d, change)), label)

    def test_updaters_declares_ai(self):
        with open(os.path.join(ROOT, 'package', 'core', 'updaters.json'), encoding='utf-8') as f:
            updaters = json.load(f)
        self.assertEqual(updaters, {'declare_ai': ['Claude']})
        self.assertEqual(package.check_updaters(updaters), [])

    def test_updaters_check(self):
        for bad in ({'declare_ai': []}, {'declare_ai': 'Claude'}, {'declare_ai': ['']}, {'declare_ai': [1]},
                    {'declare_ai': ['Claude'], 'license': {'filename': 'key.bin'}},
                    {'declare_ai': ['Claude'], 'previous': []}, {}, []):
            self.assertTrue(package.check_updaters(bad), bad)

    def guide_template(self):
        with open(os.path.join(ROOT, 'package', 'romdisks.txt'), encoding='utf-8') as f:
            return f.read()

    def test_romdisk_guide_lists_every_game_disk(self):
        disks = [{'disk': 1, 'file': 'romdisk-1.bin', 'entries': [
                     {'key': '0', 'name': 'CHESS', 'title': 'Шахматы'}, {'key': '1', 'name': 'GLASS2'}]},
                 {'disk': 2, 'file': 'romdisk-2.bin', 'entries': [{'key': 'A', 'name': 'ZMEI', 'title': ''}]}]
        text = package.romdisk_guide(self.guide_template(), disks)
        for part in ('R0,1FF,0', 'G0', 'Change the ROM disk', 'romdisk.bin', '6  TETRIS'):
            self.assertIn(part, text)
        self.assertIn('the 3 games of the Karabas core on 2 disks', text)
        self.assertIn('romdisk-1.bin (disk 1)\n  0  CHESS        Шахматы\n  1  GLASS2\n', text)
        self.assertIn('romdisk-2.bin (disk 2)\n  A  ZMEI\n', text)
        self.assertNotIn(package.GUIDE_MARKER, text)
        self.assertTrue(text.endswith('\n'))

    def test_romdisk_guide_needs_one_marker(self):
        with self.assertRaises(ValueError):
            package.romdisk_guide('no marker\n', [])

    def test_info_lists_the_games_before_the_credits(self):
        disks = [{'disk': 1, 'file': 'romdisk-1.bin', 'entries': [
                     {'key': '0', 'name': 'CHESS', 'title': 'Шахматы'}, {'key': '1', 'name': 'GLASS2'}]},
                 {'disk': 2, 'file': 'romdisk-2.bin', 'entries': [{'key': 'A', 'name': 'ZMEI', 'title': ''}]}]
        text = package.info_with_games('Title\n* No Memories.\nCredits: someone.\n', disks)
        self.assertEqual(text, 'Title\n* No Memories.\n'
                               '* Game disks (3 games): load one from the core\'s menu, then R0,1FF,0 and G0; '
                               'its menu keys:\n'
                               '* romdisk-1.bin: 0 CHESS, 1 GLASS2\n'
                               '* romdisk-2.bin: A ZMEI\n'
                               'Credits: someone.\n')
        self.assertTrue(text.isascii())
        with self.assertRaises(ValueError):
            package.info_with_games('no credits line\n', disks)

    def test_game_disks_are_built_from_the_core(self):
        if not os.path.isdir(package.PK_DIR):
            self.skipTest('core submodule not checked out')
        disks, files = package.game_disks(package.PK_DIR, {'romdisk.bin', 'monitor.bin', 'font.bin'})
        self.assertEqual(list(files), ['romdisk-%d.bin' % n for n in range(1, 10)])
        self.assertEqual([d['file'] for d in disks], list(files))
        self.assertTrue(all(len(b) == 32256 for b in files.values()))
        self.assertEqual(sum(len(d['entries']) for d in disks), 48)
        self.assertEqual(disks[0]['entries'][0]['title'], 'Шахматы')
        with self.assertRaises(SystemExit):
            package.game_disks(package.PK_DIR, {'romdisk-3.bin'})
    def test_library_rejects_bad_updaters(self):
        name = 'Cores/%s/updaters.json' % package.CORE_ID
        with tempfile.TemporaryDirectory() as d:
            path = self.library_zip(d, lambda f: f.update({name: b'{"license": {"filename": "key.bin"}}'}))
            self.assertTrue(package.check_library_zip(path))


if __name__ == '__main__':
    unittest.main()
