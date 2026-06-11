// SPDX-License-Identifier: MIT
// PRBS-31 SPORT data transmitter clocked and framed by the DSP.

module sport_tx_from_dsp_clk_chan #(
      parameter DIRECT_OUT = 0,
      parameter EARLY_BIT = 0
   )(
      (* noglobal *) input  run,
      input  aclk_in,
      input  afs_in,
      output ad0_out
   );
   localparam [30:0] PRBS31_SEED = 31'h7fffffff;
   localparam [5:0] START_DELAY_BITS = 6'd0;

   reg [30:0] lfsr = PRBS31_SEED;
   reg [4:0]  bitpos = 5'd0;
   reg [5:0]  start_delay = 6'd0;
   reg        active = 1'b0;
   reg        ready = 1'b0;
   reg        afs_d = 1'b0;
   reg        ad0_p = 1'b0;
   reg        run_seen = 1'b0;

   function prbs_next_bit;
      input [30:0] state;
      begin
         prbs_next_bit = state[30] ^ state[27];
      end
   endfunction

   wire bit_next = prbs_next_bit(lfsr);
   wire [30:0] lfsr_adv = {lfsr[29:0], bit_next};
   wire bit_after = prbs_next_bit(lfsr_adv);
   wire afs_rise = afs_in && !afs_d;
   wire run_active = run_seen;

   task reset_stream;
      begin
         lfsr <= PRBS31_SEED;
         bitpos <= 5'd0;
         start_delay <= 6'd0;
         active <= 1'b0;
         ready <= 1'b0;
         afs_d <= 1'b0;
         ad0_p <= 1'b0;
      end
   endtask

   always @(posedge aclk_in) begin
      afs_d <= afs_in;
      if (run) begin
         run_seen <= 1'b1;
      end

      if (!run_active) begin
         reset_stream();
      end else if (afs_rise && !active) begin
         ready <= 1'b1;
         active <= 1'b1;
         bitpos <= 5'd0;
         start_delay <= START_DELAY_BITS;
         ad0_p <= bit_next;
      end else if (!ready) begin
         ready <= 1'b1;
         ad0_p <= bit_next;
      end else if (active && start_delay != 6'd0) begin
         start_delay <= start_delay - 6'd1;
         ad0_p <= bit_next;
      end else if (active) begin
         if (EARLY_BIT)
            ad0_p <= bit_next;
         else
            ad0_p <= bit_after;
         lfsr <= lfsr_adv;
         if (bitpos == 5'd31) begin
            bitpos <= 5'd0;
         end else begin
            bitpos <= bitpos + 5'd1;
         end
      end else begin
         ad0_p <= bit_next;
      end
   end

   generate
   if (DIRECT_OUT) begin : gen_direct_out
`ifdef SPORT_TX_FORCE_ZERO
   assign ad0_out = 1'b0;
`elsif SPORT_TX_FORCE_ONE
   assign ad0_out = 1'b1;
`else
   assign ad0_out = ad0_p;
`endif
   end else begin : gen_sb_io
`ifdef SPORT_TX_POSEDGE_OUT
   localparam NEG_TRIGGER_OUT = 1'b0;
`else
   localparam NEG_TRIGGER_OUT = 1'b1;
`endif

   SB_IO #(.PIN_TYPE(6'b010100), .NEG_TRIGGER(NEG_TRIGGER_OUT)) ad0_io (
      .PACKAGE_PIN(ad0_out),
      .OUTPUT_CLK(aclk_in),
`ifdef SPORT_TX_FORCE_ZERO
      .D_OUT_0(1'b0)
`elsif SPORT_TX_FORCE_ONE
      .D_OUT_0(1'b1)
`else
      .D_OUT_0(ad0_p)
`endif
   );
   end
   endgenerate
endmodule

module sport_tx_from_dsp_clk #(
      parameter N = 1,
      parameter DIRECT_MASK = 0,
      parameter EARLY_MASK = 0
   )(
      (* noglobal *) input  run,
      input  [N-1:0] aclk_in,
      input  [N-1:0] afs_in,
      output [N-1:0] ad0_out
   );
   genvar i;
   generate
      for (i = 0; i < N; i = i + 1) begin : lanes
         sport_tx_from_dsp_clk_chan #(
            .DIRECT_OUT((DIRECT_MASK >> i) & 1),
            .EARLY_BIT((EARLY_MASK >> i) & 1)
         ) lane (
            .run(run),
            .aclk_in(aclk_in[i]),
            .afs_in(afs_in[i]),
            .ad0_out(ad0_out[i])
         );
      end
   endgenerate
endmodule

module sport_tx_from_dsp_clk_1 (
      (* noglobal *) input run,
      input aclk_in,
      input afs_in,
      output ad0_out
   );
   sport_tx_from_dsp_clk_chan #(
      .DIRECT_OUT(1),
      .EARLY_BIT(0)
   ) lane0 (
      .run(run),
      .aclk_in(aclk_in),
      .afs_in(afs_in),
      .ad0_out(ad0_out)
   );
endmodule
