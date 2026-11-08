import inspect
import os
import re
import sys
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'fpga', 'sim'))
import run_core_machine  # noqa: E402

core = run_core_machine.core


class CoreMachineSubsetTest(unittest.TestCase):
    def test_runner_interface(self):
        self.assertEqual(list(inspect.signature(core.build_and_run).parameters),
                         ['tools', 'name', 'params', 'frames', 'seed', 'mutant', 'ref_rev', 'mem'])
        self.assertEqual(list(inspect.signature(core.compare_stall).parameters), ['name', 'frames'])
        self.assertEqual(core.OUT, os.path.join('build', 'sim', 'machine'))

    def test_subset_matches_the_core_runner(self):
        self.assertLessEqual(set(run_core_machine.SUBSET), set(core.RUNS))
        self.assertLessEqual(set(run_core_machine.EXTRA), set(run_core_machine.SUBSET))
        self.assertEqual(run_core_machine.EXTRA, {'stall_frac': {'FREEZE_FRAMES': 0}})
        self.assertEqual(sorted(run_core_machine.runs()), sorted(run_core_machine.SUBSET))
        for name, params in run_core_machine.runs().items():
            self.assertEqual(params, dict(core.RUNS[name], **run_core_machine.EXTRA.get(name, {})), name)

    def test_extra_keys_are_tb_parameters(self):
        with open(os.path.join(core.ROOT, core.TB), encoding='utf-8') as f:
            tb = f.read()
        for name, extra in run_core_machine.EXTRA.items():
            for key in extra:
                self.assertRegex(tb, re.compile(r'\bparameter\s+(integer\s+)?%s\b' % re.escape(key)), '%s: %s' % (name, key))

    def test_memory_model_files_exist(self):
        for path in run_core_machine.MEM:
            self.assertTrue(os.path.isfile(path), path)


if __name__ == '__main__':
    unittest.main()
