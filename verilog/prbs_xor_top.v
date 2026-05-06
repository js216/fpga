// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jakob Kastelic
module prbs_xor_top (
      input  clk,
      input  rx,
      output tx
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

   reg [16:0] burst_count;
   initial burst_count = 17'd0;
   always @(posedge clk) begin
      if (rx_ready && rx_data == 8'h62)
         burst_count <= 17'd65536;
      else if (burst_count != 17'd0)
         burst_count <= burst_count - 17'd1;
      else
         burst_count <= 17'd0;
   end

   wire clk_en = clk_en_q | (burst_count != 17'd0);

   wire [31:0] state;
   wire [31:0] checksum;

   prbs_xor u_prbs (
      .clk(clk),
      .rst_n(rst_n),
      .clear(1'b0),
      .clk_en(clk_en),
      .state(state),
      .checksum(checksum)
   );

   // Print FSM: latch checksum on 'p' (8'h70), then stream eight
   // ASCII hex digits MSB-first, followed by CR (8'h0d) and LF
   // (8'h0a). print_idx == 4'd10 means idle.
   reg [31:0] checksum_q;
   reg  [3:0] print_idx;
   reg  [7:0] tx_data;
   reg        tx_start;
   wire       tx_busy;
   wire       tx_ready = ~tx_busy;

   initial begin
      checksum_q = 32'd0;
      print_idx  = 4'd10;
      tx_data    = 8'd0;
      tx_start   = 1'b0;
   end

   function [7:0] nib_to_ascii;
      input [3:0] nib;
      begin
         nib_to_ascii = (nib < 4'd10) ? (8'h30 + nib)
                                      : (8'h61 + nib - 4'd10);
      end
   endfunction

   reg [3:0] cur_nib;
   always @(*) begin
      case (print_idx)
         4'd0: cur_nib = checksum_q[31:28];
         4'd1: cur_nib = checksum_q[27:24];
         4'd2: cur_nib = checksum_q[23:20];
         4'd3: cur_nib = checksum_q[19:16];
         4'd4: cur_nib = checksum_q[15:12];
         4'd5: cur_nib = checksum_q[11: 8];
         4'd6: cur_nib = checksum_q[ 7: 4];
         4'd7: cur_nib = checksum_q[ 3: 0];
         default: cur_nib = 4'd0;
      endcase
   end

   always @(posedge clk) begin
      tx_start <= 1'b0;
      if (rx_ready && rx_data == 8'h70) begin
         checksum_q <= checksum;
         print_idx  <= 4'd0;
      end else if (print_idx != 4'd10 && tx_ready && !tx_start) begin
         case (print_idx)
            4'd8: tx_data <= 8'h0d;
            4'd9: tx_data <= 8'h0a;
            default: tx_data <= nib_to_ascii(cur_nib);
         endcase
         tx_start  <= 1'b1;
         print_idx <= print_idx + 4'd1;
      end
   end

   uart_tx u_tx (
      .clk  (clk),
      .start(tx_start),
      .data (tx_data),
      .tx   (tx),
      .busy (tx_busy)
   );

endmodule
