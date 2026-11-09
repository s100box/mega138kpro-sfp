// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//-----------------------------------------------------------------------------
// serdes_top_stub -- a behavioral stand-in for the generated SerDes_Top
// (Gowin Customized PHY, quad 1 lanes 0 and 1, raw 80-bit words), for the
// m138_peer bench. Each lane's TX words go out bit 0 first onto a line buffer
// and come back as RX words at a bit offset (lane 0: 13, lane 1: 51), so the
// two lanes are separate loops. TX and RX PCS clocks run at 20 MHz and
// 20.2 MHz, the reference clock at 10 MHz (slow, for simulation speed); the
// status outputs are high while pma_rstn is.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module SerDes_Top (
    output logic             Customized_PHY_Top_q1_ln0_rx_pcs_clkout_o,
    output logic      [87:0] Customized_PHY_Top_q1_ln0_rx_data_o,
    output logic      [ 4:0] Customized_PHY_Top_q1_ln0_rx_fifo_rdusewd_o,
    output logic             Customized_PHY_Top_q1_ln0_rx_fifo_aempty_o,
    output logic             Customized_PHY_Top_q1_ln0_rx_fifo_empty_o,
    output logic             Customized_PHY_Top_q1_ln0_rx_valid_o,
    output logic             Customized_PHY_Top_q1_ln0_tx_pcs_clkout_o,
    output logic      [ 4:0] Customized_PHY_Top_q1_ln0_tx_fifo_wrusewd_o,
    output logic             Customized_PHY_Top_q1_ln0_tx_fifo_afull_o,
    output logic             Customized_PHY_Top_q1_ln0_tx_fifo_full_o,
    output logic             Customized_PHY_Top_q1_ln0_refclk_o,
    output logic             Customized_PHY_Top_q1_ln0_signal_detect_o,
    output logic             Customized_PHY_Top_q1_ln0_rx_cdr_lock_o,
    output logic             Customized_PHY_Top_q1_ln0_pll_lock_o,
    output logic             Customized_PHY_Top_q1_ln0_ready_o,
    output logic             Customized_PHY_Top_q1_ln1_rx_pcs_clkout_o,
    output logic      [87:0] Customized_PHY_Top_q1_ln1_rx_data_o,
    output logic      [ 4:0] Customized_PHY_Top_q1_ln1_rx_fifo_rdusewd_o,
    output logic             Customized_PHY_Top_q1_ln1_rx_fifo_aempty_o,
    output logic             Customized_PHY_Top_q1_ln1_rx_fifo_empty_o,
    output logic             Customized_PHY_Top_q1_ln1_rx_valid_o,
    output logic             Customized_PHY_Top_q1_ln1_tx_pcs_clkout_o,
    output logic      [ 4:0] Customized_PHY_Top_q1_ln1_tx_fifo_wrusewd_o,
    output logic             Customized_PHY_Top_q1_ln1_tx_fifo_afull_o,
    output logic             Customized_PHY_Top_q1_ln1_tx_fifo_full_o,
    output logic             Customized_PHY_Top_q1_ln1_refclk_o,
    output logic             Customized_PHY_Top_q1_ln1_signal_detect_o,
    output logic             Customized_PHY_Top_q1_ln1_rx_cdr_lock_o,
    output logic             Customized_PHY_Top_q1_ln1_pll_lock_o,
    output logic             Customized_PHY_Top_q1_ln1_ready_o,
    input  wire logic        Customized_PHY_Top_q1_ln0_rx_clk_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_rx_fifo_rden_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_tx_clk_i,
    input  wire logic [79:0] Customized_PHY_Top_q1_ln0_tx_data_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_tx_fifo_wren_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_pma_rstn_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_pcs_rx_rst_i,
    input  wire logic        Customized_PHY_Top_q1_ln0_pcs_tx_rst_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_rx_clk_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_rx_fifo_rden_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_tx_clk_i,
    input  wire logic [79:0] Customized_PHY_Top_q1_ln1_tx_data_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_tx_fifo_wren_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_pma_rstn_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_pcs_rx_rst_i,
    input  wire logic        Customized_PHY_Top_q1_ln1_pcs_tx_rst_i
);
  logic txc = 0, rxc = 0, refc = 0;
  always #25 txc = ~txc;
  always #24.752 rxc = ~rxc;
  always #50 refc = ~refc;

  // the bench flips one line bit on a lane by setting this (lane mask)
  logic [1:0] flip = '0;
  // Bench controls model fabric word order and FIFO backpressure, not analog
  // SerDes behavior. The registered producer may complete one in-flight word.
  logic [1:0] stall = '0, ser_msb = '0, des_msb = '0;
  int tx_words[2] = '{0, 0};

  function automatic logic [79:0] reverse_word(input logic [79:0] value);
    for (int i = 0; i < 80; i++) reverse_word[i] = value[79-i];
  endfunction

  // Each lane's line: the bits sent and not yet received, oldest at bit 0, n0
  // and n1 of them. Words move 80 bits at a time (a bit queue per lane costs
  // the bench minutes). The initial fill sets each lane's bit offset.
  logic [255:0] q0 = {243'd0, 13'h1FFF}, q1 = '0;
  int n0 = 13, n1 = 51;

  wire up = Customized_PHY_Top_q1_ln0_pma_rstn_i;

  assign Customized_PHY_Top_q1_ln0_tx_pcs_clkout_o = txc;
  assign Customized_PHY_Top_q1_ln1_tx_pcs_clkout_o = txc;
  assign Customized_PHY_Top_q1_ln0_rx_pcs_clkout_o = rxc;
  assign Customized_PHY_Top_q1_ln1_rx_pcs_clkout_o = rxc;
  assign Customized_PHY_Top_q1_ln0_refclk_o = refc;
  assign Customized_PHY_Top_q1_ln1_refclk_o = refc;
  assign Customized_PHY_Top_q1_ln0_tx_fifo_afull_o = stall[0];
  assign Customized_PHY_Top_q1_ln1_tx_fifo_afull_o = stall[1];
  assign Customized_PHY_Top_q1_ln0_tx_fifo_full_o = 1'b0;
  assign Customized_PHY_Top_q1_ln1_tx_fifo_full_o = 1'b0;
  assign Customized_PHY_Top_q1_ln0_tx_fifo_wrusewd_o = '0;
  assign Customized_PHY_Top_q1_ln1_tx_fifo_wrusewd_o = '0;
  assign Customized_PHY_Top_q1_ln0_rx_fifo_rdusewd_o = '0;
  assign Customized_PHY_Top_q1_ln1_rx_fifo_rdusewd_o = '0;
  assign Customized_PHY_Top_q1_ln0_rx_fifo_empty_o = Customized_PHY_Top_q1_ln0_rx_fifo_aempty_o;
  assign Customized_PHY_Top_q1_ln1_rx_fifo_empty_o = Customized_PHY_Top_q1_ln1_rx_fifo_aempty_o;
  assign {Customized_PHY_Top_q1_ln0_signal_detect_o, Customized_PHY_Top_q1_ln0_rx_cdr_lock_o,
          Customized_PHY_Top_q1_ln0_pll_lock_o, Customized_PHY_Top_q1_ln0_ready_o} = {4{up}};
  assign {Customized_PHY_Top_q1_ln1_signal_detect_o, Customized_PHY_Top_q1_ln1_rx_cdr_lock_o,
          Customized_PHY_Top_q1_ln1_pll_lock_o, Customized_PHY_Top_q1_ln1_ready_o} = {4{up}};

  always @(posedge Customized_PHY_Top_q1_ln0_tx_clk_i)
    if (Customized_PHY_Top_q1_ln0_tx_fifo_wren_i) begin
      q0 = q0 | ({176'd0, (ser_msb[0] ? reverse_word(Customized_PHY_Top_q1_ln0_tx_data_i) :
                           Customized_PHY_Top_q1_ln0_tx_data_i) ^ 80'(flip[0])} << n0);
      tx_words[0]++;
      n0 = n0 + 80;
      if (n0 > 256) $fatal(1, "serdes_top_stub: lane 0 line buffer overflow");
      flip[0] = 1'b0;
    end
  always @(posedge Customized_PHY_Top_q1_ln1_tx_clk_i)
    if (Customized_PHY_Top_q1_ln1_tx_fifo_wren_i) begin
      q1 = q1 | ({176'd0, (ser_msb[1] ? reverse_word(Customized_PHY_Top_q1_ln1_tx_data_i) :
                           Customized_PHY_Top_q1_ln1_tx_data_i) ^ 80'(flip[1])} << n1);
      tx_words[1]++;
      n1 = n1 + 80;
      if (n1 > 256) $fatal(1, "serdes_top_stub: lane 1 line buffer overflow");
      flip[1] = 1'b0;
    end

  // RX: the FIFO has a word when 80 bits are queued; a read presents it with
  // rx_valid on the next cycle.
  always @(posedge Customized_PHY_Top_q1_ln0_rx_clk_i) begin
    Customized_PHY_Top_q1_ln0_rx_fifo_aempty_o <= n0 < 80;
    Customized_PHY_Top_q1_ln0_rx_valid_o       <= 1'b0;
    if (Customized_PHY_Top_q1_ln0_rx_fifo_rden_i && n0 >= 80) begin
      Customized_PHY_Top_q1_ln0_rx_data_o[79:0] <= des_msb[0] ? reverse_word(q0[79:0]) : q0[79:0];
      q0 = q0 >> 80;
      n0 = n0 - 80;
      Customized_PHY_Top_q1_ln0_rx_data_o[87:80] <= 8'hA5;
      Customized_PHY_Top_q1_ln0_rx_valid_o       <= 1'b1;
    end
  end
  always @(posedge Customized_PHY_Top_q1_ln1_rx_clk_i) begin
    Customized_PHY_Top_q1_ln1_rx_fifo_aempty_o <= n1 < 80;
    Customized_PHY_Top_q1_ln1_rx_valid_o       <= 1'b0;
    if (Customized_PHY_Top_q1_ln1_rx_fifo_rden_i && n1 >= 80) begin
      Customized_PHY_Top_q1_ln1_rx_data_o[79:0] <= des_msb[1] ? reverse_word(q1[79:0]) : q1[79:0];
      q1 = q1 >> 80;
      n1 = n1 - 80;
      Customized_PHY_Top_q1_ln1_rx_data_o[87:80] <= 8'h5A;
      Customized_PHY_Top_q1_ln1_rx_valid_o       <= 1'b1;
    end
  end
endmodule

`default_nettype wire
