module spi #(
      parameter LANES = 1
   ) (
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   reg [7:0] data_byte;
   initial data_byte = 8'd0;
   wire [3:0] dout_lane;
   wire oe = ~cs_n;
   generate if (LANES == 4) begin : g_quad
      reg phase;
      initial phase = 1'b0;
      always @(posedge cs_n or posedge sclk) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 1'b0;
         end else begin
            phase <= ~phase;
            if (phase) data_byte <= data_byte + 8'd1;
         end
      end
      assign dout_lane = phase ? data_byte[7:4] : data_byte[3:0];
   end else begin : g_one
      reg [2:0] phase;
      initial phase = 3'd0;
      always @(posedge cs_n or posedge sclk) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 3'd0;
         end else begin
            phase <= phase + 3'd1;
            if (phase == 3'd7) data_byte <= data_byte + 8'd1;
         end
      end
      assign dout_lane[0] = data_byte[3'd7 - phase];
      assign dout_lane[1] = data_byte[3'd7 - phase];
      assign dout_lane[2] = 1'b0;
      assign dout_lane[3] = 1'b0;
   end endgenerate
   genvar g;
   generate for (g = 0; g < 4; g = g + 1) begin : g_io
      SB_IO #(
         .PIN_TYPE(6'b100101),
         .NEG_TRIGGER(1'b1)
      ) iob (
         .PACKAGE_PIN(io[g]),
         .OUTPUT_CLK(sclk),
         .OUTPUT_ENABLE(oe),
         .D_OUT_0(dout_lane[g])
      );
   end endgenerate
endmodule
