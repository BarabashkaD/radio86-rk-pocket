"""scripts/layout.py, the simrun launcher scripts/simrun.py and their consumers: the libraries come from
the submodules lib/retroMachines (with lib/retroMachines/lib/retroICs) and lib/retro8080Software, and
nothing reads the Karabas fork any more."""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SIMRUN = os.path.join(ROOT, 'scripts', 'simrun.py')
FETCH = 'run git submodule update --init --recursive'


def repo_layout():
    """scripts/layout.py under the module name its consumers use (scripts/k1/layout.py is `layout`)."""
    name = 'rk86_repo_layout'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, 'scripts', 'layout.py'))
        sys.modules[name] = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sys.modules[name])
    return sys.modules[name]


L = repo_layout()
sys.path.insert(0, os.path.join(ROOT, 'fpga', 'sim'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'docker2tests'))
import run_core_machine  # noqa: E402
import run_sim  # noqa: E402
import remote_sim  # noqa: E402


def norm(p):
    return os.path.normcase(os.path.abspath(str(p)))


class MissingSubmodule(unittest.TestCase):
    """A missing or empty submodule: one error naming git submodule update --init --recursive."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_missing_submodule_message(self):
        with mock.patch.dict(os.environ, {'RETRO_MACHINES_DIR': self.tmp.name}):
            for fn in (L.retro_machines_dir, L.retro_ics_tools, L.rk86_roms, L.search_roots):
                with self.assertRaises(L.LayoutError) as e:
                    fn()
                self.assertEqual(str(e.exception), 'lib/retroMachines missing: ' + FETCH)
        with mock.patch.dict(os.environ, {'RETRO_SOFTWARE_DIR': self.tmp.name}):
            for fn in (L.software_dir, L.pk_dir):
                with self.assertRaises(L.LayoutError) as e:
                    fn()
                self.assertEqual(str(e.exception), 'lib/retro8080Software missing: ' + FETCH)

    def test_nested_retroics_missing(self):
        # retroMachines checked out without --recursive: its lib/retroICs is empty; the error names it
        os.makedirs(os.path.join(self.tmp.name, 'machines', 'rk86'))
        open(os.path.join(self.tmp.name, 'machines', 'rk86', 'component.toml'), 'w').close()
        os.makedirs(os.path.join(self.tmp.name, 'lib', 'retroICs'))
        with mock.patch.dict(os.environ, {'RETRO_MACHINES_DIR': self.tmp.name}):
            for fn in (L.retro_machines_dir, L.retro_ics_tools, L.rk86_roms, L.search_roots):
                with self.assertRaises(L.LayoutError) as e:
                    fn()
                self.assertEqual(str(e.exception), 'lib/retroMachines/lib/retroICs missing: ' + FETCH)

    def test_launcher_one_error_line(self):
        env = dict(os.environ, RETRO_MACHINES_DIR=self.tmp.name)
        res = subprocess.run([sys.executable, '-B', SIMRUN, 'filelist', 'machines/rk86', '--format', 'f'],
                             capture_output=True, text=True, env=env, cwd=ROOT)
        self.assertEqual(res.returncode, 2)
        self.assertEqual((res.stdout + res.stderr).strip(), 'ERROR: lib/retroMachines missing: ' + FETCH)

    def test_run_sim_one_error_line(self):
        with mock.patch.dict(os.environ, {'RETRO_MACHINES_DIR': self.tmp.name}):
            for name in ('cart_ppi', 'cpu16', 'boot'):
                ok, text = run_sim.run(name, run_sim.TESTS[name], 'iverilog', 'vvp', dict(os.environ))
                self.assertFalse(ok, name)
                self.assertEqual(text, 'ERROR: lib/retroMachines missing: ' + FETCH, name)

    def test_wrong_override_is_named(self):
        # a wrong RETRO_MACHINES_DIR / RETRO_SOFTWARE_DIR never falls back to lib/: the paths that
        # package.py and monitor_decoder.py read are the override's, so the error names its file
        sys.path.insert(0, os.path.join(ROOT, 'scripts', 'k1'))
        sys.path.insert(0, os.path.join(ROOT, 'scripts'))
        try:
            import monitor_decoder
            import package
        finally:
            sys.path.remove(os.path.join(ROOT, 'scripts'))
            sys.path.remove(os.path.join(ROOT, 'scripts', 'k1'))
        tmp = norm(os.path.realpath(self.tmp.name))
        with mock.patch.dict(os.environ, {'RETRO_MACHINES_DIR': self.tmp.name, 'RETRO_SOFTWARE_DIR': self.tmp.name}):
            machines, pk = package.lib_dirs()
            roms = monitor_decoder._roms()
        self.assertEqual(norm(os.path.realpath(machines)), tmp)
        self.assertEqual(norm(os.path.realpath(pk)), norm(os.path.join(tmp, 'rk86', 'collections', 'pyhonin-1999')))
        self.assertEqual(norm(os.path.realpath(roms)), norm(os.path.join(tmp, 'machines', 'rk86', 'roms')))

    def test_defaults(self):
        with mock.patch.dict(os.environ):
            os.environ.pop('RETRO_MACHINES_DIR', None)
            os.environ.pop('RETRO_SOFTWARE_DIR', None)
            self.assertEqual(norm(L.retro_machines_dir()), norm(os.path.join(ROOT, 'lib', 'retroMachines')))
            self.assertEqual(norm(L.retro_ics_tools()),
                             norm(os.path.join(ROOT, 'lib', 'retroMachines', 'lib', 'retroICs', 'tools')))
            self.assertEqual(norm(L.rk86_roms()),
                             norm(os.path.join(ROOT, 'lib', 'retroMachines', 'machines', 'rk86', 'roms')))
            self.assertEqual(norm(L.pk_dir()), norm(os.path.join(ROOT, 'lib', 'retro8080Software', 'rk86',
                                                                 'collections', 'pyhonin-1999')))
            for name in ('monitor.bin', 'font.bin'):
                self.assertTrue(os.path.isfile(os.path.join(L.rk86_roms(), name)), name)


def fake_root(tmp):
    """A copy of scripts/ (without the tests and the container tools) in tmp, with no lib/."""
    shutil.copytree(os.path.join(ROOT, 'scripts'), os.path.join(tmp, 'scripts'),
                    ignore=shutil.ignore_patterns('tests', 'docker2tests', '__pycache__'))
    return tmp


class MissingSubmoduleScripts(unittest.TestCase):
    """package.py and monitor_decoder.py with the default submodules (no RETRO_* set) in a tree whose
    lib/ is missing or checked out without --recursive: one ERROR line naming the fix, no traceback."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = fake_root(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if k not in ('RETRO_MACHINES_DIR', 'RETRO_SOFTWARE_DIR')}

    def run_script(self, *rel):
        res = subprocess.run([sys.executable, '-B', os.path.join(self.root, 'scripts', *rel)] + (['--readme']
                             if rel[-1] == 'package.py' else []), capture_output=True, text=True,
                             env=self.env, cwd=self.root)
        return res.returncode, (res.stdout + res.stderr).strip()

    def assert_one_error(self, missing):
        for script in (('package.py',), ('k1', 'monitor_decoder.py')):
            code, out = self.run_script(*script)
            self.assertNotEqual(code, 0, script)
            self.assertEqual(out, 'ERROR: %s missing: %s' % (missing, FETCH), script)

    def machines(self, ics_tools=False):
        m = os.path.join(self.root, 'lib', 'retroMachines')
        os.makedirs(os.path.join(m, 'machines', 'rk86'))
        open(os.path.join(m, 'machines', 'rk86', 'component.toml'), 'w').close()
        os.makedirs(os.path.join(m, 'lib', 'retroICs', *(['tools', 'simrun'] if ics_tools else [])))

    def test_no_lib(self):
        self.assert_one_error('lib/retroMachines')

    def test_not_recursive(self):
        # lib/retroMachines checked out, its own submodule lib/retroICs empty
        self.machines()
        self.assert_one_error('lib/retroMachines/lib/retroICs')

    def test_software_missing(self):
        self.machines(ics_tools=True)
        code, out = self.run_script('package.py')
        self.assertNotEqual(code, 0)
        self.assertEqual(out, 'ERROR: lib/retro8080Software missing: ' + FETCH)


def gitlink(repo, tree, path):
    """The commit that the gitlink path holds in tree (a commit) of the repo."""
    res = subprocess.run(['git', '-C', repo, 'ls-tree', tree, path], capture_output=True, text=True)
    m = re.fullmatch(r'160000 commit ([0-9a-f]{40})\t' + re.escape(path), res.stdout.strip())
    if res.returncode or not m:
        raise AssertionError('no gitlink %s at %s in %s: %s' % (path, tree, repo, res.stdout + res.stderr))
    return m.group(1)


def pins():
    """{library: pinned commit}: this repo's gitlinks, and retroICs as retroMachines' pinned commit
    pins it (the nested gitlink)."""
    machines = gitlink(ROOT, 'HEAD', 'lib/retroMachines')
    return {'retroMachines': machines,
            'retroICs': gitlink(os.path.join(ROOT, 'lib', 'retroMachines'), machines, 'lib/retroICs'),
            'retro8080Software': gitlink(ROOT, 'HEAD', 'lib/retro8080Software')}


LIB_LINK = re.compile(r'https://github\.com/BarabashkaD/(retroMachines|retroICs|retro8080Software)/'
                      r'(?:blob|tree|commit)/([0-9a-f]{7,40})(?![0-9a-f])')
SHORT_SHA = re.compile(r'`([0-9a-f]{7,40})`')


class PinnedLinks(unittest.TestCase):
    """Every library commit named in fpga/README.md is the pin: the SHA of each link into a library at
    a commit, and each `sha` on the same line, is (a prefix of) that library's gitlink."""

    def test_readme_links_are_the_pins(self):
        want = pins()
        with open(os.path.join(ROOT, 'fpga', 'README.md'), encoding='utf-8') as f:
            lines = f.read().split('\n')
        found = 0
        for n, line in enumerate(lines, 1):
            links = LIB_LINK.findall(line)
            for lib, sha in links:
                found += 1
                self.assertTrue(want[lib].startswith(sha), 'fpga/README.md:%d: %s %s is not the pin %s'
                                % (n, lib, sha, want[lib]))
            libs = {lib for lib, _ in links}
            for sha in SHORT_SHA.findall(line) if links else ():
                self.assertTrue(any(want[lib].startswith(sha) for lib in libs),
                                'fpga/README.md:%d: `%s` is not the pin of %s' % (n, sha, ', '.join(sorted(libs))))
        self.assertGreater(found, 0, 'no library link at a commit in fpga/README.md')


# Runs one function of a PowerShell script on test inputs: the function's definition from the
# parser (the script itself is not run), each case its lines joined by LF; the results as JSON.
RUN_FUNCTION = r'''param([string]$Script, [string]$Name, [string]$In, [string]$Out)
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errors)
if ($errors) { throw "parse errors in ${Script}: $($errors -join '; ')" }
$f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
if (-not $f) { throw "no function $Name in $Script" }
. ([scriptblock]::Create($f.Extent.Text))
$cases = @([IO.File]::ReadAllText($In) | ConvertFrom-Json)
$res = foreach ($c in $cases) {
    $lines = if ($c) { @($c -split "`n") } else { @() }
    $r = & $Name -Lines $lines
    if ($null -eq $r) { '' } else { [string]$r }
}
[IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject @($res)))
'''


class BuildSubmoduleCheck(unittest.TestCase):
    """build.ps1 refuses a submodule that is not at its gitlink ('+', '-' or 'U' in git submodule
    status --recursive) before anything else, with one error line naming the fix."""
    BUILD = os.path.join(ROOT, 'scripts', 'build.ps1')

    def problems(self, cases):
        pwsh = shutil.which('pwsh')
        if not pwsh:
            raise AssertionError('pwsh (PowerShell 7) needed for the build.ps1 check')
        with tempfile.TemporaryDirectory() as tmp:
            script, inp, out = (os.path.join(tmp, n) for n in ('run.ps1', 'in.json', 'out.json'))
            with open(script, 'w', encoding='utf-8', newline='\n') as f:
                f.write(RUN_FUNCTION)
            with open(inp, 'w', encoding='utf-8', newline='\n') as f:
                json.dump(['\n'.join(c) for c in cases], f)
            subprocess.run([pwsh, '-NoProfile', '-NonInteractive', '-File', script, self.BUILD,
                            'Get-SubmoduleProblem', inp, out], check=True, capture_output=True, text=True)
            with open(out, encoding='utf-8-sig') as f:
                res = json.load(f)
        return [res] if isinstance(res, str) else res

    def test_status_lines(self):
        m, i, s = 'a' * 40, 'b' * 40, 'c' * 40
        ok = [' %s lib/retro8080Software (heads/main)' % s, ' %s lib/retroMachines (v0.1.0)' % m,
              ' %s lib/retroMachines/lib/retroICs (v0.1.0)' % i]
        fix = ': run git submodule update --init --recursive'
        cases = [
            (ok, ''),
            ([], ''),
            ([ok[0], '+%s lib/retroMachines (heads/x)' % m, ok[2]], 'submodule lib/retroMachines is not at its pin' + fix),
            (ok[:2] + ['-%s lib/retroMachines/lib/retroICs' % i],
             'submodule lib/retroMachines/lib/retroICs is not checked out' + fix),
            (['U%s lib/retro8080Software' % ('0' * 40)] + ok[1:], 'submodule lib/retro8080Software has a merge conflict' + fix),
        ]
        self.assertEqual(self.problems([c for c, _ in cases]), [want for _, want in cases])

    def test_checked_first(self):
        with open(self.BUILD, encoding='utf-8') as f:
            text = f.read()
        self.assertIn('& git -C $repo submodule status --recursive', text)
        call = text.index('$problem = Get-SubmoduleProblem -Lines $status')
        self.assertIn('if ($problem) { [Console]::Error.WriteLine("ERROR: $problem"); exit 1 }', text)
        for later in ('quartus_sh', 'Remove-Item', 'simrun.py'):
            self.assertLess(call, text.index(later), later)


# The fork as a source: its submodule path, its environment variable, its old model names. Allowed:
# history (CHANGELOG.md), the licence rows (LICENSES.md), README's credits, the pinned history links of
# fpga/README.md (a link into the fork at a commit), this test.
FORK = re.compile(r'karabas-go-core-rk86|RK86_CORE_DIR|k580v(v55|t57|g75)')
ALLOWED = ('CHANGELOG.md', 'LICENSES.md', 'scripts/tests/test_layout.py')
HISTORY_LINK = re.compile(r'https://github\.com/[\w.-]+/karabas-go-core-rk86/(?:blob|tree|commit)/[0-9a-f]{7,40}[^\s)]*')
# Files allowed to name the fork for a while (path: reason); an entry without references left fails.
# Empty since the docs of the layout migration: every file is clean or in the allowed places above.
PENDING = {}


def readme_credits():
    """The line numbers of README's Credits section."""
    with open(os.path.join(ROOT, 'README.md'), encoding='utf-8') as f:
        lines = f.read().split('\n')
    out, inside = set(), False
    for n, line in enumerate(lines, 1):
        if line.startswith('## '):
            inside = line.strip() == '## Credits'
        if inside:
            out.add(n)
    return out


def fork_references():
    """(path, line number, text) of every tracked line that names the fork, but the allowed ones."""
    res = subprocess.run(['git', '-C', ROOT, 'grep', '-n', '-I', '-E', FORK.pattern], capture_output=True)
    if res.returncode not in (0, 1):
        raise AssertionError('git grep failed: %s' % res.stderr.decode(errors='replace'))
    credits = readme_credits()
    out = []
    for raw in res.stdout.decode('utf-8', errors='replace').splitlines():
        path, n, text = raw.split(':', 2)
        if path in ALLOWED or (path == 'README.md' and int(n) in credits):
            continue
        if path == 'fpga/README.md' and not FORK.search(HISTORY_LINK.sub('', text)):
            continue
        out.append((path, int(n), text))
    return out


class NoForkReferences(unittest.TestCase):
    def test_no_fork_references(self):
        found = fork_references()
        bad = ['%s:%d: %s' % (p, n, t[:120]) for p, n, t in found if p not in PENDING]
        self.assertEqual(bad, [], 'the Karabas fork is named outside the allowed places')
        stale = sorted(set(PENDING) - {p for p, _, _ in found})
        self.assertEqual(stale, [], 'PENDING entries without fork references left: remove them')

    def test_no_fork_submodule(self):
        with open(os.path.join(ROOT, '.gitmodules'), encoding='utf-8') as f:
            text = f.read()
        self.assertNotIn('karabas', text)
        paths = re.findall(r'^\s*path = (\S+)$', text, re.M)
        self.assertEqual(paths, ['lib/retroMachines', 'lib/retro8080Software'])
        res = subprocess.run(['git', '-C', ROOT, 'ls-files', '-s', '--', 'cores', 'lib'], capture_output=True, text=True)
        gitlinks = sorted(line.split('\t')[1] for line in res.stdout.splitlines() if line.startswith('160000'))
        self.assertEqual(gitlinks, ['lib/retro8080Software', 'lib/retroMachines'])


class Filelist(unittest.TestCase):
    """The machine's RTL files as the manifests list them: dependencies first (rtl.depends order),
    then the machine's own, for the Quartus project (build.ps1) and the simulations (run_sim.py)."""

    @staticmethod
    def manifest(path):
        with open(path, 'rb') as f:
            return tomllib.load(f)

    def expected(self):
        machines = str(L.retro_machines_dir())
        ics = os.path.join(machines, 'lib', 'retroICs')
        out = []

        def visit(name, where):
            m = self.manifest(os.path.join(where, *name.split('/'), 'component.toml'))
            for dep in m['rtl'].get('depends', []):
                visit(dep, os.path.join(ics, 'ics'))
            for f in m['rtl']['files']:
                p = os.path.normpath(os.path.join(where, *name.split('/'), *f.split('/')))
                if norm(p) not in map(norm, out):
                    out.append(p)
        visit('machines/rk86', machines)
        return out

    def test_filelist_matches_manifest(self):
        expected = self.expected()
        names = [os.path.basename(p) for p in expected]
        self.assertEqual(names[-3:], ['rk86_clocks16.v', 'rk86_video16.v', 'rk86_machine16.v'])
        for model in ('intel_8080a.v', 'intel_8255a.v', 'intel_8257.v', 'intel_8275.v'):
            self.assertIn(model, names)
            self.assertLess(names.index(model), names.index('rk86_machine16.v'))
        with tempfile.TemporaryDirectory(dir=os.path.join(ROOT, 'build') if os.path.isdir(os.path.join(ROOT, 'build'))
                                         else None) as build:
            res = subprocess.run([sys.executable, '-B', SIMRUN, 'filelist', 'machines/rk86', '--format', 'qsf',
                                  '--relative-to', build], capture_output=True, text=True, cwd=ROOT)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            listed = []
            for line in res.stdout.splitlines():
                m = re.fullmatch(r'set_global_assignment -name VERILOG_FILE "?([^"]+)"?', line)
                self.assertIsNotNone(m, line)
                self.assertFalse(os.path.isabs(m.group(1)), line)
                listed.append(os.path.normpath(os.path.join(build, m.group(1))))
        self.assertEqual([norm(p) for p in listed], [norm(p) for p in expected])
        for p in listed:
            self.assertTrue(os.path.isfile(p), p)
        # the simulations compile the same files in the same order; the 8255 alone for cart_ppi
        self.assertEqual([norm(p) for p in run_sim.lib_files(run_sim.MACHINE)], [norm(p) for p in expected])
        self.assertEqual([os.path.basename(p) for p in run_sim.lib_files(run_sim.PPI)], ['intel_8255a.v'])

    def test_quartus_reads_the_list(self):
        with open(os.path.join(ROOT, 'scripts', 'build.ps1'), encoding='utf-8') as f:
            build = f.read()
        with open(os.path.join(ROOT, 'fpga', 'quartus', 'create_project.tcl'), encoding='utf-8') as f:
            tcl = f.read()
        self.assertIn("scripts\\simrun.py') filelist machines/rk86 --format qsf --relative-to $BuildDir", build)
        self.assertIn('rk86_machine16_files.qsf', build)
        self.assertIn('rk86_machine16_files.qsf', tcl)
        self.assertNotIn('.prj', tcl)


class Consumers(unittest.TestCase):
    """The runners take the fault helpers apply_patch, patched_files from retroICs (simrun.negative)."""

    def assert_from_retroics(self, apply_patch, patched_files):
        tools = norm(L.retro_ics_tools())
        for fn in (apply_patch, patched_files):
            self.assertEqual(fn.__module__, 'simrun.negative')
            self.assertTrue(norm(sys.modules[fn.__module__].__file__).startswith(tools), fn)

    def test_fork_consumers_import(self):
        self.assert_from_retroics(*run_sim.negative())
        self.assert_from_retroics(*run_core_machine.negative())
        for kind, repo in (('pocket', ROOT), ('retro', str(L.retro_machines_dir()))):
            r = remote_sim.load_runner(kind, repo)
            self.assert_from_retroics(r.apply_patch, r.patched_files)
        r = remote_sim.load_runner('retro', str(L.retro_machines_dir()))
        for name in ('machine16', 'clocks16', 'video16', 'vv55', 'vt57', 'vg75', 'machines/rk86:machine16'):
            self.assertIn(name, r.tests)
        m16 = r.tests['machine16']
        self.assertEqual(m16['top'], 'tb_rk86_machine16')
        self.assertIn(norm(run_core_machine.machine_mem()), map(norm, m16['files']))
        self.assertIn('FRAMES', m16['params'])
        faults = {n[0]: n for n in m16['negatives']}
        self.assertEqual(faults['intel/8275:vg75_drq_held'][4], str(L.retro_ics_dir()))
        self.assertEqual(faults['machines/rk86:dma_rom_from_ram'][2], 'anywhere')

    def test_fault_source(self):
        rel = 'lib/retroMachines/machines/rk86/rtl/rk86_machine16.v'
        # a fault on a retroMachines file patches the checkout in use (RETRO_MACHINES_DIR), not lib/
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, 'machines', 'rk86', 'rtl'))
            open(os.path.join(tmp, 'machines', 'rk86', 'component.toml'), 'w').close()
            os.makedirs(os.path.join(tmp, 'lib', 'retroICs', 'tools', 'simrun'))
            with mock.patch.dict(os.environ, {'RETRO_MACHINES_DIR': tmp}):
                self.assertEqual(norm(os.path.realpath(run_sim.fault_source(rel))),
                                 norm(os.path.realpath(os.path.join(tmp, 'machines', 'rk86', 'rtl',
                                                                    'rk86_machine16.v'))))
        self.assertEqual(norm(run_sim.fault_source(rel)),
                         norm(os.path.join(L.retro_machines_dir(), 'machines', 'rk86', 'rtl', 'rk86_machine16.v')))
        self.assertEqual(norm(run_sim.fault_source('fpga/rtl/pocket_cart_ppi.v')),
                         norm(os.path.join(ROOT, 'fpga', 'rtl', 'pocket_cart_ppi.v')))
        _, patched_files = run_sim.negative()
        for fault in ('cpu16_bus_bit', 'cpu16_dma_rom_from_ram', 'cpu16_startup_decode'):
            patch = os.path.join(run_sim.NEG, fault + '.patch')
            self.assertEqual(patched_files(patch), [rel], fault)
            self.assertTrue(os.path.isfile(run_sim.fault_source(rel)))


def launcher():
    """scripts/simrun.py as a module; its `import layout` gets scripts/layout.py, and sys.path and a
    `layout` module loaded before (scripts/k1/layout.py) are restored afterwards."""
    name = 'rk86_simrun_launcher'
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, SIMRUN)
        mod = importlib.util.module_from_spec(spec)
        saved_path, saved = list(sys.path), sys.modules.get('layout')
        sys.modules['layout'] = L
        try:
            spec.loader.exec_module(mod)
        finally:
            sys.path[:] = saved_path
            if saved is None:
                sys.modules.pop('layout', None)
            else:
                sys.modules['layout'] = saved
        sys.modules[name] = mod
    return sys.modules[name]


# weekly.yml's library jobs: one matrix entry per test of the libraries
WEEKLY_ENTRY = re.compile(r'^\s*- \{ component: ([\w/]+), test: (\w+)\b', re.M)


class LauncherTests(unittest.TestCase):
    """The launcher's --test: only the named tests of the components, with their faults."""

    def setUp(self):
        self.sr = launcher()
        tools = str(L.retro_ics_tools())
        if tools not in sys.path:
            sys.path.insert(0, tools)
        from simrun import __main__ as simrun_main
        from simrun import manifest
        self.simrun_main, self.manifest = simrun_main, manifest

    def test_split_tests(self):
        split = self.sr.split_tests
        self.assertEqual(split(['run', 'intel/8257', '--test', 'vt57', '--test=vt57_func', '--negative']),
                         (['run', 'intel/8257', '--negative'], ['vt57', 'vt57_func']))
        self.assertEqual(split(['run', 'machines/rk86']), (['run', 'machines/rk86'], []))
        self.assertEqual(split(['filelist', 'machines/rk86', '--test', 'x']),
                         (['filelist', 'machines/rk86', '--test', 'x'], []))
        for bad in (['run', 'x', '--test'], ['run', 'x', '--test', '--negative'], ['run', 'x', '--test=']):
            with self.assertRaises(ValueError):
                split(bad)

    def test_only_named_tests(self):
        wrapped = self.sr.only_tests(self.simrun_main.components_at, ['vt57'], self.manifest.ManifestError)
        comps = wrapped(['intel/8257'], L.search_roots())
        self.assertEqual([t.name for c in comps for t in c.tests], ['vt57'])
        faults = [n for c in comps for n in c.negatives]
        self.assertTrue(faults)
        self.assertEqual({n.test for n in faults}, {'vt57'})
        with self.assertRaisesRegex(self.manifest.ManifestError, '--test nope: no such test'):
            self.sr.only_tests(self.simrun_main.components_at, ['nope'],
                               self.manifest.ManifestError)(['intel/8257'], L.search_roots())

    def test_unknown_test_one_error_line(self):
        res = subprocess.run([sys.executable, '-B', SIMRUN, 'run', 'machines/rk86', '--test', 'nope'],
                             capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(res.returncode, 2)
        self.assertEqual((res.stdout + res.stderr).strip(), 'ERROR: --test nope: no such test in machines/rk86')

    def test_weekly_runs_every_library_test(self):
        with open(os.path.join(ROOT, '.github', 'workflows', 'weekly.yml'), encoding='utf-8') as f:
            entries = WEEKLY_ENTRY.findall(f.read())
        expected = sorted((c.name, t.name) for c in self.simrun_main.discover(L.search_roots())
                          for t in c.tests)
        self.assertTrue(expected)
        self.assertEqual(sorted(entries), expected)


if __name__ == '__main__':
    unittest.main()
