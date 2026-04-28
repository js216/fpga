module spi #(
      parameter LANES = 1
   ) (
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   reg [7:0] data_byte;
   initial data_byte = 8'd0;
   generate if (LANES == 4) begin : g_quad
      reg       phase;
      reg [3:0] q;
      initial begin phase = 1'b0; q = 4'd0; end
      always @(posedge sclk or posedge cs_n) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 1'b0;
         end else begin
            phase <= ~phase;
            if (phase) data_byte <= data_byte + 8'd1;
         end
      end
      always @(negedge sclk or posedge cs_n) begin
         if (cs_n) q <= 4'd0;
         else      q <= phase ? data_byte[7:4] : data_byte[3:0];
      end
   end else begin : g_one
      reg [2:0] phase;
      reg       q;
      initial begin phase = 3'd0; q = 1'b0; end
      always @(posedge sclk or posedge cs_n) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 3'd0;
         end else begin
            phase <= phase + 3'd1;
            if (phase == 3'd7) data_byte <= data_byte + 8'd1;
         end
      end
      always @(negedge sclk or posedge cs_n) begin
         if (cs_n) q <= 1'b0;
         else      q <= data_byte[7 - phase];
      end
   end endgenerate
   wire oe = ~cs_n;
   generate if (LANES == 4) begin : g_io_quad
      assign io[0] = oe ? g_quad.q[0] : 1'bz;
      assign io[1] = oe ? g_quad.q[1] : 1'bz;
      assign io[2] = oe ? g_quad.q[2] : 1'bz;
      assign io[3] = oe ? g_quad.q[3] : 1'bz;
   end else begin : g_io_one
      assign io[0] = 1'bz;
      assign io[1] = oe ? g_one.q : 1'bz;
      assign io[2] = 1'bz;
      assign io[3] = 1'bz;
   end endgenerate
endmodule
