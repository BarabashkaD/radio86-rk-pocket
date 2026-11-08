import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import check_repo  # noqa: E402

# the sample paths and links are built by concatenation so this file does not trip the check itself
BS = '\\'
WIN_USER = 'C:' + BS + 'Users' + BS + 'someone' + BS + 'x'
WIN_PROJECT = 'D:' + BS + 'Projects' + BS + 'x'
WIN_SLASH = 'C:' + '/msys64/x'
UNC = BS + BS + 'host' + BS + 'share' + BS + 'x'
HOME = '/' + 'home' + '/someone/x'
MAC = '/' + 'Users' + '/someone/x'
WSL = '/' + 'mnt' + '/c/x'
PLACEHOLDERS = '`/' + 'home/<name>/` and `C:' + BS + 'Users' + BS + '<name>' + BS + '` as examples'
DOCS_LINKS = ('[plan](' + 'docs/superpowers/plan.md)',
              'see [x](' + '../docs/x.md)',
              'see [x](' + '/docs/x.md)',
              '[plan]: ' + 'docs/x.md',
              'https://github.com/BarabashkaD/radio86-rk-pocket/blob/main/' + 'docs/x.md')


class CheckRepoTest(unittest.TestCase):
    def test_clean_text_passes(self):
        self.assertEqual(check_repo.check_text('a.md', b'# Title\n\ntext\n'), [])
        self.assertEqual(check_repo.check_text('a.ps1', b'$env:RUNNER_TEMP; https://example.org/a\n'), [])

    def test_cr_and_final_newline(self):
        self.assertTrue(check_repo.check_text('a.v', b'module a;\r\nendmodule\r\n'))
        self.assertTrue(check_repo.check_text('a.v', b'module a; endmodule'))
        self.assertEqual(check_repo.check_text('empty.txt', b''), [])

    def test_template_and_legacy_only_skip_their_line_rule(self):
        self.assertEqual(check_repo.check_text('fpga/apf/a.v', b'module a;\r\nendmodule'), [])
        self.assertTrue(check_repo.check_text('fpga/apf/a.v', (WIN_PROJECT + '\n').encode()))
        self.assertEqual(check_repo.check_text('scripts/build.ps1', b'exit 0'), [])
        self.assertTrue(check_repo.check_text('scripts/build.ps1', b'exit 0\r\n'))
        self.assertEqual(check_repo.check_text('fpga/rtl/pocket_remap.v', b'module a;\r\n'), [])
        self.assertTrue(check_repo.check_text('fpga/rtl/pocket_remap.v', b'module a;'))

    def test_legacy_entries_still_have_their_defect(self):
        tracked = set(check_repo.tracked())
        for name, defect in check_repo.LEGACY.items():
            self.assertIn(defect, ('CR', 'no final newline'), name)
            self.assertFalse(name.startswith(check_repo.EXEMPT_PREFIXES), name)
            self.assertIn(name, tracked, '%s is not tracked any more: remove it from LEGACY' % name)
            with open(os.path.join(check_repo.ROOT, name), 'rb') as f:
                self.assertIn(defect, check_repo.line_defects(f.read()),
                              '%s no longer has "%s": remove it from LEGACY' % (name, defect))

    def test_docs_links_only_in_public_markdown(self):
        for link in DOCS_LINKS:
            self.assertTrue(check_repo.check_text('README.md', (link + '\n').encode()), link)
            self.assertTrue(check_repo.check_text('fpga/README.md', (link + '\n').encode()), link)
            self.assertEqual(check_repo.check_text('scripts/a.py', (link + '\n').encode()), [], link)
        self.assertEqual(check_repo.check_text('README.md', b'the core\'s `docs/integration.md`\n'), [])

    def test_local_paths(self):
        for text in (WIN_USER, WIN_USER.replace(BS, '/'), WIN_PROJECT, WIN_SLASH, UNC, HOME, MAC, WSL):
            self.assertTrue(check_repo.check_text('a.py', (text + '\n').encode()), text)
        self.assertEqual(check_repo.check_text('a.md', (PLACEHOLDERS + '\n').encode()), [])

    def test_repository_is_clean(self):
        self.assertEqual(check_repo.main(), 0)


if __name__ == '__main__':
    unittest.main()
