`ifdef YOSYS
// Yosys (used by the SymbiYosys formal flow) cannot legalise the
// `inout PACKAGE_PIN` port across `smt2` export, and does not
// parse the `assign (weak0, weak1) ...` strength syntax that the
// Verilator sim path uses to model the iCE40 IOB's weak
// pull-up.  The formal flow exercises gpio's FSM, handshake and
// drive-commit properties, none of which depend on the
// silicon-level race between an external driver and the
// internal pull-up; a non-bidirectional stub that drives
// PACKAGE_PIN as an output and feeds D_OUT_0 straight back to
// D_IN_0 is sufficient to keep the formal flow building while
// the bench (synthesis) and the testbench (Verilator) get the
// full behavioural model below.
module SB_IO #(
      parameter [5:0] PIN_TYPE    = 6'b000000,
      parameter [0:0] PULLUP      = 1'b0,
      parameter [0:0] NEG_TRIGGER = 1'b0
   ) (
      output PACKAGE_PIN,
      input  OUTPUT_CLK,
      input  OUTPUT_ENABLE,
      input  D_OUT_0,
      output D_IN_0
   );
   assign PACKAGE_PIN = OUTPUT_ENABLE ? D_OUT_0 : 1'b0;
   assign D_IN_0      = OUTPUT_ENABLE ? D_OUT_0 : 1'b1;
endmodule
`else
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
            (PIN_TYPE === 6'b100101 && NEG_TRIGGER === 1'b1))) begin
         $display("ERROR SB_IO sim model only supports PIN_TYPE=101001 or PIN_TYPE=100101 NEG_TRIGGER=1, got %b %b",
                  PIN_TYPE, NEG_TRIGGER);
         $finish;
      end
   end
   reg dout_reg;
   initial dout_reg = 1'b0;
   always @(negedge OUTPUT_CLK)
      dout_reg <= D_OUT_0;
   wire dout_selected = (PIN_TYPE === 6'b100101) ? dout_reg : D_OUT_0;
   assign PACKAGE_PIN = OUTPUT_ENABLE ? dout_selected : 1'bz;
   // Behavioural pull-up: when the package pin is left high-impedance
   // by every driver on the inout net, the iCE40 IOB's weak internal
   // pull-up wins.  The sim attaches a non-strength pull only on the
   // captured D_IN_0 side so the testbench's `assign gpio_line[i] =
   // ext_en[i] ? ext_drv[i] : 1'bz;` continues to race the SB_IO
   // output exactly as in silicon: whoever drives takes the line,
   // and when both let go the pull-up resolves the read to 1.
   wire d_in_pulled;
   assign (weak0, weak1) d_in_pulled = PULLUP ? 1'b1 : 1'bz;
   assign d_in_pulled = PACKAGE_PIN;
   assign D_IN_0 = d_in_pulled;
endmodule
`endif
