`timescale 1ns/1ps

module tb_cordic;
   localparam DW  = 16;
   localparam N_ITER  = 18;
   localparam INTERNAL_WIDTH = 18;
   localparam PHASE_WIDTH = 28;
   localparam real PI = 3.14159265358979323846;
   reg clk_in;
   reg reset;
   reg [PHASE_WIDTH-1:0] ftw;
   wire signed [DW-1:0] wave_out;
   
   cordic #(
      .DW(DW),
      .N_ITER(N_ITER),
      .INTERNAL_WIDTH(INTERNAL_WIDTH),
      .PHASE_WIDTH(PHASE_WIDTH)
   ) dut (
      .clk_in(clk_in), .reset(reset),
      .ftw(ftw), .wave_out(wave_out)
   );
   initial clk_in = 0;
   always #5 clk_in <= ~clk_in;
   real K;
   integer tolerance;
   integer g_max_err, g_pass_cnt;
   task automatic do_reset();
      reset = 1;
      repeat (3) @(posedge clk_in);
      reset = 0;
      repeat (3 * N_ITER) @(posedge clk_in);
   endtask
   task automatic wait_sample();
      repeat (N_ITER) @(posedge clk_in);
   endtask
   function automatic int compute_expected(
      input [PHASE_WIDTH-1:0] acc_phase
   );
      real phase_r, expected_r;
      phase_r = acc_phase * 2.0 * PI / $pow(2.0, PHASE_WIDTH);
      expected_r = $sin(phase_r)
         * K * $pow(2.0, INTERNAL_WIDTH - 2);
      return $rtoi(expected_r) >>> (INTERNAL_WIDTH - DW);
   endfunction
   function automatic int sign_extend_wave();
      return {{(32-DW){wave_out[DW-1]}}, wave_out};
   endfunction
   function automatic int compute_error(
      input int exp_val, input int got_val
   );
      int e;
      e = got_val - exp_val;
      if (e < 0)
         e = -e;
      return e;
   endfunction
   task automatic check_sample(
      input string tag,
      input int exp_val,
      input int got_val
   );
      int err;
      err = got_val - exp_val;
      if (err < 0)
         err = -err;
      if (err > g_max_err)
         g_max_err = err;
      if (err > tolerance) begin
         $display("FAIL [%s]: exp=%0d got=%0d err=%0d",
                  tag, exp_val, got_val, err);
         $fatal(1, "Error exceeds tolerance");
      end
      g_pass_cnt = g_pass_cnt + 1;
   endtask
   task automatic run_streaming(
      input reg [PHASE_WIDTH-1:0] test_ftw,
      input int n_samples,
      input string tag
   );
      int s;
      reg [PHASE_WIDTH-1:0] acc_phase;
      ftw = test_ftw;
      do_reset();
      acc_phase = test_ftw;
      for (s = 0; s < n_samples; s = s + 1) begin
         check_sample(tag, compute_expected(acc_phase),
                      sign_extend_wave());
         if (s < n_samples - 1) begin
            wait_sample();
            acc_phase = acc_phase + test_ftw;
         end
      end
   endtask
   task automatic test_directed_pointwise();
      integer test_idx;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T0: directed pointwise");
      for (test_idx = 0; test_idx < 258;
           test_idx = test_idx + 1) begin
         if (test_idx < 256)
            ftw = test_idx[PHASE_WIDTH-1:0]
                << (PHASE_WIDTH - 8);
         else if (test_idx == 256)
            ftw = 1;
         else
            ftw = {PHASE_WIDTH{1'b1}};
   
         reset = 1;
         repeat (3) @(posedge clk_in);
         reset = 0;
         repeat (3 * N_ITER) @(posedge clk_in);
   
         check_sample("T0",
            compute_expected(ftw),
            sign_extend_wave());
      end
      $display("       PASS %0d vectors, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_directed_streaming();
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T1: directed streaming");
      run_streaming(28'h0000001,  64, "T1"); // min FTW
      run_streaming(28'hFFFFFFF,  64, "T1"); // max FTW (near-Nyquist)
      run_streaming(28'h4000000,  32, "T1"); // 4 samples/cycle
      run_streaming(28'h8000000,  32, "T1"); // 2 samples/cycle
      run_streaming(28'h2000000,  64, "T1"); // 8 samples/cycle
      run_streaming(28'h5555555,  30, "T1"); // wrap every ~3 samples
      run_streaming(28'hAAAAAAA,  30, "T1"); // wrap every ~1.5 samples
      $display("       PASS %0d checks, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_random_streaming();
      int trial;
      reg [PHASE_WIDTH-1:0] test_ftw;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T2: random streaming (10 x 64)");
      for (trial = 0; trial < 10; trial = trial + 1) begin
         test_ftw = $urandom_range((1 << PHASE_WIDTH) - 1, 1)[PHASE_WIDTH-1:0];
         run_streaming(test_ftw, 64, "T2");
      end
      $display("       PASS %0d checks, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_random_drift();
      int trial, s, early_max, total_max, err;
      int exp_val, got_val;
      reg [PHASE_WIDTH-1:0] test_ftw;
      reg [PHASE_WIDTH-1:0] acc_phase;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T3: random drift (3 x 1024)");
      for (trial = 0; trial < 3; trial = trial + 1) begin
         test_ftw = $urandom_range((1 << PHASE_WIDTH) - 1, 1)[PHASE_WIDTH-1:0];
         ftw = test_ftw;
         do_reset();
         early_max = 0;
         total_max = 0;
         acc_phase = test_ftw;
         for (s = 0; s < 1024; s = s + 1) begin
            exp_val = compute_expected(acc_phase);
            got_val = sign_extend_wave();
            check_sample("T3", exp_val, got_val);
            err = compute_error(exp_val, got_val);
            if (err > total_max)
               total_max = err;
            if (s < 100 && err > early_max)
               early_max = err;
            if (s < 1023) begin
               wait_sample();
               acc_phase = acc_phase + test_ftw;
            end
         end
         if (total_max > early_max + 1) begin
            $display("FAIL [T3]: drift: early=%0d total=%0d",
                     early_max, total_max);
            $fatal(1, "Error drift detected");
         end
      end
      $display("       PASS %0d checks, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_random_wraparound();
      int trial, n_samples, wrap_at;
      reg [PHASE_WIDTH-1:0] test_ftw;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T4: wraparound (2 directed + 8 random)");
      run_streaming(28'h5555555, 30, "T4");
      run_streaming(28'hFFFFFFF, 30, "T4");
      for (trial = 0; trial < 8; trial = trial + 1) begin
         test_ftw = $urandom_range(1 << 24, 1 << 20)[PHASE_WIDTH-1:0];
         wrap_at = (1 << PHASE_WIDTH) / {4'b0, test_ftw};
         n_samples = wrap_at + 32;
         run_streaming(test_ftw, n_samples, "T4");
      end
      $display("       PASS %0d checks, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_random_ftw_change();
      int trial, s;
      reg [PHASE_WIDTH-1:0] ftw1, ftw2;
      reg [PHASE_WIDTH-1:0] acc_phase;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T5: random FTW change (10 trials)");
      for (trial = 0; trial < 10; trial = trial + 1) begin
         ftw1 = $urandom_range((1 << PHASE_WIDTH) - 1, 1)[PHASE_WIDTH-1:0];
         ftw2 = $urandom_range((1 << PHASE_WIDTH) - 1, 1)[PHASE_WIDTH-1:0];
         ftw = ftw1;
         do_reset();
         acc_phase = ftw1;
         for (s = 0; s < 16; s = s + 1) begin
            check_sample("T5a",
               compute_expected(acc_phase),
               sign_extend_wave());
            if (s < 15) begin
               wait_sample();
               acc_phase = acc_phase + ftw1;
            end
         end
         ftw = ftw2;
         for (s = 0; s < 2; s = s + 1) begin
            wait_sample();
            acc_phase = acc_phase + ftw1;
            check_sample("T5p",
               compute_expected(acc_phase),
               sign_extend_wave());
         end
         for (s = 0; s < 32; s = s + 1) begin
            wait_sample();
            acc_phase = acc_phase + ftw2;
            check_sample("T5b",
               compute_expected(acc_phase),
               sign_extend_wave());
         end
      end
      $display("       PASS %0d checks, max err = %0d / %0d LSB",
               g_pass_cnt, g_max_err, tolerance);
   endtask
   task automatic test_random_monotonicity();
      int trial, s, n_quarter, n_check;
      int prev_val, cur_val;
      reg [PHASE_WIDTH-1:0] test_ftw;
      g_max_err = 0;
      g_pass_cnt = 0;
      $display("  T6: random monotonicity (8 trials)");
      for (trial = 0; trial < 8; trial = trial + 1) begin
         test_ftw = $urandom_range(1 << 21, 1 << 18)[PHASE_WIDTH-1:0];
         ftw = test_ftw;
         do_reset();
         n_quarter = (1 << (PHASE_WIDTH - 2)) / {4'b0, test_ftw};
         n_check = (n_quarter * 4) / 5;
         if (n_check < 2)
            n_check = 2;
         prev_val = sign_extend_wave();
         g_pass_cnt = g_pass_cnt + 1;
         for (s = 1; s < n_check; s = s + 1) begin
            wait_sample();
            cur_val = sign_extend_wave();
            if (cur_val < prev_val) begin
               $display(
                  "FAIL [T6]: s=%0d prev=%0d cur=%0d FTW=%h",
                  s, prev_val, cur_val, test_ftw);
               $fatal(1, "Monotonicity violation");
            end
            prev_val = cur_val;
            g_pass_cnt = g_pass_cnt + 1;
         end
      end
      $display("       PASS %0d checks", g_pass_cnt);
   endtask
   initial begin
      K = 1.0;
      for (int j = 0; j < N_ITER - 2; j = j + 1)
         K = K * $sqrt(1.0 + $pow(2.0, -2.0 * j));
      // tolerance: angular + truncation + output (see error analysis)
      tolerance = $rtoi($ceil(
         $atan($pow(2.0, -(N_ITER - 3)))
         * K * $pow(2.0, INTERNAL_WIDTH - 2)
         / $pow(2.0, INTERNAL_WIDTH - DW)
         + (N_ITER - 2.0)
         / $pow(2.0, INTERNAL_WIDTH - DW)
         + 1.0));
      $display("K = %f, tolerance = %0d LSB", K, tolerance);
      $display("=== CORDIC testbench ===");
      test_directed_pointwise();
      test_directed_streaming();
      test_random_streaming();
      test_random_drift();
      test_random_wraparound();
      test_random_ftw_change();
      test_random_monotonicity();
      $display("ALL TESTS PASSED");
      $finish;
   end
endmodule
