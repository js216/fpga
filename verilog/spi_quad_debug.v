module spi_quad_debug #(
      parameter CLKS_PER_BIT = 104
   ) (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx
   );
   wire sclk_clk;
   SB_GB sclk_gbuf (
      .USER_SIGNAL_TO_GLOBAL_BUFFER(sclk),
      .GLOBAL_BUFFER_OUTPUT(sclk_clk)
   );

   localparam CS_HIGH_RESET_BITS = 2;
   reg [CS_HIGH_RESET_BITS-1:0] q_cs_high_count;
   reg q_cs_debounced_high;
   reg [8:0] q_sample_idx;
   reg [3:0] q_dout_quad;
   wire [8:0] q_next_sample_idx = q_sample_idx + 9'd1;
   wire [3:0] q_next_sample_nibble =
      q_next_sample_idx[0] ? q_next_sample_idx[4:1] :
                             q_next_sample_idx[8:5];
   wire [3:0] q_iob_dout = q_cs_debounced_high ? 4'd0 : q_dout_quad;
   wire q_oe = !q_cs_debounced_high;

   initial begin
      q_cs_high_count = {CS_HIGH_RESET_BITS{1'b0}};
      q_cs_debounced_high = 1'b1;
      q_sample_idx = 9'd0;
      q_dout_quad = 4'd0;
   end

   always @(negedge cs_n or posedge clk) begin
      if (!cs_n) begin
         q_cs_high_count <= {CS_HIGH_RESET_BITS{1'b0}};
         q_cs_debounced_high <= 1'b0;
      end else if (!q_cs_debounced_high) begin
         q_cs_high_count <= q_cs_high_count +
                            {{(CS_HIGH_RESET_BITS-1){1'b0}}, 1'b1};
         if (q_cs_high_count[0])
            q_cs_debounced_high <= 1'b1;
      end
   end

   always @(posedge q_cs_debounced_high or posedge sclk_clk) begin
      if (q_cs_debounced_high) begin
         q_sample_idx <= 9'd0;
         q_dout_quad <= 4'd0;
      end else begin
         q_sample_idx <= q_next_sample_idx;
         q_dout_quad <= q_next_sample_nibble;
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
         .OUTPUT_CLK(sclk_clk),
         .OUTPUT_ENABLE(q_oe),
         .D_OUT_0(q_iob_dout[qg]),
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

   always @(posedge cs_n or posedge sclk_clk) begin
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
