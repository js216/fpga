module spi_pin_hiz (
      inout        cs_n,
      inout        sclk,
      inout  [3:0] io
   );
   wire [5:0] unused;
   SB_IO #(.PIN_TYPE(6'b000001)) i_sclk (.PACKAGE_PIN(sclk), .D_IN_0(unused[0]));
   SB_IO #(.PIN_TYPE(6'b000001)) i_cs_n (.PACKAGE_PIN(cs_n), .D_IN_0(unused[1]));
   genvar g;
   generate for (g=0; g<4; g=g+1) begin : g_io
      SB_IO #(.PIN_TYPE(6'b000001)) iob (.PACKAGE_PIN(io[g]), .D_IN_0(unused[g + 2]));
   end endgenerate
endmodule

module spi_pin_walk #(
      parameter BOOT_TICKS = 48_000_000,
      parameter STEP_TICKS = 24_000_000
   ) (
      input        clk,
      inout        cs_n,
      inout        sclk,
      inout  [3:0] io
   );
   reg [27:0] count = 0;
   always @(posedge clk)
      if (count < BOOT_TICKS + 7 * STEP_TICKS - 1)
         count <= count + 1'b1;

   wire drive = count >= BOOT_TICKS;
   wire [27:0] after_boot = count - BOOT_TICKS;
   wire [2:0] slot =
      (after_boot < 1 * STEP_TICKS) ? 3'd0 :
      (after_boot < 2 * STEP_TICKS) ? 3'd1 :
      (after_boot < 3 * STEP_TICKS) ? 3'd2 :
      (after_boot < 4 * STEP_TICKS) ? 3'd3 :
      (after_boot < 5 * STEP_TICKS) ? 3'd4 :
      (after_boot < 6 * STEP_TICKS) ? 3'd5 : 3'd6;

   reg [5:0] mask;
   always @* begin
      case (slot)
         3'd0: mask = 6'h00;
         3'd1: mask = 6'h01;
         3'd2: mask = 6'h02;
         3'd3: mask = 6'h04;
         3'd4: mask = 6'h08;
         3'd5: mask = 6'h10;
         default: mask = 6'h20;
      endcase
   end

   SB_IO #(.PIN_TYPE(6'b100101)) i_sclk (
      .PACKAGE_PIN(sclk), .OUTPUT_CLK(clk),
      .OUTPUT_ENABLE(drive), .D_OUT_0(mask[0])
   );
   SB_IO #(.PIN_TYPE(6'b100101)) i_cs_n (
      .PACKAGE_PIN(cs_n), .OUTPUT_CLK(clk),
      .OUTPUT_ENABLE(drive), .D_OUT_0(mask[1])
   );
   genvar w;
   generate for (w=0; w<4; w=w+1) begin : w_io
      SB_IO #(.PIN_TYPE(6'b100101)) iob (
         .PACKAGE_PIN(io[w]), .OUTPUT_CLK(clk),
         .OUTPUT_ENABLE(drive), .D_OUT_0(mask[w + 2])
      );
   end endgenerate
endmodule

module spi_pin_drive #(
      parameter [5:0] MASK = 6'h00
   ) (
      output       cs_n,
      output       sclk,
      output [3:0] io
   );
   assign sclk  = MASK[0];
   assign cs_n  = MASK[1];
   assign io[0] = MASK[2];
   assign io[1] = MASK[3];
   assign io[2] = MASK[4];
   assign io[3] = MASK[5];
endmodule
