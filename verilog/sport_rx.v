// DSP SPORT TX lanes -> FPGA RX with bit-perfect counter check.
// Lane 0: SPORT4A on DAI1 PB01/PB02/PB04 -> P13/M11/P10.
// Lane 1: SPORT0A routed onto DAI0 PB05/PB07/PB08 -> R5/T5/R9.
// After all ACLKs go idle for ~5 ms, emits:
//   sport_rx lanes=... per_ch_words_hex=... errors_hex=... PASS
// on UART (115200 baud, tx=B12).

`ifndef SAMPLE_POS
 `define ACLK_SAMPLE_EDGE negedge
`else
 `define ACLK_SAMPLE_EDGE posedge
`endif

module sport_rx_chan #(
      parameter MIN_DONE_WORDS = 32'h00b00000,
      parameter MSB_FIRST = 1,
      parameter RESYNC = 0   // drop a stale lock after an error burst & re-acquire
   )(
      input        clk12,
      input        run,
      input        aclk_in,
      input        ad0_in,
      input        afs_in,
      output [31:0] words,
      output [31:0] errors,
      output [31:0] first_rx,
      output [31:0] first_exp,
      output [31:0] first_idx,
      output [31:0] diag0,
      output [31:0] diag1,
      output [31:0] diag2,
      output [31:0] diag3,
      output [31:0] diag4,
      output [31:0] diag5,
      output [31:0] diag6,
      output [31:0] diag7,
      output [31:0] diag8,
      output [31:0] diag9,
      output       done,
      // ~1 Hz progress snapshot (every 2^21 words = 8 MiB at 60+ Mbps)
      // and first-error capture, for live status printing.
      output [31:0] prog_w,
      output [31:0] prog_e,
      output        prog_t,
      output [31:0] fe_idx_o,
      output [31:0] fe_got_o,
      output [31:0] fe_exp_o,
      output        fe_t
   );

   localparam [31:0] PROG_MASK = 32'h001fffff;  // 2^21 words

   reg [31:0] prog_w_r = 32'd0;
   reg [31:0] prog_e_r = 32'd0;
   reg        prog_t_r = 1'b0;
   reg [31:0] fe_idx_r = 32'd0;
   reg [31:0] fe_got_r = 32'd0;
   reg [31:0] fe_exp_r = 32'd0;
   reg        fe_t_r   = 1'b0;
   reg        fe_seen  = 1'b0;
   assign prog_w = prog_w_r;
   assign prog_e = prog_e_r;
   assign prog_t = prog_t_r;
   assign fe_idx_o = fe_idx_r;
   assign fe_got_o = fe_got_r;
   assign fe_exp_o = fe_exp_r;
   assign fe_t = fe_t_r;

   wire aclk_global = aclk_in;

   reg ad0_r = 1'b0;
   reg afs_r = 1'b0;
   always @(`ACLK_SAMPLE_EDGE aclk_global) begin
      ad0_r <= ad0_in;
      afs_r <= afs_in;
   end

   // ---- PRBS-31 lockstep checker (no sync mechanism) ----
   // The DSP TX streams 32-bit PRBS-31 words. RUN holds both endpoint LFSRs at
   // the shared seed. The first AFS observation can include pad/SRU startup
   // state before the SPORT data stream is fully established; that one fixed
   // startup word is discarded without advancing the PRBS LFSR. From the next
   // word onward the checker advances exactly once per 32 DSP bit clocks.
   // There is no phase search, training pattern, skipped-word alignment, or
   // data-dependent re-sync.
   localparam [30:0] PRBS31_SEED = 31'h7FFFFFFF;
   reg [30:0] lfsr   = PRBS31_SEED;
   reg        afs_d  = 1'b0;
   reg [4:0]  bitpos = 5'd0;
   reg        started = 1'b0;
   reg        armed = 1'b0;
   reg [2:0]  arm_wait = 3'd0;
   reg        pass_ready = 1'b0;  // 0 = startup frame not yet dropped
   reg        fs_seen = 1'b0;     // dep-FS: first (artifact) rise consumed
   reg [30:0] lfsr_word = 31'h7FFFFFFF; // LFSR at current word boundary
   reg [31:0] shift_word = 32'd0;
   reg [31:0] exp_shift_word = 32'd0;
   reg [31:0] wcount = 32'd0;
   reg [31:0] ecount = 32'd0;
   reg        done_aclk = 1'b0;
   reg        done_toggle = 1'b0;
   reg [31:0] report_words_aclk = 32'd0;
   reg [31:0] report_errors_aclk = 32'd0;
`ifdef DIAG_FIRST
   reg [31:0] first_rx_r = 32'd0;
   reg [31:0] first_exp_r = 32'd0;
   reg [31:0] first_idx_r = 32'd0;
   reg        first_seen = 1'b0;
`endif
`ifdef DIAG_WORDS
   reg [31:0] diag_word0 = 32'd0;
   reg [31:0] diag_word1 = 32'd0;
   reg [31:0] diag_word2 = 32'd0;
   reg [31:0] diag_word3 = 32'd0;
   reg [31:0] diag_word4 = 32'd0;
   reg [31:0] diag_word5 = 32'd0;
   reg [31:0] diag_word6 = 32'd0;
   reg [31:0] diag_word7 = 32'd0;
   reg [31:0] diag_word8 = 32'd0;
   reg [31:0] diag_word9 = 32'd0;
   reg [3:0]  diag_count = 4'd0;
`ifdef DIAG_FSPHASE
   reg [15:0] fs_gap = 16'd0;
`endif
`ifdef DIAG_GAPAUDIT
   // FS-gap auditor: every frame must span exactly gap_nominal aclk
   // edges (32). Any deviation is an extra/missing clock edge ON THE
   // WIRE -- recorded as {gap[7:0], wcount[23:0]} per anomaly.
   reg [15:0] gap_audit = 16'd0;
   reg [15:0] gap_nominal = 16'd0;
   reg        gap_lock = 1'b0;
   reg [4:0]  fsbit_nominal = 5'd0;
   reg        fsbit_lock = 1'b0;
`endif
 `ifdef DIAG_WINDOW_START
   localparam [31:0] DIAG_BASE = `DIAG_WINDOW_START;
 `else
   localparam [31:0] DIAG_BASE = 32'd0;
 `endif
`endif

   wire [31:0] next_msb_word = {shift_word[30:0], ad0_r};
   wire [31:0] next_lsb_word = shift_word | (32'h1 << bitpos);
   wire [31:0] next_word = MSB_FIRST ? next_msb_word :
                            (ad0_r ? next_lsb_word : shift_word);

   wire        exp_bit = lfsr[30] ^ lfsr[27];
   wire [30:0] lfsr_next = {lfsr[29:0], exp_bit};
   wire [31:0] next_exp_word = {exp_shift_word[30:0], exp_bit};

   wire        next_word_bad = (next_word != next_exp_word);

   always @(`ACLK_SAMPLE_EDGE aclk_global) begin
      afs_d <= afs_r;
`ifdef DIAG_GAPAUDIT
      if (afs_r && !afs_d) begin
         if (started && !gap_lock) begin
            gap_nominal <= gap_audit + 16'd1;
            gap_lock <= 1'b1;
         end else if (fsbit_lock == 1'b0 && gap_lock) begin
            fsbit_nominal <= bitpos;
            fsbit_lock <= 1'b1;
         end else if (gap_lock && fsbit_lock
                      && ((gap_audit + 16'd1) != gap_nominal
                          || bitpos != fsbit_nominal)
                      && diag_count < 4'd8) begin
            case (diag_count)
               4'd0: diag_word0 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd1: diag_word1 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd2: diag_word2 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd3: diag_word3 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd4: diag_word4 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd5: diag_word5 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd6: diag_word6 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd7: diag_word7 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd8: diag_word8 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               4'd9: diag_word9 <= {gap_audit[7:0] + 8'd1, bitpos, wcount[18:0]};
               default: begin end
            endcase
            diag_count <= diag_count + 4'd1;
         end
         gap_audit <= 16'd0;
      end else begin
         gap_audit <= gap_audit + 16'd1;
      end
      // live counts in the last two diag slots so the dump stands alone
      diag_word8 <= wcount;
      diag_word9 <= ecount;
`endif
`ifdef DIAG_STATE
      fe_idx_r <= {28'd0, fs_seen, armed, started, pass_ready};
`endif
`ifdef DIAG_FSPHASE
      fs_gap <= fs_gap + 16'd1;
      if (run && afs_r && !afs_d) begin
         fs_gap <= 16'd0;
         prog_w_r <= {16'd0, fs_gap};
         prog_e_r <= {prog_e_r[31:16] + 16'd1, 5'd0, started, 5'd0, bitpos};
         if (diag_count < 4'd10) begin
            case (diag_count)
               4'd0: diag_word0 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd1: diag_word1 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd2: diag_word2 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd3: diag_word3 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd4: diag_word4 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd5: diag_word5 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd6: diag_word6 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd7: diag_word7 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd8: diag_word8 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               4'd9: diag_word9 <= {fs_gap, 5'd0, started, 5'd0, bitpos};
               default: begin end
            endcase
            diag_count <= diag_count + 4'd1;
            if (!done_aclk) begin
               done_aclk <= 1'b1;
               done_toggle <= ~done_toggle;
            end
         end
      end
`endif
      if (!run && !done_aclk && !started) begin
            lfsr <= PRBS31_SEED;
            afs_d <= 1'b0;
            bitpos <= 5'd0;
            started <= 1'b0;
            armed <= 1'b0;
            arm_wait <= 3'd0;
            pass_ready <= 1'b0;
            shift_word <= 32'd0;
            exp_shift_word <= 32'd0;
            wcount <= 32'd0;
            ecount <= 32'd0;
            done_aclk <= 1'b0;
            fe_seen <= 1'b0;
            fs_seen <= 1'b0;
`ifndef DIAG_FORCE_LIVE
            report_words_aclk <= 32'd0;
            report_errors_aclk <= 32'd0;
`endif
      end else if (!run && done_aclk) begin
            // Preserve the completed report long enough for the clk12 UART
            // domain to latch it after the DSP deasserts RUN at end-of-stream.
            started <= 1'b0;
            armed <= 1'b0;
      end else if (RESYNC && !started && afs_r && !afs_d) begin
            // dep-FS: arm at any FS rise; a false/glitch rise self-corrects
            // via the mid-word abort (FS dip -> rewind -> re-arm), so no
            // startup-artifact bookkeeping is needed.
            started <= 1'b1;
            pass_ready <= 1'b1;
            lfsr_word <= lfsr;
            bitpos <= 5'd1;
            shift_word <= MSB_FIRST ? {31'd0, ad0_r}
                                    : (ad0_r ? 32'h00000001 : 32'd0);
            exp_shift_word <= {31'd0, exp_bit};
            lfsr <= lfsr_next;
      end else if (!started && afs_r && !afs_d) begin
            armed <= 1'b1;
            arm_wait <= 3'd0;
      end else if (!started && armed && arm_wait < 3'd3) begin
            arm_wait <= arm_wait + 3'd1;
      end else if (!started && armed) begin
            armed <= 1'b0;
            bitpos <= 5'd1;
            started <= 1'b1;
            shift_word <= MSB_FIRST ? {31'd0, ad0_r}
                                    : (ad0_r ? 32'h00000001 : 32'd0);
            if (pass_ready) begin
               exp_shift_word <= {31'd0, exp_bit};
               lfsr <= lfsr_next;
            end
      end else if (RESYNC && started && !afs_r && bitpos != 5'd31) begin
            // dep-FS gap opened mid-word: discard the partial word and
            // rewind the expected stream to the word boundary; re-arm at
            // the next FS rise.
            started <= 1'b0;
            bitpos <= 5'd0;
            shift_word <= 32'd0;
            exp_shift_word <= 32'd0;
            lfsr <= lfsr_word;
      end else if (started) begin
            shift_word <= next_word;
            if (pass_ready) begin
               exp_shift_word <= next_exp_word;
               lfsr <= lfsr_next;
            end
`ifdef DIAG_FORCE_LIVE
            report_words_aclk <= wcount;
            report_errors_aclk <= ecount;
`endif
            if (bitpos == 5'd31) begin
               if (!pass_ready) begin
                  pass_ready <= 1'b1;
               end else begin
`ifdef DIAG_FIRST
`ifdef DIAG_MISMATCH
               if (!first_seen && next_word_bad) begin
`else
               if (!first_seen) begin
`endif
                  first_rx_r <= next_word;
                  first_exp_r <= next_exp_word;
                  first_idx_r <= wcount;
                  first_seen <= 1'b1;
               end
`endif
               wcount <= wcount + 32'd1;
               if (next_word_bad) begin
                  ecount <= ecount + 32'd1;
               end
               if (((wcount + 32'd1) & PROG_MASK) == 32'd0) begin
                  prog_w_r <= wcount + 32'd1;
                  prog_e_r <= ecount + (next_word_bad ? 32'd1 : 32'd0);
                  prog_t_r <= ~prog_t_r;
               end
               if (next_word_bad && !fe_seen) begin
                  fe_seen  <= 1'b1;
                  fe_idx_r <= wcount;
                  fe_got_r <= next_word;
                  fe_exp_r <= next_exp_word;
                  fe_t_r   <= ~fe_t_r;
               end
               if (!done_aclk && (wcount + 32'd1) >= MIN_DONE_WORDS) begin
                  done_aclk <= 1'b1;
                  done_toggle <= ~done_toggle;
                  report_words_aclk <= wcount + 32'd1;
                  report_errors_aclk <= ecount + (next_word_bad ? 32'd1 : 32'd0);
               end
`ifdef DIAG_WORDS
`ifndef DIAG_FSPHASE
`ifndef DIAG_GAPAUDIT
               if (wcount >= DIAG_BASE && diag_count < 4'd10) begin
                  case (diag_count)
                     4'd0: diag_word0 <= next_word;
                     4'd1: diag_word1 <= next_word;
                     4'd2: diag_word2 <= next_word;
                     4'd3: diag_word3 <= next_word;
                     4'd4: diag_word4 <= next_word;
                     4'd5: diag_word5 <= next_word;
                     4'd6: diag_word6 <= next_word;
                     4'd7: diag_word7 <= next_word;
                     4'd8: diag_word8 <= next_word;
                     4'd9: diag_word9 <= next_word;
                     default: begin end
                  endcase
                  diag_count <= diag_count + 4'd1;
               end
`endif
`endif
`endif
               end
            bitpos <= 5'd0;
            shift_word <= 32'd0;
            exp_shift_word <= 32'd0;
            // RESYNC (dep-FS streams): FS is LEVEL-continuous while data
            // flows (measured); keep free-running while it is high and
            // idle only on a genuine gap (FS low), re-arming at the rise.
            if (RESYNC && !afs_r)
               started <= 1'b0;
            if (RESYNC)
               lfsr_word <= lfsr_next;
            end else begin
               bitpos <= bitpos + 5'd1;
            end
      end
   end

   reg aclk_toggle = 1'b0;
   always @(posedge aclk_global) aclk_toggle <= ~aclk_toggle;

`ifdef DIAG_RAW
   reg [31:0] raw_edges = 32'd0;
   always @(posedge aclk_global) raw_edges <= raw_edges + 32'd1;
`endif

   reg [2:0] tog_sync = 3'b000;
   always @(posedge clk12) tog_sync <= {tog_sync[1:0], aclk_toggle};
   wire aclk_active = (tog_sync[2] ^ tog_sync[1]);

   reg [16:0] idle_cnt = 17'd0;
   localparam IDLE_THRESH = 17'd60000;
   reg done_r = 1'b0;

   reg [31:0] report_words = 32'd0;
   reg [31:0] report_errors = 32'd0;
   reg [2:0] done_sync = 3'b000;
   reg        done_pending = 1'b0;
   reg [7:0]  done_wait = 8'd0;
`ifdef DIAG_RAW
   reg [31:0] force_cnt = 32'd0;
`elsif DIAG_FORCE_REPORT
   reg [31:0] force_cnt = 32'd0;
`endif
   always @(posedge clk12) begin
      done_sync <= {done_sync[1:0], done_toggle};
`ifdef DIAG_RAW
      report_words <= raw_edges;
      report_errors <= 32'd0;
`elsif DIAG_FORCE_REPORT
      if (force_cnt < 32'd120000000) force_cnt <= force_cnt + 32'd1;
      if (!done_r && force_cnt == 32'd119999999) begin
         report_words <= report_words_aclk;
         report_errors <= report_errors_aclk;
         done_r <= 1'b1;
      end
`endif
      if (aclk_active) begin
         idle_cnt <= 17'd0;
      end else if (idle_cnt < IDLE_THRESH) begin
         idle_cnt <= idle_cnt + 17'd1;
      end
`ifdef DIAG_RAW
      // Force a report after ~10 s regardless of sync/idle so the raw
      // edge count (in the words field) is always emitted.
      if (force_cnt < 32'd120000000) force_cnt <= force_cnt + 32'd1;
      if (!done_r && force_cnt == 32'd119999999) done_r <= 1'b1;
`elsif DIAG_FORCE_REPORT
`else
      if (!done_r && !done_pending && (done_sync[2] ^ done_sync[1])) begin
         done_pending <= 1'b1;
         done_wait <= 8'd0;
      end else if (done_pending) begin
         done_wait <= done_wait + 8'd1;
         if (done_wait == 8'hff) begin
            report_words <= report_words_aclk;
            report_errors <= report_errors_aclk;
            done_r <= 1'b1;
            done_pending <= 1'b0;
         end
      end
`endif
   end

   assign words = report_words;
   assign errors = report_errors;
`ifdef DIAG_FIRST
   assign first_rx = first_rx_r;
   assign first_exp = first_exp_r;
   assign first_idx = first_idx_r;
`else
   assign first_rx = 32'd0;
   assign first_exp = 32'd0;
   assign first_idx = 32'd0;
`endif
`ifdef DIAG_WORDS
   assign diag0 = diag_word0;
   assign diag1 = diag_word1;
   assign diag2 = diag_word2;
   assign diag3 = diag_word3;
   assign diag4 = diag_word4;
   assign diag5 = diag_word5;
   assign diag6 = diag_word6;
   assign diag7 = diag_word7;
   assign diag8 = diag_word8;
   assign diag9 = diag_word9;
`else
   assign diag0 = 32'd0;
   assign diag1 = 32'd0;
   assign diag2 = 32'd0;
   assign diag3 = 32'd0;
   assign diag4 = 32'd0;
   assign diag5 = 32'd0;
   assign diag6 = 32'd0;
   assign diag7 = 32'd0;
   assign diag8 = 32'd0;
   assign diag9 = 32'd0;
`endif
   assign done = done_r;
endmodule

module sport_rx #(
      parameter N = 2,
      parameter MIN_DONE_WORDS = 32'h00b00000,
      parameter REPORT_LANE0 = 0,  // report/gate on a single lane only (single-lane proof)
      parameter REPORT_IDX = 0,    // which lane index to report/gate when REPORT_LANE0
      parameter RESYNC = 0,        // re-acquire after an error burst (bidir startup)
      parameter RUN_GATE = 1       // require RUN observed low before a rising edge counts
   )(
      input        clk12,
      input  [N-1:0] aclk_in,
      input  [N-1:0] ad0_in,
      input  [N-1:0] afs_in,
      input        run,
      inout        tx,
      // Visual transfer-in-progress indicator: toggles once per
      // heartbeat line, so it blinks at ~0.5 Hz while data flows
      // and holds steady when idle.
      output reg   led
   );

   initial led = 1'b0;

   wire [31:0] words [0:N-1];
   wire [31:0] errors [0:N-1];
   wire [31:0] first_rx [0:N-1];
   wire [31:0] first_exp [0:N-1];
   wire [31:0] first_idx [0:N-1];
   wire [31:0] diag0 [0:N-1];
   wire [31:0] diag1 [0:N-1];
   wire [31:0] diag2 [0:N-1];
   wire [31:0] diag3 [0:N-1];
   wire [31:0] diag4 [0:N-1];
   wire [31:0] diag5 [0:N-1];
   wire [31:0] diag6 [0:N-1];
   wire [31:0] diag7 [0:N-1];
   wire [31:0] diag8 [0:N-1];
   wire [31:0] diag9 [0:N-1];
   wire        done [0:N-1];
   wire [31:0] prog_w [0:N-1];
   wire [31:0] prog_e [0:N-1];
   wire        prog_t [0:N-1];
   wire [31:0] fe_idx [0:N-1];
   wire [31:0] fe_got [0:N-1];
   wire [31:0] fe_exp [0:N-1];
   wire        fe_t [0:N-1];

   // Between FPGA config and DSP firmware start, RUN (R10) floats high
   // while the DSP's SPI boot clocks MHz-rate noise into the lanes -- a
   // floating-armed receiver can cross a small MIN_DONE during boot and
   // fire its one-shot report into the boot bus. Honour RUN only after
   // it has been GENUINELY seen low (the firmware holds it low 60 ms at
   // start). Zero-init means "not yet seen low", which iCE40 silicon
   // honours.
   reg [2:0] run_sync = 3'b000;
   reg       run_seen_low = 1'b0;
   always @(posedge clk12) begin
      run_sync <= {run_sync[1:0], run};
      if (run_sync[2:1] == 2'b00)
         run_seen_low <= 1'b1;
   end
   wire run_gated = run & run_seen_low;
   wire print_ok = 1'b1;

   // Register ad0/afs in the IO cells, clocked by the lane's own ACLK, so
   // the pin->flop timing is fixed in silicon instead of varying with
   // placement/routing. This keeps sampling robust regardless of where the
   // lane lands (a fabric-routed input flop can sit marginally close to the
   // sample edge and silently corrupt the stream).
   wire [N-1:0] ad0_reg, afs_reg;
`ifdef NO_IOREG
   assign ad0_reg = ad0_in;
   assign afs_reg = afs_in;
`else
`ifdef SAMPLE_NEG
   localparam IO_NEG_TRIGGER = 1'b1;
`else
   localparam IO_NEG_TRIGGER = 1'b0;
`endif
   genvar io_i;
   generate
      for (io_i = 0; io_i < N; io_i = io_i + 1) begin : ioregs
`ifdef EYE_DELAY
         // Nudge the capture phase: route the IO-FF clock through a kept
         // LUT so it takes fabric routing (+2-4 ns) instead of the global
         // net, sliding the sample point into the data eye.
         (* keep *) wire aclk_dly;
         SB_LUT4 #(.LUT_INIT(16'haaaa)) eye_dly (
            .O(aclk_dly), .I0(aclk_in[io_i]),
            .I1(1'b0), .I2(1'b0), .I3(1'b0));
         SB_IO #(.PIN_TYPE(6'b000000), .NEG_TRIGGER(IO_NEG_TRIGGER)) ad0_iob (
            .PACKAGE_PIN(ad0_in[io_i]),
            .INPUT_CLK(aclk_dly),
            .D_IN_0(ad0_reg[io_i]));
         SB_IO #(.PIN_TYPE(6'b000000), .NEG_TRIGGER(IO_NEG_TRIGGER)) afs_iob (
            .PACKAGE_PIN(afs_in[io_i]),
            .INPUT_CLK(aclk_dly),
            .D_IN_0(afs_reg[io_i]));
`else
         SB_IO #(.PIN_TYPE(6'b000000), .NEG_TRIGGER(IO_NEG_TRIGGER)) ad0_iob (
            .PACKAGE_PIN(ad0_in[io_i]),
            .INPUT_CLK(aclk_in[io_i]),
            .D_IN_0(ad0_reg[io_i]));
         SB_IO #(.PIN_TYPE(6'b000000), .NEG_TRIGGER(IO_NEG_TRIGGER)) afs_iob (
            .PACKAGE_PIN(afs_in[io_i]),
            .INPUT_CLK(aclk_in[io_i]),
            .D_IN_0(afs_reg[io_i]));
`endif
      end
   endgenerate
`endif

   genvar lane_i;
   generate
      for (lane_i = 0; lane_i < N; lane_i = lane_i + 1) begin : lanes
         sport_rx_chan #(.MIN_DONE_WORDS(MIN_DONE_WORDS), .RESYNC(RESYNC)) lane (
            .clk12(clk12),
            .run(run_gated),
            .aclk_in(aclk_in[lane_i]),
            .ad0_in(ad0_reg[lane_i]),
            .afs_in(afs_reg[lane_i]),
            .words(words[lane_i]),
            .errors(errors[lane_i]),
            .first_rx(first_rx[lane_i]),
            .first_exp(first_exp[lane_i]),
            .first_idx(first_idx[lane_i]),
            .diag0(diag0[lane_i]),
            .diag1(diag1[lane_i]),
            .diag2(diag2[lane_i]),
            .diag3(diag3[lane_i]),
            .diag4(diag4[lane_i]),
            .diag5(diag5[lane_i]),
            .diag6(diag6[lane_i]),
            .diag7(diag7[lane_i]),
            .diag8(diag8[lane_i]),
            .diag9(diag9[lane_i]),
            .done(done[lane_i]),
            .prog_w(prog_w[lane_i]),
            .prog_e(prog_e[lane_i]),
            .prog_t(prog_t[lane_i]),
            .fe_idx_o(fe_idx[lane_i]),
            .fe_got_o(fe_got[lane_i]),
            .fe_exp_o(fe_exp[lane_i]),
            .fe_t(fe_t[lane_i])
         );
      end

   endgenerate

   function [7:0] hex_digit(input [3:0] nibble);
      begin
         hex_digit = (nibble < 4'd10) ? ("0" + nibble) : ("a" + (nibble - 4'd10));
      end
   endfunction

   function [31:0] diag_word(input [3:0] which);
      begin
         case (which)
            4'd0: diag_word = diag0[REPORT_IDX];
            4'd1: diag_word = diag1[REPORT_IDX];
            4'd2: diag_word = diag2[REPORT_IDX];
            4'd3: diag_word = diag3[REPORT_IDX];
            4'd4: diag_word = diag4[REPORT_IDX];
            4'd5: diag_word = diag5[REPORT_IDX];
            4'd6: diag_word = diag6[REPORT_IDX];
            4'd7: diag_word = diag7[REPORT_IDX];
            4'd8: diag_word = diag8[REPORT_IDX];
            default: diag_word = diag9[REPORT_IDX];
         endcase
      end
   endfunction

   function [7:0] diag_prefix_char(input [3:0] idx);
      begin
         case (idx)
            4'd0: diag_prefix_char = "s"; 4'd1: diag_prefix_char = "p";
            4'd2: diag_prefix_char = "o"; 4'd3: diag_prefix_char = "r";
            4'd4: diag_prefix_char = "t"; 4'd5: diag_prefix_char = "_";
            4'd6: diag_prefix_char = "r"; 4'd7: diag_prefix_char = "x";
            4'd8: diag_prefix_char = "_"; 4'd9: diag_prefix_char = "w";
            4'd10: diag_prefix_char = "o"; 4'd11: diag_prefix_char = "r";
            4'd12: diag_prefix_char = "d"; 4'd13: diag_prefix_char = "s";
            default: diag_prefix_char = " ";
         endcase
      end
   endfunction

   function [7:0] hex_word_digit(input [31:0] word, input [2:0] digit);
      begin
         case (digit)
            3'd0: hex_word_digit = hex_digit(word[31:28]);
            3'd1: hex_word_digit = hex_digit(word[27:24]);
            3'd2: hex_word_digit = hex_digit(word[23:20]);
            3'd3: hex_word_digit = hex_digit(word[19:16]);
            3'd4: hex_word_digit = hex_digit(word[15:12]);
            3'd5: hex_word_digit = hex_digit(word[11:8]);
            3'd6: hex_word_digit = hex_digit(word[7:4]);
            default: hex_word_digit = hex_digit(word[3:0]);
         endcase
      end
   endfunction

   // Live progress ("rx w=<hex> e=<hex>") roughly once per second and a
   // one-shot first-error line ("ERR w=<idx> got=<hex> exp=<hex>"), printed
   // from the REPORT_IDX lane's aclk-domain snapshots.
`ifdef DIAG_WORDS
   localparam PROG_EN = 1'b0;
`else
   localparam PROG_EN = 1'b1;
`endif
   reg [2:0]  pt_sync = 3'b000;
   reg [2:0]  fet_sync = 3'b000;
   reg        prog_pend = 1'b0;
   reg        fe_pend = 1'b0;
   reg [31:0] pw_latch = 32'd0;
   reg [31:0] pe_latch = 32'd0;
   reg [31:0] fi_latch = 32'd0;
   reg [31:0] fg_latch = 32'd0;
   reg [31:0] fx_latch = 32'd0;
   reg [1:0]  msg_kind = 2'd0;  // 0 final report, 1 progress, 2 first error
`ifdef DIAG_STATE
   reg [25:0] diag_timer = 26'd0;   // defer prints ~5.6 s past config
   reg        diag_go = 1'b0;
   wire [31:0] fe_probe = fe_idx[REPORT_IDX];
`endif

   function [7:0] prog_char(input [7:0] idx);
      begin
         if (idx >= 8'd5 && idx <= 8'd12) begin
            prog_char = hex_word_digit(pw_latch, idx[2:0] - 3'd5);
         end else if (idx >= 8'd16 && idx <= 8'd23) begin
            prog_char = hex_word_digit(pe_latch, idx[2:0]);
         end else begin
            case (idx)
               8'd0: prog_char = "r"; 8'd1: prog_char = "x";
               8'd2: prog_char = " "; 8'd3: prog_char = "w";
               8'd4: prog_char = "="; 8'd13: prog_char = " ";
               8'd14: prog_char = "e"; 8'd15: prog_char = "=";
               8'd24: prog_char = "\r";
               default: prog_char = "\n";
            endcase
         end
      end
   endfunction

   function [7:0] err_char(input [7:0] idx);
      begin
         if (idx >= 8'd6 && idx <= 8'd13) begin
            err_char = hex_word_digit(fi_latch, idx[2:0] - 3'd6);
         end else if (idx >= 8'd19 && idx <= 8'd26) begin
            err_char = hex_word_digit(fg_latch, idx[2:0] - 3'd3);
         end else if (idx >= 8'd32 && idx <= 8'd39) begin
            err_char = hex_word_digit(fx_latch, idx[2:0]);
         end else begin
            case (idx)
               8'd0: err_char = "E"; 8'd1: err_char = "R";
               8'd2: err_char = "R"; 8'd3: err_char = " ";
               8'd4: err_char = "w"; 8'd5: err_char = "=";
               8'd14: err_char = " "; 8'd15: err_char = "g";
               8'd16: err_char = "o"; 8'd17: err_char = "t";
               8'd18: err_char = "="; 8'd27: err_char = " ";
               8'd28: err_char = "e"; 8'd29: err_char = "x";
               8'd30: err_char = "p"; 8'd31: err_char = "=";
               8'd40: err_char = "\r";
               default: err_char = "\n";
            endcase
         end
      end
   endfunction

   // Drive the UART pad only once there is something to say: B12 shares a
   // net with the DSP boot bus, so driving it from configuration corrupts
   // the SPI boot (SYS_FAULT). The first print happens long after boot.
   reg tx_oe = 1'b0;
   reg reported = 1'b0;
   reg sending = 1'b0;
   reg pre_wait = 1'b0;
   reg [14:0] pre_cnt = 15'd0;
   reg [7:0] send_idx = 8'd0;
   reg [3:0] diag_send_word = 4'd0;
   reg [3:0] diag_send_digit = 4'd0;
   reg send_start = 1'b0;
   reg [7:0] send_data = 8'd0;
   wire uart_busy;
   wire uart_tx_line;

   // Loop-free lane aggregation: generate chains of continuous assigns.
   wire [N-1:0]  done_vec;
   wire [31:0]   minw_ch [0:N-1];
   wire [31:0]   tote_ch [0:N-1];
   assign done_vec[0] = done[0];
   assign minw_ch[0] = words[0];
   assign tote_ch[0] = errors[0];
   genvar agg_i;
   generate
      for (agg_i = 1; agg_i < N; agg_i = agg_i + 1) begin : agg
         assign done_vec[agg_i] = done[agg_i];
         assign minw_ch[agg_i] = (words[agg_i] < minw_ch[agg_i-1])
                                 ? words[agg_i] : minw_ch[agg_i-1];
         assign tote_ch[agg_i] = tote_ch[agg_i-1] + errors[agg_i];
      end
   endgenerate
   wire [31:0] min_words_c = minw_ch[N-1];
   wire [31:0] tot_err_c  = tote_ch[N-1];
   wire        all_done_w = REPORT_LANE0 ? done[REPORT_IDX] : (&done_vec);

   reg [31:0] w0_latch = 32'd0;
   reg [31:0] et_latch = 32'd0;
   reg collecting = 1'b0;
   reg [3:0] collect_idx = 4'd0;
   reg [31:0] min_calc = 32'hffffffff;
   reg [31:0] err_calc = 32'd0;
   reg [31:0] min_words;
   reg [31:0] total_errors;

   function [7:0] report_char(input [7:0] idx);
      begin
         if (idx >= 8'd34 && idx <= 8'd41) begin
            report_char = hex_word_digit(w0_latch, idx[2:0] - 3'd2);
         end else if (idx >= 8'd54 && idx <= 8'd61) begin
            report_char = hex_word_digit(et_latch, idx[2:0] - 3'd6);
         end else if (idx >= 8'd63 && idx <= 8'd66) begin
            if (et_latch == 32'd0 && w0_latch >= MIN_DONE_WORDS) begin
               case (idx)
                  8'd63: report_char = "P";
                  8'd64: report_char = "A";
                  8'd65: report_char = "S";
                  default: report_char = "S";
               endcase
            end else begin
               case (idx)
                  8'd63: report_char = "F";
                  8'd64: report_char = "A";
                  8'd65: report_char = "I";
                  default: report_char = "L";
               endcase
            end
         end else begin
            case (idx)
               8'd0: report_char = "s"; 8'd1: report_char = "p";
               8'd2: report_char = "o"; 8'd3: report_char = "r";
               8'd4: report_char = "t"; 8'd5: report_char = "_";
               8'd6: report_char = "r"; 8'd7: report_char = "x";
               8'd8: report_char = " "; 8'd9: report_char = "l";
               8'd10: report_char = "a"; 8'd11: report_char = "n";
               8'd12: report_char = "e"; 8'd13: report_char = "s";
               8'd14: report_char = "="; 8'd15: report_char = "0" + N;
               8'd16: report_char = " "; 8'd17: report_char = "p";
               8'd18: report_char = "e"; 8'd19: report_char = "r";
               8'd20: report_char = "_"; 8'd21: report_char = "c";
               8'd22: report_char = "h"; 8'd23: report_char = "_";
               8'd24: report_char = "w"; 8'd25: report_char = "o";
               8'd26: report_char = "r"; 8'd27: report_char = "d";
               8'd28: report_char = "s"; 8'd29: report_char = "_";
               8'd30: report_char = "h"; 8'd31: report_char = "e";
               8'd32: report_char = "x"; 8'd33: report_char = "=";
               8'd42: report_char = " "; 8'd43: report_char = "e";
               8'd44: report_char = "r"; 8'd45: report_char = "r";
               8'd46: report_char = "o"; 8'd47: report_char = "r";
               8'd48: report_char = "s"; 8'd49: report_char = "_";
               8'd50: report_char = "h"; 8'd51: report_char = "e";
               8'd52: report_char = "x"; 8'd53: report_char = "=";
               8'd62: report_char = " "; 8'd67: report_char = "\r";
               default: report_char = "\n";
            endcase
         end
      end
   endfunction

   always @(posedge clk12) begin
      send_start <= 1'b0;
      pt_sync <= {pt_sync[1:0], prog_t[REPORT_IDX]};
      fet_sync <= {fet_sync[1:0], fe_t[REPORT_IDX]};
      if (pt_sync[2] ^ pt_sync[1])
         prog_pend <= 1'b1;
`ifdef DIAG_STATE
      diag_timer <= diag_timer + 26'd1;
      if (diag_timer == 26'd0)
         diag_go <= 1'b1;
      if (diag_go && diag_timer[22:0] == 23'd0)
         prog_pend <= 1'b1;
`endif
      if (fet_sync[2] ^ fet_sync[1])
         fe_pend <= 1'b1;
`ifdef DIAG_STATE
      if (1'b0) begin
`else
      if (PROG_EN && print_ok && !sending && !pre_wait && !collecting && fe_pend && !reported) begin
`endif
         fi_latch <= fe_idx[REPORT_IDX];
         fg_latch <= fe_got[REPORT_IDX];
         fx_latch <= fe_exp[REPORT_IDX];
         msg_kind <= 2'd2;
         send_idx <= 8'd0;
         pre_wait <= 1'b1;
         pre_cnt <= 15'd0;
         tx_oe <= 1'b1;
         fe_pend <= 1'b0;
      end else if (PROG_EN && !sending && !pre_wait && !collecting && prog_pend
`ifdef DIAG_STATE
                   ) begin
`else
                   && print_ok && !reported && !all_done_w) begin
`endif
`ifdef DIAG_STATE
`ifdef DIAG_FSPHASE
         pw_latch <= prog_w[REPORT_IDX];
`else
         pw_latch <= words[REPORT_IDX];
`endif
`ifdef DIAG_FSPHASE
         pe_latch <= prog_e[REPORT_IDX];
`else
         pe_latch <= {8'h6a, 3'd0, run, 2'd0, done[0],
                      done[N > 1 ? 1 : 0], 6'd0, all_done_w, reported,
                      sending, pre_wait, prog_pend, fe_pend, collecting,
                      1'b0};
`endif
`else
         pw_latch <= prog_w[REPORT_IDX];
         pe_latch <= prog_e[REPORT_IDX];
`endif
         msg_kind <= 2'd1;
         send_idx <= 8'd0;
         pre_wait <= 1'b1;
         pre_cnt <= 15'd0;
         tx_oe <= 1'b1;
         prog_pend <= 1'b0;
         led <= ~led;
      end else if (REPORT_LANE0 && print_ok && !reported && all_done_w
                   && !sending && !pre_wait) begin
`ifdef DIAG_FIRST
`ifdef DIAG_INDEX
         w0_latch <= first_idx[REPORT_IDX];
         et_latch <= first_rx[REPORT_IDX];
`else
         w0_latch <= first_exp[REPORT_IDX];
         et_latch <= first_rx[REPORT_IDX];
`endif
`else
         w0_latch <= words[REPORT_IDX];
         et_latch <= errors[REPORT_IDX];
`endif
         pre_wait <= 1'b1;
         pre_cnt <= 15'd0;
         send_idx <= 8'd0;
         msg_kind <= 2'd0;
         tx_oe <= 1'b1;
         diag_send_word <= 4'd0;
         diag_send_digit <= 4'd0;
         reported <= 1'b1;
      end else if (!REPORT_LANE0 && print_ok && !reported && all_done_w
                   && !sending && !pre_wait) begin
         w0_latch <= min_words_c;
         et_latch <= tot_err_c;
         pre_wait <= 1'b1;
         pre_cnt <= 15'd0;
         send_idx <= 8'd0;
         msg_kind <= 2'd0;
         tx_oe <= 1'b1;
         diag_send_word <= 4'd0;
         diag_send_digit <= 4'd0;
         reported <= 1'b1;
      end else if (1'b0) begin
         min_words = min_calc;
         total_errors = err_calc + errors[collect_idx];
         if (collect_idx == 4'd0 || words[collect_idx] < min_calc)
            min_words = words[collect_idx];
         if (collect_idx == N - 1) begin
            collecting <= 1'b0;
`ifdef DIAG_FIRST
`ifdef DIAG_INDEX
            w0_latch <= first_idx[0];
            et_latch <= first_rx[0];
`else
            w0_latch <= first_exp[0];
            et_latch <= first_rx[0];
`endif
`else
            w0_latch <= min_words;
            et_latch <= total_errors;
`endif
            pre_wait <= 1'b1;
            pre_cnt <= 15'd0;
            send_idx <= 8'd0;
            msg_kind <= 2'd0;
            diag_send_word <= 4'd0;
            diag_send_digit <= 4'd0;
            reported <= 1'b1;
         end else begin
            min_calc <= min_words;
            err_calc <= total_errors;
            collect_idx <= collect_idx + 4'd1;
         end
      end else if (pre_wait) begin
         if (pre_cnt < 15'd12000) begin
            pre_cnt <= pre_cnt + 15'd1;
         end else begin
            pre_wait <= 1'b0;
            sending <= 1'b1;
            tx_oe <= 1'b1;
         end
      end else if (sending && !uart_busy && !send_start) begin
`ifdef DIAG_WORDS
         if (send_idx < 8'd15) begin
            send_data <= diag_prefix_char(send_idx[3:0]);
            send_start <= 1'b1;
            send_idx <= send_idx + 8'd1;
         end else if (diag_send_word < 4'd10) begin
            if (diag_send_digit < 4'd8) begin
               send_data <= hex_word_digit(diag_word(diag_send_word),
                                           diag_send_digit[2:0]);
               diag_send_digit <= diag_send_digit + 4'd1;
            end else begin
               send_data <= " ";
               diag_send_digit <= 4'd0;
               diag_send_word <= diag_send_word + 4'd1;
            end
            send_start <= 1'b1;
         end else if (send_idx == 8'd15) begin
            send_data <= "\r";
            send_start <= 1'b1;
            send_idx <= 8'd16;
         end else if (send_idx == 8'd16) begin
            send_data <= "\n";
            send_start <= 1'b1;
            send_idx <= 8'd17;
         end else begin
            sending <= 1'b0;
         end
`else
         if (msg_kind == 2'd1) begin
            if (send_idx < 8'd26) begin
               send_data <= prog_char(send_idx);
               send_start <= 1'b1;
               send_idx <= send_idx + 8'd1;
            end else begin
               sending <= 1'b0;
            end
         end else if (msg_kind == 2'd2) begin
            if (send_idx < 8'd42) begin
               send_data <= err_char(send_idx);
               send_start <= 1'b1;
               send_idx <= send_idx + 8'd1;
            end else begin
               sending <= 1'b0;
            end
         end else if (send_idx < 8'd69) begin
            send_data <= report_char(send_idx);
            send_start <= 1'b1;
            send_idx <= send_idx + 8'd1;
         end else begin
            sending <= 1'b0;
         end
`endif
      end
   end

   uart_tx #(.CLKS_PER_BIT(104)) u_tx (
      .clk(clk12),
      .start(send_start),
      .data(send_data),
      .tx(uart_tx_line),
      .busy(uart_busy)
   );

   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) tx_iob (
      .PACKAGE_PIN(tx),
      .OUTPUT_ENABLE(tx_oe),
      .D_OUT_0(uart_tx_line),
      .D_IN_0()
   );

endmodule
