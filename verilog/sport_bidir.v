// SPDX-License-Identifier: MIT
// Combined FPGA SPORT PRBS transmitter and DSP SPORT receiver.

module sport_bidir #(
      parameter TX_TO_DSP_N = 1,
      parameter RX_FROM_DSP_N = 1,
      parameter MIN_DONE_WORDS = 32'h00b00000,
      parameter REPORT_LANE0 = 0,
      parameter REPORT_IDX = 0,
      parameter TX_QUIET = 0,
      parameter SYNC_TX = 0,
      parameter NOPLL = 0,
      parameter NOPLL_DATA_NEG = 1,
      parameter NOPLL_CLK_POS = 1,
      parameter [1:0] SYNC_PH = 2'd1,
      parameter SHARE_PAIRS = 0   // 4-lane: pairs share one clk/fs pad
   )(
      input clk12,
      input run,
      input dsp_aclk2_in,
      input dsp_aclk3_in,
      output [TX_TO_DSP_N-1:0] fpga_ad0_out,
      output [(SHARE_PAIRS ? TX_TO_DSP_N/2 : TX_TO_DSP_N)-1:0] fpga_aclk_out,
      output [(SHARE_PAIRS ? TX_TO_DSP_N/2 : TX_TO_DSP_N)-1:0] fpga_afs_out,
      input  [RX_FROM_DSP_N-1:0] dsp_ad0_in,
      input  [RX_FROM_DSP_N-1:0] dsp_aclk_in,
      input  [RX_FROM_DSP_N-1:0] dsp_afs_in,
      inout tx
   );
   wire [TX_TO_DSP_N-1:0] tx_ad0_w;
   wire [TX_TO_DSP_N-1:0] tx_aclk_w;
   wire [TX_TO_DSP_N-1:0] tx_afs_w;

   localparam START_DELAY_CYCLES = 24000000;

   generate
      if (SYNC_TX != 0) begin : sync_tx
         // Source-synchronous streamer. The NOPLL path instantiates one
         // top-level IO-backed transmitter per output lane, all clocked by the
         // DSP-forwarded ACLK. The legacy PLL path is kept behind NOPLL=0.
         wire s_ad0, s_aclk, s_afs;
         if (NOPLL != 0) begin : nopll
            genvar tx_i;
            for (tx_i = 0; tx_i < TX_TO_DSP_N; tx_i = tx_i + 1) begin : lanes
               sport_tx_sync_nopll #(
                  .DATA_NEG(NOPLL_DATA_NEG),
                  .CLK_POS(NOPLL_CLK_POS)
               ) to_dsp (
                  // one forwarder per clock pin: lane 0 on the primary,
                  // lane 1 on the P10 copy, so neither lane's phase moves
                  // with the other's clock load.
                  // one forwarder per physical clock pin: primaries on
                  // dsp_aclk_in[0]/[1], SRU copies on aclk2 (P10) and
                  // aclk3 (T8), so no lane's phase moves with another's
                  // clock load.
                  .fwd_aclk(SHARE_PAIRS != 0
                            ? (tx_i < 2 ? dsp_aclk2_in : dsp_aclk3_in)
                            : (tx_i == 0 ? dsp_aclk_in[0] : dsp_aclk2_in)),
                  .run(run),
                  .ad0_out(tx_ad0_w[tx_i]),
                  .aclk_out(tx_aclk_w[tx_i]),
                  .afs_out(tx_afs_w[tx_i])
               );
            end
         end else begin : withpll
            sport_tx_sync #(.PH(SYNC_PH)) to_dsp (
               .fwd_aclk(dsp_aclk_in[0]),
               .ad0_out(s_ad0),
               .aclk_out(s_aclk),
               .afs_out(s_afs)
            );
            assign tx_ad0_w  = {TX_TO_DSP_N{s_ad0}};
            assign tx_aclk_w = {TX_TO_DSP_N{s_aclk}};
            assign tx_afs_w  = {TX_TO_DSP_N{s_afs}};
         end
      end else begin : free_tx
         sport_tx_prbs_ser #(
            .N(TX_TO_DSP_N),
            .START_DELAY_CYCLES(START_DELAY_CYCLES),
            .TX_QUIET(TX_QUIET)
         ) to_dsp (
            .clk12(clk12),
            .ad0_out(tx_ad0_w),
            .aclk_out(tx_aclk_w),
            .afs_out(tx_afs_w)
         );
      end
   endgenerate

   assign fpga_ad0_out  = tx_ad0_w;
   generate
      if (SHARE_PAIRS != 0) begin : pairpads
         // one clk/fs pad per pair, driven by the pair's even lane
         genvar pp;
         for (pp = 0; pp < TX_TO_DSP_N/2; pp = pp + 1) begin : pairs
            assign fpga_aclk_out[pp] = tx_aclk_w[2*pp];
            assign fpga_afs_out[pp]  = tx_afs_w[2*pp];
         end
      end else begin : flatpads
         assign fpga_aclk_out = tx_aclk_w;
         assign fpga_afs_out  = tx_afs_w;
      end
   endgenerate

   sport_rx #(.N(RX_FROM_DSP_N), .MIN_DONE_WORDS(MIN_DONE_WORDS),
              .REPORT_LANE0(REPORT_LANE0), .REPORT_IDX(REPORT_IDX),
              .RESYNC(1), .RUN_GATE(0)) from_dsp (
      .clk12(clk12),
      .aclk_in(dsp_aclk_in),
      .ad0_in(dsp_ad0_in),
      .afs_in(dsp_afs_in),
      .run(run),
      .tx(tx)
   );
endmodule
