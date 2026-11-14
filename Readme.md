# Fault+

Fault+ is a fork of [Fault](https://github.com/AUCOHL/Fault) with a Tcl interface for selected Cadence Genus and Modus command forms. It runs the open-source Fault backend for synthesis, scan stitching and stuck-at test generation.

## Install

After cloning this repository, run one command:

```sh
./install.sh
```

The installer downloads the environment built from this revision and adds `faultplus` to `~/.local/bin`. Your existing `fault` command and installation stay separate. It includes native Fault and Yosys binaries, Tcl, Icarus Verilog and the Python packages. Swift is built inside the environment; you do not need it on the host.

Linux x86_64 and ARM64 are supported through Docker or Podman. If neither engine is usable, the installer installs Podman using apt, dnf, yum, zypper, pacman or apk. That step needs administrator permission. Other distributions need a working container engine first. A host that disables containers or user namespaces needs its administrator to enable them.

A published revision uses a prebuilt download. For unpublished revisions or local source changes, the installer builds the environment, which takes several minutes. Use `./install.sh --build` to rebuild it explicitly. Internet access is needed for the first installation.

The environment pins these stable tool releases, checked on 14 November 2026: Fault 0.9.4, Yosys 0.71, Icarus Verilog 13.0 and Tcl 9.1.0. The fork is built with Swift 6.4.2. Yosys uses Tcl 8.6.18 internally for its C API compatibility. Exact build versions are recorded in `/opt/faultplus/VERSIONS.txt` inside the environment.

## Run

Start an interactive Tcl session:

```sh
faultplus
```

Or run a script from the current directory:

```sh
faultplus -f design.tcl
```

The launcher shares your home and current directory with the container, preserving their absolute paths. Keep external-drive inputs within the current directory tree. Outputs belong to your user. If `~/.local/bin` is outside your `PATH`, use `~/.local/bin/faultplus`.

Try the included small examples from the repository root:

```sh
faultplus -f faultplus/examples/atpg.tcl
faultplus -f faultplus/examples/genus_scan.tcl
```

The first creates stuck-at patterns and a combinational Verilog replay testbench. The second synthesizes a small design and stitches its scan chain. Both write outputs into the current directory.

## Command support

| Command group | What runs |
| --- | --- |
| `read_libs`, `read_hdl`, `elaborate`, `syn_generic`, `syn_map`, `write_hdl` | Load the flow settings, then synthesize with Fault/Yosys at `syn_map`. |
| `define_test_clock`, `define_test_signal`, `define_shift_enable`, `define_test_mode`, `define_scan_chain`, `connect_scan_chains` | Set the supported clock, reset and scan ports, then run `fault chain`. |
| `build_model`, `build_testmode`, `build_faultmodel`, `create_logic_tests`, `report_faults` | Prepare a stuck-at run and report Fault's results. Supported sequential inputs are cut into pseudo-I/O. |
| `write_vectors -language verilog` | Export functional replay for scalar combinational designs with one output. |

These mappings cover selected command forms. They do not reproduce Cadence databases, synthesis algorithms, DFT DRC, scan capture sequences, delay ATPG, compression, MBIST/LBIST, diagnosis or tester formats. Unsupported commands and options return errors. Read the [command reference](faultplus/README.md) before reusing a script.

The shell accepts 21 command names from this subset. There is no measured percentage of Cadence compatibility. This fork has not been compared against a licensed Cadence installation. Sharing a command name does not establish identical behavior or results.

## Development

The [Linux workflow](.github/workflows/faultplus.yml) builds the fork on x86_64 and ARM64, runs the shell/backend checks and publishes install packages from `main`. Direct RTL replay tests use Questa when it is available. Fault's internal fault simulator uses Icarus.

For a native development environment, follow [Fault's dependency instructions](docs/Source/installation.md), then install this checkout and `./faultplus`. Run:

```sh
python3 -m unittest discover -s faultplus/tests -v
```

DFT lessons are maintained in [tcl-train](https://github.com/quannguyen247/tcl-train/tree/main/eda/dft).

## License

Fault and this fork use the [Apache License 2.0](License). Copyright © 2018-2024 The American University in Cairo and other contributors. Third-party notices are retained in [OSAcknowledgements](OSAcknowledgements). The reused example fixtures carry their [MIT notice](faultplus/examples/LICENSE.tcl-train).

Some optional upstream distributions include Atalanta or PODEM, which have separate noncommercial restrictions. The supplied Fault+ environment uses Fault's default generator and does not bundle those tools.

Fault+ is independent of Cadence. Cadence, Genus and Modus are names owned by their respective trademark holders.
