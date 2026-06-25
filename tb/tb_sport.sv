// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
`timescale 1ns/1ps

module tb_sport;
   localparam [30:0] PRBS31_SEED = 31'h7fffffff;
   localparam WORDS    = 600;
   localparam MIN_DONE = 32'd512;
   localparam ARM_FILL = 35;          // 32 (one word) + 3 (arm-pipeline phase)
   localparam UART_CPB = 104;         // clk12 cycles per UART bit (115200 @ 12 MHz)
   
   reg aclk = 1'b0;
   always #8 aclk <= ~aclk;
   reg clk12 = 1'b0;
   always #40 clk12 <= ~clk12;
   
   reg ad0 = 1'b0;        // RESYNC=0 lane stimulus
   reg afs = 1'b0;
   reg ad0b = 1'b0;       // RESYNC=1 lane / negative-control stimulus
   reg afsb = 1'b0;
   reg [1:0] ad0w = 2'b00; // two-lane wrapper stimulus
   reg [1:0] afsw = 2'b00;
   reg run = 1'b0;
   wire [31:0] words;
   wire [31:0] errors;
   wire        done;
   sport_rx_chan #(.MIN_DONE_WORDS(MIN_DONE)) dut (
      .clk12(clk12), .run(run), .aclk_in(aclk), .ad0_in(ad0),
      .afs_in(afs), .words(words), .errors(errors), .done(done));
   
   wire [31:0] words_r;
   wire [31:0] errors_r;
   wire        done_r;
   sport_rx_chan #(.MIN_DONE_WORDS(MIN_DONE), .RESYNC(1)) dut_r (
      .clk12(clk12), .run(run), .aclk_in(aclk), .ad0_in(ad0b),
      .afs_in(afsb), .words(words_r), .errors(errors_r), .done(done_r));
   
   wire [31:0] words_n;
   wire [31:0] errors_n;
   wire        done_n;
   reg         ad0n = 1'b0;
   reg         afsn = 1'b0;
   sport_rx_chan #(.MIN_DONE_WORDS(MIN_DONE), .RESYNC(1)) dut_n (
      .clk12(clk12), .run(run), .aclk_in(aclk), .ad0_in(ad0n),
      .afs_in(afsn), .words(words_n), .errors(errors_n), .done(done_n));
   
   wire tx_w;
   wire led_w;
   pullup(tx_w);
   sport_rx #(.N(2), .MIN_DONE_WORDS(MIN_DONE), .RESYNC(1)) dut_w (
      .clk12(clk12), .aclk_in({aclk, aclk}), .ad0_in(ad0w), .afs_in(afsw),
      .run(run), .tx(tx_w), .led(led_w));
   
   integer wi, bi;
   reg [31:0] cur;
   reg [30:0] prbs_state;
   function [31:0] prbs31_word(input [30:0] s_in);
      integer i; reg [30:0] s; reg [31:0] w; reg nb;
      begin
         s = s_in; w = 32'd0;
         for (i = 0; i < 32; i = i + 1) begin
            nb = s[30] ^ s[27];
            s = {s[29:0], nb};
            w = {w[30:0], nb};
         end
         prbs31_word = w;
      end
   endfunction
   
   function [30:0] prbs31_advance(input [30:0] s_in);
      integer i; reg [30:0] s; reg nb;
      begin
         s = s_in;
         for (i = 0; i < 32; i = i + 1) begin
            nb = s[30] ^ s[27];
            s = {s[29:0], nb};
         end
         prbs31_advance = s;
      end
   endfunction
   task send_bit_a(input val, input fsv);
      begin @(posedge aclk); ad0 = val; afs = fsv; end
   endtask
   task send_word_a(input [31:0] w);
      integer k;
      begin
         for (k = 0; k < 32; k = k + 1)
            send_bit_a(w[31-k], (k == 0) ? 1'b1 : 1'b0);
      end
   endtask
   
   task send_word_b(input [31:0] w);
      integer k;
      begin
         for (k = 0; k < 32; k = k + 1) begin
            @(posedge aclk); ad0b = w[31-k]; afsb = 1'b1;
         end
      end
   endtask
   
   task send_word_n(input [31:0] w);
      integer k;
      begin
         for (k = 0; k < 32; k = k + 1) begin
            @(posedge aclk); ad0n = w[31-k]; afsn = 1'b1;
         end
      end
   endtask
   task send_word_flip_n(input [31:0] w);
      integer k;
      begin
         for (k = 0; k < 32; k = k + 1) begin
            @(posedge aclk); ad0n = (k == 5) ? ~w[31-k] : w[31-k]; afsn = 1'b1;
         end
      end
   endtask
   
   task send_word_w(input [31:0] w);
      integer k;
      begin
         for (k = 0; k < 32; k = k + 1) begin
            @(posedge aclk); ad0w = {w[31-k], w[31-k]}; afsw = 2'b11;
         end
      end
   endtask
   reg        wrapper_pass = 1'b0;
   reg [7:0]  uart_byte;
   reg [1:0]  pass_match = 2'd0;
   integer    ub;
   initial begin
      forever begin
         @(negedge tx_w);                         // start bit
         repeat (UART_CPB + UART_CPB/2) @(posedge clk12);
         for (ub = 0; ub < 8; ub = ub + 1) begin  // 8 data bits, LSB first
            uart_byte[ub] = tx_w;
            repeat (UART_CPB) @(posedge clk12);
         end
         if (uart_byte == "P") pass_match = 2'd1;
         else if (uart_byte == "A" && pass_match == 2'd1) pass_match = 2'd2;
         else if (uart_byte == "S" && pass_match == 2'd2) pass_match = 2'd3;
         else if (uart_byte == "S" && pass_match == 2'd3) begin
            wrapper_pass = 1'b1; pass_match = 2'd0;
         end else pass_match = 2'd0;
      end
   end
   task settle(input integer max_ticks);
      integer t;
      begin
         t = 0;
         while (t < max_ticks) begin
            @(posedge clk12);
            t = t + 1;
         end
      end
   endtask
   initial begin
      ad0 = 1'b0; afs = 1'b0; ad0b = 1'b0; afsb = 1'b0;
      ad0n = 1'b0; afsn = 1'b0; ad0w = 2'b00; afsw = 2'b00; run = 1'b0;
      repeat (4) @(posedge aclk);
      run = 1'b1;
   
         send_bit_a(1'b0, 1'b1);
         for (bi = 0; bi < ARM_FILL; bi = bi + 1) send_bit_a(1'b0, 1'b0);
         prbs_state = PRBS31_SEED;
         for (wi = 0; wi < WORDS; wi = wi + 1) begin
            cur = prbs31_word(prbs_state);
            prbs_state = prbs31_advance(prbs_state);
            send_word_a(cur);
         end
         @(posedge aclk); ad0 = 1'b0; afs = 1'b0;
         settle(2000);
         $display("RESULT r0 words=%0d errors=%0d done=%0d", words, errors, done);
         if (!done || words < MIN_DONE)
            $fatal(1, "tb_sport t1: receiver did not finish (%0d/%0d words)", words, MIN_DONE);
         if (errors != 32'd0)
            $fatal(1, "tb_sport t1: %0d word errors", errors);
         prbs_state = PRBS31_SEED;
         for (wi = 0; wi < WORDS; wi = wi + 1) begin
            cur = prbs31_word(prbs_state);
            prbs_state = prbs31_advance(prbs_state);
            send_word_b(cur);
         end
         @(posedge aclk); ad0b = 1'b0; afsb = 1'b0;
         settle(2000);
         $display("RESULT r1 words=%0d errors=%0d done=%0d", words_r, errors_r, done_r);
         if (!done_r || words_r < MIN_DONE)
            $fatal(1, "tb_sport t2: RESYNC lane did not finish (%0d/%0d words)", words_r, MIN_DONE);
         if (errors_r != 32'd0)
            $fatal(1, "tb_sport t2: %0d word errors", errors_r);
         prbs_state = PRBS31_SEED;
         for (wi = 0; wi < WORDS; wi = wi + 1) begin
            cur = prbs31_word(prbs_state);
            prbs_state = prbs31_advance(prbs_state);
            if (wi == 100) send_word_flip_n(cur);
            else           send_word_n(cur);
         end
         @(posedge aclk); ad0n = 1'b0; afsn = 1'b0;
         settle(2000);
         $display("RESULT neg words=%0d errors=%0d done=%0d", words_n, errors_n, done_n);
         if (!done_n)
            $fatal(1, "tb_sport t3: negative control did not finish");
         if (errors_n == 32'd0)
            $fatal(1, "tb_sport t3: injected error went undetected");
         prbs_state = PRBS31_SEED;
         for (wi = 0; wi < WORDS; wi = wi + 1) begin
            cur = prbs31_word(prbs_state);
            prbs_state = prbs31_advance(prbs_state);
            send_word_w(cur);
         end
         @(posedge aclk); ad0w = 2'b00; afsw = 2'b00;
         settle(300000);
         $display("RESULT wrapper pass_seen=%0d", wrapper_pass);
         if (!wrapper_pass)
            $fatal(1, "tb_sport t4: two-lane wrapper never reported PASS");
   
      $display("tb_sport: PASS");
      $finish;
   end
endmodule
