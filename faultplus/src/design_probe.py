#!/usr/bin/env python3
"""Conservative structural checks and scalar Verilog replay for Fault+.

This helper is deliberately limited to modeled, flattened netlists. It is not
an ATPG/DFT rule checker and rejects unrecognized cell types and port formats.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

IDENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_$]*$')
SEQ = re.compile(r'^\$(?:_?(?:a|s)?(?:dff|dlatch|sr)|_?ff|mem)', re.IGNORECASE)
COMB = {'$scopeinfo', '$not', '$pos', '$neg', '$and', '$or', '$xor', '$xnor',
        '$reduce_and', '$reduce_or', '$reduce_xor', '$reduce_xnor', '$reduce_bool',
        '$logic_not', '$logic_and', '$logic_or', '$shl', '$shr', '$sshl', '$sshr',
        '$shift', '$shiftx', '$lt', '$le', '$eq', '$ne', '$eqx', '$nex', '$ge', '$gt',
        '$add', '$sub', '$mul', '$div', '$mod', '$divfloor', '$modfloor', '$pow',
        '$mux', '$pmux', '$bmux', '$demux', '$bwmux', '$lut', '$sop', '$tribuf',
        '$slice', '$concat', '$fa', '$lcu', '$alu', '$macc'}


def quote_yosys(value):
    value = str(value)
    if '\n' in value or '\r' in value or '\x00' in value:
        raise ValueError('newline/NUL in path is unsupported')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def inspect_design(netlist, models, top):
    if not IDENT.fullmatch(top):
        raise ValueError('only simple Verilog top names can be auto-checked')
    with tempfile.TemporaryDirectory(prefix='faultplus-model-') as tmp:
        original = Path(tmp, 'hier.json')
        flatfile = Path(tmp, 'flat.json')
        script = (f'read_verilog -sv {quote_yosys(models)} {quote_yosys(netlist)}; '
                  f'hierarchy -check -top {top}; proc; check -assert; '
                  f'write_json {quote_yosys(original)}; flatten; '
                  f'write_json {quote_yosys(flatfile)}')
        try:
            p = subprocess.run(['yosys', '-Q', '-T', '-p', script], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValueError(f'Yosys structural check unavailable: {exc}') from exc
        if p.returncode:
            errors = [line.strip() for line in p.stdout.splitlines() if 'ERROR:' in line]
            raise ValueError('Yosys could not check netlist: ' + (errors[-1] if errors else p.stdout[-500:]))
        hier = json.loads(original.read_text())['modules']
        flat = json.loads(flatfile.read_text())['modules'][top]
    return hier, flat


def classify(hier, flat, top):
    seq = []
    for cell in flat.get('cells', {}).values():
        kind = cell['type']
        if SEQ.match(kind):
            seq.append(kind)
        elif kind not in COMB:
            raise ValueError(f'unmodeled or unsupported cell {kind}; cannot safely classify this design')
    if not seq:
        return 'COMBINATIONAL', ''
    inferred = []
    found = 0
    for cell in hier[top].get('cells', {}).values():
        name = cell['type']
        module = hier.get(name)
        if module is None:
            if SEQ.match(name):
                raise ValueError('top-level sequential primitive needs explicit cell mapping')
            continue
        nested = [c['type'] for c in module.get('cells', {}).values() if SEQ.match(c['type'])]
        if nested:
            # Conservative direct standard-cell case, not a hierarchy wrapper.
            if len(nested) != 1 or not {'D', 'Q'} <= set(module.get('ports', {})):
                raise ValueError(f'cannot infer FF mapping for {name}; use a supported cell model/config')
            if not IDENT.fullmatch(name):
                raise ValueError(f'unsupported sequential cell name {name}')
            found += 1
            if name not in inferred:
                inferred.append(name)
    if not inferred or found != len(seq):
        raise ValueError('sequential logic is hierarchical or is not a supported D/Q flip-flop')
    return 'SEQUENTIAL', ','.join(inferred)


def write_replay(hier, flat, top, jsonfile, target, clock, reset, reset_active_low, bypass):
    kind, _ = classify(hier, flat, top)
    if kind != 'COMBINATIONAL':
        raise ValueError('Verilog replay is limited to combinational netlists, not scan/FF patterns')
    ports = hier[top]['ports']
    for name, port in ports.items():
        if not IDENT.fullmatch(name) or len(port['bits']) != 1 or port['direction'] not in {'input', 'output'}:
            raise ValueError('Verilog replay currently supports simple scalar input/output ports only')
    vectors = json.loads(Path(jsonfile).read_text())
    inputs = [entry['name'] for entry in vectors['inputs']]
    outputs = [entry['name'] for entry in vectors['outputs']]
    if len(outputs) != 1 or len(set(inputs)) != len(inputs):
        raise ValueError('Verilog replay currently supports exactly one scalar output')
    if any(n not in ports or ports[n]['direction'] != 'input' for n in inputs):
        raise ValueError('Fault input list does not match netlist ports')
    if outputs[0] not in ports or ports[outputs[0]]['direction'] != 'output':
        raise ValueError('Fault output does not match netlist ports')
    constants = {clock: 1, reset: int(reset_active_low)}
    for item in bypass:
        name, sep, val = item.partition('=')
        if not sep:
            val = '1'
        if not IDENT.fullmatch(name) or val not in {'0', '1'}:
            raise ValueError('unsupported bypass value')
        constants[name] = int(val)
    const_ports = {k: v for k, v in constants.items() if k in ports}
    if set(inputs) & set(const_ports):
        raise ValueError('input also declared constant')
    if set(n for n, p in ports.items() if p['direction'] == 'input') != set(inputs) | set(const_ports):
        raise ValueError('not every DUT input is accounted for')
    if set(n for n, p in ports.items() if p['direction'] == 'output') != set(outputs):
        raise ValueError('not every DUT output is represented')
    rows = vectors['coverageList']
    if not rows:
        raise ValueError('empty pattern list')
    lines = ['`timescale 1ns/1ps', '// Fault+ functional replay of Fault vectors; not Modus scan patterns.',
             'module faultplus_vector_tb;']
    for name, port in ports.items():
        lines.append(f"  {'reg' if port['direction'] == 'input' else 'wire'} {name};")
    lines.append(f"  {top} dut (" + ', '.join(f'.{name}({name})' for name in ports) + ');')
    lines.append('  initial begin')
    for name, val in const_ports.items():
        lines.append(f"    {name} = 1'b{val};")
    for i, row in enumerate(rows):
        vv, golden = row['vector'], row['goldenOutput']
        if len(vv) != len(inputs) or golden not in ('0', '1'):
            raise ValueError('unsupported vector width or expected value')
        for name, item in zip(inputs, vv):
            if len(item) != 2 or item[0] != '+' or item[1] not in (0, 1):
                raise ValueError('unsupported Fault vector encoding')
            lines.append(f"    {name} = 1'b{item[1]};")
        lines.append(f"    #1; if ({outputs[0]} !== 1'b{golden}) $fatal(1, \"Vector {i} failed\");")
    lines += [f'    $display("Fault+ replay: {len(rows)} vectors passed");',
              '    $finish;', '  end', 'endmodule', '']
    Path(target).write_text('\n'.join(lines))
    return len(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['classify', 'replay'])
    parser.add_argument('--netlist', required=True)
    parser.add_argument('--models', required=True)
    parser.add_argument('--top', required=True)
    parser.add_argument('--json')
    parser.add_argument('--output')
    parser.add_argument('--clock', default='')
    parser.add_argument('--reset', default='')
    parser.add_argument('--reset-active-low', choices=['0', '1'], default='0')
    parser.add_argument('--bypass', action='append', default=[])
    args = parser.parse_args()
    try:
        hier, flat = inspect_design(args.netlist, args.models, args.top)
        if args.action == 'classify':
            ports = hier[args.top]['ports']
            for pin in [args.clock] + [item.partition('=')[0] for item in args.bypass]:
                if pin and (pin not in ports or ports[pin]['direction'] != 'input'):
                    raise ValueError(f'test input {pin!r} is absent or is not an input port')
            print(' '.join(classify(hier, flat, args.top)).strip())
        else:
            if not args.json or not args.output:
                raise ValueError('replay requires input JSON and output file')
            if Path(args.output).resolve() in {Path(x).resolve() for x in (args.netlist, args.models, args.json)}:
                raise ValueError('output file cannot overwrite the design, cell model, or vector input')
            print(write_replay(hier, flat, args.top, args.json, args.output,
                               args.clock, args.reset, args.reset_active_low == '1', args.bypass))
    except (ValueError, OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f'Fault+ model check: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
