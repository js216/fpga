`timescale 1ns/1ps

module tb_spi_quad;
   reg       cs_n = 1'b1;
   reg       sclk = 1'b0;
   wire [3:0] io;

   spi #(.LANES(4)) dut (.cs_n(cs_n), .sclk(sclk), .io(io));

   integer    b;
   reg [3:0]  lo, hi;
   reg [7:0]  rx;
   integer    errs;

   initial begin
      errs = 0;
      #20 cs_n = 1'b0;
      #5;
      for (b = 0; b < 256; b = b + 1) begin
         #5 sclk = 1'b1;
         lo = io;
         #5 sclk = 1'b0;
         #5 sclk = 1'b1;
         hi = io;
         #5 sclk = 1'b0;
         rx = {hi, lo};
         if (rx !== b[7:0]) begin
            $display("FAIL byte %0d: got %02x expected %02x", b, rx, b[7:0]);
            errs = errs + 1;
         end
      end
      #5 cs_n = 1'b1;
      #20;
      if (errs == 0) $display("PASS tb_spi_quad: 256 bytes match");
      else           $display("FAIL tb_spi_quad: %0d byte mismatches", errs);
      $finish;
   end
endmodule
