`timescale 1ns/1ps

module tb_spi_quad;
   reg        cs_n = 1'b1;
   reg        sclk = 1'b0;
   reg        clk = 1'b0;
   wire [3:0] io;
   reg        master_oe = 1'b0;
   reg        master_io0 = 1'b0;
   always #42 clk <= ~clk;
   assign io[0] = master_oe ? master_io0 : 1'bz;
   pullup pu0 (io[0]);
   pullup pu1 (io[1]);
   pullup pu2 (io[2]);
      pullup pu3 (io[3]);
      spi #(.LANES(4), .FRAME_MODE(1)) dut (
         .clk(clk), .cs_n(cs_n), .sclk(sclk), .io(io));
   integer    errs;
   /* verilator lint_off UNUSEDSIGNAL */
   reg [3:0]  first_edge_sample, second_edge_sample;
   /* verilator lint_on UNUSEDSIGNAL */
   reg [3:0]  first_sample, second_sample;
   reg [3:0]  first_late_sample, second_late_sample;
   reg [7:0]  rx;
      task automatic clock_cmd_bit(input bitval);
         begin
            master_io0 = bitval;
            #5;
            sclk = 1'b1;
            #10;
            sclk = 1'b0;
            #5;
         end
      endtask

      task automatic clock_dummy_bit;
         begin
            #5;
            sclk = 1'b1;
            #10;
            sclk = 1'b0;
            #5;
         end
      endtask

      task automatic send_cmd_byte(input [7:0] value);
         integer bitidx;
         begin
            for (bitidx = 7; bitidx >= 0; bitidx = bitidx - 1)
               clock_cmd_bit(value[bitidx]);
         end
      endtask

      task automatic send_frame_header(input [23:0] start);
         integer d;
         begin
            master_oe = 1'b1;
            send_cmd_byte(8'h6b);
            send_cmd_byte(start[23:16]);
            send_cmd_byte(start[15:8]);
            send_cmd_byte(start[7:0]);
            master_oe = 1'b0;
            for (d = 0; d < 8; d = d + 1)
               clock_dummy_bit();
         end
      endtask

         task automatic clock_byte(input integer expected);
               reg [7:0] expected_raw;
               begin
                  expected_raw = expected[7:0];
               #5;
               sclk = 1'b1;
               first_edge_sample = io;
               #8;
               first_sample = io;
                     #1;
                     first_late_sample = io;
                     if (first_late_sample !== first_sample) begin
                        $display("FAIL byte %0d: first nibble changed around late sample point: sample=%x late=%x",
                                 expected, first_sample, first_late_sample);
                        errs = errs + 1;
                     end
               #1;
               sclk = 1'b0;
               #5;
               sclk = 1'b1;
               second_edge_sample = io;
               #8;
               second_sample = io;
                     #1;
                     second_late_sample = io;
                     if (second_late_sample !== second_sample) begin
                        $display("FAIL byte %0d: second nibble changed around late sample point: sample=%x late=%x",
                                 expected, second_sample, second_late_sample);
                        errs = errs + 1;
                     end
                  #1;
                  sclk = 1'b0;
                  rx = {second_sample, first_sample};
            if (rx !== expected_raw) begin
            $display("FAIL byte %0d: got %02x expected %02x",
                     expected, rx, expected_raw);
            errs = errs + 1;
         end
      end
   endtask

         task automatic clock_byte_paused(input integer expected);
               reg [3:0] first_end, second_end;
               reg [7:0] expected_raw;
               begin
                  expected_raw = expected[7:0];
               #5;
               sclk = 1'b1;
               first_edge_sample = io;
               #8;
               first_sample = io;
                     #1;
                     first_late_sample = io;
                     if (first_late_sample !== first_sample) begin
                        $display("FAIL byte %0d paused: first nibble changed around late sample point: sample=%x late=%x",
                                 expected, first_sample, first_late_sample);
                        errs = errs + 1;
                     end
                  #16;
                  first_end = io;
                  if (first_end !== first_sample) begin
                     $display("FAIL byte %0d paused: first nibble changed while SCLK high: start=%x end=%x",
                              expected, first_sample, first_end);
                     errs = errs + 1;
                  end
            sclk = 1'b0;
            #20;
               #5;
               sclk = 1'b1;
               second_edge_sample = io;
               #8;
               second_sample = io;
                     #1;
                     second_late_sample = io;
                     if (second_late_sample !== second_sample) begin
                        $display("FAIL byte %0d paused: second nibble changed around late sample point: sample=%x late=%x",
                                 expected, second_sample, second_late_sample);
                        errs = errs + 1;
                     end
                  #16;
                  second_end = io;
                  if (second_end !== second_sample) begin
                     $display("FAIL byte %0d paused: second nibble changed while SCLK high: start=%x end=%x",
                              expected, second_sample, second_end);
                     errs = errs + 1;
                  end
               sclk = 1'b0;
               rx = {second_sample, first_sample};
         if (rx !== expected_raw) begin
            $display("FAIL byte %0d paused: got %02x expected %02x",
                     expected, rx, expected_raw);
            errs = errs + 1;
         end
      end
   endtask
      task automatic frame_expect(input [23:0] start,
                                  input integer expected_start,
                                  input integer count,
                                  input integer high_gap);
         integer k;
               begin
                  #20 cs_n = 1'b0;
                  #5;
                  send_frame_header(start);
                  for (k = 0; k < count; k = k + 1)
                     clock_byte(expected_start + k);
                  #5 cs_n = 1'b1;
            #(high_gap);
         end
      endtask
      task automatic frame_from(input [23:0] start, input integer count);
         begin
            frame_expect(start, {24'd0, start[7:0]}, count, 500000);
         end
      endtask
      task automatic short_gap_burst;
         begin
            frame_expect(24'd0, 0, 16, 500);
            frame_expect(24'd16, 16, 240, 500000);
         end
      endtask
      task automatic visible_gap_burst;
         begin
            frame_expect(0, 0, 4, 500000);
            frame_expect(0, 0, 64, 500000);
         end
      endtask
      task automatic paused_frame_from(input [23:0] start, input integer count);
         integer k;
               begin
                  #20 cs_n = 1'b0;
               #5;
                  send_frame_header(start);
                  for (k = 0; k < count; k = k + 1)
                     clock_byte_paused({8'd0, start} + k);
                  #5 cs_n = 1'b1;
            #500000;
         end
      endtask
      task automatic cs_high_quiet;
         begin
            #20000;
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
         frame_from(24'h000020, 64);
         cs_high_quiet();
         short_gap_burst();
         cs_high_quiet();
         visible_gap_burst();
      cs_high_quiet();
      paused_frame_from(0, 32);
      cs_high_quiet();
      frame_expect(0, 0, 4096, 500000);
         cs_high_quiet();
         cs_high_quiet();
         if (errs == 0)
            $display("PASS tb_spi_quad: framed bytes plus CS-high checks match");
      else begin
         $display("FAIL tb_spi_quad: %0d mismatches", errs);
         $fatal(1);
      end
      $finish;
   end
endmodule
