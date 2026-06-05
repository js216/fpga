// SPDX-License-Identifier: MIT
// sport_tx_prbs_multi.v --- N parallel SPORT PRBS31 streamers off one PLL.
// Each channel is an independent copy of the proven single-channel
// generator (same seed/timing), so the DSP receives N synchronized
// PRBS31 streams and verifies each with its own state. Aggregate
// throughput is N x per-channel rate.

module prbs_chan (
      input  pll_clk,
      input  pll_lock,
      output reg ad0_r,
      output reg afs_r
   );
   localparam [30:0] PRBS31_SEED = 31'h7fffffff;
   localparam [31:0] DUMMY_WORD  = 32'hA5A55A5A;
   localparam [13:0] DUMMY_WORDS = 14'd8192;
   localparam [21:0] IDLE_CYCLES = 22'd200000;
   localparam [1:0]  PH_DUMMY    = 2'd0;
   localparam [1:0]  PH_IDLE     = 2'd1;
   localparam [1:0]  PH_PATTERN  = 2'd2;

   reg [4:0]  bitcnt      = 5'd0;
   reg [1:0]  phase       = PH_DUMMY;
   reg [13:0] dummy_count = 14'd0;
   reg [21:0] idle_count  = 22'd0;
   reg [30:0] prbs_state  = PRBS31_SEED;
   reg [31:0] shift_word  = 32'd0;

   function [31:0] prbs31_word;
      input [30:0] s_in; integer i; reg [30:0] s; reg [31:0] w; reg nb;
      begin
         s = s_in; w = 32'd0;
         for (i = 0; i < 32; i = i + 1) begin
            nb = s[30] ^ s[27]; s = {s[29:0], nb}; w = {w[30:0], nb};
         end
         prbs31_word = w;
      end
   endfunction
   function [30:0] prbs31_advance;
      input [30:0] s_in; integer i; reg [30:0] s; reg nb;
      begin
         s = s_in;
         for (i = 0; i < 32; i = i + 1) begin nb = s[30] ^ s[27]; s = {s[29:0], nb}; end
         prbs31_advance = s;
      end
   endfunction

   wire [31:0] current_payload = prbs31_word(prbs_state);

   always @(negedge pll_clk) begin
      if (!pll_lock) begin
         bitcnt <= 5'd0; phase <= PH_DUMMY; dummy_count <= 14'd0;
         idle_count <= 22'd0; prbs_state <= PRBS31_SEED; shift_word <= 32'd0;
         afs_r <= 1'b0; ad0_r <= 1'b0;
      end else if (phase == PH_IDLE) begin
         afs_r <= 1'b0; ad0_r <= 1'b0;
         if (idle_count == IDLE_CYCLES - 22'd1) begin
            phase <= PH_PATTERN; idle_count <= 22'd0; bitcnt <= 5'd0;
         end else idle_count <= idle_count + 22'd1;
      end else begin
         afs_r <= (bitcnt == 5'd0);
         if (bitcnt == 5'd0) begin
            if (phase == PH_DUMMY) begin
               ad0_r <= DUMMY_WORD[31]; shift_word <= {DUMMY_WORD[30:0], 1'b0};
            end else begin
               ad0_r <= current_payload[31]; shift_word <= {current_payload[30:0], 1'b0};
            end
            bitcnt <= 5'd1;
         end else begin
            ad0_r <= shift_word[31]; shift_word <= {shift_word[30:0], 1'b0};
            if (bitcnt == 5'd31) begin
               bitcnt <= 5'd0;
               if (phase == PH_DUMMY) begin
                  if (dummy_count == DUMMY_WORDS - 14'd1) begin
                     phase <= PH_IDLE; dummy_count <= 14'd0;
                  end else dummy_count <= dummy_count + 14'd1;
               end else prbs_state <= prbs31_advance(prbs_state);
            end else bitcnt <= bitcnt + 5'd1;
         end
      end
   end
endmodule

module sport_tx_prbs_multi #(
      parameter N = 2
   )(
      input              clk12,
      output [N-1:0]     ad0_out,
      output [N-1:0]     aclk_out,
      output [N-1:0]     afs_out
   );
   wire pll_clk, pll_lock;
   SB_PLL40_CORE #(
      .FEEDBACK_PATH("SIMPLE"),
      .DIVR(4'd0),
      .DIVF(7'd82),
      .DIVQ(3'd4),
      .FILTER_RANGE(3'd1)
   ) pll (
      .REFERENCECLK(clk12), .PLLOUTCORE(pll_clk), .LOCK(pll_lock),
      .RESETB(1'b1), .BYPASS(1'b0)
   );

   genvar i;
   generate
      for (i = 0; i < N; i = i + 1) begin : ch
         wire ad0_w, afs_w;
         prbs_chan g (.pll_clk(pll_clk), .pll_lock(pll_lock),
                      .ad0_r(ad0_w), .afs_r(afs_w));
         assign ad0_out[i]  = ad0_w;
         assign afs_out[i]  = afs_w;
         assign aclk_out[i] = pll_clk;
      end
   endgenerate
endmodule
