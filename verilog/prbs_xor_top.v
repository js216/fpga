// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module prbs_xor_top (
      input clk,
      input rx
   );

   wire       rx_ready;
   wire [7:0] rx_data;

   uart_rx u_rx (
      .clk(clk),
      .rx(rx),
      .ready(rx_ready),
      .data(rx_data)
   );

   reg rst_n;
   initial rst_n = 1'b1;
   always @(posedge clk) begin
      if (rx_ready && rx_data == 8'h72)
         rst_n <= 1'b0;
      else
         rst_n <= 1'b1;
   end

   reg clk_en_q;
   initial clk_en_q = 1'b0;
   always @(posedge clk) begin
      if (rx_ready && rx_data == 8'h73)
         clk_en_q <= 1'b1;
      else
         clk_en_q <= 1'b0;
   end

   wire [31:0] state;
   wire [31:0] checksum;

   prbs_xor u_prbs (
      .clk(clk),
      .rst_n(rst_n),
      .clear(1'b0),
      .clk_en(clk_en_q),
      .state(state),
      .checksum(checksum)
   );

endmodule
