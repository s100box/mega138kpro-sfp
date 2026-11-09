// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//-----------------------------------------------------------------------------
// tb_m138_peer -- the whole Tang Mega 138K Pro peer over its UART, against
// serdes_top_stub (each lane looped to itself at its own bit offset).
//
// Every register access is real serial bits in the ku5p_uart_bridge protocol
// at 2 Mbaud: the ID and RATE registers, the lane status and lock bits, a
// counter clear, error injection on one lane (the other must not move), a
// line error, the lane configuration, the PMA reset, and the frequency
// counters (a 50,000-cycle gate, so they read in kHz).
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_m138_peer;
  localparam int BAUD = 2_000_000;
  localparam real BIT_NS = 1.0e9 / BAUD;

  logic sys_clk = 0, key_n = 1, rxd = 1;
  wire txd, sfp0, sfp1;
  wire [3:0] led_n;
  always #10 sys_clk = ~sys_clk;

  m138_peer #(
      .RATE_KBPS (3_125_000),
      .BAUD      (BAUD),
      .RST_CYCLES(500),
      .FREQ_GATE (50_000)
  ) dut (
      .sys_clk,
      .key_n,
      .uart_rxd        (rxd),
      .uart_txd        (txd),
      .led_n,
      .sfp_tx_disable_0(sfp0),
      .sfp_tx_disable_1(sfp1)
  );

  int errors = 0;
  task automatic fail(input string msg);
    $display("tb_m138_peer: FAIL: %s", msg);
    errors++;
  endtask

  // ---- UART host --------------------------------------------------------------
  task automatic put(input logic [7:0] b);
    rxd = 0;
    #(BIT_NS);
    for (int i = 0; i < 8; i++) begin
      rxd = b[i];
      #(BIT_NS);
    end
    rxd = 1;
    #(BIT_NS);
  endtask

  // Poll for the start bit in 1/16-bit steps, give up after 400 bit times.
  task automatic get(output logic [7:0] b);
    int t;
    t = 0;
    while (txd !== 1'b0 && t < 400 * 16) begin
      #(BIT_NS / 16);
      t++;
    end
    if (txd !== 1'b0) begin
      fail("no reply byte");
      b = 8'hxx;
      return;
    end
    #(BIT_NS * 1.5 - BIT_NS / 32);
    for (int i = 0; i < 8; i++) begin
      b[i] = txd;
      #(BIT_NS);
    end
  endtask

  task automatic hdr(input logic [7:0] cmd, input logic [23:0] a);
    put(8'hA5);
    put(cmd);
    put(a[23:16]);
    put(a[15:8]);
    put(a[7:0]);
    put(8'h00);
  endtask

  task automatic wr(input logic [23:0] a, input logic [31:0] d);
    logic [7:0] s, st;
    hdr(8'h02, a);
    put(d[31:24]);
    put(d[23:16]);
    put(d[15:8]);
    put(d[7:0]);
    get(s);
    get(st);
    if (s !== 8'h5A || st !== 8'h00) fail($sformatf("write %06h: reply %02h %02h", a, s, st));
  endtask

  task automatic rd(input logic [23:0] a, output logic [31:0] d);
    logic [7:0] s, st, b0, b1, b2, b3;
    hdr(8'h01, a);
    get(s);
    get(st);
    get(b0);
    get(b1);
    get(b2);
    get(b3);
    if (s !== 8'h5A || st !== 8'h00) fail($sformatf("read %06h: reply %02h %02h", a, s, st));
    d = {b0, b1, b2, b3};
  endtask

  task automatic expect_rd(input logic [23:0] a, input logic [31:0] want, input string what);
    logic [31:0] d;
    rd(a, d);
    if (d !== want) fail($sformatf("%s: %08h, want %08h", what, d, want));
  endtask

  // lane n counters
  task automatic lane(input int n, output logic [31:0] eb, output logic [31:0] ew,
                      output logic [63:0] lw, output logic [31:0] ll);
    logic [31:0] lo, hi;
    rd(24'h40 + 32 * n, eb);
    rd(24'h44 + 32 * n, ew);
    rd(24'h48 + 32 * n, lo);
    rd(24'h4C + 32 * n, hi);
    rd(24'h50 + 32 * n, ll);
    lw = {hi, lo};
  endtask

  logic [31:0] d, eb0, ew0, ll0, eb1, ew1, ll1;
  logic [63:0] lw0, lw1;
  int pma_edges = 0, rx_reset_edges = 0, tx_reset_edges = 0;
  always @(negedge dut.pma_rstn) pma_edges++;
  always @(posedge dut.pcs_rx_rst) rx_reset_edges++;
  always @(posedge dut.pcs_tx_rst) tx_reset_edges++;

  task automatic check_locks(input logic lane0, input logic lane1, input string what);
    rd(24'h00C, d);
    if ({d[12], d[4]} !== {lane1, lane0}) fail($sformatf("%s: STATUS %08h", what, d));
  endtask

  initial begin
    wait (dut.rst_n);  // the power-on reset lasts 65,536 clocks (1.3 ms)
    #5_000;
    expect_rd(24'h000, 32'h4D31_3338, "ID");
    expect_rd(24'h004, 32'd3_125_000, "RATE");
    if (sfp0 !== 1'b0 || sfp1 !== 1'b0) fail("an SFP transmitter is disabled");

    // both lanes locked, all status bits up, LEDs on
    #20_000;
    rd(24'h00C, d);
    if (d[5:0] !== 6'b111111 || d[13:8] !== 6'b111111) fail($sformatf("STATUS %08h", d));
    if (led_n !== 4'b0000) fail($sformatf("LEDs %b with both lanes locked", led_n));

    // clear, then clean
    wr(24'h008, 32'h1);
    #20_000;
    lane(0, eb0, ew0, lw0, ll0);
    lane(1, eb1, ew1, lw1, ll1);
    if (eb0 != 0 || eb1 != 0 || ll0 != 0 || ll1 != 0) fail("errors on clean loops");
    if (lw0 < 200 || lw1 < 200) fail($sformatf("locked words %0d/%0d", lw0, lw1));

    // inject on lane 1 only
    wr(24'h008, 32'h1);
    wr(24'h014, 32'h2);
    #20_000;
    lane(0, eb0, ew0, lw0, ll0);
    lane(1, eb1, ew1, lw1, ll1);
    if (eb0 != 0) fail($sformatf("lane 0 moved (%0d) on a lane 1 injection", eb0));
    if (eb1 != 3) fail($sformatf("lane 1 injection: %0d error bits, want 3", eb1));

    // Exercise both toggle directions, then lane 0 independently.
    wr(24'h014, 32'h2);
    #20_000;
    lane(1, eb1, ew1, lw1, ll1);
    if (eb1 !== 32'd6) fail("second lane 1 injection was lost or repeated");
    wr(24'h014, 32'h1);
    #20_000;
    lane(0, eb0, ew0, lw0, ll0);
    if (eb0 !== 32'd3) fail("lane 0 injection did not reach its checker");

    // A stopped FIFO must preserve a pending injection until a real word is
    // accepted. The other lane continues and must remain error-free.
    wr(24'h008, 32'h1);
    @(negedge dut.u_serdes.txc);
    dut.u_serdes.stall = 2'b01;
    repeat (3) @(negedge dut.u_serdes.txc);
    begin
      int sent;
      sent = dut.u_serdes.tx_words[0];
      wr(24'h014, 32'h1);
      if (dut.u_serdes.tx_words[0] != sent) fail("TX continued through FIFO backpressure");
    end
    @(negedge dut.u_serdes.txc);
    dut.u_serdes.stall = '0;
    #20_000;
    lane(0, eb0, ew0, lw0, ll0);
    lane(1, eb1, ew1, lw1, ll1);
    if (eb0 !== 32'd3 || eb1 !== 32'd0) fail("stalled injection lost, repeated or crossed lanes");

    // a line error on lane 0
    wr(24'h008, 32'h1);
    dut.u_serdes.flip[0] = 1'b1;
    #20_000;
    lane(0, eb0, ew0, lw0, ll0);
    if (eb0 != 3) fail($sformatf("lane 0 line error: %0d error bits, want 3", eb0));

    // lane configuration reads back, and TX invert on lane 0 alone unlocks it
    wr(24'h010, 32'h0000_0002);
    expect_rd(24'h010, 32'h0000_0002, "LANE_CFG");
    #20_000;
    rd(24'h00C, d);
    if (d[4] !== 1'b0 || d[12] !== 1'b1) fail($sformatf("lane 0 TX invert: STATUS %08h", d));
    wr(24'h010, 32'h0000_0003);
    #20_000;
    rd(24'h00C, d);
    if (d[4] !== 1'b1) fail("lane 0 did not relock with RX invert too");
    wr(24'h010, 32'h0);

    // UART configuration must reach both lane CDC paths. Independent model
    // word-order controls make the expected PRBS result external to the DUT.
    for (int n = 0; n < 2; n++) begin
      dut.u_serdes.ser_msb[n] = 1'b1;
      #20_000;
      check_locks(n == 1, n == 0, "uncompensated serializer reversal");
      wr(24'h010, 32'h8 << (8 * n));
      #20_000;
      check_locks(1'b1, 1'b1, "TX reversal compensation");
      dut.u_serdes.ser_msb[n] = 1'b0;
      dut.u_serdes.des_msb[n] = 1'b1;
      wr(24'h010, 32'h4 << (8 * n));
      #20_000;
      check_locks(1'b1, 1'b1, "RX reversal compensation");
      dut.u_serdes.des_msb[n] = 1'b0;
      wr(24'h010, 32'h10 << (8 * n));
      #20_000;
      check_locks(n == 1, n == 0, "TX_OFF lane selection");
      lane(n, eb0, ew0, lw0, ll0);
      if (ll0 == 0) fail("TX_OFF did not record lock loss");
      wr(24'h010, 32'h0);
      #20_000;
      check_locks(1'b1, 1'b1, "lane control recovery");
    end

    wr(24'h3FC, 32'hFFFF_FFFF);
    expect_rd(24'h3FC, 32'h0, "unmapped register");
    expect_rd(24'h010, 32'h0, "unmapped write preserved LANE_CFG");

    // PMA reset: the lanes come back
    wr(24'h008, 32'h2);
    rd(24'h008, d);  // the reset (500 cycles) ends before any UART read does
    #20_000;
    rd(24'h00C, d);
    if (d[5:0] !== 6'b111111) fail($sformatf("after PMA reset: STATUS %08h", d));
    wr(24'h008, 32'h4);
    wr(24'h008, 32'h8);
    if (pma_edges != 1 || rx_reset_edges != 1 || tx_reset_edges != 1)
      fail("reset command selected the wrong SerDes reset pins");
    expect_rd(24'h008, 32'h0, "reset completion");

    // A second board reset restores register defaults and UART operation.
    wr(24'h010, 32'h0303);
    key_n = 1'b0;
    wait (!dut.rst_n);
    #200;
    key_n = 1'b1;
    wait (dut.rst_n);
    #20_000;
    expect_rd(24'h000, 32'h4D31_3338, "ID after key reset");
    expect_rd(24'h010, 32'h0, "LANE_CFG after key reset");
    check_locks(1'b1, 1'b1, "key reset recovery");

    // frequency counters: kHz with a 50,000-cycle gate
    #3_000_000;
    rd(24'h200, d);
    if (d < 9_900 || d > 10_100) fail($sformatf("refclk %0d kHz, want 10000", d));
    rd(24'h204, d);
    if (d < 19_900 || d > 20_100) fail($sformatf("lane 0 TX clock %0d kHz, want 20000", d));
    rd(24'h208, d);
    if (d < 20_100 || d > 20_300) fail($sformatf("lane 0 RX clock %0d kHz, want 20200", d));

    if (errors == 0) begin
      $display("tb_m138_peer: PASS");
      $finish;
    end else $fatal(1, "tb_m138_peer: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "tb_m138_peer: FAIL: timeout");
  end
endmodule

`default_nettype wire
