# Command reference

Start Fault+ with `faultplus`, or pass a Tcl file with `faultplus -f flow.tcl`. Normal Tcl variables, loops and `source` work inside the session. [Installation](../Readme.md#install) sets up the complete backend.

## Stuck-at flow

```tcl
build_model -workdir [pwd] \
    -designsource design.v -techlib cells.v -designtop top
build_testmode -testmode COMB -assignfile pins.assign
build_faultmodel -includedynamic no
create_logic_tests -testmode COMB -experiment run1
report_faults -testmode COMB -experiment run1
write_vectors -testmode COMB -inexperiment run1 \
    -language verilog -outputfilename replay.v
```

Use your netlist, top name and Verilog cell models. `-techlib` accepts one `.v` file. It does not read a Modus techlib database or a Liberty file at this step. The [included example](examples/atpg.tcl) has complete inputs.

The assign file accepts one clock (`+ES` or `-ES`) and constant input assignments (`+TI` or `-TI`):

```text
assign pin=clk test_function=-ES;
assign pin=rst test_function=-TI;
```

Other assign functions, multiple clocks and scan sequences are rejected. Fault holds its clock high during fault simulation. `define_test_signal -function async_set_reset -active low rst_n` can set an active-low reset before the model is built.

Yosys checks the flattened cell models. Supported D/Q flip-flops can be cut into pseudo-inputs and outputs for Fault. That result is a combinational fault campaign; converting it to scan shift/capture patterns requires additional work.

Results go under `.faultplus/`: `run1.json`, `run1.coverage.yml` and, for sequential input, `run1.cut.v`. Repeating an experiment replaces its files. Fault/Pyverilog can also create `parser.out` and `parsetab.py`.

`write_vectors` supports only scalar combinational ports and one output. The resulting Verilog file checks Fault's golden output for each vector. Sequential, bus and tester-format exports are rejected.

## Synthesis and scan

The [synthesis example](examples/genus_scan.tcl) uses this order:

```tcl
read_libs cells.lib
read_hdl design.v
elaborate top
syn_generic
syn_map
define_test_clock -name CK -period 10 clk
define_test_signal -function async_set_reset -active high rst
define_shift_enable -name SE -active high shift
define_test_mode -name TM -active high test
define_scan_chain -name sc -sdi sin -sdo sout -shift_enable SE -create_ports
connect_scan_chains
write_hdl > chained.v
```

`read_libs`, `read_hdl`, `elaborate` and `syn_generic` record settings. Synthesis occurs at `syn_map`; it also writes `.faultplus/synth.log`. Clock period and SDC constraints are not applied. The scan step uses DFF types inferred from the mapping log and runs `fault chain`, including Fault's boundary chain. Check the generated ports and `FAULT METADATA`.

[full_flow.tcl](examples/full_flow.tcl) combines synthesis/scan with a separate ATPG run on the original cut netlist. It does not generate serialized scan patterns.

## Supported scope

| Area | Limit |
| --- | --- |
| HDL and libraries | One Liberty library for synthesis; Verilog v1995/v2001 input. |
| Scan | One scan configuration; active-high shift and test controls. No Genus DFT objects or DRC. |
| Fault model | Static stuck-at. Fault creates sites during `create_logic_tests`. |
| Testmode and experiment | One current mode and result. Names are labels; no Modus database is built. |
| Reports | Fault JSON/YAML; no Modus fault classification or Genus PPA reports. |
| Vector export | Scalar combinational Verilog replay only. No STIL, WGL, TDL or tester timing. |

`set_db workdir DIR`, `set_option testmode NAME` and `set_context -testmode NAME` manage the current output directory and mode label.

`verify_test_structures`, `report_test_structures`, `create_scanchain_tests`, `commit_tests`, `check_dft_rules`, `syn_opt`, `read_sdc`, `report_timing`, `report_area` and `report_power` return explicit unsupported errors. Compression, at-speed/delay ATPG, MBIST/LBIST, IJTAG and diagnosis are not implemented by these aliases.

For native Fault operations without a verified alias, use `faultplus run synth|cut|atpg|chain|tap|asm ...` inside Tcl. `faultplus configure`, `faultplus status` and `faultplus export` expose backend settings and results. These extensions are documented by `faultplus help`; the [native example](examples/native_full_flow.tcl) exercises them. `fault asm` requires a matching scan netlist with `FAULT METADATA`.

Fault+ defaults to one ATPG worker after a concurrent Fault crash was observed. In a native environment, set `FAULT_THREADS` to a positive integer to override it. The fork also initializes generated headers once per process and preserves filenames passed to Yosys.

## Checks and sources

`python3 -m unittest discover -s faultplus/tests -v` tests option rejection, argument handling, real synthesis/scan/ATPG and vector replay. Questa tests require `vlog`, `vlib`, `vsim` and a usable license. The install container runs the backend checks; it does not include Questa.

Public references: [Fault usage](https://fault.readthedocs.io/en/stable/usage.html), [Cadence Modus](https://www.cadence.com/en_US/home/tools/digital-design-and-signoff/test-automation/modus-dft-software.html), and [Cadence's pin assignment example](https://community.cadence.com/cadence_technology_forums/f/digital-implementation/17455/encounter-test-write-a-pin-assigment-file). Compatibility with a licensed Cadence installation has not been tested.
