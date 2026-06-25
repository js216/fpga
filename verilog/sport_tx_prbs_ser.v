// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module prbs_chan_ser (
      input  pll_clk,
      input  enable,
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
   reg        nb;

   always @(negedge pll_clk) begin
      if (!enable) begin
         ad0_r <= 1'b0;
         afs_r <= 1'b0;
         bitcnt <= 5'd0;
         phase <= PH_DUMMY;
         dummy_count <= 14'd0;
         idle_count <= 22'd0;
         prbs_state <= PRBS31_SEED;
         shift_word <= 32'd0;
      end else if (phase == PH_IDLE) begin
         afs_r <= 1'b0; ad0_r <= 1'b0;
         if (idle_count == IDLE_CYCLES - 22'd1) begin
            phase <= PH_PATTERN; idle_count <= 22'd0; bitcnt <= 5'd0;
         end else idle_count <= idle_count + 22'd1;
      end else if (phase == PH_DUMMY) begin
         afs_r <= (bitcnt == 5'd0);
         if (bitcnt == 5'd0) begin
            ad0_r <= DUMMY_WORD[31]; shift_word <= {DUMMY_WORD[30:0], 1'b0};
            bitcnt <= 5'd1;
         end else begin
            ad0_r <= shift_word[31]; shift_word <= {shift_word[30:0], 1'b0};
            if (bitcnt == 5'd31) begin
               bitcnt <= 5'd0;
               if (dummy_count == DUMMY_WORDS - 14'd1) begin
                  phase <= PH_IDLE; dummy_count <= 14'd0;
               end else dummy_count <= dummy_count + 14'd1;
            end else bitcnt <= bitcnt + 5'd1;
         end
      end else begin
         afs_r <= (bitcnt == 5'd0);
         nb = prbs_state[30] ^ prbs_state[27];
         ad0_r <= nb;
         prbs_state <= {prbs_state[29:0], nb};
         bitcnt <= (bitcnt == 5'd31) ? 5'd0 : bitcnt + 5'd1;
      end
   end
endmodule
module sport_tx_prbs_ser #(
      parameter N = 1,
      parameter START_DELAY_CYCLES = 0,
      parameter TX_QUIET = 0
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

   wire stream_enable;
   generate
      if (START_DELAY_CYCLES == 0) begin : no_delay
         assign stream_enable = 1'b1;
      end else begin : delayed_start
         reg [31:0] start_delay = 32'd0;
         reg stream_enable_r = 1'b0;
         always @(posedge clk12) begin
            if (!stream_enable_r) begin
               if (start_delay == START_DELAY_CYCLES - 1)
                  stream_enable_r <= 1'b1;
               else
                  start_delay <= start_delay + 32'd1;
            end
         end
         assign stream_enable = stream_enable_r;
      end
   endgenerate

   wire ad0_w, afs_w;
   wire chan_en = (TX_QUIET != 0) ? 1'b0 : stream_enable;
   prbs_chan_ser g (.pll_clk(pll_clk), .enable(chan_en), .ad0_r(ad0_w), .afs_r(afs_w));

   assign ad0_out = (TX_QUIET != 0) ? {N{1'b0}} : {N{ad0_w}};
   assign afs_out = (TX_QUIET != 0) ? {N{1'b0}} : {N{afs_w}};

   genvar i;
   generate
      for (i = 0; i < N; i = i + 1) begin : ch
         assign aclk_out[i] = (TX_QUIET != 0) ? 1'b0 : pll_clk;
      end
   endgenerate
endmodule
