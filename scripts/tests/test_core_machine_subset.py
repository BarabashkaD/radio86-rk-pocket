import os
import sys
import tomllib
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'fpga', 'sim'))
import run_core_machine  # noqa: E402


class CoreMachineTest(unittest.TestCase):
    """run_core_machine.py runs the machine16 test of retroMachines' machines/rk86 manifest."""

    def manifest(self):
        path = os.path.join(str(run_core_machine.layout().retro_machines_dir()), 'machines', 'rk86', 'component.toml')
        with open(path, 'rb') as f:
            return tomllib.load(f)

    def test_manifest_machine16(self):
        m = self.manifest()
        self.assertEqual(m['component']['name'], run_core_machine.COMPONENT)
        tests = {t['name']: t for t in m['test']}
        self.assertIn(run_core_machine.TEST, tests)
        test = tests[run_core_machine.TEST]
        self.assertEqual(test['tier'], run_core_machine.TIER)
        self.assertIn('tb/tb_rk86_mem16.v', test['files'])     # the file --replace replaces
        self.assertIn('FRAMES', test.get('params', {}))        # what --frames sets
        self.assertTrue(os.path.isfile(run_core_machine.machine_mem()), run_core_machine.machine_mem())
        self.assertEqual(os.path.normcase(run_core_machine.machine_mem()),
                         os.path.normcase(os.path.join(str(run_core_machine.layout().retro_machines_dir()),
                                                       'machines', 'rk86', 'tb', 'tb_rk86_mem16.v')))
        # no test of a lower tier replaces the memory: only machine16 runs on pocket_memory
        for t in m['test']:
            if t['name'] != run_core_machine.TEST:
                self.assertNotIn('tb/tb_rk86_mem16.v', t['files'], t['name'])

    def test_command_line(self):
        cmd = run_core_machine.command('iverilog-path')
        self.assertEqual(cmd[:5], [sys.executable, '-B', run_core_machine.SIMRUN, 'run', 'machines/rk86'])
        self.assertTrue(os.path.isfile(run_core_machine.SIMRUN), run_core_machine.SIMRUN)
        self.assertEqual(cmd[cmd.index('--tier') + 1], 'standard')
        self.assertEqual(cmd[cmd.index('--iverilog') + 1], 'iverilog-path')
        self.assertEqual(cmd[cmd.index('--out') + 1], os.path.join(ROOT, 'build', 'sim', 'core_machine'))
        target, files = cmd[cmd.index('--replace') + 1].split('=', 1)
        self.assertEqual(target, run_core_machine.machine_mem())
        mem = files.split(',')
        self.assertEqual(mem, [os.path.join(ROOT, 'fpga', 'sim', 'memory', 'tb_rk86_mem16.v'),
                               os.path.join(ROOT, 'fpga', 'rtl', 'pocket_memory.v')])
        for path in [target] + mem:
            self.assertTrue(os.path.isabs(path), path)
        self.assertNotIn('--param', cmd)
        cmd = run_core_machine.command('iverilog-path', frames=3)
        self.assertEqual(cmd[cmd.index('--param') + 1], 'FRAMES=3')

    def test_memory_model_files_exist(self):
        for path in run_core_machine.MEM:
            self.assertTrue(os.path.isfile(path), path)

    def test_fault(self):
        self.assertEqual(run_core_machine.FAULT_EXPECTED, 'ERROR: dma byte')
        self.assertTrue(os.path.isfile(run_core_machine.FAULT_PATCH), run_core_machine.FAULT_PATCH)
        apply_patch, patched_files = run_core_machine.negative()
        self.assertEqual(patched_files(run_core_machine.FAULT_PATCH), ['fpga/rtl/pocket_memory.v'])
        self.assertEqual(run_core_machine.FAULT_DIR,
                         os.path.join(ROOT, 'build', 'sim', 'core_machine', 'neg_memory_dropped_after_rd'))


if __name__ == '__main__':
    unittest.main()
