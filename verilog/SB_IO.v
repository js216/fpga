module SB_IO #(
      parameter [5:0] PIN_TYPE    = 6'b000000,
      parameter [0:0] PULLUP      = 1'b0,
      parameter [0:0] NEG_TRIGGER = 1'b0
   ) (
      inout  PACKAGE_PIN,
      input  INPUT_CLK,
      input  OUTPUT_CLK,
      input  OUTPUT_ENABLE,
      input  D_OUT_0,
      input  D_OUT_1,
      output D_IN_0
   );
   initial begin
      if (!((PIN_TYPE === 6'b101001 && NEG_TRIGGER === 1'b0) ||
            (PIN_TYPE === 6'b100101) ||
            (PIN_TYPE === 6'b100001) ||
            (PIN_TYPE === 6'b000000) ||
            (PIN_TYPE === 6'b010100) ||
            (PIN_TYPE === 6'b010000) ||
            (PIN_TYPE === 6'b110101))) begin
         $display("ERROR SB_IO sim model only supports PIN_TYPE=101001 NEG_TRIGGER=0, 100101, 100001, or 110101, got %b %b",
                  PIN_TYPE, NEG_TRIGGER);
         $finish;
      end
   end
   /* DDR output flops (PIN_TYPE=100001).  With NEG_TRIGGER=1:
    *   dout_q_0 captured at negedge OUTPUT_CLK,
    *   dout_q_1 captured at posedge OUTPUT_CLK.
    * Pad outputs dout_q_1 while OUTPUT_CLK high, dout_q_0 while low. */
   reg dout_reg;
   reg dout_q_0_ddr;
   reg dout_q_1_ddr;
   reg oe_reg;
   initial dout_reg     = 1'b0;
   initial dout_q_0_ddr = 1'b0;
   initial dout_q_1_ddr = 1'b0;
   initial oe_reg       = 1'b0;
   generate if (NEG_TRIGGER) begin : g_neg
      always @(negedge OUTPUT_CLK) begin
         dout_reg <= D_OUT_0;
         dout_q_0_ddr <= D_OUT_0;
         oe_reg <= OUTPUT_ENABLE;
      end
      always @(posedge OUTPUT_CLK)
         dout_q_1_ddr <= D_OUT_1;
   end else begin : g_pos
      always @(posedge OUTPUT_CLK) begin
         dout_reg <= D_OUT_0;
         dout_q_0_ddr <= D_OUT_0;
         oe_reg <= OUTPUT_ENABLE;
      end
      always @(negedge OUTPUT_CLK)
         dout_q_1_ddr <= D_OUT_1;
   end endgenerate
   /* DDR dout selection per yosys cells_sim.v:
    *   dout = (OUTPUT_CLK ^ NEG_TRIGGER) ? dout_q_0 : dout_q_1.
    * With NEG_TRIGGER=1: clk high → dout_q_1 (latched at posedge),
    *                     clk low  → dout_q_0 (latched at negedge).
    * With NEG_TRIGGER=0: clk high → dout_q_0, clk low → dout_q_1. */
   wire dout_ddr = (OUTPUT_CLK ^ NEG_TRIGGER) ? dout_q_0_ddr
                                              : dout_q_1_ddr;
   wire dout_selected = (PIN_TYPE === 6'b100001) ? dout_ddr :
                        (PIN_TYPE === 6'b100101 ||
                         PIN_TYPE === 6'b110101) ? dout_reg : D_OUT_0;
   wire oe_selected = (PIN_TYPE === 6'b110101) ? oe_reg : OUTPUT_ENABLE
                       | (PIN_TYPE === 6'b010100) | (PIN_TYPE === 6'b010000);
   generate if (PIN_TYPE !== 6'b000000) begin : g_pad_drive
   assign PACKAGE_PIN = oe_selected ? dout_selected : 1'bz;
   end endgenerate
   /* Registered input (PIN_TYPE=000000): pin captured by INPUT_CLK,
    * NEG_TRIGGER selects the capture edge. */
   reg din_q;
   initial din_q = 1'b0;
   generate if (NEG_TRIGGER) begin : g_din_neg
      always @(negedge INPUT_CLK) din_q <= PACKAGE_PIN;
   end else begin : g_din_pos
      always @(posedge INPUT_CLK) din_q <= PACKAGE_PIN;
   end endgenerate
   wire din_raw = (PULLUP && (PACKAGE_PIN === 1'bz)) ? 1'b1 : PACKAGE_PIN;
   assign D_IN_0 = (PIN_TYPE === 6'b000000) ? din_q : din_raw;
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
