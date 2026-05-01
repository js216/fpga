`timescale 1ns/1ps

module tb_spi_1lane;
   reg        cs_n = 1'b1;
   reg        sclk = 1'b0;
   wire [3:0] io;
   pullup pu0 (io[0]);
   pullup pu1 (io[1]);
   pullup pu2 (io[2]);
   pullup pu3 (io[3]);
   spi #(.LANES(1)) dut (.cs_n(cs_n), .sclk(sclk), .io(io));
   integer   errs;
   reg [7:0] rx_io0;
   reg [7:0] rx_io1;
   task automatic clock_byte(input integer expected);
      integer i;
      begin
         rx_io0 = 8'd0;
         rx_io1 = 8'd0;
         for (i = 0; i < 8; i = i + 1) begin
            #5 sclk = 1'b1;
            rx_io0 = {rx_io0[6:0], io[0]};
            rx_io1 = {rx_io1[6:0], io[1]};
            #5 sclk = 1'b0;
         end
         if (rx_io0 !== expected[7:0] || rx_io1 !== expected[7:0]) begin
            $display("FAIL byte %0d: io0=%02x io1=%02x expected %02x",
                     expected, rx_io0, rx_io1, expected[7:0]);
            errs = errs + 1;
         end
      end
   endtask
   task automatic frame(input integer count);
      integer k;
      begin
         #20 cs_n = 1'b0;
         #5;
         for (k = 0; k < count; k = k + 1)
            clock_byte(k);
         #5 cs_n = 1'b1;
         #20;
      end
   endtask
   task automatic cs_high_quiet;
      begin
         #5 sclk = 1'b1;
         if (io !== 4'b1111) begin
            $display("FAIL cs-high: io=%b expected 1111 (slave should release)",
                     io);
            errs = errs + 1;
         end
         #5 sclk = 1'b0;
      end
   endtask
   initial begin
      errs = 0;
      cs_high_quiet();
      cs_high_quiet();
      frame(256);
      frame(4096);
      cs_high_quiet();
      cs_high_quiet();
      if (errs == 0)
         $display("PASS tb_spi_1lane: 4352 bytes plus CS-high checks match");
      else
         $display("FAIL tb_spi_1lane: %0d mismatches", errs);
      $finish;
   end
endmodule
