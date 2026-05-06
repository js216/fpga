// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module prbs_xor (
      input             clk,
      input             rst_n,
      input             clear,
      input             clk_en,
      output reg [31:0] state,
      output reg [31:0] checksum
   );

   localparam [31:0] SEED = 32'h0000_0001;
   localparam [31:0] POLY = 32'h8020_0003;

   initial state    = SEED;
   initial checksum = 32'h0000_0000;

   always @(posedge clk) begin
      if (!rst_n) begin
         state    <= SEED;
         checksum <= 32'h0000_0000;
      end else if (clk_en) begin
         if (state[0])
            state <= (state >> 1) ^ POLY;
         else
            state <= (state >> 1);
         if (clear)
            checksum <= 32'h0000_0000;
         else
            checksum <= checksum ^ state;
      end
   end
endmodule
