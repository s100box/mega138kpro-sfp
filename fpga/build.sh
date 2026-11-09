#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
#
# Build or load m138_peer for one line rate.
#
#   fpga/build.sh synth <3|6|10>   bitstream for 3.125, 6.25 or 10.3125 Gb/s
#   fpga/build.sh prog  <3|6|10>   load it into SRAM over JTAG
#
# The rate has no default. The r10312 IP expects a 125 MHz reference and the
# dock supplies 100 MHz, so that build runs at 8.25 Gb/s
# (doc/mega138kpro-sfp-design.md).
#
# The SerDes IP for each rate is under fpga/serdes/r3125, r6250 and r10312
# (README.md says how to generate it); M138_SERDES_DIR overrides it. The build
# runs in $M138_BUILD/<r3125|r6250|r10312> ($M138_BUILD defaults to
# C:/mega138kpro-sfp-build on Windows, ~/mega138kpro-sfp-build elsewhere),
# never in the repository. The sources come from this repository and the
# siblings hh-xcku5p-dev and hh-uart (build.tcl); gowin.sh from retrosim-build.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lib="$here/../../retrosim-build/gowin.sh"
[ -f "$lib" ] || { echo "missing ../retrosim-build sibling" >&2; exit 1; }
. "$lib"
gowin_board mega138kpro

usage() { echo "usage: build.sh synth|prog 3|6|10" >&2; exit 2; }
[ $# -eq 2 ] || usage
cmd=$1
# period: the PCS clocks (line rate / 80); refper: the reference the rate's
# IP was generated for.
case $2 in
  3)  sub=r3125;  kbps=3125000;  period=25.600; refper=10 ;;
  6)  sub=r6250;  kbps=6250000;  period=12.800; refper=10 ;;
  10) sub=r10312; kbps=10312500; period=7.758;  refper=8 ;;
  *)  usage ;;
esac
base="m138_peer_$2"
if [ -n "${M138_BUILD:-}" ]; then out=$M138_BUILD
elif [ -d /c ]; then out=/c/mega138kpro-sfp-build
else out=$HOME/mega138kpro-sfp-build; fi
# One directory per rate: gowin_prog's staleness check scans the whole
# directory, so another rate's generated files would make this one look stale.
out="$out/$sub"
gen="$out/gen"
mkdir -p "$gen"

# M138_SERDES_DIR overrides the IP directory.
serdes=${M138_SERDES_DIR:-$here/serdes/$sub}
for f in serdes.v serdes.csr customized_phy/customized_phy.v; do
  [ -f "$serdes/$f" ] || { echo "missing $serdes/$f -- generate the SerDes IP (README.md)" >&2; exit 1; }
done

# The generated files are written only for a synthesis, so a prog does not
# make the bitstream look older than its sources.
if [ "$cmd" = synth ]; then
printf '`define M138_RATE_KBPS %s\n' "$kbps" > "$gen/m138_rate.svh"
# Every clock is asynchronous to every other.
cat > "$gen/m138_peer.sdc" <<SDC
create_clock -name sys_clk -period 20 [get_ports {sys_clk}]
create_clock -name ln0_tx -period $period [get_nets {tx_clk[0]}]
create_clock -name ln0_rx -period $period [get_nets {rx_clk[0]}]
create_clock -name ln1_tx -period $period [get_nets {tx_clk[1]}]
create_clock -name ln1_rx -period $period [get_nets {rx_clk[1]}]
create_clock -name refclk -period $refper [get_nets {refclk[0]}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {ln0_tx}] -group [get_clocks {ln0_rx}] -group [get_clocks {ln1_tx}] -group [get_clocks {ln1_rx}] -group [get_clocks {refclk}]
SDC
fi

w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
export M138_DIR=$(w "$here") M138_SERDES=$(w "$serdes") M138_GEN=$(w "$gen") \
       M138_SDC=$(w "$gen/m138_peer.sdc") M138_BASE=$base GOWIN_DEVICE GOWIN_PART
export GOWIN_TCL=$(w "$here/build.tcl")
cd "$out"
case $cmd in
  synth) gowin_synth "$base" "$gen/m138_peer.sdc" ;;
  prog)  gowin_prog "$base" ;;
  *)     usage ;;
esac
