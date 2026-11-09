// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//-----------------------------------------------------------------------------
// m138_prbs_lane -- PRBS-31 over one Gowin SerDes lane's 80-bit raw fabric
// interface: a generator on the TX side, a self-synchronizing checker with
// counters on the RX side, both in the lane's own clocks.
//
// The pattern is x^31 + x^28 + 1, the one the XCKU5P's GTYs and the
// RK-ZYNQ7100's GTXs generate and check: in time order, bit n of the line is
// b[n-31] ^ b[n-28]. Word bit 0 is the first on the line (IPUG1024, "low
// first"); cfg's TX_REV/RX_REV bits reverse the word in case a SerDes sends
// bit 79 first, and TX_INV/RX_INV invert it (a checker that sees the other
// polarity finds no PRBS at all, since the inverse does not follow the
// recurrence).
//
// The checker predicts each bit from the 31 before it, so it needs no seed
// and no word alignment, and one flipped line bit shows as three error bits
// (the bit itself, then again 28 and 31 bits later). err_bits therefore
// counts about three per line error.
//
// Lock: 32 error-free words in a row lock; in lock, 4 words in a row with 8
// or more error bits unlock (and count one lost lock). Error bits and words
// are counted only while locked, so a lane that has never locked reads 0
// errors and 0 locked words, never a clean result. A word of all zeros (after
// RX_INV) is a bad word with W error bits: an idle or stuck line follows the
// recurrence trivially, and PRBS-31 never has more than 30 zeros in a row.
//
// Counters live in rx_clk. clk takes a snapshot with a toggle handshake: it
// flips snap_req, the lane copies its counters into hold registers and flips
// snap_ack, and clk copies the hold registers after it sees the ack. The hold
// registers stay still from then until the next request.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module m138_prbs_lane #(
    parameter int unsigned W = 80  // raw SerDes word width; this design uses 80
) (
    // clk domain (register side)
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic [ 4:0] cfg,         // [0] rx_inv [1] tx_inv [2] rx_rev [3] tx_rev [4] tx_off
    input  wire logic        clr_tgl,     // each change clears the counters
    input  wire logic        inj_tgl,     // each change flips one TX bit
    output logic             locked,      // synchronized to clk
    output logic      [31:0] err_bits,
    output logic      [31:0] err_words,
    output logic      [63:0] lock_words,
    output logic      [31:0] lost_lock,

    // TX (tx_clk)
    input  wire logic         tx_clk,
    input  wire logic         tx_afull,
    output logic              tx_wren,
    output logic      [W-1:0] tx_data,

    // RX (rx_clk)
    input wire logic         rx_clk,
    input wire logic         rx_valid,
    input wire logic [W-1:0] rx_data
);

  // ---- helpers --------------------------------------------------------------
  function automatic logic [W-1:0] rev(input logic [W-1:0] v);
    for (int i = 0; i < W; i++) rev[i] = v[W-1-i];
  endfunction

  // Next W line bits after state s (s[30] the most recent bit), and the new
  // state: x[k] = s[k] for k < 31, x[31+i] = x[i] ^ x[i+3].
  function automatic logic [W+30:0] prbs_step(input logic [30:0] s);
    logic [W+30:0] x;
    x[30:0] = s;
    for (int i = 0; i < W; i++) x[31+i] = x[i] ^ x[i+3];
    return x;
  endfunction

  logic snap_req;  // clk domain; declared here because the RX side reads it

  // ---- TX -------------------------------------------------------------------
  // Configuration is a software-held level, not an atomic CDC transaction.
  // Change it only between measurements and allow the lane clocks to settle.
  (* ASYNC_REG = "TRUE" *) logic [4:0] tcfg_m = '0, tcfg_s = '0;
  (* ASYNC_REG = "TRUE" *) logic tinj_m = 1'b0, tinj_s = 1'b0;
  logic          tinj_d = 1'b0;
  logic [  30:0] tx_state = 31'h7FFF_FFFF;
  logic [W+30:0] tx_x;

  assign tx_x = prbs_step(tx_state);

  always_ff @(posedge tx_clk) begin
    tcfg_m  <= cfg;
    tcfg_s  <= tcfg_m;
    tinj_m  <= inj_tgl;
    tinj_s  <= tinj_m;
    tx_wren <= !tx_afull;
    if (!tx_afull) begin : g_word
      logic [W-1:0] w;
      // Acknowledge the toggle only when its word enters the TX pipeline.
      // Back-pressure must not consume an injection without transmitting it.
      tinj_d   <= tinj_s;
      tx_state <= tx_x[W+30:W];
      w = tx_x[W+30:31];
      if (tcfg_s[3]) w = rev(w);
      if (tcfg_s[1]) w = ~w;
      if (tcfg_s[4]) w = '0;
      w[0] = w[0] ^ (tinj_s ^ tinj_d);
      tx_data <= w;
    end
  end

  // ---- RX -------------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [4:0] rcfg_m = '0, rcfg_s = '0;
  (* ASYNC_REG = "TRUE" *) logic rclr_m = 1'b0, rclr_s = 1'b0, rsr_m = 1'b0, rsr_s = 1'b0;
  logic rclr_d = 1'b0, rsr_d = 1'b0, ack = 1'b0;
  logic [30:0] hist = '0;
  logic v1 = 1'b0, v2 = 1'b0, v3 = 1'b0, z1 = 1'b0, z2 = 1'b0;
  logic [W-1:0] e1 = '0;
  logic [  3:0] part           [10];  // popcount of each 8-bit group of e1
  logic [  6:0] nerr = '0;
  logic [  5:0] good_run = '0;
  logic [  2:0] bad_run = '0;
  logic         rlocked = 1'b0;
  logic [31:0] c_err = '0, c_errw = '0, c_lost = '0;
  logic [63:0] c_lock = '0;
  logic [31:0] h_err = '0, h_errw = '0, h_lost = '0;
  logic [  63:0] h_lock = '0;

  // stage 0 registers the word straight off the SerDes, before any logic
  logic          v0 = 1'b0;
  logic [ W-1:0] rd0 = '0;
  wire  [ W-1:0] rw = (rcfg_s[2] ? rev(rd0) : rd0) ^ {W{rcfg_s[0]}};
  wire  [W+30:0] rx_x = {rw, hist};

  always_ff @(posedge rx_clk) begin
    rcfg_m <= cfg;
    rcfg_s <= rcfg_m;
    rclr_m <= clr_tgl;
    rclr_s <= rclr_m;
    rclr_d <= rclr_s;
    rsr_m  <= snap_req;
    rsr_s  <= rsr_m;
    rsr_d  <= rsr_s;

    v0     <= rx_valid;
    if (rx_valid) rd0 <= rx_data;
    // stage 1: error vector
    v1 <= v0;
    if (v0) begin
      z1   <= rw == '0;
      hist <= rx_x[W+30:W];
      e1   <= rx_x[W+30:31] ^ rx_x[W-1:0] ^ rx_x[W+2:3];  // bit i: x[31+i] ^ x[i] ^ x[i+3]
    end
    // stage 2: partial popcounts
    v2 <= v1;
    z2 <= z1;
    for (int g = 0; g < W / 8; g++) begin : g_pop
      logic [3:0] c;
      c = '0;
      for (int b = 0; b < 8; b++) c = c + e1[8*g+b];
      part[g] <= c;
    end
    // stage 3: the word's error bits
    v3 <= v2;
    begin : g_sum
      logic [6:0] n;
      n = '0;
      for (int g = 0; g < W / 8; g++) n = n + part[g];
      nerr <= z2 ? 7'(W) : n;
    end
    // stage 4: lock and counters
    if (rclr_s ^ rclr_d) begin
      c_err  <= '0;
      c_errw <= '0;
      c_lock <= '0;
      c_lost <= '0;
    end else if (v3) begin : g_count
      logic [ 6:0] n;
      logic [32:0] sum;
      n   = nerr;
      sum = {1'b0, c_err} + n;
      if (!rlocked) begin
        good_run <= (n == 0) ? good_run + 1'b1 : '0;
        bad_run  <= '0;
        if (n == 0 && good_run == 6'd31) rlocked <= 1'b1;
      end else begin
        c_lock <= c_lock + 1'b1;  // 64-bit elapsed-word count wraps; error counters saturate
        if (n != 0) begin
          c_err <= sum[32] ? 32'hFFFF_FFFF : sum[31:0];
          if (c_errw != 32'hFFFF_FFFF) c_errw <= c_errw + 1'b1;
        end
        bad_run <= (n >= 8) ? bad_run + 1'b1 : '0;
        if (n >= 8 && bad_run == 3'd3) begin
          rlocked  <= 1'b0;
          good_run <= '0;
          if (c_lost != 32'hFFFF_FFFF) c_lost <= c_lost + 1'b1;
        end
      end
    end
    if (rsr_s ^ rsr_d) begin
      h_err  <= c_err;
      h_errw <= c_errw;
      h_lock <= c_lock;
      h_lost <= c_lost;
      ack    <= ~ack;
    end
  end

  // ---- clk side -------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic ack_m, ack_s, lk_m, lk_s;
  logic ack_d, waiting;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      snap_req   <= 1'b0;
      waiting    <= 1'b0;
      ack_m      <= 1'b0;
      ack_s      <= 1'b0;
      ack_d      <= 1'b0;
      lk_m       <= 1'b0;
      lk_s       <= 1'b0;
      err_bits   <= '0;
      err_words  <= '0;
      lock_words <= '0;
      lost_lock  <= '0;
    end else begin
      ack_m <= ack;
      ack_s <= ack_m;
      ack_d <= ack_s;
      lk_m  <= rlocked;
      lk_s  <= lk_m;
      if (ack_s ^ ack_d) begin
        err_bits   <= h_err;
        err_words  <= h_errw;
        lock_words <= h_lock;
        lost_lock  <= h_lost;
        waiting    <= 1'b0;
      end else if (!waiting) begin
        snap_req <= ~snap_req;
        waiting  <= 1'b1;
      end
    end
  end
  assign locked = lk_s;

endmodule

`default_nettype wire
