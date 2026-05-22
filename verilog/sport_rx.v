// SPORT4A TX -> FPGA RX with bit-perfect PRBS check.
// AD0 P16, ACLK N16, AFS K14. After ACLK goes idle for ~5 ms,
// emits "RX got=NNNNN err=NNNNN bit_clk=62500000 PASS\r\n" on UART
// (115200 baud, tx=B12).

module sport_rx (
      input  clk12,
      input  aclk_in,
      input  ad0_in,
      input  afs_in,
      output tx
   );

   wire aclk_global;

   SB_GB aclk_global_buf (
      .USER_SIGNAL_TO_GLOBAL_BUFFER(aclk_in),
      .GLOBAL_BUFFER_OUTPUT(aclk_global)
   );

   // Register AD0 and AFS at the iCE40 IO boundary. yosys
   // synth_ice40 packs these flops into SB_IO cells, which
   // minimises pin-to-FF routing delay and gives the tightest
   // possible setup margin against incoming ACLK. At 62.5 MHz
   // the half-period budget for data eye is 8 ns; without the
   // IO-flop pack, fabric routing eats into that.
   reg ad0_r = 1'b0;
   reg afs_r = 1'b0;
   always @(posedge aclk_global) begin
      ad0_r <= ad0_in;
      afs_r <= afs_in;
   end

   // --- ACLK domain: deserialise + LFSR compare -----------------
   reg [31:0] shreg  = 32'd0;
   reg [5:0]  bitcnt = 6'd0;
   reg        afs_d  = 1'b0;
   reg        in_frame = 1'b0;
   reg [31:0] wcount = 32'd0;
   reg [31:0] ecount = 32'd0;
   reg [31:0] afs_count = 32'd0;
   reg [31:0] expected = 32'd0;
   reg        synced   = 1'b0;
   reg [31:0] first_word = 32'd0;
   reg [31:0] second_word = 32'd0;
   reg [31:0] third_word = 32'd0;

   // LFSR single-step advance (taps 32/22/2/1). The DSP TX firmware
   // calls lfsr_next() once per 32-bit word, so consecutive
   // transmitted words are ONE LFSR step apart (not 32 -- this
   // pattern is a sequence of LFSR state snapshots, sent MSB-first
   // per word, not a continuous bit-PRBS).
   function [31:0] adv1(input [31:0] s);
      begin
         adv1 = {s[30:0], (s[31] ^ s[21] ^ s[1] ^ s[0])};
      end
   endfunction

   function [31:0] adv2(input [31:0] s);
      begin
         adv2 = adv1(adv1(s));
      end
   endfunction

   // The word that completes at this clock = {shreg[30:0], ad0_r}
   // (shreg shifted up plus current bit as LSB). Use the IO-flop
   // registered AD0 / AFS, NOT the raw pin wires, so the bit
   // pipeline runs entirely on a clean clock-aligned sample.
   wire [31:0] word_now = {shreg[30:0], ad0_r};

   // Sync state machine: the SPORT enable/preload boundary may
   // drop 0, 1, or 2 words depending on timing. After the first
   // non-zero received word, we don't yet know which case we're
   // in -- so wait for the second received word and pick the
   // skip count (1, 2, or 3 LFSR steps from first_word) that
   // matches it. From then on, compare strictly with adv1 each
   // word. 2'b00 = need first word; 2'b01 = need second word
   // (held for sync resolution); 2'b11 = synced.
   reg [1:0] sync_state = 2'd0;

   always @(posedge aclk_global) begin
      afs_d <= afs_r;
      if (afs_r && !afs_d) begin
         shreg     <= {31'd0, ad0_r};
         bitcnt    <= 6'd1;
         in_frame  <= 1'b1;
         afs_count <= afs_count + 32'd1;
      end else if (in_frame) begin
         shreg <= {shreg[30:0], ad0_r};
         if (bitcnt == 6'd31) begin
            // 32 bits in -- word_now is the completed word.
            bitcnt <= 6'd0;
            in_frame <= 1'b0;
            if (synced || word_now != 32'd0) begin
               wcount <= wcount + 32'd1;
               if (sync_state == 2'd0) begin
                  // First non-zero word captured.
                  first_word <= word_now;
                  sync_state <= 2'd1;
               end else if (sync_state == 2'd1) begin
                  // Second received word: find skip count 1/2/3
                  // that aligns with first_word's LFSR walk.
                  second_word <= word_now;
                  if (word_now == adv1(first_word)) begin
                     expected <= adv2(first_word);
                     synced   <= 1'b1;
                     sync_state <= 2'd3;
                  end else if (word_now == adv2(first_word)) begin
                     expected <= adv1(adv2(first_word));
                     synced   <= 1'b1;
                     sync_state <= 2'd3;
                  end else if (word_now == adv1(adv2(first_word))) begin
                     expected <= adv2(adv2(first_word));
                     synced   <= 1'b1;
                     sync_state <= 2'd3;
                  end else begin
                     // No alignment found in first 3 LFSR steps;
                     // count as error and continue checking
                     // (expected stays as adv2 default).
                     expected <= adv2(first_word);
                     synced   <= 1'b1;
                     sync_state <= 2'd3;
                     ecount <= ecount + 32'd1;
                  end
               end else begin
                  if (wcount == 32'd2)
                     third_word <= word_now;
                  if (word_now != expected)
                     ecount <= ecount + 32'd1;
                  expected <= adv1(expected);
               end
            end
         end else begin
            bitcnt <= bitcnt + 6'd1;
         end
      end
   end

   // --- ACLK toggle for idle detection --------------------------
   reg aclk_toggle = 1'b0;
   always @(posedge aclk_global) aclk_toggle <= ~aclk_toggle;

   // --- 12 MHz domain: idle detect + UART emit ------------------
   reg [2:0] tog_sync = 3'b000;
   always @(posedge clk12) tog_sync <= {tog_sync[1:0], aclk_toggle};
   wire aclk_active = (tog_sync[2] ^ tog_sync[1]);

   reg [16:0] idle_cnt = 17'd0;
   localparam IDLE_THRESH = 17'd60000;
   reg fire_report = 1'b0;
   reg reported    = 1'b0;

   reg [31:0] w_sync = 32'd0;
   reg [31:0] e_sync = 32'd0;
   always @(posedge clk12) w_sync <= wcount;
   always @(posedge clk12) e_sync <= ecount;

   always @(posedge clk12) begin
      if (aclk_active) begin
         idle_cnt <= 17'd0;
      end else if (idle_cnt < IDLE_THRESH) begin
         idle_cnt <= idle_cnt + 17'd1;
      end
      if (!reported && w_sync != 32'd0 && idle_cnt == IDLE_THRESH) begin
         fire_report <= 1'b1;
         reported    <= 1'b1;
      end else begin
         fire_report <= 1'b0;
      end
   end

   // --- UART byte emitter ---------------------------------------
   // Template (92 bytes):
   //   "RX got=NNNNNNNNNN err=NNNNNNNNNN bit_clk=62500000 PASS "
   //   "w1=HHHHHHHH w2=HHHHHHHH w3=HHHHHHHH\r\n"
   //   indices: got digits at msg[7..16] (MSB at [7], LSB at [16]),
   //            err digits at msg[22..31].
   // 10 decimal digits cover the full 32-bit range (max
   // 4,294,967,295), so 2 GiB / 4 = 536,870,912 words fits with
   // room to spare.
   localparam MSG_LEN = 7'd92;
   reg [7:0] msg [0:91];
   initial begin
      msg[0]  = "R"; msg[1]  = "X"; msg[2]  = " ";
      msg[3]  = "g"; msg[4]  = "o"; msg[5]  = "t"; msg[6]  = "=";
      msg[7]  = "0"; msg[8]  = "0"; msg[9]  = "0"; msg[10] = "0";
      msg[11] = "0"; msg[12] = "0"; msg[13] = "0"; msg[14] = "0";
      msg[15] = "0"; msg[16] = "0";
      msg[17] = " "; msg[18] = "e"; msg[19] = "r"; msg[20] = "r";
      msg[21] = "=";
      msg[22] = "0"; msg[23] = "0"; msg[24] = "0"; msg[25] = "0";
      msg[26] = "0"; msg[27] = "0"; msg[28] = "0"; msg[29] = "0";
      msg[30] = "0"; msg[31] = "0";
      msg[32] = " "; msg[33] = "b"; msg[34] = "i"; msg[35] = "t";
      msg[36] = "_"; msg[37] = "c"; msg[38] = "l"; msg[39] = "k";
      msg[40] = "=";
      msg[41] = "6"; msg[42] = "2"; msg[43] = "5"; msg[44] = "0";
      msg[45] = "0"; msg[46] = "0"; msg[47] = "0"; msg[48] = "0";
      msg[49] = " "; msg[50] = "P"; msg[51] = "A"; msg[52] = "S";
      msg[53] = "S";
      msg[54] = " "; msg[55] = "w"; msg[56] = "1"; msg[57] = "=";
      msg[58] = "0"; msg[59] = "0"; msg[60] = "0"; msg[61] = "0";
      msg[62] = "0"; msg[63] = "0"; msg[64] = "0"; msg[65] = "0";
      msg[66] = " "; msg[67] = "w"; msg[68] = "2"; msg[69] = "=";
      msg[70] = "0"; msg[71] = "0"; msg[72] = "0"; msg[73] = "0";
      msg[74] = "0"; msg[75] = "0"; msg[76] = "0"; msg[77] = "0";
      msg[78] = " "; msg[79] = "w"; msg[80] = "3"; msg[81] = "=";
      msg[82] = "0"; msg[83] = "0"; msg[84] = "0"; msg[85] = "0";
      msg[86] = "0"; msg[87] = "0"; msg[88] = "0"; msg[89] = "0";
      msg[90] = "\r"; msg[91] = "\n";
   end

   reg [31:0] nw_latch = 32'd0;
   reg [31:0] ne_latch = 32'd0;
   reg [31:0] w1_latch = 32'd0;
   reg [31:0] w2_latch = 32'd0;
   reg [31:0] w3_latch = 32'd0;
   reg [3:0]  digit_state = 4'd0;
   reg        rendering = 1'b0;

   function [7:0] hex_char(input [3:0] n);
      begin
         hex_char = (n < 4'd10) ? ("0" + n) : ("A" + (n - 4'd10));
      end
   endfunction

   reg [6:0]  send_idx = 7'd0;
   reg        send_start = 1'b0;
   reg [7:0]  send_data = 8'd0;
   wire       uart_busy;
   reg        sending = 1'b0;

   always @(posedge clk12) begin
      send_start <= 1'b0;
      if (fire_report) begin
         nw_latch    <= w_sync;
         ne_latch    <= e_sync;
         w1_latch    <= first_word;
         w2_latch    <= second_word;
         w3_latch    <= third_word;
         rendering   <= 1'b1;
         digit_state <= 4'd0;
      end else if (rendering) begin
         // 10 digits per field; got at msg[7..16], err at msg[22..31]
         // (state 0 renders LSB = msg[16] / msg[31], state 9 renders
         // MSB = msg[7] / msg[22]).
         case (digit_state)
            4'd0: begin msg[16] <= "0" + (nw_latch % 10);
                        msg[31] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd1; end
            4'd1: begin msg[15] <= "0" + (nw_latch % 10);
                        msg[30] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd2; end
            4'd2: begin msg[14] <= "0" + (nw_latch % 10);
                        msg[29] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd3; end
            4'd3: begin msg[13] <= "0" + (nw_latch % 10);
                        msg[28] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd4; end
            4'd4: begin msg[12] <= "0" + (nw_latch % 10);
                        msg[27] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd5; end
            4'd5: begin msg[11] <= "0" + (nw_latch % 10);
                        msg[26] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd6; end
            4'd6: begin msg[10] <= "0" + (nw_latch % 10);
                        msg[25] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd7; end
            4'd7: begin msg[9]  <= "0" + (nw_latch % 10);
                        msg[24] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd8; end
            4'd8: begin msg[8]  <= "0" + (nw_latch % 10);
                        msg[23] <= "0" + (ne_latch % 10);
                        nw_latch <= nw_latch / 10;
                        ne_latch <= ne_latch / 10;
                        digit_state <= 4'd9; end
            4'd9: begin msg[7]  <= "0" + (nw_latch % 10);
                        msg[22] <= "0" + (ne_latch % 10);
                        if (e_sync == 32'd0 && w_sync >= 32'd4096) begin
                           msg[50] <= "P"; msg[51] <= "A";
                           msg[52] <= "S"; msg[53] <= "S";
                        end else begin
                           msg[50] <= "F"; msg[51] <= "A";
                           msg[52] <= "I"; msg[53] <= "L";
                        end
                        msg[58] <= hex_char(w1_latch[31:28]);
                        msg[59] <= hex_char(w1_latch[27:24]);
                        msg[60] <= hex_char(w1_latch[23:20]);
                        msg[61] <= hex_char(w1_latch[19:16]);
                        msg[62] <= hex_char(w1_latch[15:12]);
                        msg[63] <= hex_char(w1_latch[11:8]);
                        msg[64] <= hex_char(w1_latch[7:4]);
                        msg[65] <= hex_char(w1_latch[3:0]);
                        msg[70] <= hex_char(w2_latch[31:28]);
                        msg[71] <= hex_char(w2_latch[27:24]);
                        msg[72] <= hex_char(w2_latch[23:20]);
                        msg[73] <= hex_char(w2_latch[19:16]);
                        msg[74] <= hex_char(w2_latch[15:12]);
                        msg[75] <= hex_char(w2_latch[11:8]);
                        msg[76] <= hex_char(w2_latch[7:4]);
                        msg[77] <= hex_char(w2_latch[3:0]);
                        msg[82] <= hex_char(w3_latch[31:28]);
                        msg[83] <= hex_char(w3_latch[27:24]);
                        msg[84] <= hex_char(w3_latch[23:20]);
                        msg[85] <= hex_char(w3_latch[19:16]);
                        msg[86] <= hex_char(w3_latch[15:12]);
                        msg[87] <= hex_char(w3_latch[11:8]);
                        msg[88] <= hex_char(w3_latch[7:4]);
                        msg[89] <= hex_char(w3_latch[3:0]);
                        rendering   <= 1'b0;
                        sending     <= 1'b1;
                        send_idx    <= 7'd0; end
            default: rendering <= 1'b0;
         endcase
      end else if (sending && !uart_busy && !send_start) begin
         if (send_idx < MSG_LEN) begin
            send_data  <= msg[send_idx];
            send_start <= 1'b1;
            send_idx   <= send_idx + 7'd1;
         end else begin
            sending <= 1'b0;
         end
      end
   end

   uart_tx #(.CLKS_PER_BIT(104)) u_tx (
      .clk(clk12),
      .start(send_start),
      .data(send_data),
      .tx(tx),
      .busy(uart_busy)
   );

endmodule
