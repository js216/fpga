`timescale 1ns/1ps

module tb_blinky;
   localparam PERIOD = 10;
   
   reg  clk;
   wire led;
   
   blinky #(.PERIOD(PERIOD)) dut (
      .clk(clk), .led(led)
   );
   
   // clock: 10ns period
   initial clk = 0;
   always #5 clk <= ~clk;
   
   integer toggle_count;
   integer cycle_count;
   reg prev_led;
   initial begin
      toggle_count = 0;
      cycle_count = 0;
      prev_led = led;
   
      repeat (5 * PERIOD) begin
         @(negedge clk);
         cycle_count = cycle_count + 1;
         if (led !== prev_led) begin
            toggle_count = toggle_count + 1;
            if (cycle_count != PERIOD) begin
               $display(
                  "FAIL: cycle %0d, exp %0d",
                  cycle_count, PERIOD);
               $fatal(1, "Incorrect toggle period");
            end
            cycle_count = 0;
         end
         prev_led = led;
      end
   
      if (toggle_count != 5) begin
         $display("FAIL: exp 5 toggles, got %0d",
                  toggle_count);
         $fatal(1, "Wrong number of toggles");
      end
      $display("PASS: %0d toggles, period %0d",
               toggle_count, PERIOD);
      $finish;
   end
endmodule
