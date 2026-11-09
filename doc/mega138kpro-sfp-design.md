# mega138kpro-sfp design

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

For setup, build commands, and commit checks, see the [README](../README.md).
This document defines the design and its verification scope.

**Contents**

- [1. Purpose](#1-purpose)
- [2. Architecture](#2-architecture)
- [3. PRBS lane (`m138_prbs_lane`)](#3-prbs-lane-m138_prbs_lane)
- [4. Registers](#4-registers)
- [5. Clocks and constraints](#5-clocks-and-constraints)
- [6. SerDes configuration](#6-serdes-configuration)
- [7. Hardware validation](#7-hardware-validation)
- [8. Verification](#8-verification)

## 1. Purpose

`m138_peer` makes a Sipeed Tang Mega 138K Pro Dock (GW5AST-LV138FPG676) a
PRBS-31 far end on its two SFP+ cages. Another board's transceivers send
PRBS-31 to it and check what it sends back, and a PC reads its counters. It
supports testing the XCKU5P's QSFP lanes, through a QSFP+ to 4x SFP+ active
optical cable, and the RK-ZYNQ7100's SFP+ cages over SFP DAC cables. The
other end's transceivers are Xilinx GTYs or GTXs; this end's are Gowin's, so
a fault that follows the far end's transceiver family is told apart from one
in the near end's.

<a id="2-structure"></a>
## 2. Architecture

```text
            sys_clk 50 MHz                       SerDes quad 1 (SerDes_Top, generated)
  key_n ─► reset ─► rst_n                       ┌──────────────────────────────┐
                        │                       │ lane 0  tx_clk/rx_clk, 80-bit │◄─► SFP+ cage 0
  uart_rxd ─► ku5p_uart_bridge ─► registers ◄──►│ lane 1  tx_clk/rx_clk, 80-bit │◄─► SFP+ cage 1
  uart_txd ◄─┘     (bus master)      │          └──────────────────────────────┘
                                     ├── m138_prbs_lane ×2 (one per lane)
                                     └── ku5p_freq_bank (5 channels)
```

- `ku5p_uart_bridge` (hh-xcku5p-dev) turns the UART into a 32-bit register
  bus at 115200 baud; it holds its own grant (`m_gnt` tied to `m_lock`)
  because it is the only master. Its frame format and the design ID ping are
  in hh-xcku5p-dev's `pl/board/SPEC.md`.
- `SerDes_Top` is the Gowin Customized PHY for lanes 0 and 1 of quad 1, raw
  (no 8B/10B, no word alignment), 20-bit internal width at 1:4, so each lane
  moves an 80-bit word per PCS clock. Its RX FIFO is read whenever it is not
  almost empty, and the lane takes the words that come out with `rx_valid`.
- Each `m138_prbs_lane` generates and checks one lane in that lane's own TX
  and RX clocks, and hands its counters to `sys_clk` through a snapshot.
- `ku5p_freq_bank` (hh-xcku5p-dev) counts five clocks against `sys_clk`.

The SFP+ transmit-disable outputs are tied low: both cages always transmit.

### Reset

`rst_n` comes from a 16-bit power-on counter, about 1.3 ms at 50 MHz, held
at zero while the dock's key (`key_n`, synchronized) is pressed. It resets
the bridge, the registers and the lanes' register-side state; the SerDes has
resets of its own under CTRL (section 4).

### LEDs

`led_n` is active low: LED 0 and LED 1 light while lane 0 and lane 1 are
PRBS-locked, LED 2 and LED 3 while their CDRs report lock.

<a id="3-the-lane-m138_prbs_lane"></a>
## 3. PRBS lane (`m138_prbs_lane`)

### Generator

The pattern is x^31 + x^28 + 1: in time order, line bit n is
b[n-31] ^ b[n-28]. That is the PRBS-31 the XCKU5P's GTYs and the
RK-ZYNQ7100's GTXs generate and check. `prbs_step` produces the next 80 line
bits from the last 31 in one step; word bit 0 is the first on the line, the
order the Gowin SerDes sends ("low first"). `cfg` modifies the word on its
way out: TX_REV reverses it (for a serializer that sends bit 79 first),
TX_INV inverts it, TX_OFF sends zeros, and each change of `inj_tgl` flips
bit 0 of one word. An injection stays pending during TX back-pressure and
is consumed by the next word sent. This toggle interface holds one pending
injection; software must wait for transmission before issuing another.
Configuration bits cross as software-held levels, so change them between
measurements and allow the lane clocks to settle before reading counters.

### Checker

The checker predicts every received bit from the 31 before it, so it needs
no seed and no word alignment: whatever bit offset the receiver's words have,
the recurrence holds across word boundaries. A flipped line bit breaks the
recurrence three times (the bit itself, and again 28 and 31 bits later), so
`err_bits` counts about three per line error. RX_REV and RX_INV undo a
reversed or inverted receiver. A checker that sees the inverted pattern
finds errors everywhere, because the inverse of PRBS-31 does not follow the
recurrence; this is how the host tool finds each lane's polarity.

The receive path is a five-stage pipeline in `rx_clk`: the word is
registered off the SerDes; the 80-bit error vector is formed; ten 8-bit
popcounts; their sum, `nerr`, the word's error bits; lock and the
counters. An all-zero word (after RX_INV) counts as 80 errors: a stuck or
idle line follows the recurrence trivially, and PRBS-31 never has more
than 30 zeros in a row.

### Lock and counters

- 32 error-free words in a row lock the lane.
- While locked, 4 words in a row with 8 or more error bits unlock it and
  count one lost lock.
- Error bits (`err_bits`), words with errors (`err_words`) and words checked
  (`lock_words`, 64 bits) count only while locked, so a lane that has never
  locked reads 0 errors and 0 words, never a clean result.
- The 32-bit counters saturate at 0xFFFF_FFFF instead of wrapping; the
  64-bit locked-word count wraps modulo 2^64.
- Each change of `clr_tgl` clears all four.

### Snapshot

The counters live in `rx_clk`. The register side takes a snapshot with a
toggle handshake: it flips `snap_req`, the lane copies its counters into
hold registers and flips `snap_ack`, and the register side copies the hold
registers once it sees the ack. The hold registers do not move between a
request and the next one, so the register side samples stable values.
`locked` is synchronized into `clk` on its own.

## 4. Registers

32-bit registers at byte addresses, acked the cycle after the request:

| Address | Name | Contents |
|---|---|---|
| 0x000 | ID | "M138", 0x4D31_3338 (also the bridge's ping reply) |
| 0x004 | RATE | the IP target rate in kb/s (3125000, 6250000 or 10312500), not a measured rate; the last target runs at 8.25 Gb/s on this dock (§6) |
| 0x008 | CTRL | write: [0] clear every lane's counters, [1] PMA reset, [2] PCS RX reset, [3] PCS TX reset; read: [1]..[3] the reset in progress |
| 0x00C | STATUS | lane n in byte n: [0] PLL lock, [1] CDR lock, [2] signal detect, [3] ready, [4] PRBS locked, [5] RX valid |
| 0x010 | LANE_CFG | lane n at bits [8n+4:8n]: [0] RX invert, [1] TX invert, [2] RX bit reverse, [3] TX bit reverse, [4] TX all zeros |
| 0x014 | INJECT | write: bit n flips one TX bit on lane n |
| 0x040 + 0x20n | lane n | +0x00 error bits, +0x04 words with errors, +0x08 / +0x0C words checked while locked (low, high), +0x10 lock losses |
| 0x200 | frequency counters | `ku5p_freq_bank`, 1 s gate: channel 0 the SerDes reference clock, 1 and 2 lane 0's TX and RX PCS clocks, 3 and 4 lane 1's |

A CTRL reset lasts `RST_CYCLES` (50,000 cycles, 1 ms). Unmapped addresses
read 0 and ignore writes.

## 5. Clocks and constraints

`fpga/build.sh` writes the timing constraints for each rate. Every clock is
asynchronous to every other, and every crossing is a two-flop synchronizer
or the snapshot handshake:

| Clock | Period |
|---|---|
| `sys_clk` | 20 ns (50 MHz) |
| lane TX and RX PCS clocks (line rate / 80) | 25.6 ns at 3.125 Gb/s, 12.8 ns at 6.25; the r10312 build constrains 7.758 ns but physically runs at about 9.697 ns on the dock (§6) |
| the SerDes reference clock | 10 ns (8 ns for the 10.3125 Gb/s IP) |

The build also writes `m138_rate.svh`, which sets `RATE_KBPS` and so the
RATE register.

<a id="6-the-serdes-and-its-reference-clock"></a>
## 6. SerDes configuration

**The reference clock is 100 MHz, not the 125 MHz of Sipeed's SFP
examples.** The dock's MS5351 drives quad 1's REFCLK1; frequency counter
channel 0 measures it (100,005,900 Hz on the bench dock). An IP generated for
125 MHz runs every rate at 0.8 times its setting. The IDE does not configure
10.3125 Gb/s from 100 MHz (10.3125 / 0.1 is not a ratio its PLLs reach), so
the r10312 IP is generated for 125 MHz on QPLL1. Nothing in this design
reprograms the MS5351, so on the dock that build runs at 8.25 Gb/s: the
138K Pro is a far end at 3.125 and 6.25 Gb/s only.

**A Gowin CDR can lock on the wrong frequency.** At 3.125 Gb/s a lane's CDR
can settle at about 3.47 Gb/s (its recovered clock 43.4 MHz instead of
39.06), with its lock flag high and the PRBS checker out of lock. A PCS RX
reset (CTRL bit 2) leaves it there; a PMA reset (CTRL bit 1) makes it acquire
again. The host driver (`M138Peer.configure` in hh-xcku5p-dev's
`tools/ku5p/m138peer.py`) therefore starts every run with a PMA reset.
Frequency counter channels 2 and 4, the lanes' RX clocks, show a lane in
this state.

### 6.1 IP generation

The generated SerDes IP is not in the repository: the Customized PHY
configuration (line rate, reference clock, PLL, width, coding) can only be
generated in the Gowin IDE's IP Core Generator, because gw_sh's IP commands
expose no SerDes settings and GowinModGen rebuilds only the Verilog wrapper,
not the register file (`serdes.csr`) that carries the rate.
`fpga/serdes/<rate>/serdes.ipc` records the settings of each generation.
Generate `serdes.v`, `serdes.csr`, `serdes_tmp.toml` and
`customized_phy/customized_phy.v` into `fpga/serdes/r3125`, `r6250` and
`r10312` as follows.

In Gowin IDE 1.9.12.03, with any project for GW5AST-LV138FPG676AC1/I0:
**Tools > IP Core Generator > SerDes**, File Name `serdes`, Module Name
`SerDes_Top`, Protocol **Customized** > Create, keeping the default
`Customized_PHY_Top` module name:

| Setting | Value |
|---|---|
| Channel Selection | Q1 Lane0, Q1 Lane1 |
| TX and RX Line Rate | 3.125, 6.25 or 10.3125 |
| Reference Clock Source | Q1 REFCLK1 |
| Reference Clock Frequency | **100 MHz** (125 MHz for 10.3125) |
| PLL Selection | QPLL0 (QPLL1 for 10.3125) |
| Loopback Mode | OFF |
| Internal Data Width | 20 |
| TX and RX External Data Ratio | 1:4 (an 80-bit word) |
| 8B/10B Encoding, Decoding, Word Alignment | all off |
| Channel Bonding, Clock Correction | off, None |

Five synthesis warnings are expected, all on `Customized_PHY_Top`: that it
is swept, and that four of its quad 0 inputs (`Q0_FABRIC_CMU*_O`) are
undriven. That module is configuration only, and the SerDes quad
(`GTR12_QUAD` in `serdes.v`) carries the lanes.

<a id="7-results"></a>
## 7. Hardware validation

**Xilinx GTX and Gowin SerDes interoperate cleanly.** `ku5p.py zynq-m138`
joins the RK-ZYNQ7100's SFP+ cages to this board's with passive SFP DAC
cables, 3 m on one pair and 1 m on the other. Both directions of both pairs
run at once, with default settings at both ends and this board's receivers
started with a PMA reset:

| Rate | Time | Bits per direction | Errors, all four directions | BER |
|---|---|---|---|---|
| 3.125 Gb/s | 15 min | 2.84 x 10^12 | 0 | < 1.1 x 10^-12 |
| 6.25 Gb/s | 15 min | 5.75 x 10^12 | 0 | < 5.2 x 10^-13 |

(95 % confidence bounds.)

**Through the XCKU5P's QSFP cage and a QSFP+ to 4x SFP+ active optical
cable**, `ku5p.py qsfp-peer --m138` finds every lane error-free both ways at
3.125 and 6.25 Gb/s (lanes 0 to 3, two at a time). Passive copper between
the XCKU5P and this board is not reliable: the XCKU5P has no AC-coupling
capacitors on its QSFP lines (hh-xcku5p-dev's user guide, section 11).

## 8. Verification

`sim/gate.sh` runs two self-checking iverilog benches; each passes only by
printing `<bench>: PASS` and exiting 0, and fails with `$fatal` otherwise.

- `tb_m138_prbs_lane` drives one lane through a serial line model: each TX
  word goes onto the line bit 0 first, and the RX side takes 80-bit words
  from it on its own, slightly faster clock, at an arbitrary bit offset,
  with `tx_afull` random and `rx_valid` low while too few bits have arrived.
  The bench checks the line with its own serial code, not the DUT's
  functions: every bit must equal b[n-31] ^ b[n-28]. It then checks lock on
  a clean loop, three error bits for one injected TX bit (including a request
  held through TX back-pressure) and for one flipped line bit, lock loss
  under TX inversion and relock with RX inversion, an
  MSB-first serializer undone by TX_REV and an MSB-first deserializer by
  RX_REV, no lock on an all-zero or an all-one line, and relock and clear.
- `tb_m138_peer` runs the whole design, its register bridge and frequency
  counters included, against `serdes_top_stub.sv`, which loops each lane's
  TX words back as RX words at its own bit offset (13 and 51 bits) on
  slightly different TX and RX clocks. Every register access is real serial
  bits in the bridge protocol, at 2 Mbaud for simulation speed. It checks the
  ID and RATE registers, status, lock and the LEDs, counter clear, error
  injection on one lane with the other unmoved, a line error, the lane
  configuration, the PMA reset, and the frequency counters (on a 50,000-cycle
  gate, so they read in kHz).

`sim/lint.sh` runs Verible lint over the RTL and the format check over the
RTL and the benches. `sim/vl/cov.ps1` measures line, branch and toggle
coverage of the same benches under Verilator; `doc/coverage.md` records the
result and explains the points that are not covered.
