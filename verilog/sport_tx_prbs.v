module sport_tx_prbs (
      input  clk12,
      output ad0_out,
      output aclk_out,
      output afs_out
   );

   wire pll_clk;
   wire pll_lock;

   // 12 MHz osc -> 12 * (DIVF+1) / 2^DIVQ = 12 * 83 / 16 = 62.25 MHz,
   // the closest the iCE40 PLL can get to the 62.5 MHz SPORT external-
   // receive ceiling (datasheet Table 19, fSPTCLKEXT RX) from a 12 MHz
   // reference. Matches sport_tx_prbs_multi.v so every FPGA->DSP
   // section runs at the exact same bit clock.
   SB_PLL40_CORE #(
      .FEEDBACK_PATH("SIMPLE"),
      .DIVR(4'd0),
      .DIVF(7'd82),
      .DIVQ(3'd4),
      .FILTER_RANGE(3'd1)
   ) pll (
      .REFERENCECLK(clk12),
      .PLLOUTCORE(pll_clk),
      .LOCK(pll_lock),
      .RESETB(1'b1),
      .BYPASS(1'b0)
   );

   localparam [30:0] PRBS31_SEED   = 31'h7fffffff;
   localparam [31:0] DUMMY_WORD    = 32'hA5A55A5A;
   localparam [13:0] DUMMY_WORDS   = 14'd8192;
   localparam [21:0] IDLE_CYCLES   = 22'd200000;
   localparam [1:0]  PH_DUMMY      = 2'd0;
   localparam [1:0]  PH_IDLE       = 2'd1;
   localparam [1:0]  PH_PATTERN    = 2'd2;

   reg [4:0]  bitcnt      = 5'd0;
   reg [1:0]  phase       = PH_DUMMY;
   reg [13:0] dummy_count = 14'd0;
   reg [21:0] idle_count  = 22'd0;
   reg [30:0] prbs_state  = PRBS31_SEED;
   reg [31:0] shift_word  = 32'd0;
   reg        afs_r       = 1'b0;
   reg        ad0_r       = 1'b0;

   function [31:0] prbs31_word;
      input [30:0] s_in;
      integer i;
      reg [30:0] s;
      reg [31:0] w;
      reg new_bit;
      begin
         s = s_in;
         w = 32'd0;
         for (i = 0; i < 32; i = i + 1) begin
            new_bit = s[30] ^ s[27];
            s = {s[29:0], new_bit};
            w = {w[30:0], new_bit};
         end
         prbs31_word = w;
      end
   endfunction

   function [30:0] prbs31_advance;
      input [30:0] s_in;
      integer i;
      reg [30:0] s;
      reg new_bit;
      begin
         s = s_in;
         for (i = 0; i < 32; i = i + 1) begin
            new_bit = s[30] ^ s[27];
            s = {s[29:0], new_bit};
         end
         prbs31_advance = s;
      end
   endfunction

   wire [31:0] current_payload = prbs31_word(prbs_state);

   // Drive data + AFS on the FALLING edge of pll_clk so the DSP's
   // rising-edge sample sees a value that's already half a period
   // stable. ACLK is forwarded directly from the PLL output.
   always @(negedge pll_clk) begin
      if (!pll_lock) begin
         bitcnt     <= 5'd0;
         phase      <= PH_DUMMY;
         dummy_count <= 14'd0;
         idle_count <= 22'd0;
         prbs_state <= PRBS31_SEED;
         shift_word <= 32'd0;
         afs_r      <= 1'b0;
         ad0_r      <= 1'b0;
      end else begin
         if (phase == PH_IDLE) begin
            afs_r <= 1'b0;
            ad0_r <= 1'b0;
            if (idle_count == IDLE_CYCLES - 22'd1) begin
               phase      <= PH_PATTERN;
               idle_count <= 22'd0;
               bitcnt     <= 5'd0;
            end else begin
               idle_count <= idle_count + 22'd1;
            end
         end else begin
            afs_r <= (bitcnt == 5'd0);
            if (bitcnt == 5'd0) begin
               if (phase == PH_DUMMY) begin
                  ad0_r      <= DUMMY_WORD[31];
                  shift_word <= {DUMMY_WORD[30:0], 1'b0};
               end else begin
                  ad0_r      <= current_payload[31];
                  shift_word <= {current_payload[30:0], 1'b0};
               end
               bitcnt <= 5'd1;
            end else begin
               ad0_r      <= shift_word[31];
               shift_word <= {shift_word[30:0], 1'b0};
               if (bitcnt == 5'd31) begin
                  bitcnt <= 5'd0;
                  if (phase == PH_DUMMY) begin
                     if (dummy_count == DUMMY_WORDS - 14'd1) begin
                        phase       <= PH_IDLE;
                        dummy_count <= 14'd0;
                     end else begin
                        dummy_count <= dummy_count + 14'd1;
                     end
                  end else begin
                     prbs_state <= prbs31_advance(prbs_state);
                  end
               end else begin
                  bitcnt <= bitcnt + 5'd1;
               end
            end
         end
      end
   end

   assign aclk_out = pll_clk;
   assign ad0_out  = ad0_r;
   assign afs_out  = afs_r;

endmodule
