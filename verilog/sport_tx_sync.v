// SPDX-License-Identifier: MIT
// sport_tx_sync.v --- source-synchronous to_dsp streamer for the bidirectional
// link. Proven 2026-06-07: a free-running to_dsp transmitter injects SSO/
// ground-bounce that corrupts EVERY from_dsp input lane; holding the to_dsp
// pins static makes from_dsp read errors=0. This module locks a 4x PLL to the
// forwarded DSP aclk and switches all to_dsp outputs on a quarter-bit phase
// grid (parameter PH) so the switching noise falls OUTSIDE from_dsp's posedge
// sample window. The phase sweep found PH=3 gives from_dsp errors=0 while the
// transmitter runs.
//
// v2: emits a DSP-RX-valid waveform so the bidirectional link works in BOTH
// directions. The output clock aclk_out RISES at phase PH+2 (where the DSP
// samples) while data is launched at phase PH -- a half-bit earlier -- so the
// DSP receiver sees stable data. Because the SSO event phases stay {PH, PH+2}
// regardless of which aclk edge sits where, the PH=3 from_dsp-clean result is
// preserved. A dummy/idle/pattern startup lets the DSP RX align on the gap
// (mirrors the proven free-running prbs_chan flow).

module sport_tx_sync #(
      parameter [1:0] PH = 2'd3   // clk4x phase at which data is launched
   )(
      input  fwd_aclk,            // forwarded DSP aclk (from_dsp's sample clock)
      output ad0_out,
      output aclk_out,
      output afs_out
   );
   wire clk4x, pll_lock;
   SB_PLL40_CORE #(
      .FEEDBACK_PATH("SIMPLE"),
      .DIVR(4'd0), .DIVF(7'd15), .DIVQ(3'd2),
      .FILTER_RANGE(3'b100)
   ) pll (
      .REFERENCECLK(fwd_aclk), .PLLOUTCORE(clk4x),
      .LOCK(pll_lock), .BYPASS(1'b0), .RESETB(1'b1)
   );

   // Phase counter: tracks the forwarded aclk (same scheme as the proven PoC).
   reg [1:0] aclk_s = 2'b0;
   always @(posedge clk4x) aclk_s <= {aclk_s[0], fwd_aclk};
   wire aclk_rise = aclk_s[0] & ~aclk_s[1];
   reg [1:0] p = 2'd0;
   always @(posedge clk4x) p <= aclk_rise ? 2'd1 : (p + 2'd1);

   localparam [30:0] PRBS31_SEED = 31'h7fffffff;
   localparam [31:0] DUMMY_WORD  = 32'hA5A55A5A;
   localparam [13:0] DUMMY_WORDS = 14'd8192;
   localparam [21:0] IDLE_BITS   = 22'd200000;
   localparam [1:0]  PH_DUMMY    = 2'd0;
   localparam [1:0]  PH_IDLE     = 2'd1;
   localparam [1:0]  PH_PATTERN  = 2'd2;

   localparam [21:0] STARTUP_HOLD = 22'd60000;    // ~1ms idle after lock before dummy

   reg [4:0]  bitcnt      = 5'd0;
   reg [1:0]  fsm         = PH_DUMMY;
   reg [13:0] dummy_count = 14'd0;
   reg [21:0] idle_count  = 22'd0;
   reg [21:0] hold_count  = 22'd0;
   reg        started     = 1'b0;
   reg [30:0] lfsr        = PRBS31_SEED;
   reg [31:0] shift_word  = 32'd0;
   reg [31:0] ctr         = 32'd0;   // pattern payload: incrementing counter
   reg [31:0] ctr_sh      = 32'd0;
   reg        ad0_q = 1'b0, afs_q = 1'b0, aclk_q = 1'b0;

   always @(posedge clk4x) begin
      // Continuous 62.5 MHz output clock: rises at PH+2 (DSP sample point),
      // falls at PH (where data is launched). Toggles in every FSM phase so
      // the DSP RX always has a clock.
      if (p == PH)            aclk_q <= 1'b0;
      else if (p == PH + 2'd2) aclk_q <= 1'b1;

      // One bit per forwarded-aclk period, launched at phase PH.
      if (p == PH) begin
         if (!started) begin
            // Hold idle (clock toggling, no frames) so the DSP RX reaches its
            // align wait-loop before the dummy/idle gap appears.
            afs_q <= 1'b0; ad0_q <= 1'b0;
            if (hold_count == STARTUP_HOLD - 22'd1) begin
               started <= 1'b1; hold_count <= 22'd0;
            end else hold_count <= hold_count + 22'd1;
         end else if (fsm == PH_IDLE) begin
            afs_q <= 1'b0; ad0_q <= 1'b0;
            if (idle_count == IDLE_BITS - 22'd1) begin
               fsm <= PH_PATTERN; idle_count <= 22'd0; bitcnt <= 5'd0;
            end else idle_count <= idle_count + 22'd1;
         end else if (fsm == PH_DUMMY) begin
            afs_q <= (bitcnt == 5'd0);
            if (bitcnt == 5'd0) begin
               ad0_q <= DUMMY_WORD[31]; shift_word <= {DUMMY_WORD[30:0], 1'b0};
               bitcnt <= 5'd1;
            end else begin
               ad0_q <= shift_word[31]; shift_word <= {shift_word[30:0], 1'b0};
               if (bitcnt == 5'd31) begin
                  bitcnt <= 5'd0;
                  if (dummy_count == DUMMY_WORDS - 14'd1) begin
                     fsm <= PH_IDLE; dummy_count <= 14'd0;
                  end else dummy_count <= dummy_count + 14'd1;
               end else bitcnt <= bitcnt + 5'd1;
            end
         end else begin   // PH_PATTERN: incrementing counter, MSB-first
            if (bitcnt == 5'd0) begin
               afs_q  <= 1'b1;
               ad0_q  <= ctr[31];
               ctr_sh <= {ctr[30:0], 1'b0};
               bitcnt <= 5'd1;
            end else begin
               afs_q  <= 1'b0;
               ad0_q  <= ctr_sh[31];
               ctr_sh <= {ctr_sh[30:0], 1'b0};
               if (bitcnt == 5'd31) begin
                  bitcnt <= 5'd0;
                  ctr <= ctr + 32'd1;
               end else bitcnt <= bitcnt + 5'd1;
            end
         end
      end
   end

   assign ad0_out  = ad0_q;
   assign afs_out  = afs_q;
   assign aclk_out = aclk_q;
endmodule
