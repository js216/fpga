`timescale 1ns/1ps

module tb_spi_quad;
   reg        cs_n = 1'b1;
   reg        sclk = 1'b0;
   wire [3:0] io;
   pullup pu0 (io[0]);
   pullup pu1 (io[1]);
   pullup pu2 (io[2]);
   pullup pu3 (io[3]);
   spi #(.LANES(4)) dut (.cs_n(cs_n), .sclk(sclk), .io(io));
   integer    errs;
   reg [3:0]  first_sample, second_sample;
   reg [7:0]  rx;
   task automatic clock_byte(input integer expected);
      begin
         #5 sclk = 1'b1;
         #1;
         first_sample = io;
         #4 sclk = 1'b0;
         #5 sclk = 1'b1;
         #1;
         second_sample = io;
         #4 sclk = 1'b0;
         rx = {first_sample, second_sample};
         if (rx !== expected[7:0]) begin
            $display("FAIL byte %0d: got %02x expected %02x",
                     expected, rx, expected[7:0]);
            errs = errs + 1;
         end
      end
   endtask
   
   task automatic clock_byte_paused(input integer expected);
      begin
         #5 sclk = 1'b1;
         #1;
         first_sample = io;
         #19;
         if (io !== first_sample) begin
            $display("FAIL byte %0d upper-pause: io changed from %x to %x",
                     expected, first_sample, io);
            errs = errs + 1;
         end
         sclk = 1'b0;
         #20;
         if (io !== expected[3:0]) begin
            $display("FAIL byte %0d low-pause: io=%x expected lower nibble %x",
                     expected, io, expected[3:0]);
            errs = errs + 1;
         end
         #5 sclk = 1'b1;
         #1;
         second_sample = io;
         #19;
         if (io !== second_sample) begin
            $display("FAIL byte %0d lower-pause: io changed from %x to %x",
                     expected, second_sample, io);
            errs = errs + 1;
         end
         #4 sclk = 1'b0;
         rx = {first_sample, second_sample};
         if (rx !== expected[7:0]) begin
            $display("FAIL byte %0d paused: got %02x expected %02x",
                     expected, rx, expected[7:0]);
            errs = errs + 1;
         end
      end
   endtask
   task automatic frame_from(input integer start, input integer count);
      integer k;
      begin
         #20 cs_n = 1'b0;
         #5;
         for (k = 0; k < count; k = k + 1)
            clock_byte(start + k);
         #5 cs_n = 1'b1;
         #20;
      end
   endtask
   task automatic paused_frame_from(input integer start, input integer count);
      integer k;
      begin
         #20 cs_n = 1'b0;
         #5;
         for (k = 0; k < count; k = k + 1)
            clock_byte_paused(start + k);
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
      frame_from(0, 256);
      cs_high_quiet();
      /* Each CS-low interval restarts the slave's byte counter at zero,
       * so the paused and long frames also expect bytes 0,1,2,...  This
       * matches the deterministic-seed behaviour of spi.v's quad block. */
      paused_frame_from(0, 32);
      cs_high_quiet();
      frame_from(0, 4096);
      cs_high_quiet();
      cs_high_quiet();
      if (errs == 0)
         $display("PASS tb_spi_quad: 4384 bytes plus CS-high checks match");
      else
         $display("FAIL tb_spi_quad: %0d mismatches", errs);
      $finish;
   end
endmodule
