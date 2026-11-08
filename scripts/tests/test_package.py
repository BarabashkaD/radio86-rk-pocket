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
        files['Cores/%s/icon.bin' % package.CORE_ID] = package.graphic(36, 36, 'RK', 2)
        files['Platforms/_images/%s.bin' % package.PLATFORM] = package.graphic(521, 165, 'RK86', 12)
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

    def test_library_rejects_bad_updaters(self):
        name = 'Cores/%s/updaters.json' % package.CORE_ID
        with tempfile.TemporaryDirectory() as d:
            path = self.library_zip(d, lambda f: f.update({name: b'{"license": {"filename": "key.bin"}}'}))
            self.assertTrue(package.check_library_zip(path))


if __name__ == '__main__':
    unittest.main()
