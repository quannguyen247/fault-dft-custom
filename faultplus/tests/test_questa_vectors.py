"""Replay the small real Fault output on Questa when both tools are present."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('fault') and shutil.which('vsim') and
                     shutil.which('vlog') and shutil.which('vlib'),
                     'Fault or Questa not in PATH')
class QuestaVectorTest(unittest.TestCase):
    def test_generated_scan_chain_shift_on_questa(self):
        with tempfile.TemporaryDirectory(prefix='faultplus-scan-questa-') as tmp:
            def run(*cmd):
                result = subprocess.run(cmd, cwd=tmp, text=True, capture_output=True, timeout=90)
                if result.returncode:
                    self.fail(f"{cmd}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
                return result

            run(str(ROOT / 'bin' / 'faultplus'), '-f', str(ROOT / 'examples' / 'genus_scan.tcl'))
            run('vlib', 'work')
            run('vlog', str(ROOT / 'examples' / 'cells_sim.v'),
                str(Path(tmp) / 'chained.v'), str(ROOT / 'examples' / 'tb_scan.v'))
            result = run('vsim', '-c', 'tb_scan', '-do',
                         'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0')
            self.assertIn('FAULTPLUS_SCAN_PASS', result.stdout)
            self.assertNotIn('Fatal:', result.stdout)

    def test_fault_golden_vectors_on_questa(self):
        with tempfile.TemporaryDirectory(prefix='faultplus-questa-') as tmp:
            def run(*cmd):
                result = subprocess.run(cmd, cwd=tmp, text=True, capture_output=True, timeout=90)
                if result.returncode:
                    self.fail(f"{cmd}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
                return result

            run(str(ROOT / 'bin' / 'faultplus'), '-f', str(ROOT / 'examples' / 'atpg.tcl'))
            data = json.loads((Path(tmp) / '.faultplus' / 'and2.json').read_text())
            self.assertEqual([p['name'] for p in data['inputs']], ['a', 'b'])
            self.assertTrue(data['coverageList'])
            steps = []
            for i, vector in enumerate(data['coverageList']):
                a, b = (int(v[1]) for v in vector['vector'])
                expected = vector['goldenOutput']
                self.assertIn(expected, ('0', '1'))
                steps.append(f"a=1'b{a}; b=1'b{b}; #1; "
                             f"if (y !== 1'b{expected}) $fatal(1, \"vector {i}\");")
            tb = Path(tmp) / 'tb.v'
            tb.write_text('`timescale 1ns/1ps\nmodule tb; reg clk=0,rst=0,a,b; wire y;\n'
                          'and2_top dut(.clk(clk),.rst(rst),.a(a),.b(b),.y(y));\n'
                          'initial begin\n' + '\n'.join(steps) +
                          '\n$display("FAULTPLUS_QUESTA_PASS"); $finish; end endmodule\n')
            run('vlib', 'work')
            run('vlog', str(ROOT / 'examples' / 'and2_cells.v'),
                str(ROOT / 'examples' / 'and2_netlist.v'), str(tb))
            result = run('vsim', '-c', 'tb', '-do',
                         'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0')
            self.assertIn('FAULTPLUS_QUESTA_PASS', result.stdout)
            self.assertNotIn('Fatal:', result.stdout)
            # Also compile and run the actual file produced by write_vectors.
            run('vlog', str(Path(tmp) / 'and2_vectors.v'))
            result = run('vsim', '-c', 'faultplus_vector_tb', '-do',
                         'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0')
            self.assertIn('vectors passed', result.stdout)
            self.assertNotIn('Fatal:', result.stdout)
            # The same replay must reject a faulty implementation (AND -> OR).
            bad = Path(tmp) / 'bad'
            bad.mkdir()
            mutant = bad / 'cells.v'
            mutant.write_text('module AND2(input A,input B,output Y); assign Y=A|B; endmodule\n')
            for cmd in [('vlib', 'work'),
                        ('vlog', str(mutant), str(ROOT / 'examples' / 'and2_netlist.v'), str(Path(tmp) / 'and2_vectors.v'))]:
                check = subprocess.run(cmd, cwd=bad, text=True, capture_output=True, timeout=90)
                self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            check = subprocess.run(['vsim', '-c', 'faultplus_vector_tb', '-do',
                                    'onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0'],
                                   cwd=bad, text=True, capture_output=True, timeout=90)
            # This Questa edition can return zero after $fatal, so inspect the
            # transcript rather than treating exit status as proof of success.
            self.assertIn('Fatal: Vector', check.stdout)
            self.assertNotIn('vectors passed', check.stdout)


if __name__ == '__main__':
    unittest.main()
