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
      parameter SHARE_PAIRS = 0,  // 4-lane: pairs share one clk/fs pad
      parameter FROM_DSP_EN = 1   // 0: D->F lanes are unverified clock
                                  // scaffolding -- receiver held in reset,
                                  // prints nothing, claims nothing
   )(
      input clk12,
      input run,
      output [TX_TO_DSP_N-1:0] fpga_ad0_out,
      output [(SHARE_PAIRS ? TX_TO_DSP_N/2 : TX_TO_DSP_N)-1:0] fpga_aclk_out,
      output [(SHARE_PAIRS ? TX_TO_DSP_N/2 : TX_TO_DSP_N)-1:0] fpga_afs_out,
      output led,
      input  [RX_FROM_DSP_N-1:0] dsp_ad0_in,
      input  [RX_FROM_DSP_N-1:0] dsp_aclk_in,
`ifdef SHARE_COPIES
      // 4-lane only: pair forwarders launch from the SRU clock copies
      // (P10/T8), the never-failed clocking for SHARE_PAIRS. Primary
      // forwarding (proven for 1x1/2x2) showed thermal-onset pair0
      // desync on the 4-lane netlists (FFFF-DDDD 2026-06-12 evening).
      input  dsp_aclk2_in,
      input  dsp_aclk3_in,
`endif
      input  [RX_FROM_DSP_N-1:0] dsp_afs_in,
      inout tx
   );
   wire [TX_TO_DSP_N-1:0] tx_ad0_w;
   wire [TX_TO_DSP_N-1:0] tx_aclk_w;
   wire [TX_TO_DSP_N-1:0] tx_afs_w;

   localparam START_DELAY_CYCLES = 24000000;

   generate
      if (SYNC_TX != 0) begin : sync_tx
         // Source-synchronous streamer: one top-level IO-backed transmitter
         // per output lane, all clocked by the DSP-forwarded ACLK (NOPLL=1).
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
                  // Rule proven by the 4-lane config: forwarders run on
                  // the SRU clock copies, never on the primary clocks that
                  // feed the from_dsp capture registers -- mixing loads
                  // shifts the capture/launch phases per netlist.
                  // Every forwarder launches from the PRIMARY capture
                  // clock of its lane. The SRU copies (P10/T8) existed to
                  // offload primaries that EYE_DELAY's fabric spurs were
                  // loading; with EYE_DELAY gone the primaries are clean
                  // globals, and copy-clocked 2x2 forwarders showed a
                  // thermal-onset single-lane desync (FF-DD 512MiB,
                  // 2026-06-12, onset moves run-to-run = analog).
                  .fwd_aclk(
`ifdef SHARE_COPIES
                            SHARE_PAIRS != 0
                            ? (tx_i < 2 ? dsp_aclk2_in : dsp_aclk3_in) :
`endif
                            dsp_aclk_in[tx_i]),
                  .run(run),
                  .ad0_out(tx_ad0_w[tx_i]),
                  .aclk_out(tx_aclk_w[tx_i]),
                  .afs_out(tx_afs_w[tx_i])
               );
            end
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
      .led(led),
      .clk12(clk12),
      .aclk_in(dsp_aclk_in),
      .ad0_in(dsp_ad0_in),
      .afs_in(dsp_afs_in),
      .run(FROM_DSP_EN ? run : 1'b0),
      .tx(tx)
   );
endmodule
