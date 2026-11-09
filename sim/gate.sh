#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Run the self-checking iverilog benches. The SerDes is a behavioral stand-in
# (serdes_top_stub.sv), so a plain iverilog runs them with no vendor library.
# The register bridge and frequency counters come from the sibling checkout
# hh-xcku5p-dev and the UART cores from hh-uart; both must sit beside this
# repository.
#
# A bench passes when vvp exits 0 and prints "<bench>: PASS"; this script
# exits non-zero if any bench does not.
set -euo pipefail
cd "$(dirname "$0")"

# Locate iverilog / vvp: an explicit $OSS_CAD_SUITE wins, else PATH, else an OSS
# CAD Suite unzipped under the user's home ($HOME can be redirected, so also try
# $USERPROFILE and /c/Users/<name>). If none is found, skip (exit 0) so a plain
# clone without iverilog still gates on lint.
if [ -z "${OSS_CAD_SUITE:-}" ] && ! command -v iverilog >/dev/null 2>&1; then
  for base in "$HOME" "${USERPROFILE:-}" "/c/Users/${USERNAME:-${USER:-}}"; do
    [ -n "$base" ] || continue
    command -v cygpath >/dev/null 2>&1 && base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
    if [ -x "$base/oss-cad-suite/bin/iverilog" ] || [ -x "$base/oss-cad-suite/bin/iverilog.exe" ]; then
      OSS_CAD_SUITE="$base/oss-cad-suite"
      break
    fi
  done
fi
# Prepend both bin/ and lib/ (on Windows, bin/ alone exits 127 on missing DLLs).
# Normalize a Windows root first: a raw drive-letter colon would split PATH.
if [ -n "${OSS_CAD_SUITE:-}" ]; then
  ocs="$OSS_CAD_SUITE"
  command -v cygpath >/dev/null 2>&1 && ocs="$(cygpath -u "$ocs")"
  export PATH="$ocs/bin:$ocs/lib:$PATH"
fi
if ! command -v iverilog >/dev/null 2>&1; then
  echo "gate: iverilog not found (set OSS_CAD_SUITE or add to PATH) -- skipping benches"
  exit 0
fi

KU5P=../../hh-xcku5p-dev/pl/board/rtl
UART=../../hh-uart/rtl
for f in "$KU5P/ku5p_uart_bridge.sv" "$UART/uart_rx_core.sv"; do
  [ -f "$f" ] || { echo "gate: missing $f -- check out hh-xcku5p-dev and hh-uart beside this repository"; exit 1; }
done

fail=0
run() {  # <bench> [iverilog options] <sources...>; the bench is also the top module
  local name=$1
  shift
  local log
  if ! log=$(iverilog -g2012 -s "$name" -o "$name.vvp" "$@" 2>&1); then
    echo "[$name] FAIL: does not compile"
    echo "$log" | tail -8
    fail=1
    return
  fi
  local out rc=0
  out=$(vvp -n "$name.vvp" 2>&1 </dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "^$name: PASS"; then
    echo "[$name] $(echo "$out" | grep "^$name: PASS" | head -1)"
  else
    echo "[$name] FAIL (vvp exit $rc)"
    echo "$out" | tail -8
    fail=1
  fi
}

# The PRBS-31 lane against a serial line model with a bit offset, TX
# back-pressure and RX gaps.
run tb_m138_prbs_lane tb_m138_prbs_lane.sv ../rtl/m138_prbs_lane.sv
# The whole design over real UART bits, against a stand-in SerDes_Top that
# loops each lane to itself.
run tb_m138_peer -I. tb_m138_peer.sv serdes_top_stub.sv ../rtl/m138_peer.sv \
  ../rtl/m138_prbs_lane.sv "$KU5P/ku5p_uart_bridge.sv" "$KU5P/ku5p_freq_bank.sv" \
  "$KU5P/ku5p_freq_chan.sv" "$UART/uart_baud_dds.sv" "$UART/uart_rx_core.sv" \
  "$UART/uart_tx_core.sv"

if [ "$fail" -eq 0 ]; then
  echo "ALL BENCHES PASS"
else
  echo "BENCH FAILURE"
  exit 1
fi
