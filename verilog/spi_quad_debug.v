module spi_quad_debug #(
      parameter CLKS_PER_BIT = 104
   ) (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx
   );
   reg [7:0] q_data_byte;
   reg q_phase;
   reg [3:0] q_dout_quad;
   wire [3:0] q_next_byte_upper = q_data_byte[7:4] + {3'b000, &q_data_byte[3:0]};
   wire q_oe = ~cs_n;

   initial begin
      q_data_byte = 8'd0;
      q_phase = 1'b0;
      q_dout_quad = 4'd0;
   end

   always @(posedge cs_n or posedge sclk) begin
      if (cs_n) begin
         q_phase <= 1'b0;
      end else begin
         q_dout_quad <= q_phase ? q_next_byte_upper : q_data_byte[3:0];
         q_phase <= ~q_phase;
         if (q_phase)
            q_data_byte <= q_data_byte + 8'd1;
      end
   end

   genvar qg;
   wire [3:0] q_io_sample;
   generate for (qg = 0; qg < 4; qg = qg + 1) begin : q_io
      SB_IO #(
         .PIN_TYPE(6'b100101),
         .NEG_TRIGGER(1'b1)
      ) iob (
         .PACKAGE_PIN(io[qg]),
         .OUTPUT_CLK(sclk),
         .OUTPUT_ENABLE(q_oe),
         .D_OUT_0(q_dout_quad[qg]),
         .D_IN_0(q_io_sample[qg])
      );
   end endgenerate

   reg [7:0]   frame_count;
   reg [7:0]   last_frame_count;
   reg [15:0]  edge_count;
   reg [15:0]  last_edges;
   reg [5:0]   nibble_count;
   reg [127:0] nibbles;
   reg [127:0] last_nibbles;
   reg         active;
   reg         frame_toggle;

   initial begin
      frame_count = 8'd0;
      last_frame_count = 8'd0;
      edge_count = 16'd0;
      last_edges = 16'd0;
      nibble_count = 6'd0;
      nibbles = 128'd0;
      last_nibbles = 128'd0;
      active = 1'b0;
      frame_toggle = 1'b0;
   end

   always @(negedge cs_n)
      frame_count <= frame_count + 8'd1;

   always @(posedge cs_n or posedge sclk) begin
      if (cs_n) begin
         active <= 1'b0;
         edge_count <= 16'd0;
         nibble_count <= 6'd0;
         nibbles <= 128'd0;
      end else begin
         if (!active) begin
            active <= 1'b1;
            edge_count <= 16'd1;
            nibble_count <= 6'd1;
            nibbles <= {124'd0, q_io_sample};
         end else begin
            edge_count <= edge_count + 16'd1;
            if (nibble_count < 6'd32) begin
               nibbles <= {nibbles[123:0], q_io_sample};
               nibble_count <= nibble_count + 6'd1;
            end
         end
      end
   end

   always @(posedge cs_n) begin
      if (edge_count != 16'd0) begin
         last_frame_count <= frame_count;
         last_edges <= edge_count;
         last_nibbles <= nibbles;
         frame_toggle <= ~frame_toggle;
      end
   end

   reg pending;
   reg frame_toggle_meta;
   reg frame_toggle_seen;
   reg [5:0] char_idx;
   reg tx_start;
   reg [7:0] tx_data;
   wire tx_busy;
   
   initial begin
      pending = 1'b0;
      frame_toggle_meta = 1'b0;
      frame_toggle_seen = 1'b0;
      char_idx = 6'd0;
      tx_start = 1'b0;
      tx_data = 8'h00;
   end
   
   always @(posedge clk) begin
      tx_start <= 1'b0;
      frame_toggle_meta <= frame_toggle;
      if (frame_toggle_meta != frame_toggle_seen && !pending && char_idx == 6'd0) begin
         pending <= 1'b1;
         frame_toggle_seen <= frame_toggle_meta;
      end
      if (pending && !tx_busy && !tx_start) begin
         tx_data <= quad_debug_char(char_idx);
         tx_start <= 1'b1;
         if (char_idx == 6'd49) begin
            pending <= 1'b0;
            char_idx <= 6'd0;
         end else begin
            char_idx <= char_idx + 6'd1;
         end
      end
   end
   
   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk(clk),
      .start(tx_start),
      .data(tx_data),
      .tx(tx),
      .busy(tx_busy)
   );
   
   function [7:0] quad_hex_digit;
      input [3:0] n;
      begin
         quad_hex_digit = (n < 4'd10) ? (8'h30 + {4'd0, n})
                                      : (8'h57 + {4'd0, n});
      end
   endfunction
   
   function [3:0] quad_sample_nibble;
      input [5:0] idx;
      begin
         quad_sample_nibble = last_nibbles[(31 - idx) * 4 +: 4];
      end
   endfunction
   
   function [7:0] quad_debug_char;
      input [5:0] idx;
      begin
         case (idx)
            6'd0:  quad_debug_char = "Q";
            6'd1:  quad_debug_char = " ";
            6'd2:  quad_debug_char = "F";
            6'd3:  quad_debug_char = "=";
            6'd4:  quad_debug_char = quad_hex_digit(last_frame_count[7:4]);
            6'd5:  quad_debug_char = quad_hex_digit(last_frame_count[3:0]);
            6'd6:  quad_debug_char = " ";
            6'd7:  quad_debug_char = "E";
            6'd8:  quad_debug_char = "=";
            6'd9:  quad_debug_char = quad_hex_digit(last_edges[15:12]);
            6'd10: quad_debug_char = quad_hex_digit(last_edges[11:8]);
            6'd11: quad_debug_char = quad_hex_digit(last_edges[7:4]);
            6'd12: quad_debug_char = quad_hex_digit(last_edges[3:0]);
            6'd13: quad_debug_char = " ";
            6'd14: quad_debug_char = "N";
            6'd15: quad_debug_char = "=";
            6'd48: quad_debug_char = 8'h0d;
            6'd49: quad_debug_char = 8'h0a;
            default: begin
               if (idx >= 6'd16 && idx < 6'd48)
                  quad_debug_char = quad_hex_digit(quad_sample_nibble(idx - 6'd16));
               else
                  quad_debug_char = 8'h00;
            end
         endcase
      end
   endfunction
endmodule
