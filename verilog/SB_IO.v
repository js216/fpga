module SB_IO #(
      parameter [5:0] PIN_TYPE    = 6'b000000,
      parameter [0:0] NEG_TRIGGER = 1'b0
   ) (
      inout  PACKAGE_PIN,
      input  OUTPUT_CLK,
      input  OUTPUT_ENABLE,
      input  D_OUT_0,
      output D_IN_0
   );
   initial begin
      if (!(PIN_TYPE === 6'b100101 && NEG_TRIGGER === 1'b1)) begin
         $display("ERROR SB_IO sim model only supports PIN_TYPE=100101 NEG_TRIGGER=1, got %b %b",
                  PIN_TYPE, NEG_TRIGGER);
         $finish;
      end
   end
   reg dout_reg;
   initial dout_reg = 1'b0;
   always @(negedge OUTPUT_CLK)
      dout_reg <= D_OUT_0;
   assign PACKAGE_PIN = OUTPUT_ENABLE ? dout_reg : 1'bz;
   assign D_IN_0 = PACKAGE_PIN;
endmodule
