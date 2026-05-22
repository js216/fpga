module spi #(
      parameter LANES = 1,
      parameter START_DELAY_CLKS = 0,
      /* Accepted for testbench compatibility, currently unused. */
      parameter FRAME_MODE = 0
   ) (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   /* SCLK input glitch filter: short HIGH bounces on the SCLK input
    * (coupled-back from adjacent IO[0]+IO[1]+IO[3] pad transitions
    * on the iCEstick TQ144 package pins 47/44/48 when 3 data lines
    * go LOW→HIGH together — happens on the 0→B and 0→F within-byte
    * nibble transitions) can make the FPGA register a spurious
    * negedge/posedge pair, dropping a nibble.  Route SCLK through
    * three pass-through LUT4s and AND all four taps; the filtered
    * version only sees HIGH when SCLK has been continuously HIGH
    * through the whole chain (~5 ns).  3 buffers is the empirical
    * sweet spot: 2 still lets glitches through (byte 15 drops at
    * presc=31), 1 lets through everywhere; 3 delivers bit-perfect
    * 2 GiB reads at presc=31 (verified end-to-end with CRC32,
    * 81.9 Mbps sustained).  At presc≤19 the filter delay eats too
    * much SCLK setup margin and the data garbles.  Pushing to 400
    * Mbps requires a different SI mitigation (channel coding to
    * avoid 0→B/0→F transitions, or PCB-level re-pinning so io[3:0]
    * aren't adjacent to sclk).
    *
    * For 1-lane at presc=5 (109 MHz, 4.6 ns half-period), the
    * filter's ~5 ns slave-launch delay would normally eat the
    * master's setup margin.  But running the 1-lane master with
    * SSHIFT=1 delays the master sample by one extra half-cycle
    * (~9.2 ns after the SCLK negedge), comfortably past the
    * slave's filter-delayed drive — so the filter is left
    * unconditional here, keeping 4-lane netlist identical to its
    * previously-verified configuration. */
   wire sclk_d1, sclk_d2, sclk_d3, sclk_d4;
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      sclk_lut1 (.O(sclk_d1), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk));
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      sclk_lut2 (.O(sclk_d2), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk_d1));
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      sclk_lut3 (.O(sclk_d3), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk_d2));
   (* keep *) SB_LUT4 #(.LUT_INIT(16'hff00))
      sclk_lut4 (.O(sclk_d4), .I0(1'b0), .I1(1'b0), .I2(1'b0), .I3(sclk_d3));
   wire sclk_filt_a, sclk_filtered;
   (* keep *) SB_LUT4 #(.LUT_INIT(16'h8000))
      sclk_and_a (.O(sclk_filt_a),
                  .I0(sclk), .I1(sclk_d1), .I2(sclk_d2), .I3(sclk_d3));
   (* keep *) SB_LUT4 #(.LUT_INIT(16'h8888))
      sclk_and_b (.O(sclk_filtered),
                  .I0(sclk_filt_a), .I1(sclk_d4),
                  .I2(1'b0), .I3(1'b0));

   /* Route SCLK through a global buffer for high-fanout
    * distribution.  4-lane uses sclk_filtered (5-ns delay buys
    * setup margin past SSO/IO-bounce settling at presc=31); 1-lane
    * uses raw sclk (filter delay would eat the master setup margin
    * at presc=5 / 109 MHz even with SSHIFT=1). */
   wire sclk_g;
   generate if (LANES == 4) begin : g_sclk_filt
      SB_GB sclk_gbuf (
         .USER_SIGNAL_TO_GLOBAL_BUFFER(sclk_filtered),
         .GLOBAL_BUFFER_OUTPUT(sclk_g)
      );
   end else begin : g_sclk_pass
      SB_GB sclk_gbuf (
         .USER_SIGNAL_TO_GLOBAL_BUFFER(sclk),
         .GLOBAL_BUFFER_OUTPUT(sclk_g)
      );
   end endgenerate
   /* CS debounce: only release the emit reset after CS has been seen
    * HIGH for 2 fabric (`clk`, 12 MHz) cycles.  Prevents spurious
    * resets from short CS glitches that the iCE40 input buffer would
    * otherwise pass through.  Modelled on spi_quad_debug.v. */
   localparam CS_HIGH_RESET_BITS = 2;
   reg [CS_HIGH_RESET_BITS-1:0] cs_high_count;
   reg cs_debounced_high;
   initial cs_high_count = {CS_HIGH_RESET_BITS{1'b0}};
   initial cs_debounced_high = 1'b1;
   always @(negedge cs_n or posedge clk) begin
      if (!cs_n) begin
         cs_high_count <= {CS_HIGH_RESET_BITS{1'b0}};
         cs_debounced_high <= 1'b0;
      end else if (!cs_debounced_high) begin
         cs_high_count <= cs_high_count +
                          {{(CS_HIGH_RESET_BITS-1){1'b0}}, 1'b1};
         if (cs_high_count[0])
            cs_debounced_high <= 1'b1;
      end
   end
   reg [7:0] data_byte;
   reg [15:0] start_delay_count;
   initial data_byte = 8'd0;
   initial start_delay_count = 16'd0;
   wire [3:0] dout_lane;
   wire start_ready_1lane = (START_DELAY_CLKS == 0) ||
                            (start_delay_count >= START_DELAY_CLKS);
   /* For LANES=1, oe gates only on the 1-lane prefix delay.  For
    * LANES=4, oe additionally gates on the per-transaction SCLK
    * counter to keep IO[3:0] tristated during the master's opcode and
    * address phases (where the master drives IO0). */
   wire oe_1lane = ~cs_n && start_ready_1lane;
   wire quad_data_phase_q;
   wire quad_data_phase = (LANES == 4) ? quad_data_phase_q : 1'b1;
   /* For quad mode use the debounced CS, NOT the raw cs_n.  This
    * ensures OE doesn't drop momentarily on short CS-high glitches
    * during a long transfer. */
   wire oe_quad  = ~cs_debounced_high && quad_data_phase;
   wire oe = (LANES == 4) ? oe_quad : oe_1lane;
   always @(posedge cs_n or posedge sclk_g) begin
      if (cs_n)
         start_delay_count <= 16'd0;
      else if (!start_ready_1lane)
         start_delay_count <= start_delay_count + 16'd1;
   end
   generate if (LANES == 4) begin : g_quad
      /* 4-lane counter emit, launched on negedge sclk_g and
       * captured by the IOB on the same negedge.  prefix_cnt
       * counts the first 38 SCLK negedges (opcode 8 + 24-bit
       * address 24 + dummy 8 = 40 prefix SCLK, minus 2 for the
       * fabric→IOB negedge pipeline).  At the 38th negedge the
       * state machine enters the data phase and starts driving
       * HIGH/LOW nibble pairs from data_byte at each subsequent
       * negedge, latched by the IOB on the next negedge and
       * visible to the master on the following posedge. */
      reg [5:0] prefix_cnt;
      reg       data_phase;
      reg       phase_lo;     // 0: next emit is HIGH, 1: next is LOW
      reg [3:0] dout_quad;
      initial prefix_cnt = 6'd0;
      initial data_phase = 1'b0;
      initial phase_lo   = 1'b0;
      initial dout_quad  = 4'd0;
      /* Only drive IO[3:0] during the data phase.  During opcode and
       * address phases the master drives IO0; keeping the slave in
       * HiZ on those phases avoids contention. */
      assign quad_data_phase_q = data_phase;

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

      assign dout_lane = dout_quad;
   end else begin : g_one
      reg [2:0] phase;
      reg dout_one;
      wire [7:0] data_byte_next = data_byte + 8'd1;
      initial phase = 3'd0;
      initial dout_one = 1'b0;
      always @(posedge cs_n or negedge sclk_g) begin
         if (cs_n) begin
            data_byte <= 8'd0;
            phase     <= 3'd0;
            dout_one  <= 1'b0;
         end else if (start_ready_1lane) begin
            if (phase == 3'd7) begin
               data_byte <= data_byte_next;
               phase     <= 3'd0;
               dout_one  <= data_byte_next[3'd7];
            end else begin
               phase    <= phase + 3'd1;
               dout_one <= data_byte[3'd6 - phase];
            end
         end
      end
      assign dout_lane[0] = dout_one;
      assign dout_lane[1] = dout_one;
      assign dout_lane[2] = 1'b0;
      assign dout_lane[3] = 1'b0;
   end endgenerate
   genvar g;
   wire [3:0] io_d_in_unused;
   generate if (LANES == 4) begin : g_quad_io
      /* PIN_TYPE 6'b100101 + NEG_TRIGGER=1: registered D_OUT_0 on
       * negedge sclk_g, combinational OE.  Standard Mode 0 SPI
       * slave timing: launch on negedge, master samples on next
       * posedge.  Combinational OE so the bus releases the moment
       * CS rises even if SCLK has stopped. */
      for (g = 0; g < 4; g = g + 1) begin : g_io
         SB_IO #(
            .PIN_TYPE(6'b100101),
            .NEG_TRIGGER(1'b1)
         ) iob (
            .PACKAGE_PIN(io[g]),
            .OUTPUT_CLK(sclk_g),
            .OUTPUT_ENABLE(oe),
            .D_OUT_0(dout_lane[g]),
            .D_IN_0(io_d_in_unused[g])
         );
      end
   end else begin : g_one_io
      for (g = 0; g < 4; g = g + 1) begin : g_io
         SB_IO #(
            .PIN_TYPE(6'b101001)
         ) iob (
            .PACKAGE_PIN(io[g]),
            .OUTPUT_CLK(sclk_g),
            .OUTPUT_ENABLE(oe),
            .D_OUT_0(dout_lane[g]),
            .D_IN_0(io_d_in_unused[g])
         );
      end
   end endgenerate
endmodule
