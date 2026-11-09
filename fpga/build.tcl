# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# m138_peer, non-project gw_sh build. build.sh runs this in the build
# directory (through retrosim-build/gowin.sh's gowin_synth) and exports:
#   M138_DIR     fpga/                     M138_SERDES  the SerDes IP directory
#   M138_GEN     generated m138_rate.svh   M138_SDC     generated timing
#   M138_BASE    output base name          GOWIN_DEVICE, GOWIN_PART
set here  $env(M138_DIR)
set repo  [file normalize $here/..]
set ws    [file normalize $repo/..]
set serdes $env(M138_SERDES)
set_device -name $env(GOWIN_DEVICE) $env(GOWIN_PART)
foreach f [list \
    $ws/hh-uart/rtl/uart_baud_dds.sv $ws/hh-uart/rtl/uart_rx_core.sv $ws/hh-uart/rtl/uart_tx_core.sv \
    $ws/hh-xcku5p-dev/pl/board/rtl/ku5p_uart_bridge.sv \
    $ws/hh-xcku5p-dev/pl/board/rtl/ku5p_freq_chan.sv \
    $ws/hh-xcku5p-dev/pl/board/rtl/ku5p_freq_bank.sv \
    $repo/rtl/m138_prbs_lane.sv $repo/rtl/m138_peer.sv \
    $serdes/customized_phy/customized_phy.v $serdes/serdes.v] {
  if {![file exists $f]} { error "missing source $f" }
  add_file -type verilog $f
}
add_file -type cst $here/m138_peer.cst
add_file -type sdc $env(M138_SDC)
set_csr $serdes/serdes.csr
set_option -top_module m138_peer
set_option -include_path $env(M138_GEN)
set_option -verilog_std sysv2017
set_option -output_base_name $env(M138_BASE)
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
run all
