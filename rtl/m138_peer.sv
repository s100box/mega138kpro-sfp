// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//-----------------------------------------------------------------------------
// m138_peer -- the Tang Mega 138K Pro Dock as a PRBS-31 far end for the
// XCKU5P's QSFP lanes: both SFP+ cages (SerDes quad 1, lanes 0 and 1) run
// m138_prbs_lane, and the PC reaches the registers through the same UART
// bridge as hh-xcku5p-dev's ku5p_board (its ku5p_uart_bridge, 115200 8N1 on
// the dock's debugger channel B).
//
// The SerDes itself is Gowin's Customized PHY in raw mode (no 8B10B, no word
// alignment), 20-bit internal width at 1:4, so 80 bits a word, generated for
// one IP target rate per build (doc/mega138kpro-sfp-design.md). RATE_KBPS
// reports that target; the r10312 IP runs at 8.25 Gb/s with the dock's 100 MHz
// reference instead of its configured 125 MHz. It is not a measured rate.
//
// Registers (byte addresses, 32-bit, acked the cycle after the request):
//   0x000 ID        "M138" (0x4D313338)
//   0x004 RATE      IP target rate, kb/s (see reference-clock limitation above)
//   0x008 CTRL      W: [0] clear every lane's counters  [1] PMA reset
//                   [2] PCS RX reset  [3] PCS TX reset (resets last RST_CYCLES)
//                   R: [1]..[3] the resets in progress
//   0x00C STATUS    lane n at [8n+]: [0] PLL lock [1] CDR lock [2] signal
//                   detect [3] ready [4] PRBS locked [5] RX valid
//   0x010 LANE_CFG  lane n at [8n+4:8n]: [0] RX invert [1] TX invert
//                   [2] RX bit reverse [3] TX bit reverse [4] TX all zeros
//   0x014 INJECT    W: bit n flips one TX bit on lane n
//   0x040 + 0x20n   lane n: +0 error bits (about 3 per line error), +4 words
//                   with errors, +8/+C words checked while locked (lo/hi),
//                   +10 lock losses
//   0x200           ku5p_freq_bank (hh-xcku5p-dev), 1 s gate: ch0 reference clock, ch1/ch2
//                   lane 0 TX/RX PCS clock, ch3/ch4 lane 1 TX/RX PCS clock
//-----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

// M138_RATE_KBPS: the build writes it (build.sh); the benches take sim's copy.
`include "m138_rate.svh"

module m138_peer #(
    parameter int unsigned RATE_KBPS  = `M138_RATE_KBPS,
    parameter int unsigned CLK_HZ     = 50_000_000,
    parameter int unsigned BAUD       = 115_200,
    parameter int unsigned RST_CYCLES = 50_000,           // 1 ms
    parameter int unsigned FREQ_GATE  = CLK_HZ            // counts in Hz
) (
    input  wire logic       sys_clk,           // 50 MHz
    input  wire logic       key_n,             // dock key S0: reset
    input  wire logic       uart_rxd,
    output logic            uart_txd,
    output logic      [3:0] led_n,
    output logic            sfp_tx_disable_0,
    output logic            sfp_tx_disable_1
);

  localparam int unsigned W = 80;
  localparam logic [31:0] DESIGN_ID = 32'h4D31_3338;

  wire clk = sys_clk;

  // ---- reset: key and power-on ---------------------------------------------
  logic [15:0] por = '0;
  (* ASYNC_REG = "TRUE" *) logic [1:0] key_s = 2'b11;
  logic rst_n = 1'b0;
  always_ff @(posedge clk) begin
    key_s <= {key_s[0], key_n};
    if (!key_s[1]) por <= '0;
    else if (!(&por)) por <= por + 1'b1;
    rst_n <= &por;
  end

  assign sfp_tx_disable_0 = 1'b0;
  assign sfp_tx_disable_1 = 1'b0;

  // ---- UART bridge ----------------------------------------------------------
  logic m_lock, m_req, m_we, m_ack;
  logic [23:0] m_addr;
  logic [31:0] m_wdata, m_rdata;
  ku5p_uart_bridge #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (BAUD)
  ) u_bridge (
      .clk,
      .rst_n,
      .rxd      (uart_rxd),
      .txd      (uart_txd),
      .id       (DESIGN_ID),
      .m_lock,
      .m_gnt    (m_lock),
      .m_req,
      .m_we,
      .m_addr,
      .m_wdata,
      .m_ack,
      .m_rdata,
      .m_timeout(1'b0)
  );

  // ---- SerDes -----------------------------------------------------------------
  logic [1:0] tx_clk, rx_clk, refclk, tx_afull, tx_wren, rx_valid, rx_aempty;
  logic [1:0] pll_lock, cdr_lock, sig_det, ready;
  logic [W-1:0] tx_data[2];
  logic [ 87:0] rx_data[2];
  logic pma_rstn, pcs_rx_rst, pcs_tx_rst;

  SerDes_Top u_serdes (
      .Customized_PHY_Top_q1_ln0_rx_pcs_clkout_o  (rx_clk[0]),
      .Customized_PHY_Top_q1_ln0_rx_data_o        (rx_data[0]),
      .Customized_PHY_Top_q1_ln0_rx_fifo_rdusewd_o(),
      .Customized_PHY_Top_q1_ln0_rx_fifo_aempty_o (rx_aempty[0]),
      .Customized_PHY_Top_q1_ln0_rx_fifo_empty_o  (),
      .Customized_PHY_Top_q1_ln0_rx_valid_o       (rx_valid[0]),
      .Customized_PHY_Top_q1_ln0_tx_pcs_clkout_o  (tx_clk[0]),
      .Customized_PHY_Top_q1_ln0_tx_fifo_wrusewd_o(),
      .Customized_PHY_Top_q1_ln0_tx_fifo_afull_o  (tx_afull[0]),
      .Customized_PHY_Top_q1_ln0_tx_fifo_full_o   (),
      .Customized_PHY_Top_q1_ln0_refclk_o         (refclk[0]),
      .Customized_PHY_Top_q1_ln0_signal_detect_o  (sig_det[0]),
      .Customized_PHY_Top_q1_ln0_rx_cdr_lock_o    (cdr_lock[0]),
      .Customized_PHY_Top_q1_ln0_pll_lock_o       (pll_lock[0]),
      .Customized_PHY_Top_q1_ln0_ready_o          (ready[0]),
      .Customized_PHY_Top_q1_ln1_rx_pcs_clkout_o  (rx_clk[1]),
      .Customized_PHY_Top_q1_ln1_rx_data_o        (rx_data[1]),
      .Customized_PHY_Top_q1_ln1_rx_fifo_rdusewd_o(),
      .Customized_PHY_Top_q1_ln1_rx_fifo_aempty_o (rx_aempty[1]),
      .Customized_PHY_Top_q1_ln1_rx_fifo_empty_o  (),
      .Customized_PHY_Top_q1_ln1_rx_valid_o       (rx_valid[1]),
      .Customized_PHY_Top_q1_ln1_tx_pcs_clkout_o  (tx_clk[1]),
      .Customized_PHY_Top_q1_ln1_tx_fifo_wrusewd_o(),
      .Customized_PHY_Top_q1_ln1_tx_fifo_afull_o  (tx_afull[1]),
      .Customized_PHY_Top_q1_ln1_tx_fifo_full_o   (),
      .Customized_PHY_Top_q1_ln1_refclk_o         (refclk[1]),
      .Customized_PHY_Top_q1_ln1_signal_detect_o  (sig_det[1]),
      .Customized_PHY_Top_q1_ln1_rx_cdr_lock_o    (cdr_lock[1]),
      .Customized_PHY_Top_q1_ln1_pll_lock_o       (pll_lock[1]),
      .Customized_PHY_Top_q1_ln1_ready_o          (ready[1]),
      .Customized_PHY_Top_q1_ln0_rx_clk_i         (rx_clk[0]),
      .Customized_PHY_Top_q1_ln0_rx_fifo_rden_i   (!rx_aempty[0]),
      .Customized_PHY_Top_q1_ln0_tx_clk_i         (tx_clk[0]),
      .Customized_PHY_Top_q1_ln0_tx_data_i        (tx_data[0]),
      .Customized_PHY_Top_q1_ln0_tx_fifo_wren_i   (tx_wren[0]),
      .Customized_PHY_Top_q1_ln0_pma_rstn_i       (pma_rstn),
      .Customized_PHY_Top_q1_ln0_pcs_rx_rst_i     (pcs_rx_rst),
      .Customized_PHY_Top_q1_ln0_pcs_tx_rst_i     (pcs_tx_rst),
      .Customized_PHY_Top_q1_ln1_rx_clk_i         (rx_clk[1]),
      .Customized_PHY_Top_q1_ln1_rx_fifo_rden_i   (!rx_aempty[1]),
      .Customized_PHY_Top_q1_ln1_tx_clk_i         (tx_clk[1]),
      .Customized_PHY_Top_q1_ln1_tx_data_i        (tx_data[1]),
      .Customized_PHY_Top_q1_ln1_tx_fifo_wren_i   (tx_wren[1]),
      .Customized_PHY_Top_q1_ln1_pma_rstn_i       (pma_rstn),
      .Customized_PHY_Top_q1_ln1_pcs_rx_rst_i     (pcs_rx_rst),
      .Customized_PHY_Top_q1_ln1_pcs_tx_rst_i     (pcs_tx_rst)
  );

  // ---- lanes -------------------------------------------------------------------
  logic [15:0] lane_cfg;
  logic        clr_tgl;
  logic [1:0] inj_tgl, locked;
  logic [31:0] err_bits[2], err_words[2], lost_lock[2];
  logic [63:0] lock_words[2];

  for (genvar n = 0; n < 2; n++) begin : g_lane
    m138_prbs_lane #(
        .W(W)
    ) u_lane (
        .clk,
        .rst_n,
        .cfg       (lane_cfg[8*n+:5]),
        .clr_tgl,
        .inj_tgl   (inj_tgl[n]),
        .locked    (locked[n]),
        .err_bits  (err_bits[n]),
        .err_words (err_words[n]),
        .lock_words(lock_words[n]),
        .lost_lock (lost_lock[n]),
        .tx_clk    (tx_clk[n]),
        .tx_afull  (tx_afull[n]),
        .tx_wren   (tx_wren[n]),
        .tx_data   (tx_data[n]),
        .rx_clk    (rx_clk[n]),
        .rx_valid  (rx_valid[n]),
        .rx_data   (rx_data[n][W-1:0])
    );
  end

  // ---- status into clk -------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic [11:0] st_m, st_s;
  always_ff @(posedge clk) begin
    st_m <= {
      rx_valid[1],
      pll_lock[1],
      cdr_lock[1],
      sig_det[1],
      ready[1],
      1'b0,
      rx_valid[0],
      pll_lock[0],
      cdr_lock[0],
      sig_det[0],
      ready[0],
      1'b0
    };
    st_s <= st_m;
  end
  // STATUS lane byte: [0] pll [1] cdr [2] sd [3] ready [4] prbs locked [5] rx valid
  function automatic logic [7:0] lane_status(input logic [5:0] s, input logic lk);
    // s = {rx_valid, pll, cdr, sd, ready, -}
    return {2'b00, s[5], lk, s[1], s[2], s[3], s[4]};
  endfunction
  wire [31:0] status = {
    16'h0, lane_status(st_s[11:6], locked[1]), lane_status(st_s[5:0], locked[0])
  };

  // ---- frequency counters -----------------------------------------------------
  logic f_req, f_ack;
  logic [31:0] f_rdata;
  ku5p_freq_bank #(
      .NCH        (5),
      .GATE_CYCLES(FREQ_GATE)
  ) u_freq (
      .clk,
      .rst_n,
      .req     (f_req),
      .we      (m_we),
      .addr    (m_addr[7:0]),
      .wdata   (m_wdata),
      .ack     (f_ack),
      .rdata   (f_rdata),
      .meas_clk({rx_clk[1], tx_clk[1], rx_clk[0], tx_clk[0], refclk[0]})
  );

  // ---- registers -----------------------------------------------------------------
  logic [$clog2(RST_CYCLES+1)-1:0] rst_cnt;
  logic [                     2:0] rst_sel;  // [0] PMA [1] PCS RX [2] PCS TX
  logic                            r_ack;
  logic [                    31:0] r_rdata;

  wire                             is_freq = m_addr[23:8] == 16'h0002;
  assign f_req      = m_req && is_freq;
  assign m_ack      = is_freq ? f_ack : r_ack;
  assign m_rdata    = is_freq ? f_rdata : r_rdata;

  assign pma_rstn   = !(rst_sel[0] && rst_cnt != 0);
  assign pcs_rx_rst = rst_sel[1] && rst_cnt != 0;
  assign pcs_tx_rst = rst_sel[2] && rst_cnt != 0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lane_cfg <= '0;
      clr_tgl  <= 1'b0;
      inj_tgl  <= '0;
      rst_cnt  <= '0;
      rst_sel  <= '0;
      r_ack    <= 1'b0;
      r_rdata  <= '0;
    end else begin
      if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'b1;
      r_ack <= m_req && !is_freq;
      if (m_req && !is_freq) begin
        if (m_we) begin
          case (m_addr[11:2])
            10'h002: begin
              if (m_wdata[0]) clr_tgl <= ~clr_tgl;
              if (|m_wdata[3:1]) begin
                rst_sel <= m_wdata[3:1];
                rst_cnt <= RST_CYCLES;
              end
            end
            10'h004: lane_cfg <= {3'b0, m_wdata[12:8], 3'b0, m_wdata[4:0]};
            10'h005: inj_tgl <= inj_tgl ^ m_wdata[1:0];
            default: ;
          endcase
        end
        case (m_addr[11:2])
          10'h000: r_rdata <= DESIGN_ID;
          10'h001: r_rdata <= RATE_KBPS;
          10'h002: r_rdata <= {28'h0, rst_cnt != 0 ? rst_sel : 3'b000, 1'b0};
          10'h003: r_rdata <= status;
          10'h004: r_rdata <= {16'h0, lane_cfg};
          10'h010: r_rdata <= err_bits[0];
          10'h011: r_rdata <= err_words[0];
          10'h012: r_rdata <= lock_words[0][31:0];
          10'h013: r_rdata <= lock_words[0][63:32];
          10'h014: r_rdata <= lost_lock[0];
          10'h018: r_rdata <= err_bits[1];
          10'h019: r_rdata <= err_words[1];
          10'h01A: r_rdata <= lock_words[1][31:0];
          10'h01B: r_rdata <= lock_words[1][63:32];
          10'h01C: r_rdata <= lost_lock[1];
          default: r_rdata <= '0;
        endcase
      end
    end
  end

  // ---- LEDs (active low): lane 0/1 PRBS locked, lane 0/1 CDR locked -----------
  assign led_n = ~{st_s[9], st_s[3], locked[1], locked[0]};

endmodule

`default_nettype wire
