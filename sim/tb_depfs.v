// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
// Measured dep-FS waveform: FS double-rise (adjacent ticks) at stream
// start, then LEVEL-HIGH forever; bit0 of word0 at the rise; clock
// free-running; back-to-back 32-bit MSB-first PRBS words.
`timescale 1ns/1ps
module tb_depfs;
   reg aclk=0; always #8 aclk=~aclk;
   reg clk12=0; always #41 clk12=~clk12;
   reg run=0, ad0=0, afs=0;
   wire [31:0] words, errors;
   sport_rx_chan #(.MIN_DONE_WORDS(32'd64), .RESYNC(1)) dut (
      .clk12(clk12), .run(run),
      .aclk_in(aclk), .ad0_in(ad0), .afs_in(afs),
      .words(words), .errors(errors));
   reg [30:0] s; integer wi, bi; reg [31:0] cur;
   function [31:0] pw(input [30:0] si); integer i; reg [30:0] ss; reg nb; reg [31:0] w;
      begin ss=si; for(i=0;i<32;i=i+1) begin nb=ss[30]^ss[27]; ss={ss[29:0],nb}; w={w[30:0],nb}; end pw=w; end
   endfunction
   function [30:0] padv(input [30:0] si); integer i; reg [30:0] ss; reg nb;
      begin ss=si; for(i=0;i<32;i=i+1) begin nb=ss[30]^ss[27]; ss={ss[29:0],nb}; end padv=ss; end
   endfunction
   initial begin
      $monitor("t=%0t run=%b afs=%b fs_seen=%b armed=%b started=%b pass_ready=%b bitpos=%0d wcount=%0d",
               $time, run, afs, dut.fs_seen, dut.armed, dut.started, dut.pass_ready, dut.bitpos, dut.wcount);
      // done/report check after stream

      run=0; afs=0; ad0=0;
      #2000; run=1;
      #1000;
      // measured double-rise: high 1 tick, low 1 tick, then high forever
      @(negedge aclk); afs=1;
      @(negedge aclk); afs=0;
      s=31'h7fffffff;
      // second rise WITH bit0 of word0
      for (wi=0; wi<100; wi=wi+1) begin
         cur=pw(s); s=padv(s);
`ifdef GAP_BETWEEN
         // FIFO-paced stream: FS dips for GAP_TICKS between words
         if (wi != 0) begin
            for (bi=0; bi<`GAP_TICKS; bi=bi+1) begin
               @(negedge aclk); afs = 0; ad0 = 0;
            end
         end
`endif
         for (bi=0; bi<32; bi=bi+1) begin
            @(negedge aclk);
            ad0 = cur[31-bi];
            afs = 1;   // level-high while a word shifts
         end
      end
      @(negedge aclk); run=0; afs=0; ad0=0;
      #400000;
      $display("RESULT words=%0d errors=%0d done=%b ecount_live=%0d", words, errors, dut.done_aclk, dut.ecount);
      $finish;
   end
endmodule
