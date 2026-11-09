// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//-----------------------------------------------------------------------------
// tb_m138_prbs_lane -- m138_prbs_lane against a serial line model.
//
// The model serializes each TX word bit 0 first into a bit queue (the line),
// and the RX side takes 80 bits a word from it on its own, slightly faster
// clock, with rx_valid low when too few bits have arrived. A few junk bits
// ahead of the stream put the RX words at an arbitrary bit offset, as a real
// receiver without word alignment sees them. tx_afull is driven at random.
//
// The line itself is checked by the bench's own serial code, not the DUT's
// functions: in time order every bit must equal b[n-31] ^ b[n-28], the
// XCKU5P's and the Zynq's PRBS-31.
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_m138_prbs_lane;
  localparam int W = 80;

  logic clk = 0, tx_clk = 0, rx_clk = 0, rst_n = 0;
  always #10 clk = ~clk;  // 50 MHz
  always #4 tx_clk = ~tx_clk;  // 125 MHz
  always #3.96  rx_clk = ~rx_clk;  // 1 % fast: rx_valid has gaps

  logic [4:0] cfg = '0;
  logic clr_tgl = 0, inj_tgl = 0, locked;
  logic [31:0] err_bits, err_words, lost_lock;
  logic [63:0] lock_words;
  logic tx_afull = 0, tx_wren, rx_valid = 0;
  logic [W-1:0] tx_data, rx_data = '0;

  m138_prbs_lane #(.W(W)) dut (.*);

  int errors = 0;
  task automatic fail(input string msg);
    $display("tb_m138_prbs_lane: FAIL: %s", msg);
    errors++;
  endtask

  // ---- line model -------------------------------------------------------------
  bit line                                                             [$];
  bit stall_tx = 0;  // deterministic back-pressure around an injection
  bit flip_next = 0;  // flip one line bit (a channel error)
  bit check_line = 1;  // run the serial recurrence check on TX bits
  bit ser_msb = 0, des_msb = 0;  // a serializer/deserializer that runs MSB first
  bit hist[$];
  int line_bad = 0, line_checked = 0;

  initial repeat (37) line.push_back($urandom_range(0, 1));  // bit offset

  always @(posedge tx_clk) begin
    tx_afull <= stall_tx || ($urandom_range(0, 15) == 0);
    if (tx_wren) begin
      for (int i = 0; i < W; i++) begin
        bit b;
        b = tx_data[ser_msb?W-1-i : i];
        if (check_line) begin
          if (hist.size() == 31) begin
            if (b !== (hist[0] ^ hist[3])) line_bad++;
            line_checked++;
            void'(hist.pop_front());
          end
          hist.push_back(b);
        end
        if (flip_next) begin
          b         = !b;
          flip_next = 0;
        end
        line.push_back(b);
      end
    end
  end

  always @(posedge rx_clk) begin
    if (line.size() >= W) begin
      for (int i = 0; i < W; i++) rx_data[des_msb?W-1-i : i] <= line.pop_front();
      rx_valid <= 1;
    end else rx_valid <= 0;
  end

  task automatic settle(input int n = 400);
    repeat (n) @(posedge clk);
  endtask
  task automatic clear();
    clr_tgl = !clr_tgl;
    settle(100);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;

    // 1: a clean loop locks and counts no errors
    settle(600);
    if (!locked) fail("no lock on a clean loop");
    clear();
    settle(400);
    if (err_bits != 0 || err_words != 0) fail($sformatf("clean loop: %0d error bits", err_bits));
    if (lock_words < 200) fail($sformatf("clean loop: only %0d locked words", lock_words));
    if (lost_lock != 0) fail("clean loop lost lock");
    if (line_checked < 10000 || line_bad != 0)
      fail($sformatf("line: %0d of %0d bits break b[n] = b[n-31] ^ b[n-28]", line_bad, line_checked
           ));

    // 2: one injected TX bit is three error bits
    clear();
    inj_tgl = !inj_tgl;
    settle(400);
    if (err_bits != 3) fail($sformatf("injection: %0d error bits, want 3", err_bits));
    if (err_words < 1 || err_words > 2) fail($sformatf("injection: %0d error words", err_words));

    // An injection that crosses while the TX FIFO is full belongs to the
    // next transmitted word; it must survive an arbitrarily long stall.
    clear();
    @(negedge tx_clk);
    stall_tx = 1;
    repeat (8) @(negedge tx_clk);
    inj_tgl = !inj_tgl;
    repeat (16) @(negedge tx_clk);
    stall_tx = 0;
    settle(400);
    if (err_bits !== 32'd3) fail($sformatf("stalled injection: %0d error bits, want 3", err_bits));
    settle(400);
    if (err_bits !== 32'd3) fail("stalled injection count changed after the first word");

    // 3: so is one flipped line bit
    clear();
    flip_next = 1;
    settle(400);
    if (err_bits != 3) fail($sformatf("line flip: %0d error bits, want 3", err_bits));
    if (!locked) fail("lost lock on one error");

    // 4: TX inverted alone breaks lock; RX inverted too restores it
    check_line = 0;
    clear();
    cfg = 5'b00010;
    settle(400);
    if (locked) fail("locked with TX inverted and RX not");
    if (lost_lock != 1) fail($sformatf("TX invert: %0d lock losses, want 1", lost_lock));
    cfg = 5'b00011;
    settle(600);
    if (!locked) fail("no lock with TX and RX inverted");

    // 5: an MSB-first serializer is undone by TX_REV, an MSB-first
    //    deserializer by RX_REV (each within its own words)
    cfg     = 5'b00000;
    ser_msb = 1;
    settle(600);
    if (locked) fail("locked through an MSB-first serializer without TX_REV");
    cfg = 5'b01000;
    settle(600);
    if (!locked) fail("no lock through an MSB-first serializer with TX_REV");
    ser_msb = 0;
    des_msb = 1;
    cfg     = 5'b00000;
    settle(600);
    if (locked) fail("locked through an MSB-first deserializer without RX_REV");
    cfg = 5'b00100;
    settle(600);
    if (!locked) fail("no lock through an MSB-first deserializer with RX_REV");
    clear();
    settle(300);
    if (err_bits != 0) fail($sformatf("reversed loop: %0d error bits", err_bits));
    des_msb = 0;
    cfg     = 5'b00000;
    settle(600);

    // Seed only counter state at a clock boundary, then drive real line
    // errors through the complete checker. This checks saturation and 64-bit
    // wrap without replacing arithmetic or waiting for billions of events.
    @(negedge rx_clk);
    dut.c_err  = 32'hFFFF_FFFE;
    dut.c_errw = 32'hFFFF_FFFE;
    dut.c_lost = 32'hFFFF_FFFE;
    dut.c_lock = 64'hFFFF_FFFF_FFFF_FFFE;

    // 6: an all-zero line never locks (it satisfies the recurrence)
    cfg        = 5'b10000;
    settle(600);
    if (locked) fail("locked on an all-zero line");
    if (err_bits !== 32'hFFFF_FFFF || err_words !== 32'hFFFF_FFFF || lost_lock !== 32'hFFFF_FFFF)
      fail("error counters did not saturate");
    if (lock_words == 0 || lock_words > 1000) fail("64-bit locked-word count did not wrap");
    cfg = 5'b00000;
    settle(600);
    if (!locked) fail("no relock before saturation hold test");
    cfg = 5'b10000;
    settle(600);
    if (locked || err_bits !== 32'hFFFF_FFFF || err_words !== 32'hFFFF_FFFF ||
        lost_lock !== 32'hFFFF_FFFF)
      fail("saturated error counters wrapped on later errors");
    cfg = 5'b10001;  // zeros inverted = ones: must not lock either
    settle(600);
    if (locked) fail("locked on an all-ones line with RX inverted");

    // 7: back to normal, and the counters clear
    cfg = 5'b00000;
    settle(600);
    if (!locked) fail("no relock after the zero line");
    clear();
    if (err_bits != 0 || lost_lock != 0) fail("clear left counts behind");

    if (errors == 0) begin
      $display("tb_m138_prbs_lane: PASS");
      $finish;
    end else $fatal(1, "tb_m138_prbs_lane: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "tb_m138_prbs_lane: FAIL: timeout");
  end
endmodule

`default_nettype wire
