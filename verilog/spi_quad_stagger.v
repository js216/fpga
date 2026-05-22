/* 4-lane QSPI slave with staggered IO[3] launch.
 *
 * Production spi.v g_quad has all four IOB output flops clocked off
 * the same sclk_g, so on the 0→B and 0→F within-byte nibble
 * transitions IO[0]+IO[1]+IO[3] all transition LOW→HIGH at the same
 * negedge.  The in-FPGA LA confirmed this is an SSO/IO-bounce on the
 * slave→master IO lines, not an FPGA state-machine bug.
 *
 * Here we drive IO[3] off sclk_g delayed by 2 pass-through LUT4s
 * (~3 ns), so its LOW→HIGH transition starts ~3 ns after IO[0],
 * IO[1], IO[2]'s.  At any given instant only ≤2 IOs are transitioning
 * simultaneously, reducing the SSO peak.  The master still samples
 * at the same posedge — IO[3] just needs to settle within
 * (half_period - 3 ns - setup_time), which gives plenty of margin
 * at SCLK rates up to ~100 MHz (5 ns half-period - 3 ns stagger - 1
 * ns setup = 1 ns; tight but theoretically workable).
 *
 * Trades a couple ns of SCLK setup-margin headroom on IO[3] for
 * relief from the SSO bounce that the static-glitch filter masked
 * indirectly by delaying everything by ~5 ns.  This version doesn't
 * have the SCLK filter — all the slack is on IO[3]. */
module spi_quad_stagger (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );

   /* ---------- SCLK distribution (no filter) ---------- */
   wire sclk_g;
   SB_GB sclk_gbuf (
      .USER_SIGNAL_TO_GLOBAL_BUFFER(sclk),
      .GLOBAL_BUFFER_OUTPUT(sclk_g)
   );

   /* IO[3] gets a delayed copy of sclk_g via a 2-LUT chain. */
   wire sclk_g_d1, sclk_g_io3;
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      io3_dly1 (.O(sclk_g_d1),  .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk_g));
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      io3_dly2 (.O(sclk_g_io3), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk_g_d1));

   /* ---------- CS debounce ---------- */
   localparam CS_HIGH_RESET_BITS = 2;
   reg [CS_HIGH_RESET_BITS-1:0] cs_high_count;
   reg                          cs_debounced_high;
   initial cs_high_count     = {CS_HIGH_RESET_BITS{1'b0}};
   initial cs_debounced_high = 1'b1;
   always @(negedge cs_n or posedge clk) begin
      if (!cs_n) begin
         cs_high_count     <= {CS_HIGH_RESET_BITS{1'b0}};
         cs_debounced_high <= 1'b0;
      end else if (!cs_debounced_high) begin
         cs_high_count <= cs_high_count +
                          {{(CS_HIGH_RESET_BITS-1){1'b0}}, 1'b1};
         if (cs_high_count[0])
            cs_debounced_high <= 1'b1;
      end
   end

   /* ---------- Counter emit ---------- */
   reg [5:0] prefix_cnt;
   reg       data_phase;
   reg       phase_lo;
   reg [7:0] data_byte;
   reg [3:0] dout_quad;
   initial prefix_cnt = 6'd0;
   initial data_phase = 1'b0;
   initial phase_lo   = 1'b0;
   initial data_byte  = 8'd0;
   initial dout_quad  = 4'd0;

   wire oe = ~cs_debounced_high && data_phase;

   always @(posedge cs_debounced_high or negedge sclk_g) begin
      if (cs_debounced_high) begin
         prefix_cnt <= 6'd0;
         data_phase <= 1'b0;
         phase_lo   <= 1'b0;
         data_byte  <= 8'd0;
         dout_quad  <= 4'd0;
      end else if (!data_phase) begin
         prefix_cnt <= prefix_cnt + 6'd1;
         if (prefix_cnt == 6'd37)
            data_phase <= 1'b1;
         dout_quad <= 4'd0;
      end else begin
         if (!phase_lo) begin
            dout_quad <= data_byte[7:4];
            phase_lo  <= 1'b1;
         end else begin
            dout_quad <= data_byte[3:0];
            phase_lo  <= 1'b0;
            data_byte <= data_byte + 8'd1;
         end
      end
   end

   /* ---------- IOB outputs ----------
    * io[0..2] on sclk_g, io[3] on sclk_g_io3 (= sclk_g + 2 LUT delays). */
   wire [3:0] io_d_in_unused;
   SB_IO #(.PIN_TYPE(6'b100101), .NEG_TRIGGER(1'b1)) iob_0 (
      .PACKAGE_PIN(io[0]), .OUTPUT_CLK(sclk_g),
      .OUTPUT_ENABLE(oe), .D_OUT_0(dout_quad[0]),
      .D_IN_0(io_d_in_unused[0]));
   SB_IO #(.PIN_TYPE(6'b100101), .NEG_TRIGGER(1'b1)) iob_1 (
      .PACKAGE_PIN(io[1]), .OUTPUT_CLK(sclk_g),
      .OUTPUT_ENABLE(oe), .D_OUT_0(dout_quad[1]),
      .D_IN_0(io_d_in_unused[1]));
   SB_IO #(.PIN_TYPE(6'b100101), .NEG_TRIGGER(1'b1)) iob_2 (
      .PACKAGE_PIN(io[2]), .OUTPUT_CLK(sclk_g),
      .OUTPUT_ENABLE(oe), .D_OUT_0(dout_quad[2]),
      .D_IN_0(io_d_in_unused[2]));
   SB_IO #(.PIN_TYPE(6'b100101), .NEG_TRIGGER(1'b1)) iob_3 (
      .PACKAGE_PIN(io[3]), .OUTPUT_CLK(sclk_g_io3),
      .OUTPUT_ENABLE(oe), .D_OUT_0(dout_quad[3]),
      .D_IN_0(io_d_in_unused[3]));

endmodule
