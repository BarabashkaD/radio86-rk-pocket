import os
import sys
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'fpga', 'sim'))
import run_core_machine  # noqa: E402

core = run_core_machine.core


class CoreMachineTest(unittest.TestCase):
    def test_runner_interface(self):
        self.assertIn(run_core_machine.TEST, core.TESTS)
        test = core.TESTS[run_core_machine.TEST]
        files = test['files']() if callable(test['files']) else test['files']
        self.assertIn(core.MEM, files)           # the file --mem replaces
        self.assertEqual(core.OUT, os.path.join('build', 'sim', 'machine16'))
        self.assertTrue(os.path.isfile(run_core_machine.RUNNER), run_core_machine.RUNNER)
        self.assertEqual(os.path.normcase(os.path.abspath(core.__file__)),
                         os.path.normcase(os.path.abspath(run_core_machine.RUNNER)))

    def test_command_line(self):
        cmd = run_core_machine.command('iverilog-path')
        self.assertEqual(cmd[:6], [sys.executable, '-B', run_core_machine.RUNNER, '--iverilog', 'iverilog-path',
                                   'machine16'])
        self.assertEqual(cmd[6], '--mem')
        mem = cmd[7:]
        self.assertEqual(mem, [os.path.join(ROOT, 'fpga', 'sim', 'memory', 'tb_rk86_mem16.v'),
                               os.path.join(ROOT, 'fpga', 'rtl', 'pocket_memory.v')])
        for path in mem:
            self.assertTrue(os.path.isabs(path), path)
        self.assertIn('--frames', run_core_machine.command('iverilog-path', frames=3))

    def test_memory_model_files_exist(self):
        for path in run_core_machine.MEM:
            self.assertTrue(os.path.isfile(path), path)

    def test_fault(self):
        self.assertEqual(run_core_machine.FAULT_EXPECTED, 'ERROR: dma byte')
        self.assertTrue(os.path.isfile(run_core_machine.FAULT_PATCH), run_core_machine.FAULT_PATCH)
        self.assertEqual(core.patched_files(run_core_machine.FAULT_PATCH), ['fpga/rtl/pocket_memory.v'])
        self.assertEqual(run_core_machine.FAULT_DIR,
                         os.path.join(ROOT, 'build', 'sim', 'core_machine', 'neg_memory_dropped_after_rd'))


if __name__ == '__main__':
    unittest.main()
