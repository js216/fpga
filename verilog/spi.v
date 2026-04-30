module spi #(
      parameter LANES = 1,
      parameter START_DELAY_CLKS = 0
   ) (
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   reg [7:0] data_byte;
   reg [15:0] start_delay_count;
   initial data_byte = 8'd0;
   initial start_delay_count = 16'd0;
   wire [3:0] dout_lane;
   wire start_ready = (START_DELAY_CLKS == 0) ||
                      (start_delay_count >= START_DELAY_CLKS);
   wire oe = ~cs_n && start_ready;
   always @(posedge cs_n or posedge sclk) begin
      if (cs_n)
         start_delay_count <= 16'd0;
      else if (!start_ready)
         start_delay_count <= start_delay_count + 16'd1;
   end
   generate if (LANES == 4) begin : g_quad
      reg phase;
      reg [3:0] dout_quad;
      wire [3:0] next_byte_upper = data_byte[7:4] + {3'b000, &data_byte[3:0]};
      initial phase = 1'b0;
      initial dout_quad = 4'd0;
      always @(posedge cs_n or posedge sclk) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 1'b0;
            dout_quad <= 4'd0;
         end else if (start_ready) begin
            dout_quad <= phase ? next_byte_upper : data_byte[3:0];
            phase <= ~phase;
            if (phase)
               data_byte <= data_byte + 8'd1;
         end
      end
      assign dout_lane = dout_quad;
   end else begin : g_one
      reg [2:0] phase;
      initial phase = 3'd0;
      always @(posedge cs_n or posedge sclk) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 3'd0;
         end else if (start_ready) begin
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
   wire [3:0] io_d_in_unused;
   generate if (LANES == 4) begin : g_quad_io
      for (g = 0; g < 4; g = g + 1) begin : g_io
         SB_IO #(
            .PIN_TYPE(6'b100101),
            .NEG_TRIGGER(1'b1)
         ) iob (
            .PACKAGE_PIN(io[g]),
            .OUTPUT_CLK(sclk),
            .OUTPUT_ENABLE(oe),
            .D_OUT_0(dout_lane[g]),
            .D_IN_0(io_d_in_unused[g])
         );
      end
   end else begin : g_one_io
      for (g = 0; g < 4; g = g + 1) begin : g_io
         SB_IO #(
            .PIN_TYPE(6'b100101),
            .NEG_TRIGGER(1'b1)
         ) iob (
            .PACKAGE_PIN(io[g]),
            .OUTPUT_CLK(sclk),
            .OUTPUT_ENABLE(oe),
            .D_OUT_0(dout_lane[g]),
            .D_IN_0(io_d_in_unused[g])
         );
      end
   end endgenerate
endmodule
