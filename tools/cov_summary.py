#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""cov_summary.py -- render doc/coverage.md from the merged Verilator coverage
.dat produced by sim/vl/cov.ps1.

Declares this repository's report (scope, notes, prose); the parser and the
layout are retrosim-build/tools/cov_summary_lib.py. The hand-authored
"## Hole triage" section of doc/coverage.md is kept across regenerations.

Usage:  python tools/cov_summary.py [--report-dir <dir>] [--out doc/coverage.md]
        python tools/cov_summary.py --holes      # also list uncovered points to stderr
"""
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = Path(os.environ.get("RETROSIM_BUILD", REPO.parent / "retrosim-build")) / "tools"
if not LIB.is_dir():
    sys.exit("cov_summary: missing ../retrosim-build sibling (check it out beside this repository)")
sys.path.insert(0, str(LIB))
import cov_summary_lib as cov  # noqa: E402

_under_rtl = cov.is_sv_under("rtl")


def in_scope(path: str) -> bool:
    """A source of this repository's rtl/ (the sibling repositories have rtl/
    directories of their own; coverage.vlt excludes them, and this keeps them
    out even if it does not)."""
    return _under_rtl(path) and (REPO / "rtl" / os.path.basename(path.replace("\\", "/"))).is_file()


REPORT = cov.Report(
    repo=REPO,
    title="mega138kpro-sfp RTL code coverage (Verilator)",
    body=[
        "- Suite (the benches `sim/vl/CMakeLists.txt` builds): the same "
        "self-checking benches `ninja sim` runs under iverilog, re-elaborated "
        "under Verilator with `--main`. Points are merged by logical identity "
        "across benches and instances (covered if any instance hit it).\n",
        "- Scope: coverage is instrumented on the synthesizable RTL only "
        "(`rtl/*.sv`); the testbenches are excluded by `sim/vl/coverage.vlt`.\n",
    ],
    sections=[cov.Section("RTL", in_scope)],
    notes={
        "m138_prbs_lane.sv": "PRBS-31 generator, self-synchronizing checker, counters",
        "m138_peer.sv": "SerDes wrapper, register map, resets, LEDs",
    },
)

if __name__ == "__main__":
    raise SystemExit(cov.main(REPORT))
