import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'bin' / 'faultplus'

# Deliberately a subprocess, so Tcl argument boundaries and exit status are tested.
FAKE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\\n')
if args[0] == 'synth':
    out = pathlib.Path(args[args.index('--output') + 1])
    out.write_text('module top; endmodule\\n')
    print('mapped 2 $_DFF_PP0_ cells to \\DFFARX1 cells.')
    if os.environ.get('FAKE_SYNTH_ERROR'):
        print('ERROR: deliberate Yosys failure')
elif args[0] in ('chain', 'cut'):
    pathlib.Path(args[args.index('--output') + 1]).write_text('module top; endmodule\\n')
elif args[0] == 'atpg' and not os.environ.get('FAKE_NO_OUTPUT'):
    pathlib.Path(args[args.index('--output') + 1]).write_text('{}')
    pathlib.Path(args[args.index('--output-coverage-metadata') + 1]).write_text('ratio: 1.0\\n')
'''


class ShellTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='faultplus test ')
        self.path = Path(self.tmp.name)
        self.fake = self.path / 'fake fault'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.log = self.path / 'args.jsonl'
        self.env = dict(os.environ, FAULTPLUS_FAULT=str(self.fake), FAKE_LOG=str(self.log))
        self.env.pop('FAULT_THREADS', None)
        (self.path / 'cells.v').write_text('module cell; endmodule\n')
        (self.path / 'design.v').write_text('module top; endmodule\n')
        (self.path / 'lib.lib').write_text('library(lib) {}\n')

    def tearDown(self):
        self.tmp.cleanup()

    def run_tcl(self, content, **extra_env):
        script = self.path / 'script.tcl'
        script.write_text(content)
        return subprocess.run([str(CLI), '-f', str(script)], cwd=self.path,
                              env=dict(self.env, **extra_env), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def setup_atpg(self):
        return '''
faultplus configure -clock clk -input_kind combinational -atpg_options {-v 8 -m 80 --ceiling 8}
build_model -workdir [pwd] -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode COMB
build_faultmodel -includedynamic no
'''

    def test_modus_partial_flow_and_export(self):
        p = self.run_tcl(self.setup_atpg() + '''
create_logic_tests -testmode COMB -experiment demo
report_faults -testmode COMB -experiment demo
faultplus export -format json -output export.json
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('ratio: 1.0', p.stdout)
        self.assertEqual((self.path / 'export.json').read_text(), '{}')
        args = self.calls()[0]
        self.assertEqual(args[0], 'atpg')
        self.assertIn(str(self.path / 'cells.v'), args)
        self.assertIn(str(self.path / 'design.v'), args)
        self.assertIn('not a Modus experiment', p.stderr)

    def test_genus_synthesis_and_chain(self):
        p = self.run_tcl('''
read_libs lib.lib
read_hdl {design.v}
elaborate top
syn_generic
syn_map
define_test_clock -name CK -period 10 clk
define_shift_enable -name SE -active high shift
define_test_mode -name TM -active high test
define_scan_chain -name sc -sdi sin -sdo sout -shift_enable SE -create_ports
connect_scan_chains
write_hdl > output.v
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([x[0] for x in self.calls()], ['synth', 'chain'])
        self.assertTrue((self.path / 'output.v').is_file())
        self.assertIn('--blackbox-models', self.calls()[0])
        self.assertIn('--sin', self.calls()[1])
        self.assertIn('DFFARX1', self.calls()[1])

    def test_synthesis_rejects_hidden_backend_error(self):
        p = self.run_tcl('read_libs lib.lib\nread_hdl design.v\nelaborate top\nsyn_map\n', FAKE_SYNTH_ERROR='1')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('deliberate Yosys failure', p.stderr)

    def test_no_output_does_not_claim_success(self):
        p = self.run_tcl(self.setup_atpg() + 'create_logic_tests -experiment demo\n', FAKE_NO_OUTPUT='1')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('did not create expected output', p.stderr)

    def test_atpg_worker_limit_is_default_and_can_be_overridden(self):
        p = self.run_tcl(self.setup_atpg() + 'create_logic_tests\nputs "workers=$::env(FAULT_THREADS)"\n')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('workers=1', p.stdout)
        p = self.run_tcl(self.setup_atpg() + 'create_logic_tests\nputs "workers=$::env(FAULT_THREADS)"\n', FAULT_THREADS='3')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('workers=3', p.stdout)
        p = self.run_tcl(self.setup_atpg() + 'create_logic_tests\n', FAULT_THREADS='0')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('FAULT_THREADS must be a positive integer', p.stderr)

    def test_unsupported_options_are_rejected(self):
        for line, expected in [
            ('build_testmode -testmode FULLSCAN -assignfile pin.txt', '-assignfile'),
            ('build_faultmodel -includedynamic yes', 'dynamic/transition'),
            ('create_logic_tests -testmode COMB -effort high', '-effort'),
            ('write_vectors -language stil', 'cannot generate'),
            ('verify_test_structures', 'does not implement'),
        ]:
            with self.subTest(line=line):
                p = self.run_tcl(self.setup_atpg() + line + '\n')
                self.assertNotEqual(p.returncode, 0)
                self.assertIn(expected, p.stderr)

    def test_assignfile_subset_and_rejected_scan_signal(self):
        (self.path / 'design.v').write_text(
            'module top(input clk, input mode, output y); assign y = mode; endmodule\n')
        (self.path / 'pins.assign').write_text(
            'assign pin=clk test_function=-ES;\nassign pin=mode test_function=+TI;\n')
        p = self.run_tcl('''
build_model -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode COMB -assignfile pins.assign
build_faultmodel -includedynamic no
create_logic_tests -testmode COMB -experiment demo
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('--bypassing', self.calls()[0])
        self.assertIn('mode=1', self.calls()[0])
        (self.path / 'pins.assign').write_text(
            'assign pin=clk test_function=-ES;\nassign pin=se test_function=+SE;\n')
        p = self.run_tcl('''
build_model -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode FULLSCAN -assignfile pins.assign
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('unsupported -assignfile statement', p.stderr)

    def test_assignfile_rejects_missing_clock_port(self):
        (self.path / 'design.v').write_text('module top(input clk); endmodule\n')
        (self.path / 'pins.assign').write_text('assign pin=bad_clock test_function=-ES;\n')
        p = self.run_tcl('''
build_model -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode COMB -assignfile pins.assign
build_faultmodel -includedynamic no
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('bad_clock', p.stderr)
        self.assertEqual(self.calls(), [])

    def test_auto_model_check_rejects_unmodeled_cells(self):
        (self.path / 'cells.v').write_text('module opaque(input A, output Y); endmodule\n')
        (self.path / 'design.v').write_text(
            'module top(input clk, input a, output y); opaque u(a,y); endmodule\n')
        p = self.run_tcl('''
define_test_clock -name CK clk
build_model -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode COMB
build_faultmodel -includedynamic no
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('cannot safely classify design', p.stderr)
        self.assertEqual(self.calls(), [])

    def test_no_shell_interpolation_and_all_native_subcommands(self):
        p = self.run_tcl('faultplus run tap --clock clk {literal;touch INJECTED} -o out.v\n')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('literal;touch INJECTED', self.calls()[0])
        self.assertFalse((self.path / 'INJECTED').exists())
        p = self.run_tcl('faultplus run atpg | /bin/false\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('unsafe exec', p.stderr)

    def test_invalidated_result_and_sequential_dff_requirement(self):
        p = self.run_tcl(self.setup_atpg() + '''
create_logic_tests -experiment demo
faultplus configure -clock other
report_faults
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('no successful', p.stderr)
        p = self.run_tcl(self.setup_atpg() + '''
faultplus configure -input_kind sequential
build_faultmodel
create_logic_tests
''')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('sequential input requires', p.stderr)

    def test_tcl_variables_loops_and_multiline(self):
        p = self.run_tcl('''
set langs {stil verilog}
foreach lang $langs {
    if {![catch {write_vectors -language $lang} message]} {error "expected rejection"}
    puts "rejected:$lang"
}
''')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('rejected:stil', p.stdout)
        self.assertIn('rejected:verilog', p.stdout)


@unittest.skipUnless(shutil.which('fault'), 'Fault not installed')
class RealFaultTest(unittest.TestCase):
    def test_full_fault_flow(self):
        with tempfile.TemporaryDirectory(prefix='faultplus-full-') as tmp:
            p = subprocess.run([str(CLI), '-f', str(ROOT / 'examples' / 'native_full_flow.tcl')],
                               cwd=tmp, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            for name in ('chained.v', 'jtag.v', 'vectors.bin', 'golden.bin', '.faultplus/seq.json'):
                with self.subTest(file=name):
                    self.assertGreater((Path(tmp) / name).stat().st_size, 0)
            self.assertIn('FAULT METADATA', (Path(tmp) / 'chained.v').read_text())

    def test_genus_real_synth_and_scan(self):
        with tempfile.TemporaryDirectory(prefix='faultplus-scan-') as tmp:
            p = subprocess.run([str(CLI), '-f', str(ROOT / 'examples' / 'genus_scan.tcl')],
                               cwd=tmp, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=90)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            netlist = (Path(tmp) / 'chained.v').read_text()
            self.assertIn('FAULT METADATA', netlist)
            self.assertIn('"internalCount":2', netlist)
            self.assertNotIn('ERROR:', (Path(tmp) / '.faultplus' / 'synth.log').read_text())

    def test_synthesis_preserves_paths_with_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory(prefix="faultplus path's ") as tmp:
            work = Path(tmp)
            liberty = work / "cell library.lib"
            design = work / "input design.v"
            shutil.copy(ROOT / 'examples' / 'tech_lib.lib', liberty)
            shutil.copy(ROOT / 'examples' / 'seq_design.v', design)
            script = work / 'synth.tcl'
            script.write_text(f"read_libs {{{liberty}}}\nread_hdl {{{design}}}\n"
                              "elaborate seq_design\nsyn_generic\nsyn_map\nwrite_hdl > result.v\n")
            p = subprocess.run([str(CLI), '-f', str(script)], cwd=work, text=True,
                               capture_output=True, timeout=120)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn('module seq_design', (work / 'result.v').read_text())
            self.assertNotIn('ERROR:', (work / '.faultplus' / 'synth.log').read_text())

    def test_and2_atpg(self):
        with tempfile.TemporaryDirectory(prefix='faultplus-real-') as tmp:
            script = (ROOT / 'examples' / 'atpg.tcl').read_text()
            self.assertNotIn('faultplus configure', script)
            self.assertNotIn('faultplus export', script)
            p = subprocess.run([str(CLI), '-f', str(ROOT / 'examples' / 'atpg.tcl')],
                               cwd=tmp, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=60)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            vec = json.loads((Path(tmp) / '.faultplus' / 'and2.json').read_text())
            self.assertTrue(vec['coverageList'])
            self.assertTrue((Path(tmp) / 'and2_vectors.v').is_file())
            self.assertIn('ratio:', (Path(tmp) / '.faultplus' / 'and2.coverage.yml').read_text())


if __name__ == '__main__':
    unittest.main()
