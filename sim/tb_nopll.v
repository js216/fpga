// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
`timescale 1ns/1ps
module tb_nopll;
   reg clk=0; always #8 clk=~clk;
   reg run=0;
   wire ad0,aclk,afs;
   sport_tx_sync_nopll #(.DATA_NEG(1),.CLK_POS(1)) dut(
      .fwd_aclk(clk),.run(run),.ad0_out(ad0),.aclk_out(aclk),.afs_out(afs));
   integer i; reg [31:0] w; reg [30:0] s; reg b; integer errs;
   initial begin
      #200; run=1; #1;
      s=31'h7fffffff; errs=0;
      // data launches on negedge (DATA_NEG=1): wait for the first FS,
      // then sample word-aligned from that bit.
      @(posedge afs);
      for (i=0;i<32*40;i=i+1) begin
         #1;
         w={w[30:0],ad0};
         if (i%32==31) begin
            b=0;
            begin : exp
               reg [31:0] e; integer k;
               e=0;
               for (k=0;k<32;k=k+1) begin
                  e={e[30:0], s[30]^s[27]};
                  s={s[29:0], s[30]^s[27]};
               end
               if (w!==e) begin errs=errs+1; if (errs<4) $display("word %0d got=%08x exp=%08x", i/32, w, e); end
            end
         end
         @(negedge clk);
      end
      $display("RESULT errs=%0d", errs);
      $finish;
   end
endmodule
