module spi #(
      parameter LANES = 1,
      parameter START_DELAY_CLKS = 0,
      parameter FRAME_MODE = 0,
      parameter DIAG_MODE = 0,
      parameter QUAD_LAUNCH_POSEDGE = 0,
      parameter IOB_OUTPUT_NEGEDGE = 0,
      parameter QUAD_HIGH_LEAD = 0,
      parameter QUAD_SEED_BIAS = 0,
      parameter PRBS_MODE = 0,
      parameter PRBS32_MODE = 0,
      parameter QUAD_REG_OUTPUT = 0
   ) (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   wire sclk_stream = sclk;
   /* IOB output-register launch edge. Default posedge sclk (EVB). The custom
    * build can launch the pad register on the opposite edge to move the data
    * eye relative to the master's sample point. */
   wire iob_output_clk = IOB_OUTPUT_NEGEDGE ? ~sclk : sclk;
   /* verilator lint_off UNUSEDSIGNAL */
   reg [7:0] data_byte;
   /* verilator lint_on UNUSEDSIGNAL */
   /* verilator lint_off SYNCASYNCNET */
   reg [1:0] cs_sync;
   reg [11:0] cs_high_count;
   reg cs_s_d;
   /* verilator lint_off UNUSEDSIGNAL */
   reg cs_async_rst;
   /* verilator lint_on UNUSEDSIGNAL */
   /* verilator lint_on SYNCASYNCNET */
   initial data_byte = 8'd0;
   initial cs_sync = 2'b11;
   initial cs_high_count = 12'hfff;
   initial cs_s_d = 1'b1;
   initial cs_async_rst = 1'b1;
   wire [3:0] dout_lane;
   wire lane_ready;
   /* verilator lint_off UNUSEDSIGNAL */
   wire [3:0] io_d_in;
   /* verilator lint_on UNUSEDSIGNAL */
   wire quad_reseed_gap = &cs_high_count;
   wire oe = !cs_n && lane_ready;
   
   /* verilator lint_off SYNCASYNCNET */
   always @(posedge clk) begin
      cs_sync <= {cs_sync[0], cs_n};
      cs_s_d <= cs_sync[1];
      if (cs_sync[1]) begin
         if (!quad_reseed_gap)
            cs_high_count <= cs_high_count + 12'd1;
      end else begin
         cs_high_count <= 12'd0;
      end
   end
   
   always @(posedge clk or negedge cs_n) begin
      if (!cs_n)
         cs_async_rst <= 1'b0;
      else
         cs_async_rst <= cs_s_d;
   end
   
   /* verilator lint_on SYNCASYNCNET */
   generate if (LANES == 4) begin : g_quad
      if (FRAME_MODE != 0) begin : g_framed
         localparam [5:0] FRAME_PREFIX_CLKS = 6'd40; /* 8 opcode + 24 addr + 8 dummy */
         /* verilator lint_off UNUSEDSIGNAL */
         reg [3:0] quad_dout;
         /* verilator lint_on UNUSEDSIGNAL */
         reg [5:0] frame_edges;
         reg [5:0] frame_fall_edges;
         reg [7:0] frame_addr_lsb;
         reg quad_drive;
         reg quad_low_phase;
         reg payload_active;
         /* 32-bit byte-PRBS state (PRBS32_MODE). Reseeded to a fixed value at the
          * start of each CS read (cs_async_rst); a read holds CS low for its whole
          * length, so the LFSR runs continuously across that read. The emitted
          * payload byte is lfsr_v[7:0]; lfsr32_step8() advances 8 single Galois
          * steps per byte. The master mirrors this exact stream (prbs32 in cli.c
          * and the matrix CRC in the verify). */
         reg [31:0] lfsr_v;
         initial quad_dout = 4'd0;
         initial frame_edges = 6'd0;
         initial frame_fall_edges = 6'd0;
         initial frame_addr_lsb = 8'd0;
         initial quad_drive = 1'b0;
         initial quad_low_phase = 1'b1;
         initial payload_active = 1'b0;
         initial lfsr_v = 32'hFFFFFFFF;
         function [3:0] quad_diag_nibble;
            input [7:0] idx;
            begin
               case (DIAG_MODE)
                  1: quad_diag_nibble = idx[3:0];
                  2: begin
                     case (idx[1:0])
                        2'd0: quad_diag_nibble = 4'h1;
                        2'd1: quad_diag_nibble = 4'h2;
                        2'd2: quad_diag_nibble = 4'h4;
                        default: quad_diag_nibble = 4'h8;
                     endcase
                  end
                  3: quad_diag_nibble = idx[0] ? 4'hf : 4'h0;
                  4: quad_diag_nibble = idx[7:4];
                  5: quad_diag_nibble = idx[0] ? 4'h1 : 4'h0;
                  6: quad_diag_nibble = idx[0] ? 4'h2 : 4'h0;
                  7: quad_diag_nibble = idx[0] ? 4'h4 : 4'h0;
                  8: quad_diag_nibble = idx[0] ? 4'h8 : 4'h0;
                  default: quad_diag_nibble = 4'h0;
               endcase
            end
         endfunction
         function [3:0] quad_payload_nibble;
            input [7:0] byte_value;
            input low_phase;
            begin
               if (DIAG_MODE == 0)
                  quad_payload_nibble = low_phase ? byte_value[3:0]
                                                   : byte_value[7:4];
               else
                  quad_payload_nibble = quad_diag_nibble({byte_value[6:0], low_phase});
            end
         endfunction
         /* prbs8: eight unrolled 8-bit Galois LFSR steps (poly x^8+x^6+x^5+x^4+1,
          * Galois mask 0xB8). It diffuses the byte index into a pseudo-random byte
          * so the streamed payload exercises ~50%-density bit transitions on every
          * lane instead of the smooth counter. The mapping is a fixed bijection of
          * the 8-bit index; the master mirrors it byte-for-byte (prbs8() in cli.c),
          * so the existing 256-periodic CRC/validate path is unchanged. */
         function [7:0] prbs8;
            input [7:0] x;
            integer k;
            reg [7:0] s;
            begin
               s = x;
               for (k = 0; k < 8; k = k + 1)
                  s = (s >> 1) ^ (s[0] ? 8'hB8 : 8'h00);
               prbs8 = s;
            end
         endfunction
         /* Payload byte at a given counter index: PRBS when PRBS_MODE, else the
          * raw incrementing counter. */
         function [7:0] payload_value;
            input [7:0] idx;
            begin
               payload_value = (PRBS_MODE != 0) ? prbs8(idx) : idx;
            end
         endfunction
         /* 32-bit Galois LFSR, eight single right-shift steps (mask 0xA3000000),
          * one byte per emitted byte. Period 2^32-1 bytes (~4 GiB). */
         function [31:0] lfsr32_step8;
            input [31:0] s;
            integer k;
            reg [31:0] t;
            begin
               t = s;
               for (k = 0; k < 8; k = k + 1)
                  t = (t >> 1) ^ (t[0] ? 32'hA3000000 : 32'h0);
               lfsr32_step8 = t;
            end
         endfunction
         always @(posedge cs_async_rst or posedge sclk_stream) begin
            if (cs_async_rst) begin
               frame_edges <= 6'd0;
               frame_addr_lsb <= 8'd0;
               quad_drive <= 1'b0;
            end else if (!cs_n) begin
               if (frame_edges < FRAME_PREFIX_CLKS)
                  frame_edges <= frame_edges + 6'd1;
               if (frame_edges >= 6'd24 && frame_edges < 6'd32)
                  frame_addr_lsb <= {frame_addr_lsb[6:0], io_d_in[0]};
               if (frame_edges == FRAME_PREFIX_CLKS - 6'd1)
                  quad_drive <= 1'b1;
            end
         end
         /* Launch edge for the payload presenter. Default negedge sclk; the custom
          * build can launch a half-cycle earlier (posedge) to place settled data
          * under the master's sample point. */
         wire quad_launch_clk = QUAD_LAUNCH_POSEDGE ? sclk_stream : ~sclk_stream;
         /* Next byte's PRBS32 state (one byte = 8 LFSR steps ahead), used for the
          * QUAD_HIGH_LEAD high nibble. */
         wire [31:0] lfsr_v_next = lfsr32_step8(lfsr_v);
         /* Payload byte for the current index vs the high-lead (next) index. In
          * PRBS32_MODE these come from the running LFSR; otherwise the counter /
          * prbs8 of the index. */
         wire [7:0] pv_seed = (PRBS32_MODE != 0) ? lfsr_v[7:0]
                              : payload_value(frame_addr_lsb + QUAD_SEED_BIAS[7:0]);
         wire [7:0] pv_high = (PRBS32_MODE != 0) ? lfsr_v_next[7:0]
                              : payload_value(data_byte + QUAD_HIGH_LEAD[7:0]);
         wire [7:0] pv_low_next = (PRBS32_MODE != 0) ? lfsr_v_next[7:0]
                              : payload_value(data_byte + 8'd1);
         always @(posedge cs_async_rst or posedge quad_launch_clk) begin
            if (cs_async_rst) begin
               data_byte <= 8'd0;
               lfsr_v <= 32'hFFFFFFFF;
               quad_dout <= quad_payload_nibble(
                               (PRBS32_MODE != 0) ? 8'hFF : payload_value(8'd0), 1'b1);
               frame_fall_edges <= 6'd0;
               quad_low_phase <= 1'b1;
               payload_active <= 1'b0;
            end else if (!cs_n) begin
               if (!payload_active) begin
                  if (frame_fall_edges < FRAME_PREFIX_CLKS - 6'd1) begin
                     frame_fall_edges <= frame_fall_edges + 6'd1;
                  end else if (frame_fall_edges == FRAME_PREFIX_CLKS - 6'd1) begin
                     frame_fall_edges <= FRAME_PREFIX_CLKS;
                     payload_active <= 1'b1;
                     /* QUAD_SEED_BIAS offsets the counter start so that, after the
                      * QUAD_HIGH_LEAD high/low pairing shift, the master sees the
                      * counter value its address selected (bias = -HIGH_LEAD). */
                     data_byte <= frame_addr_lsb + QUAD_SEED_BIAS[7:0];
                     quad_dout <= quad_payload_nibble(pv_seed, 1'b1);
                     quad_low_phase <= 1'b1;
                  end
               end else begin
                  if (quad_low_phase) begin
                     /* QUAD_HIGH_LEAD advances the high nibble by QUAD_HIGH_LEAD bytes
                      * so it pairs correctly with its low nibble at the master
                      * (compensates the per-byte high/low sample offset; see the
                      * DIAG_MODE probe in missions/fpga-mpu-spi-custom.md). In
                      * PRBS32_MODE the high nibble is the next LFSR byte. */
                     quad_dout <= quad_payload_nibble(pv_high, 1'b0);
                     quad_low_phase <= 1'b0;
                  end else begin
                     data_byte <= data_byte + 8'd1;
                     /* Advance the PRBS32 LFSR one byte (8 steps) in lockstep. */
                     if (PRBS32_MODE != 0)
                        lfsr_v <= lfsr_v_next;
                     quad_dout <= quad_payload_nibble(pv_low_next, 1'b1);
                     quad_low_phase <= 1'b1;
                  end
               end
            end
         end
         assign lane_ready = quad_drive;
         assign dout_lane = quad_dout;
      end else begin : g_immediate
         /* verilator lint_off UNUSEDSIGNAL */
         reg [3:0] quad_dout;
         /* verilator lint_on UNUSEDSIGNAL */
         reg quad_low_phase;
         initial quad_dout = 4'd0;
         initial quad_low_phase = 1'b1;
         function [3:0] quad_diag_nibble;
            input [7:0] idx;
            begin
               case (DIAG_MODE)
                  1: quad_diag_nibble = idx[3:0];
                  2: begin
                     case (idx[1:0])
                        2'd0: quad_diag_nibble = 4'h1;
                        2'd1: quad_diag_nibble = 4'h2;
                        2'd2: quad_diag_nibble = 4'h4;
                        default: quad_diag_nibble = 4'h8;
                     endcase
                  end
                  3: quad_diag_nibble = idx[0] ? 4'hf : 4'h0;
                  4: quad_diag_nibble = idx[7:4];
                  5: quad_diag_nibble = idx[0] ? 4'h1 : 4'h0;
                  6: quad_diag_nibble = idx[0] ? 4'h2 : 4'h0;
                  7: quad_diag_nibble = idx[0] ? 4'h4 : 4'h0;
                  8: quad_diag_nibble = idx[0] ? 4'h8 : 4'h0;
                  default: quad_diag_nibble = 4'h0;
               endcase
            end
         endfunction
         function [3:0] quad_payload_nibble;
            input [7:0] byte_value;
            input low_phase;
            begin
               if (DIAG_MODE == 0)
                  quad_payload_nibble = low_phase ? byte_value[3:0]
                                                   : byte_value[7:4];
               else
                  quad_payload_nibble = quad_diag_nibble({byte_value[6:0], low_phase});
            end
         endfunction
         always @(posedge cs_async_rst or posedge sclk_stream) begin
            if (cs_async_rst) begin
               data_byte <= 8'd0;
               quad_dout <= quad_payload_nibble(8'd0, 1'b1);
               quad_low_phase <= 1'b1;
            end else if (!cs_n) begin
               if (quad_low_phase) begin
                  quad_dout <= quad_payload_nibble(data_byte, 1'b0);
                  quad_low_phase <= 1'b0;
               end else begin
                  data_byte <= data_byte + 8'd1;
                  quad_dout <= quad_payload_nibble(data_byte + 8'd1, 1'b1);
                  quad_low_phase <= 1'b1;
               end
            end
         end
         assign lane_ready = 1'b1;
         assign dout_lane = quad_dout;
      end
   end else begin : g_one
      reg [2:0] phase;
      reg dout_one;
      wire [7:0] data_byte_next = data_byte + 8'd1;
      initial phase = 3'd0;
      initial dout_one = 1'b0;
      assign lane_ready = (START_DELAY_CLKS == 0);
      always @(posedge cs_async_rst or negedge sclk_stream) begin
         if (cs_async_rst) begin
            data_byte <= 8'd0;
            phase     <= 3'd0;
            dout_one  <= 1'b0;
         end else if (lane_ready) begin
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
   /* QUAD_REG_OUTPUT=1 uses the IOB output flip-flop (PIN_TYPE output field
    * 6'b1101 = registered output + enable) instead of the transparent driver.
    * The registered launch has a small, fixed clk-to-out with no fabric routing
    * in the data path, shrinking the launch delay at the highest prescalers. */
   localparam [5:0] QUAD_PIN_TYPE = QUAD_REG_OUTPUT ? 6'b110101 : 6'b101001;
   generate if (LANES == 4) begin : g_quad_io
   	   for (g = 0; g < 4; g = g + 1) begin : g_io
   	      SB_IO #(
   	         .PIN_TYPE(QUAD_PIN_TYPE)
   	      ) iob (
            .PACKAGE_PIN(io[g]),
            .OUTPUT_CLK(iob_output_clk),
            .OUTPUT_ENABLE(oe),
            .D_OUT_0(dout_lane[g]),
            .D_IN_0(io_d_in[g])
         );
      end
   end else begin : g_one_io
      for (g = 0; g < 4; g = g + 1) begin : g_io
         SB_IO #(
            .PIN_TYPE(6'b101001)
         ) iob (
               .PACKAGE_PIN(io[g]),
               .OUTPUT_CLK(iob_output_clk),
               .OUTPUT_ENABLE(oe),
               .D_OUT_0(dout_lane[g]),
               .D_IN_0(io_d_in[g])
            );
      end
   end endgenerate
endmodule
