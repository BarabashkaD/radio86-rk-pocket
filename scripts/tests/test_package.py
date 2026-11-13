import contextlib
import io
import json
import os
import re
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

    def test_romdisk_slot_takes_8_mb(self):
        with open(os.path.join(ROOT, 'package', 'core', 'data.json'), encoding='utf-8') as f:
            slots = {s['id']: s for s in json.load(f)['data']['data_slots']}
        self.assertEqual(slots[2]['size_maximum'], 8388608)
        self.assertEqual(slots[2]['address'], '0x22000000')
        self.assertEqual(slots[2]['parameters'], 75)

    def test_updaters_check(self):
        for bad in ({'declare_ai': []}, {'declare_ai': 'Claude'}, {'declare_ai': ['']}, {'declare_ai': [1]},
                    {'declare_ai': ['Claude'], 'license': {'filename': 'key.bin'}},
                    {'declare_ai': ['Claude'], 'previous': []}, {}, []):
            self.assertTrue(package.check_updaters(bad), bad)

    def template(self):
        with open(os.path.join(ROOT, 'package', 'ROMDISKS.txt'), encoding='utf-8') as f:
            return f.read()

    def test_romdisks_text_lists_every_game_disk(self):
        disks = [{'disk': 1, 'file': 'romdisk-1.bin', 'entries': [
                     {'key': '0', 'name': 'CHESS', 'title': 'Шахматы'}, {'key': '1', 'name': 'GLASS2'}]},
                 {'disk': 2, 'file': 'romdisk-2.bin', 'entries': [{'key': 'A', 'name': 'ZMEI', 'title': ''}]}]
        text = package.romdisks_text(self.template(), disks)
        for part in ('R0,1FF,0', 'G0', 'romdisk.bin', '6 TETRIS', 'Core Settings > Reset',
                     'Core Settings > Cold boot'):
            self.assertIn(part, text)
        self.assertIn('The 3 games of the Karabas core on 2 disks', text)
        self.assertIn('romdisk-1.bin (disk 1)\n  0  CHESS        Шахматы\n  1  GLASS2\n', text)
        self.assertIn('romdisk-2.bin (disk 2)\n  A  ZMEI\n', text)
        self.assertNotIn(package.GUIDE_MARKER, text)
        self.assertNotRegex(text, r'@[A-Z_]+@')          # every placeholder filled
        self.assertNotIn('`', text)                     # plain text, not Markdown
        self.assertNotRegex(text, r'(?m)^#')
        self.assertNotIn('](', text)
        self.assertTrue(text.endswith('\n') and not text.endswith('\n\n'))

    def test_romdisks_text_needs_one_marker(self):
        with self.assertRaises(ValueError):
            package.romdisks_text('no marker\n', [])
        with self.assertRaises(ValueError):
            package.romdisks_text('%s\n%s\n' % (package.GUIDE_MARKER, package.GUIDE_MARKER), [])

    def test_romdisks_text_links_kiselevs_file_from_assets_json(self):
        with open(os.path.join(ROOT, 'package', 'assets.json'), encoding='utf-8') as f:
            asset = next(a for a in json.load(f)['assets'] if a['name'] == 'romdisk.bin')
        commit = re.fullmatch(r'https://raw\.githubusercontent\.com/skiselev/radio-86rk/([0-9a-f]{40})/'
                              r'Software/rom_disk\.bin', asset['source']).group(1)
        for text in (package.romdisks_text(self.template(), []), package.readme_section()):
            self.assertIn(asset['source'], text)
            self.assertIn('https://github.com/skiselev/radio-86rk/blob/%s/Software/rom_disk.bin' % commit, text)
            self.assertIn(asset['sha256'], text)
            self.assertIn(str(asset['size']), text)
            self.assertRegex(text, r'save it as\s+`?romdisk\.bin')

    def test_romdisks_text_says_where_to_get_and_put_each_image(self):
        for text in (package.romdisks_text(self.template(), []), package.readme_section()):
            for part in ('card.bin', 'fatcard.bin', 'romdisk-1.bin', 'romdisk-5.bin', 'romdisk-LICENSE.txt',
                         'SHA256SUMS.txt', 'https://github.com/BarabashkaD/radio86-rk-pocket/releases',
                         'Assets/radio86rk/BarabashkaD.Radio86RK/', '.bin', 'R0,1FF,0', 'G0',
                         'Cold boot', '0.8.2', 'romdisks.txt', 'reads FF'):
                self.assertIn(part, text)

    def test_readme_romdisk_section_is_current(self):
        with open(os.path.join(ROOT, 'README.md'), encoding='utf-8') as f:
            text = f.read()
        begin, end = text.find(package.README_BEGIN), text.find(package.README_END)
        self.assertTrue(0 <= begin < end, 'README.md: ROM disk image markers missing')
        self.assertEqual(text.count(package.README_BEGIN), 1)
        section = text[begin + len(package.README_BEGIN):end].strip('\n')
        self.assertEqual(section, package.readme_section(),
                         'README.md ROM disk images section is stale: python -B scripts/package.py --readme')
        self.assertTrue(section.startswith('## ROM disk images\n'))
        self.assertIn('[Game disks](#game-disks)', section)       # the game lists stay in their own block

    def test_assets_json_marks_what_stays_out_of_the_package(self):
        with open(os.path.join(ROOT, 'package', 'assets.json'), encoding='utf-8') as f:
            table = json.load(f)
        self.assertEqual({a['name'] for a in table['assets'] if a.get('package', True)},
                         {'monitor.bin', 'font.bin'})
        self.assertEqual([a.get('package') for a in table['licences']], [False])

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
        self.assertEqual(list(files), ['romdisk-%d.bin' % n for n in range(1, 6)])
        self.assertEqual([d['file'] for d in disks], list(files))
        self.assertTrue(all(len(b) == 65536 for b in files.values()))
        self.assertEqual(sum(len(d['entries']) for d in disks), 48)
        self.assertEqual(disks[0]['entries'][1]['title'], 'Шахматы')
        with self.assertRaises(SystemExit):
            package.game_disks(package.PK_DIR, {'romdisk-3.bin'})

    def test_library_rejects_bad_updaters(self):
        name = 'Cores/%s/updaters.json' % package.CORE_ID
        with tempfile.TemporaryDirectory() as d:
            path = self.library_zip(d, lambda f: f.update({name: b'{"license": {"filename": "key.bin"}}'}))
            self.assertTrue(package.check_library_zip(path))


class BuiltPackageTest(unittest.TestCase):
    """package.py as the CI dry run calls it (a 256-byte stand-in bitstream), with an empty assets
    folder: the package must not need Kiselev's ROM disk or its licence. The output folder is a
    system temp folder (on Windows often another drive than the repository)."""
    ASSETS = 'Assets/%s/%s/' % (package.PLATFORM, package.CORE_ID)
    CORES = 'Cores/%s/' % package.CORE_ID

    @classmethod
    def setUpClass(cls):
        if not os.path.isdir(package.PK_DIR) or not os.path.isfile(os.path.join(package.CORE_SRC, 'roms', 'BIOS.BIN')):
            raise unittest.SkipTest('core submodule not checked out')
        cls.tmp = tempfile.TemporaryDirectory()
        build = os.path.join(cls.tmp.name, 'stand-in')
        os.makedirs(os.path.join(build, 'output_files'))
        with open(os.path.join(build, 'output_files', 'ap_core.rbf'), 'wb') as f:
            f.write(bytes(range(256)))
        assets = os.path.join(cls.tmp.name, 'assets')
        os.makedirs(assets)
        out = os.path.join(cls.tmp.name, 'package')
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            rc = package.main(['--version', '0.0.0-test', '--date', '2000-01-01', '--build', build,
                               '--assets', assets, '--output', out])
        if rc != 0:
            raise AssertionError('package.py failed:\n' + log.getvalue())
        cls.zip_path = os.path.join(out, '%s_0.0.0-test_2000-01-01.zip' % package.CORE_ID)
        with zipfile.ZipFile(cls.zip_path) as z:
            cls.files = {n: z.read(n) for n in z.namelist()}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_assets_folder_holds_no_romdisk_image(self):
        assets = sorted(n[len(self.ASSETS):] for n in self.files if n.startswith(self.ASSETS))
        self.assertEqual(assets, ['ROMDISKS.txt', 'font.bin', 'monitor.bin'])
        for name in self.files:
            base = name.rsplit('/', 1)[-1]
            self.assertNotRegex(base.lower(), r'^romdisk(-\d+)?\.bin$', name)
            self.assertNotIn(base, ('romdisks.txt', 'LICENSE-romdisk.txt'), name)
        self.assertNotIn(self.CORES + 'LICENSE-romdisk.txt', self.files)
        self.assertEqual(sorted(n[len(self.CORES):] for n in self.files if n.startswith(self.CORES + 'LICENSE')),
                         ['LICENSE-karabas-core.txt', 'LICENSE.txt'])

    def test_library_checks_pass(self):
        self.assertEqual(package.check_library_zip(self.zip_path), [])

    def test_romdisks_txt_lists_every_game_and_links_kiselevs_file(self):
        raw = self.files[self.ASSETS + 'ROMDISKS.txt']
        text = raw.decode('utf-8')                      # UTF-8 with the Russian titles, not ASCII
        self.assertFalse(text.isascii())
        self.assertNotIn('\r', text)
        self.assertTrue(text.endswith('\n'))
        built = package.build_romdisks.build(package.PK_DIR)
        disks = package.build_romdisks.metadata(built, package.build_romdisks.descriptions(package.PK_DIR))
        self.assertEqual(len(disks), 5)
        for d in disks:
            self.assertIn('%s (disk %d)' % (d['file'], d['disk']), text)
            for e in d['entries']:
                self.assertIn(e['name'], text)
                if e.get('title'):
                    self.assertIn(e['title'], text)
        self.assertIn('The 48 games of the Karabas core on 5 disks', text)
        with open(os.path.join(ROOT, 'package', 'assets.json'), encoding='utf-8') as f:
            asset = next(a for a in json.load(f)['assets'] if a['name'] == 'romdisk.bin')
        self.assertIn(asset['source'], text)
        for part in ('card.bin', 'fatcard.bin', 'Assets/radio86rk/BarabashkaD.Radio86RK/'):
            self.assertIn(part, text)

    def test_info_txt_points_to_romdisks_txt(self):
        info = self.files[self.CORES + 'info.txt'].decode('utf-8')
        self.assertTrue(info.isascii())
        self.assertEqual(sum(1 for line in info.split('\n') if line.startswith('Credits:')), 1)
        self.assertIn('ROM disk images are separate downloads on the release page; '
                      'see ROMDISKS.txt in the Assets folder.', info)
        self.assertEqual(info.count('ROMDISKS.txt'), 1)
        self.assertNotIn('romdisks.txt', info)
        self.assertNotIn('not in this package', info)
        self.assertIn('* romdisk-5.bin: ', info)         # the game list stays


if __name__ == '__main__':
    unittest.main()
