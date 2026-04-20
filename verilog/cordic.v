module cordic #(
   parameter DW=16,
   N_ITER=18,
   INTERNAL_WIDTH=18,
   PHASE_WIDTH=28)
   (
      input clk_in,
      input reset,
      input [PHASE_WIDTH-1:0] ftw, // frequency tuning word
      output reg signed [DW-1:0] wave_out
   );

   localparam [INTERNAL_WIDTH-1:0] ampl_in
      = 1 << (INTERNAL_WIDTH - 2);
   reg [$clog2(N_ITER-1):0] i;
   reg signed [PHASE_WIDTH-1:0] phase;
   reg signed [INTERNAL_WIDTH-1:0]  sin_out;
   reg signed [INTERNAL_WIDTH-1:0]  cos_out;
   
   // phase accumulator
   reg signed [PHASE_WIDTH-1:0] phase_acc;
   wire [1:0] quadrant = phase_acc[PHASE_WIDTH-1:PHASE_WIDTH-2];
   always @(posedge(clk_in)) begin
      if (reset)
         begin
            i <= 0;
            phase <= 0;
            sin_out <= 0;
            cos_out <= 0;
            phase_acc <= 0;
         end
      else begin
         i <= i + 1;
         if (i == N_ITER-1)
            begin
               i <= 0;
               sin_out <= 0;
               phase_acc <= phase_acc + ftw;
               phase <= {phase_acc[PHASE_WIDTH-2], phase_acc[PHASE_WIDTH-2:0]};
               wave_out <= sin_out[INTERNAL_WIDTH-1:INTERNAL_WIDTH-DW];
            
               if ((quadrant == 1) || (quadrant == 2))
                  cos_out <= -ampl_in;
               else
                  cos_out <= ampl_in;
            end
         else
            begin
               // for negative phase angle
               if (phase[PHASE_WIDTH-1]) begin
                  cos_out <= cos_out + (sin_out >>> (i-1));
                  sin_out <= sin_out - (cos_out >>> (i-1));
                  phase <= phase + cordic_angle[i-1];
               end
            
               // for positive phase angle
               else begin
                  cos_out <= cos_out - (sin_out >>> (i-1));
                  sin_out <= sin_out + (cos_out >>> (i-1));
                  phase <= phase - cordic_angle[i-1];
               end
            end
      end
   end
   wire [PHASE_WIDTH-1:0] cordic_angle [N_ITER];
   assign cordic_angle[ 0] = 28'h2000000; // 45.000000 deg
   assign cordic_angle[ 1] = 28'h12e4051; // 26.565050 deg
   assign cordic_angle[ 2] = 28'h09fb385; // 14.036243 deg
   assign cordic_angle[ 3] = 28'h051111d; //  7.125016 deg
   assign cordic_angle[ 4] = 28'h028b0d4; //  3.576334 deg
   assign cordic_angle[ 5] = 28'h0145d7e; //  1.789910 deg
   assign cordic_angle[ 6] = 28'h00a2f61; //  0.895173 deg
   assign cordic_angle[ 7] = 28'h00517c5; //  0.447614 deg
   assign cordic_angle[ 8] = 28'h0028be5; //  0.223810 deg
   assign cordic_angle[ 9] = 28'h00145f2; //  0.111904 deg
   assign cordic_angle[10] = 28'h000a2f9; //  0.055952 deg
   assign cordic_angle[11] = 28'h000517c; //  0.027975 deg
   assign cordic_angle[12] = 28'h00028be; //  0.013988 deg
   assign cordic_angle[13] = 28'h000145f; //  0.006994 deg
   assign cordic_angle[14] = 28'h0000a2f; //  0.003496 deg
   assign cordic_angle[15] = 28'h0000517; //  0.001747 deg
   assign cordic_angle[16] = 28'h000028b; //  0.000873 deg
   assign cordic_angle[17] = 28'h0000145; //  0.000436 deg
`ifdef FORMAL
   initial assume(reset);
   reg f_past_valid;
   initial f_past_valid = 0;
   always @(posedge clk_in) f_past_valid <= 1;
   always @(posedge clk_in) begin
      if (f_past_valid && $past(reset)) begin
         assert(i == 0);
         assert(phase == 0);
         assert(sin_out == 0);
         assert(cos_out == 0);
         assert(phase_acc == 0);
      end
   end
   always @(posedge clk_in) begin
      if (f_past_valid && !reset && !$past(reset)
          && i == 0) begin
         if ($past(quadrant) == 2'd1
             || $past(quadrant) == 2'd2)
            assert(cos_out < 0);
         else
            assert(cos_out > 0);
      end
   end
`endif
endmodule
