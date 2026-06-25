module SB_IO #(
      parameter [5:0] PIN_TYPE    = 6'b000000,
      parameter [0:0] PULLUP      = 1'b0,
      parameter [0:0] NEG_TRIGGER = 1'b0
   ) (
      inout  PACKAGE_PIN,
      input  OUTPUT_CLK,
      input  OUTPUT_ENABLE,
      input  D_OUT_0,
      output D_IN_0
   );
   initial begin
      if (!((PIN_TYPE === 6'b101001 && NEG_TRIGGER === 1'b0) ||
            (PIN_TYPE === 6'b100101))) begin
         $display("ERROR SB_IO sim model only supports PIN_TYPE=101001 NEG_TRIGGER=0 or PIN_TYPE=100101, got %b %b",
                  PIN_TYPE, NEG_TRIGGER);
         $finish;
      end
   end
   reg dout_reg;
   initial dout_reg = 1'b0;
   generate if (NEG_TRIGGER) begin : g_neg
      always @(negedge OUTPUT_CLK) begin
         dout_reg <= D_OUT_0;
      end
   end else begin : g_pos
      always @(posedge OUTPUT_CLK) begin
         dout_reg <= D_OUT_0;
      end
   end endgenerate
   wire dout_selected = (PIN_TYPE === 6'b100101) ? dout_reg : D_OUT_0;
   assign PACKAGE_PIN = OUTPUT_ENABLE ? dout_selected : 1'bz;
   assign D_IN_0 = (PULLUP && (PACKAGE_PIN === 1'bz)) ? 1'b1 : PACKAGE_PIN;
endmodule

/* verilator lint_off DECLFILENAME */
module SB_LUT4 #(
      parameter [15:0] LUT_INIT = 16'h0000
   ) (
      output O,
      input  I0,
      input  I1,
      input  I2,
      input  I3
   );
   wire [7:0] s3 = I3 ? LUT_INIT[15:8] : LUT_INIT[7:0];
   wire [3:0] s2 = I2 ? s3[7:4] : s3[3:0];
   wire [1:0] s1 = I1 ? s2[3:2] : s2[1:0];
   assign #1 O = I0 ? s1[1] : s1[0];
endmodule

/* verilator lint_off DECLFILENAME */
module SB_GB (
      input  USER_SIGNAL_TO_GLOBAL_BUFFER,
      output GLOBAL_BUFFER_OUTPUT
   );
   assign #1 GLOBAL_BUFFER_OUTPUT = USER_SIGNAL_TO_GLOBAL_BUFFER;
endmodule
/* verilator lint_on DECLFILENAME */
