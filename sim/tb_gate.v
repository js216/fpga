// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
// Reproduce the 128B bench scenario at the sport_rx TOP level:
//   phase 1: pre-boot float -- run high-ish, noise on aclk/ad0/afs
//   phase 2: DSP boots, drives RUN low
//   phase 3: RUN high, 40 PRBS words stream, then idle
// Pass criteria: done fires, words==40ish>=32, errors==0.
`timescale 1ns/1ps
module tb_gate;
   localparam [30:0] SEED = 31'h7fffffff;
   reg clk12 = 0; always #41.6 clk12 = ~clk12;   // 12 MHz
   reg aclk_free = 0; always #8.3 aclk_free = ~aclk_free; // 60 MHz
   reg aclk_en = 0;
   wire aclk = aclk_free & aclk_en;
   reg ad0_pre = 0, afs = 0, run = 0;
   // model the hardware's data-vs-FS lag that arm_wait is calibrated to
   reg [3:0] ad0_lag = 4'd0;
   wire ad0 = ad0_lag[3];
   wire tx;

   sport_rx #(.N(1), .MIN_DONE_WORDS(32'd32)) dut (
      .clk12(clk12), .aclk_in(aclk), .ad0_in(ad0), .afs_in(afs),
      .run(run), .tx(tx));

   // crude uart decode at 115200 (8680ns/bit) on tx
   initial begin : uartmon
      forever begin
         @(negedge tx);
         begin : byterx
            integer bi; reg [7:0] by;
            #(8680/2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
               #8680; by[bi] = tx;
            end
            $write("%c", by);
         end
      end
   end

   integer wi, bi, ni;
   reg [30:0] st;
   reg [31:0] cur;
   always @(posedge aclk_free) if (aclk_en) ad0_lag <= {ad0_lag[2:0], ad0_pre};
   task tick(input d, input f);
      begin
         @(negedge aclk_free); ad0_pre = d; afs = f; aclk_en = 1;
         @(posedge aclk_free);
      end
   endtask
   function [31:0] pw(input [30:0] s_in);
      integer i; reg [30:0] s; reg nb; reg [31:0] w;
      begin s=s_in; for (i=0;i<32;i=i+1) begin nb=s[30]^s[27]; s={s[29:0],nb}; w={w[30:0],nb}; end pw=w; end
   endfunction
   function [30:0] padv(input [30:0] s_in);
      integer i; reg [30:0] s; reg nb;
      begin s=s_in; for (i=0;i<32;i=i+1) begin nb=s[30]^s[27]; s={s[29:0],nb}; end padv=s; end
   endfunction

   initial begin
      // phase 1: float-high run + boot-bleed noise
      run = 1;
      for (ni = 0; ni < 3000; ni = ni + 1)
         tick($random[0], $random[1]);
      aclk_en = 0;
      // phase 2: RUN driven low (DSP boot), aclk silent  ~1ms scaled
      run = 0;
      #1000000;
      // phase 3: RUN high then stream starts shortly after
      run = 1;
      #5000;
      st = SEED;
      // real SPORT emits one junk startup frame before word 0
      for (bi = 0; bi < 32; bi = bi + 1)
         tick($random[0], (bi == 0));
      for (wi = 0; wi < 40; wi = wi + 1) begin
         cur = pw(st); st = padv(st);
         for (bi = 0; bi < 32; bi = bi + 1)
            tick(cur[31-bi], (bi == 0));
      end
      @(negedge aclk_free); aclk_en = 0; ad0_pre = 0; afs = 0;
      run = 0;
      #12000000;  // let idle/done/print run
      $display("");
      $display("SIM done");
      $finish;
   end
endmodule
