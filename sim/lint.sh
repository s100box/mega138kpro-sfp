#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Verible lint over the mega138kpro-sfp RTL, then the Verible format check (--verify
# against ../.verible.format) over the RTL and the benches. Stamps lint.ok on success.
set -euo pipefail
cd "$(dirname "$0")"

# Resolve verible-verilog-lint: an explicit $VERIBLE wins, else PATH, else a release
# unzipped under ~/verible/. If none is found, skip gracefully (stamp lint.ok, exit 0)
# so a plain clone without verible still gates on the sims -- override with
# VERIBLE=/path/to/verible-verilog-lint.
VERIBLE="${VERIBLE:-}"
if [ -z "$VERIBLE" ]; then
  if command -v verible-verilog-lint >/dev/null 2>&1; then
    VERIBLE=verible-verilog-lint
  else
    for base in "$HOME" "${USERPROFILE:-}" "/c/Users/${USERNAME:-${USER:-}}"; do
      [ -n "$base" ] || continue
      command -v cygpath >/dev/null 2>&1 && base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
      for c in "$base"/verible/*/verible-verilog-lint "$base"/verible/*/verible-verilog-lint.exe; do
        [ -x "$c" ] && { VERIBLE="$c"; break 2; }
      done
    done
  fi
fi
if [ -z "$VERIBLE" ] || ! command -v "$VERIBLE" >/dev/null 2>&1; then
  echo "lint: verible not found (set VERIBLE or add to PATH) -- skipping"
  echo lint-ok > lint.ok
  exit 0
fi

RTL="../rtl/m138_prbs_lane.sv ../rtl/m138_peer.sv"
TB="tb_m138_prbs_lane.sv tb_m138_peer.sv serdes_top_stub.sv"

# shellcheck disable=SC2086
"$VERIBLE" --rules_config ../.rules.verible_lint $RTL

# Format check with the formatter beside the linter: every file must already be
# in the ../.verible.format style (apply it with --inplace, without --verify).
FORMAT="${VERIBLE%verible-verilog-lint*}verible-verilog-format${VERIBLE##*verible-verilog-lint}"
command -v "$FORMAT" >/dev/null 2>&1 || FORMAT=verible-verilog-format
if command -v "$FORMAT" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  "$FORMAT" --flagfile=../.verible.format --inplace --verify $RTL $TB
else
  echo "lint: verible-verilog-format not found beside the linter -- format check skipped"
fi
echo lint-ok > lint.ok
