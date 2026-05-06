// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module prbs_xor (
      input             clk,
      input             rst_n,
      output reg [31:0] state
   );

   localparam [31:0] SEED = 32'h0000_0001;
   localparam [31:0] POLY = 32'h8020_0003;

   initial state = SEED;

   always @(posedge clk) begin
      if (!rst_n)
         state <= SEED;
      else if (state[0])
         state <= (state >> 1) ^ POLY;
      else
         state <= (state >> 1);
   end
endmodule
