// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
//
// Testbench: drive sport_rx_chan with a modeled DSP SPORT TX waveform.
//   CONTINUOUS : 1 = back-to-back frames (DMA), 0 = clock gap between (polled)
//   LEAD       : 1 = assert afs on one extra cycle BEFORE the 32 data bits
//   MSBFIRST   : 1 = transmit MSB first, 0 = LSB first
//   PRBS       : 1 = transmit the mission PRBS-31 stream, 0 = counters
module tb;
`ifndef CONTINUOUS
 `define CONTINUOUS 1
`endif
`ifndef LEAD
 `define LEAD 0
`endif
`ifndef MSBFIRST
 `define MSBFIRST 1
`endif
`ifndef PRBS
 `define PRBS 1
`endif
   localparam CONT = `CONTINUOUS;
   localparam LEAD = `LEAD;
   localparam MSB  = `MSBFIRST;
   localparam USE_PRBS = `PRBS;
   localparam [30:0] PRBS31_SEED = 31'h7fffffff;

   reg clk12 = 1'b0;
   always #40 clk12 = ~clk12;

   reg aclk_en = 1'b0;
   reg aclk_free = 1'b0;
   always #8 aclk_free = ~aclk_free;
   wire aclk = aclk_free & aclk_en;

   reg ad0 = 1'b0;
   reg afs = 1'b0;
   reg run = 1'b0;

`ifndef DELAY
 `define DELAY 0
`endif
   // Delay the data line by `DELAY bit-periods relative to clk/afs to model
   // a data net that arrives skewed because of FPGA routing.
   reg [7:0] ad0_pipe = 8'd0;
   always @(posedge aclk_free) if (aclk_en) ad0_pipe <= {ad0_pipe[6:0], ad0};
   wire ad0_dly = (`DELAY == 0) ? ad0 : ad0_pipe[`DELAY-1];

   wire [31:0] words;
   wire [31:0] errors;
   wire        done;

   sport_rx_chan #(.MIN_DONE_WORDS(32'd100)) dut (
      .clk12(clk12), .run(run), .aclk_in(aclk), .ad0_in(ad0_dly),
      .afs_in(afs), .words(words), .errors(errors), .done(done));

   integer wi, bi;
   reg [31:0] cur;
   reg b;
   reg [30:0] prbs_state;

   function [31:0] prbs31_word;
      input [30:0] s_in;
      integer i;
      reg [30:0] s;
      reg [31:0] w;
      reg new_bit;
      begin
         s = s_in;
         w = 32'd0;
         for (i = 0; i < 32; i = i + 1) begin
            new_bit = s[30] ^ s[27];
            s = {s[29:0], new_bit};
            w = {w[30:0], new_bit};
         end
         prbs31_word = w;
      end
   endfunction

   function [30:0] prbs31_advance;
      input [30:0] s_in;
      integer i;
      reg [30:0] s;
      reg new_bit;
      begin
         s = s_in;
         for (i = 0; i < 32; i = i + 1) begin
            new_bit = s[30] ^ s[27];
            s = {s[29:0], new_bit};
         end
         prbs31_advance = s;
      end
   endfunction

   task send_bit(input val, input fsv);
      begin
         aclk_en = 1'b1;
         @(negedge aclk_free);
         ad0 = val; afs = fsv;
         @(posedge aclk_free);
      end
   endtask

   initial begin
      ad0 = 1'b0; afs = 1'b0; aclk_en = 1'b0;
      prbs_state = PRBS31_SEED;
      #100;
      run = 1'b1;
      for (wi = 0; wi < 3000; wi = wi + 1) begin
         if (USE_PRBS) begin
            cur = prbs31_word(prbs_state);
            prbs_state = prbs31_advance(prbs_state);
         end else begin
            cur = wi[31:0];
         end
         if (LEAD)
            send_bit(1'b0, 1'b1);
         for (bi = 0; bi < 32; bi = bi + 1) begin
            b = MSB ? cur[31-bi] : cur[bi];
            if (LEAD)
               send_bit(b, 1'b0);
            else
               send_bit(b, (bi == 0) ? 1'b1 : 1'b0);
         end
         if (CONT == 0) begin
            @(negedge aclk_free);
            aclk_en = 1'b0;
            ad0 = 1'b0; afs = 1'b0;
            #64;
         end
      end
      @(negedge aclk_free);
      aclk_en = 1'b0; ad0 = 1'b0; afs = 1'b0;
      run = 1'b0;
      repeat (400) @(posedge clk12);
      $display("RESULT cont=%0d lead=%0d msb=%0d words=%0d errors=%0d",
               CONT, LEAD, MSB, words, errors);
      $finish;
   end
endmodule
