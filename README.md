# mega138kpro-sfp

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

A PRBS-31 link tester for the Sipeed Tang Mega 138K Pro Dock. Its two SFP+
cages provide an independent far end for the XCKU5P and RK-ZYNQ7100 boards
at 3.125 or 6.25 Gb/s, controlled through the XCKU5P host tool.

Board listing: [Tang Mega 138K Pro Dock on Amazon](https://www.amazon.com/dp/B0F2FBXH2Z).

## Documentation

| Document | Contents |
|---|---|
| [Design](doc/mega138kpro-sfp-design.md) | Architecture, registers, SerDes generation, rate limits, and verification. |
| [Coverage](doc/coverage.md) | Measured coverage and hole triage. |
| [RTL style](https://github.com/s100box/retrosim-build/blob/main/doc/rtl-style.md) | Shared formatting, local lint exceptions, and checked scope. |

## Repository layout

| Path | Contents |
|---|---|
| `rtl/m138_peer.sv` | The top: the generated SerDes, two lanes, the register bridge, the frequency counters, the resets and the LEDs. |
| `rtl/m138_prbs_lane.sv` | One PRBS-31 lane: generator, checker, lock, saturating counters, and a snapshot handshake into the register clock. Vendor-neutral. |
| `fpga/` | The Gowin build: `build.sh`, `build.tcl`, the pin constraints `m138_peer.cst`, and `serdes/<rate>/serdes.ipc`, the record of each SerDes IP generation. |
| `sim/` | The self-checking benches, a behavioral `SerDes_Top` stand-in, the lint and bench scripts, and the Verilator coverage suite (`sim/vl/`). |
| `tools/cov_summary.py` | Renders `doc/coverage.md` from a coverage run. |
| `mega138kpro-sfp.core` | FuseSoC manifest: the file list and compile order. |

## Requirements

### Tools

| Tool | Version | Used for |
|---|---|---|
| Gowin EDA (`gw_sh`, `programmer_cli`, and the IDE's IP Core Generator) | 1.9.12.03 | `fpga/build.sh`; the SerDes IP can only be generated in the IDE (below) |
| [Verible](https://github.com/chipsalliance/verible) | v0.0-4053 | lint and format check (`ninja`) |
| [Icarus Verilog](https://github.com/steveicarus/iverilog) (`iverilog`, `vvp`) from the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) | 14.0 | the benches (`ninja sim`) |
| [Ninja](https://ninja-build.org/) | 1.10 or later | drives both |
| [Verilator](https://www.veripool.org/verilator/) from the OSS CAD Suite, with Visual Studio (MSVC) and its CMake | 5.049 | the coverage suite (`sim/vl/cov.ps1`), opt-in |
| Python | 3.10 or later | shared hook checks and coverage/report tools; the host tool in hh-xcku5p-dev |

`sim/lint.sh` finds `verible-verilog-lint` through `VERIBLE`, PATH, or a
release unzipped under `~/verible/`, and the formatter beside it;
`sim/gate.sh` finds the OSS CAD Suite through `OSS_CAD_SUITE`, PATH, or
`~/oss-cad-suite`. Either script skips itself when its tool is absent, so a
clone with one tool still gates on that one.

### Sibling repositories

The design builds from sources in two sibling checkouts, and the build and
gate scripts take their tool paths from a third, so the checkout must sit
next to them:

| Repository | Provides |
|---|---|
| `hh-xcku5p-dev` | `pl/board/rtl/ku5p_uart_bridge.sv`, the UART register bridge, and `ku5p_freq_chan.sv` + `ku5p_freq_bank.sv`, the frequency counters; and the host tool, `tools/ku5p.py`, whose `qsfp-peer --m138` and `zynq-m138` commands drive this board (`tools/ku5p/m138peer.py`) |
| `hh-uart` | `rtl/uart_baud_dds.sv`, `uart_rx_core.sv`, `uart_tx_core.sv`, under the bridge |
| `retrosim-build` | `gowin.sh`, which `fpga/build.sh` sources to run `gw_sh` and `programmer_cli` and to refuse to load a stale bitstream; `toolchain.ninja`, which defines `bash_exe` for the ninja rules; `hooks/gate-env.sh`, which the pre-commit hook sources to put Verible and the OSS CAD Suite on PATH; and `tools/vl_cov.ps1` + `tools/cov_summary_lib.py`, the coverage suite's driver and report renderer (which find Verilator and the MSVC build environment through `toolchain.ps1` and `tools/vs_env.ps1`) |
| `hh-rk-zynq7100-dev` | optional: the RK-ZYNQ7100 far end that `zynq-m138` joins to this board |

```text
<workspace>/
  mega138kpro-sfp/
  hh-xcku5p-dev/
  hh-uart/
  retrosim-build/
```

## Getting started

Generate the SerDes IP using the [design settings](doc/mega138kpro-sfp-design.md#61-ip-generation) before the first build.

```sh
fpga/build.sh synth 3        # 3.125 Gb/s bitstream (6 for 6.25; see the 10-rate limitation below)
fpga/build.sh prog 3         # load it into SRAM over JTAG
```

The line rate is fixed per bitstream and has no default. `10` builds but
runs at 8.25 Gb/s on the dock, whose SerDes reference clock is 100 MHz
(the design doc says why). The build runs outside the repository, in
`$M138_BUILD/<r3125|r6250|r10312>` (`M138_BUILD` defaults to
`C:/mega138kpro-sfp-build` on Windows and `~/mega138kpro-sfp-build`
elsewhere), one directory per rate. `M138_SERDES_DIR` points the build at a
SerDes IP directory other than `fpga/serdes/<rate>`.

With the bitstream loaded, from an hh-xcku5p-dev checkout:

```sh
python tools/ku5p.py qsfp-peer --m138 <port> --rate 3    # the XCKU5P's QSFP lanes against this board
python tools/ku5p.py zynq-m138 --m138 <port> --zynq USER@HOST   # an RK-ZYNQ7100 against this board
```

`<port>` is the dock debugger's second serial port. `qsfp-peer` checks that
the loaded bitstream's rate matches the XCKU5P's and names the build to load
if it does not.

## Verification

From the repository root:

```sh
ninja -C sim                  # lint and format checks
ninja -C sim sim              # self-checking Icarus benches
```

The [verification specification](doc/mega138kpro-sfp-design.md#8-verification)
describes the lane and full-design checks. The scripts also run directly as
`bash sim/lint.sh` and `bash sim/gate.sh`.

### Coverage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim/vl/cov.ps1
python tools/cov_summary.py
```

The optional suite regenerates [doc/coverage.md](doc/coverage.md), preserving
its hole triage; `--holes` lists uncovered points.

### Commit checks

Enable the hook with `git config core.hooksPath .githooks`. It checks shell
and Python syntax, lint, formatting, and both simulations.
`.rules.verible_lint` allows uppercase localparams and blocking assignments
to block-local temporaries inside `always_ff`.

## License

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

### Contributions

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
