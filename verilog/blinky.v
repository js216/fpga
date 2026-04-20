module blinky #(
   parameter PERIOD = 6_000_000,
   parameter WIDTH  = $clog2(PERIOD))
   (
      input  clk,
      output reg led
   );

   reg [WIDTH-1:0] counter;

   initial begin
      counter = 0;
      led     = 0;
   end

   always @(posedge clk) begin
      if (counter == PERIOD - 1) begin
         counter <= 0;
         led <= ~led;
      end else begin
         counter <= counter + 1;
      end
   end

`ifdef FORMAL
   reg f_past_valid;
   initial f_past_valid = 0;
   always @(posedge clk) f_past_valid <= 1;
   initial begin
      assert(counter == 0);
      assert(led == 0);
   end
   always @(posedge clk) begin
      assert(counter < PERIOD);
   end
   always @(posedge clk) begin
      if (f_past_valid) begin
         if ($past(counter) == PERIOD - 1)
            assert(counter == 0);
         else
            assert(counter == $past(counter) + 1);
      end
   end
`endif
endmodule
