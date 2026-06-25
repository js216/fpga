// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module sport_tx_sync_nopll #(
      parameter DATA_NEG = 1,
      parameter CLK_POS  = 1
   )(
      input  fwd_aclk,
      input  run,
      output ad0_out,
      output aclk_out,
      output afs_out
   );
   reg [1:0] run_s = 2'b00;
   reg [5:0] warm  = 6'd0;
   localparam [30:0] PRBS31_SEED = 31'h7FFFFFFF;

   reg [30:0] lfsr   = PRBS31_SEED;
   reg [4:0]  bitcnt = 5'd0;
   reg        ad0_p  = 1'b0;
   reg        afs_p  = 1'b0;

   always @(posedge fwd_aclk) begin
      run_s <= {run_s[0], run};
      if (!run_s[1] || warm != 6'd63) begin
         if (run_s[1])
            warm <= warm + 6'd1;
         else
            warm <= 6'd0;
         lfsr   <= PRBS31_SEED;
         bitcnt <= 5'd0;
         ad0_p  <= 1'b0;
         afs_p  <= 1'b0;
      end else begin
         ad0_p  <= lfsr[30] ^ lfsr[27];
         afs_p  <= (bitcnt == 5'd0);
         lfsr   <= {lfsr[29:0], (lfsr[30] ^ lfsr[27])};
         bitcnt <= bitcnt + 5'd1;
      end
   end
   SB_IO #(.PIN_TYPE(6'b010100), .NEG_TRIGGER(DATA_NEG ? 1'b1 : 1'b0)) ad0_io (
      .PACKAGE_PIN(ad0_out), .OUTPUT_CLK(fwd_aclk), .D_OUT_0(ad0_p)
   );
   SB_IO #(.PIN_TYPE(6'b010100), .NEG_TRIGGER(DATA_NEG ? 1'b1 : 1'b0)) afs_io (
      .PACKAGE_PIN(afs_out), .OUTPUT_CLK(fwd_aclk), .D_OUT_0(afs_p)
   );
   SB_IO #(.PIN_TYPE(6'b010000)) aclk_io (
      .PACKAGE_PIN(aclk_out), .OUTPUT_CLK(fwd_aclk),
      .D_OUT_0(CLK_POS ? 1'b1 : 1'b0), .D_OUT_1(CLK_POS ? 1'b0 : 1'b1)
   );
endmodule
