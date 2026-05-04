`timescale 1ns/1ps

module tb_jedec;
   localparam CLKS_PER_BIT = 104;

   reg clk;
   initial clk = 0;
   always #5 clk <= ~clk;

   reg       cs_n, sclk;
   wire      tx;

   // Master-side tri-state drivers for the four IO pins. Each lane
   // is driven by the TB only when its `oe` bit is set; otherwise
   // the TB leaves the line as 1'bz so the DUT can drive it. The
   // DUT exposes the lines as `inout [3:0] io` with its own
   // tri-state enables per lane.
   reg  [3:0] tb_io_out;
   reg  [3:0] tb_io_oe;
   wire [3:0] io;
   genvar gi;
   generate
      for (gi = 0; gi < 4; gi = gi + 1) begin : tb_io_drivers
         assign io[gi] = tb_io_oe[gi] ? tb_io_out[gi] : 1'bz;
      end
   endgenerate

   // Convenience handles for the TB's single-lane view. `mosi` is
   // the TB-driven line into the DUT (io[0] when oe is set); `miso`
   // is the DUT's single-lane response line (io[1] read back).
   wire miso = io[1];

   jedec dut (
      .clk (clk),
      .cs_n(cs_n),
      .sclk(sclk),
      .io  (io),
      .tx  (tx)
   );

   initial begin
      cs_n     = 1;
      sclk     = 0;
      tb_io_out = 4'b0000;
      tb_io_oe  = 4'b0000;
   end

   // Shorthand: a single-lane spi_byte sets TB oe to drive only
   // io[0] (MOSI). A quad sample routine drops all oe so the DUT
   // can drive all four IO pins during a 0x6B data phase.
   task automatic set_mosi_drive();
      begin
         tb_io_oe = 4'b0001;
      end
   endtask
   task automatic release_io();
      begin
         tb_io_oe  = 4'b0000;
         tb_io_out = 4'b0000;
      end
   endtask

   wire       sniff_ready;
   wire [7:0] sniff_data;
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) sniffer (
      .clk  (clk),
      .rx   (tx),
      .ready(sniff_ready),
      .data (sniff_data)
   );

   reg [7:0] rx_queue [0:255];
   reg [7:0] rx_head, rx_tail;
   initial begin rx_head = 0; rx_tail = 0; end
   always @(posedge clk) begin
      if (sniff_ready) begin
         rx_queue[rx_head] <= sniff_data;
         rx_head <= rx_head + 1;
      end
   end

   string     line;
   // SCLK timing knobs. The legacy slow path uses #60/#120/#60 per
   // bit (240 ns => ~4.17 MHz). Tests at the end push these much
   // smaller to verify the redesigned sclk-domain capture path runs
   // cleanly at 50 MHz and beyond.
   integer t_q  = 60;   // quarter-bit setup window
   integer t_h  = 120;  // SCLK high duration
   reg [31:0] oracle_crc;
   function automatic [31:0] crc32_step(input [31:0] c, input bit_in);
      crc32_step = (c >> 1)
                 ^ ((c[0] ^ bit_in) ? 32'hEDB88320 : 32'h00000000);
   endfunction
   function automatic [31:0] crc32_byte(input [31:0] c, input [7:0] b);
      crc32_byte = crc32_step(crc32_step(crc32_step(crc32_step(
                     crc32_step(crc32_step(crc32_step(crc32_step(
                        c, b[0]), b[1]), b[2]), b[3]),
                                 b[4]), b[5]), b[6]), b[7]);
   endfunction

   // Drive one SPI byte, MSB first, and capture MISO MSB-first on
   // SCLK rising edges (mode 0 -- master samples on rise). Each half
   // period is 12 FPGA clk cycles (clk = 10 ns, half-period = 120 ns
   // => ~4.17 MHz SCLK), slow enough to exercise the real multi-cycle
   // gap between sclk_rise and sclk_fall on the DUT. The `driven`
   // flag gates `oracle_crc` accumulation: pass 1 for opcode /
   // address / dummy / write-data bytes (master-driven on MOSI), 0
   // for bytes clocked only to read MISO from the slave.
   task automatic spi_byte(input [7:0] b, input driven, output [7:0] got);
      integer i;
      begin
         tb_io_oe = 4'b0001; // drive only io[0] = MOSI
         got = 8'h00;
         for (i = 7; i >= 0; i = i - 1) begin
            tb_io_out[0] = b[i];
            #(t_q);
            sclk = 1;
            got[i] = miso;
            #(t_h);
            sclk = 0;
            #(t_q);
         end
         if (driven) oracle_crc = crc32_byte(oracle_crc, b);
      end
   endtask

   // Send-only variant used wherever the slave's MISO byte is
   // ignored (opcode and address bytes of write/program frames,
   // dummy clocks ahead of slave-driven phases).
   task automatic spi_send(input [7:0] b, input driven);
      integer i;
      begin
         tb_io_oe = 4'b0001;
         for (i = 7; i >= 0; i = i - 1) begin
            tb_io_out[0] = b[i];
            #(t_q);
            sclk = 1;
            #(t_h);
            sclk = 0;
            #(t_q);
         end
         if (driven) oracle_crc = crc32_byte(oracle_crc, b);
      end
   endtask

   // 0x6B dummy byte: master tri-states all four IO lines for 8
   // SCLK cycles and does not sample anything useful on MISO.
   task automatic spi_dummy_quad();
      integer i;
      begin
         tb_io_oe  = 4'b0000;
         tb_io_out = 4'b0000;
         for (i = 0; i < 8; i = i + 1) begin
            #(t_q);
            sclk = 1;
            #(t_h);
            sclk = 0;
            #(t_q);
         end
      end
   endtask

   // 0x6B data byte: master tri-states all four IO lines and
   // samples IO[3:0] on each SCLK rise. Two rises per data byte.
   // The slave drives UPPER nibble on the first negedge and LOWER
   // on the second.
   //
   // Sampling cadence matches a real QSPI master and also asserts
   // the bus does not change while SCLK is high. Each nibble is read
   // immediately after the rising edge and again at the end of the
   // high pulse; the two samples must match, and the end sample is
   // what the byte assembler consumes.
   task automatic spi_quad_data_byte(output [7:0] got);
      reg [3:0] first_start, first_nib;
      reg [3:0] second_start, second_nib;
      begin
         tb_io_oe  = 4'b0000;
         tb_io_out = 4'b0000;
         #(t_q);
         sclk = 1;
         #1;
         first_start = io[3:0];
         if (t_h > 1) #(t_h - 1);
         first_nib = io[3:0];   // UPPER nibble of the byte
         if (first_start !== first_nib)
            $fatal(1, "FAIL: 6B upper nibble changed while SCLK high: start=%b end=%b",
                   first_start, first_nib);
         sclk = 0;
         #(t_q);
         sclk = 1;
         #1;
         second_start = io[3:0];
         if (t_h > 1) #(t_h - 1);
         second_nib = io[3:0];  // LOWER nibble of the byte
         if (second_start !== second_nib)
            $fatal(1, "FAIL: 6B lower nibble changed while SCLK high: start=%b end=%b",
                   second_start, second_nib);
         sclk = 0;
         #(t_q);
         got = {first_nib, second_nib};
      end
   endtask

   // Master-side quad data write (0x32 data phase). Master drives
   // all four IO pins at one nibble per SCLK cycle using the same
   // JEDEC nibble mapping as the quad-output path. Also folds the
   // byte into `oracle_crc` (master-driven).
   task automatic spi_quad_write_byte(input [7:0] b);
      begin
         tb_io_oe  = 4'b1111;
         tb_io_out = b[7:4];   // upper nibble: IO3=b7 .. IO0=b4
         #(t_q);
         sclk = 1;
         #(t_h);
         sclk = 0;
         #(t_q);
         tb_io_out = b[3:0];   // lower nibble: IO3=b3 .. IO0=b0
         #(t_q);  // wait; second half of the previous cycle already
         sclk = 1;
         #(t_h);
         sclk = 0;
         #(t_q);
         oracle_crc = crc32_byte(oracle_crc, b);
      end
   endtask

   // Format and compare a captured log line against the step-9
   // schema: `op=<hh> bytes=<dd> mosi_crc=<8hex>`. The byte count
   // is displayed modulo 100 by the DUT's 2-digit printer; for the
   // streaming tests we pass the value already taken modulo 100 so
   // the expected string lines up with what the DUT emits.
   // Parse and compare a captured log line against an expected
   // `prefix` and finalised CRC (prefix should be e.g. "op=9f
   // bytes=4"; the CRC is appended as " mosi_crc=hhhhhhhh").
   task automatic expect_line(input string prefix, input [31:0] crc);
      string expected;
      begin
         expected = $sformatf("%s mosi_crc=%08h", prefix, crc);
         recv_line(line);
         $display("captured: %s", line);
         if (line != expected)
            $fatal(1, "FAIL: want '%s' got '%s'", expected, line);
      end
   endtask

   // Pop bytes from the sniffer queue until an LF, returning the
   // line (CR stripped) as a string.
   task automatic recv_line(output string s);
      reg [7:0] b;
      reg       done;
      begin
         s = "";
         done = 0;
         while (!done) begin
            while (rx_head === rx_tail) @(posedge clk);
            b = rx_queue[rx_tail];
            rx_tail = rx_tail + 1;
            if (b == 8'h0a) done = 1;
            else if (b != 8'h0d) s = {s, string'(b)};
         end
      end
   endtask

   reg [7:0] got0, got1, got2, got3;

   initial begin
      repeat (50) @(posedge clk);

      // Frame 1: 0x9F + 3 dummy bytes (total 4 bytes).
      oracle_crc      = 32'hFFFFFFFF;
      @(posedge clk);
      // Before CS falls: all OEs must be low.
      if (dut.io_oe !== 4'b0000)
         $fatal(1, "FAIL: pre-frame io_oe = %b, want 0000", dut.io_oe);
      cs_n = 0;
      #200;
      // Opcode phase (master driving io[0]): all OEs still low.
      if (dut.io_oe !== 4'b0000)
         $fatal(1, "FAIL: opcode-phase io_oe = %b, want 0000", dut.io_oe);
      spi_byte(8'h9F, 1'b1, got0);   // opcode (master-driven)
      // After opcode boundary the slave drives io[1] (single-lane MISO)
      // for the data phase. Other lanes remain Hi-Z.
      spi_byte(8'h00, 1'b0, got1);   // read phase (slave-driven)
      if (dut.io_oe !== 4'b0010)
         $fatal(1, "FAIL: 9F data-phase io_oe = %b, want 0010", dut.io_oe);
      spi_byte(8'h00, 1'b0, got2);
      if (dut.io_oe !== 4'b0010)
         $fatal(1, "FAIL: 9F data-phase io_oe = %b, want 0010", dut.io_oe);
      spi_byte(8'h00, 1'b0, got3);
      #200 cs_n = 1;
      #50;
      if (dut.io_oe !== 4'b0000)
         $fatal(1, "FAIL: post-CS io_oe = %b, want 0000", dut.io_oe);

      $display("MISO trace: byte0=%02h byte1=%02h byte2=%02h byte3=%02h",
               got0, got1, got2, got3);
      if (got1 !== 8'h20) $fatal(1, "FAIL: MISO byte1 = %02h", got1);
      if (got2 !== 8'h20) $fatal(1, "FAIL: MISO byte2 = %02h", got2);
      if (got3 !== 8'h14) $fatal(1, "FAIL: MISO byte3 = %02h", got3);
      expect_line("op=9f bytes=4", oracle_crc ^ 32'hFFFFFFFF);
      oracle_crc      = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0;
      #200;
      spi_byte(8'hBB, 1'b1, got0);
      #200 cs_n = 1;

      $display("MISO trace (non-9F): byte0=%02h", got0);
      if (got0 !== 8'h00) $fatal(1, "FAIL: MISO on non-9F = %02h", got0);
      expect_line("op=bb bytes=1", oracle_crc ^ 32'hFFFFFFFF);
      oracle_crc      = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0;
      #200;
      spi_byte(8'h05, 1'b1, got0);
      spi_byte(8'h00, 1'b0, got1);
      #200 cs_n = 1;

      $display("MISO trace (05): byte0=%02h byte1=%02h", got0, got1);
      if (got1 !== 8'h00) $fatal(1, "FAIL: RDSR MISO byte1 = %02h", got1);
      expect_line("op=05 bytes=2", oracle_crc ^ 32'hFFFFFFFF);

      // Frame 3b: WREN, then RDSR -- expect SR bit1 (WEL) = 1.
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h06, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=06 bytes=1", oracle_crc ^ 32'hFFFFFFFF);
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h05, 1'b1, got0);
      spi_byte(8'h00, 1'b0, got1);
      #200 cs_n = 1;
      $display("MISO trace (05 post-WREN): byte0=%02h byte1=%02h", got0, got1);
      if (got1 !== 8'h02)
         $fatal(1, "FAIL: RDSR after WREN expected 0x02, got %02h", got1);
      expect_line("op=05 bytes=2", oracle_crc ^ 32'hFFFFFFFF);

      // Frame 3c: WRDI, then RDSR -- expect SR bit1 (WEL) = 0.
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h04, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=04 bytes=1", oracle_crc ^ 32'hFFFFFFFF);
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h05, 1'b1, got0);
      spi_byte(8'h00, 1'b0, got1);
      #200 cs_n = 1;
      $display("MISO trace (05 post-WRDI): byte0=%02h byte1=%02h", got0, got1);
      if (got1 !== 8'h00)
         $fatal(1, "FAIL: RDSR after WRDI expected 0x00, got %02h", got1);
      expect_line("op=05 bytes=2", oracle_crc ^ 32'hFFFFFFFF);

      // Slave drives 16 pattern bytes starting at addr 0: 0,1,...,15.
      begin : frame4
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0;
         #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1) begin
            spi_byte(8'h00, 1'b0, got_arr[k]);
            end
         #200 cs_n = 1;

         $write("MISO trace (03 pattern at addr 0):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: 03 pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 5: 0x02 without WREN. Slave drives nothing.
      oracle_crc      = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h02, 1'b1, got0);
      spi_byte(8'h00, 1'b1, got0);
      spi_byte(8'h00, 1'b1, got0);
      spi_byte(8'h00, 1'b1, got0);
      spi_byte(8'hAA, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=02 bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      // Frame 6: 0x03 read at addr 0 -- pattern reads are
      // independent of the page buffer, so this just confirms the
      // pattern source is unaffected by a prior no-WEL 0x02 frame.
      begin : frame6
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_byte(8'h00, 1'b0, got0);
         #200 cs_n = 1;
         $display("MISO trace (03 after no-WEL 02): %02h", got0);
         if (got0 !== 8'h00)
            $fatal(1, "FAIL: 03 pattern at addr 0: got %02h, want 00", got0);
         expect_line("op=03 bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 7: WREN.
      oracle_crc      = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h06, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=06 bytes=1", oracle_crc ^ 32'hFFFFFFFF);
      begin : frame8
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h02, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_send(8'h50 + k[7:0], 1'b1);
         #200 cs_n = 1;
         expect_line("op=02 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 9: 0x03 read at addr 0x000010 -- expect pattern
      // 0x10..0x1F. Confirms the address LSB is captured into
      // the pattern counter.
      begin : frame9
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);  // opcode
         spi_send(8'h00, 1'b1);  // addr [23:16]
         spi_send(8'h00, 1'b1);  // addr [15:8]
         spi_send(8'h10, 1'b1);  // addr [7:0]
         for (k = 0; k < 16; k = k + 1) begin
            spi_byte(8'h00, 1'b0, got_arr[k]);
            end
         #200 cs_n = 1;
         $write("MISO trace (03 pattern at addr 0x10):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== (8'h10 + k[7:0]))
               $fatal(1, "FAIL: 03 pattern at 0x10 data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'h10 + k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 10: 0x0B Fast Read -- slave drives 16 data bytes.
      begin : frame10
         reg [7:0] got_dummy;
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h0B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h80, 1'b1);  // addr LSB = 0x80
         spi_byte(8'h00, 1'b0, got_dummy);  // not slave-driven
         for (k = 0; k < 16; k = k + 1) begin
            spi_byte(8'h00, 1'b0, got_arr[k]);
            end
         #200 cs_n = 1;
         $display("MISO during 0x0B dummy byte: %02h", got_dummy);
         if (got_dummy !== 8'h00)
            $fatal(1, "FAIL: 0x0B dummy MISO = %02h, want 00", got_dummy);
         $write("MISO trace (0B pattern at addr 0x80):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== (8'h80 + k[7:0]))
               $fatal(1, "FAIL: 0B pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'h80 + k[7:0]);
         expect_line("op=0b bytes=21", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 11: 0x6B Quad Output Read -- slave drives 16 quad
      // pattern bytes starting at addr 0xFE so the wrap from 0xFF
      // back to 0x00 is exercised on the quad path.
      begin : frame11
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);

         release_io();
         if (tb_io_oe !== 4'b0000)
            $fatal(1, "FAIL: TB did not release IO before 0x6B frame");

         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'hFE, 1'b1);  // addr LSB = 0xFE -- exercises wrap
         // Probe the DUT's per-lane output enable: must be 0 during
         // the dummy byte (master tri-states all four lanes), and
         // must turn on for all four lanes once the data phase
         // begins. Step-13 hardware bug: only 3 of 4 lanes actually
         // drove during the data phase, so the master saw the bus
         // idle state (0xDD) instead of slave data.
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6B io_oe asserted during dummy: %b",
                   dut.io_oe);
         spi_dummy_quad();
         if (dut.io_oe !== 4'b1111)
            $fatal(1, "FAIL: 6B io_oe must drive all 4 lanes after dummy, got %b",
                   dut.io_oe);
         for (k = 0; k < 16; k = k + 1) begin
            spi_quad_data_byte(got_arr[k]);
            if (dut.io_oe !== 4'b1111)
               $fatal(1, "FAIL: 6B io_oe dropped during data byte %0d: %b",
                      k, dut.io_oe);
            end
         #200 cs_n = 1;

         #100;
         if (io !== 4'bzzzz)
            $fatal(1, "FAIL: DUT did not release IO after CS rise, io=%b", io);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6B io_oe must drop after CS rise: %b",
                   dut.io_oe);

         $write("QUAD trace (6B pattern at addr 0xFE):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== (8'hFE + k[7:0]))
               $fatal(1, "FAIL: 6B pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'hFE + k[7:0]);
         expect_line("op=6b bytes=9", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 11b: 0x6C Quad Output Read -- same framing as 0x6B
      // but emits one-hot nibbles 1,2,4,8,... for lane/phase
      // diagnostics. Upper-first byte assembly yields 12 48 ...
      begin : frame11b
         reg [7:0] got_arr [0:15];
         integer   k;
         reg [7:0] want;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);

         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6C, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6C io_oe asserted during dummy: %b",
                   dut.io_oe);
         spi_dummy_quad();
         if (dut.io_oe !== 4'b1111)
            $fatal(1, "FAIL: 6C io_oe must drive all 4 lanes after dummy, got %b",
                   dut.io_oe);
         for (k = 0; k < 16; k = k + 1) begin
            spi_quad_data_byte(got_arr[k]);
            if (dut.io_oe !== 4'b1111)
               $fatal(1, "FAIL: 6C io_oe dropped during data byte %0d: %b",
                      k, dut.io_oe);
         end
         #200 cs_n = 1;

         #100;
         if (io !== 4'bzzzz)
            $fatal(1, "FAIL: DUT did not release IO after 6C CS rise, io=%b", io);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6C io_oe must drop after CS rise: %b",
                   dut.io_oe);

         $write("QUAD trace (6C one-hot nibbles):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1) begin
            want = k[0] ? 8'h48 : 8'h12;
            if (got_arr[k] !== want)
               $fatal(1, "FAIL: 6C one-hot data[%0d]=%02h want %02h",
                      k, got_arr[k], want);
         end
         expect_line("op=6c bytes=9", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 11c: 0x6D Quad Output Read -- same framing as 0x6B
      // but emits byte diagnostics 06..0d repeatedly.
      begin : frame11c
         reg [7:0] got_arr [0:15];
         integer   k;
         reg [7:0] want;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);

         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6D, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6D io_oe asserted during dummy: %b",
                   dut.io_oe);
         spi_dummy_quad();
         if (dut.io_oe !== 4'b1111)
            $fatal(1, "FAIL: 6D io_oe must drive all 4 lanes after dummy, got %b",
                   dut.io_oe);
         for (k = 0; k < 16; k = k + 1) begin
            spi_quad_data_byte(got_arr[k]);
            if (dut.io_oe !== 4'b1111)
               $fatal(1, "FAIL: 6D io_oe dropped during data byte %0d: %b",
                      k, dut.io_oe);
         end
         #200 cs_n = 1;

         #100;
         if (io !== 4'bzzzz)
            $fatal(1, "FAIL: DUT did not release IO after 6D CS rise, io=%b", io);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6D io_oe must drop after CS rise: %b",
                   dut.io_oe);

         $write("QUAD trace (6D byte sequence):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1) begin
            want = 8'h06 + {5'b0, k[2:0]};
            if (got_arr[k] !== want)
               $fatal(1, "FAIL: 6D sequence data[%0d]=%02h want %02h",
                      k, got_arr[k], want);
         end
         expect_line("op=6d bytes=9", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 12: 0x32 WITHOUT prior 0x06 -- WEL is clear, so the
      // quad-input write must be ignored. Send addr=0 + 16 data
      // bytes 0xC0..0xCF in quad. `bytes=` field is in byte-
      // equivalents: 1 + 3 + 16 = 20.
      begin : frame12
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h32, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_quad_write_byte(8'hC0 + k[7:0]);
         release_io();
         #200 cs_n = 1;
         expect_line("op=32 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 13: 0x03 readback after no-WEL 32 -- pattern source
      // is independent of the page buffer, so the response must
      // be the addr-0 pattern (0x00..0x0F) regardless of what the
      // (rejected) write tried to do.
      begin : frame13
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1) begin
            spi_byte(8'h00, 1'b0, got_arr[k]);
            end
         #200 cs_n = 1;
         $write("MISO trace (03 after no-WEL 32):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: 03 pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 14: WREN.
      oracle_crc      = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h06, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=06 bytes=1", oracle_crc ^ 32'hFFFFFFFF);
      begin : frame15
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h32, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1) begin
            // 0x32 is a quad WRITE: master drives all four lanes;
            // the slave must NOT drive any io_oe during this phase.
            if (dut.io_oe !== 4'b0000)
               $fatal(1, "FAIL: 32 data byte %0d io_oe=%b, want 0000",
                      k, dut.io_oe);
            spi_quad_write_byte(8'hC0 + k[7:0]);
         end
         release_io();
         #200 cs_n = 1;
         expect_line("op=32 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 16: 0x03 readback after WEL+quad-32 -- pattern at
      // addr 0 is 0x00..0x0F, independent of any prior writes.
      begin : frame16
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1) begin
            spi_byte(8'h00, 1'b0, got_arr[k]);
            end
         #200 cs_n = 1;
         $write("MISO trace (03 after quad-32, pattern):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: 03 pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 16b: 0x6B quad-output readback at addr 0 -- expect
      // pattern 0x00..0x0F. Nibble-alignment regression: the
      // negedge presenter must drive `{byte_N_upper, byte_N_lower}`
      // for byte N (not the silicon-observed
      // `{byte_N_lower, byte_N_upper}` swap of the first revision,
      // which was caused by a phase-shift between the prefetch
      // mirror and the negedge slice).
      begin : frame16b
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc      = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6B/CF pre-dummy io_oe=%b", dut.io_oe);
         spi_dummy_quad();
         if (dut.io_oe !== 4'b1111)
            $fatal(1, "FAIL: 6B/CF data-phase io_oe=%b, want 1111",
                   dut.io_oe);
         for (k = 0; k < 16; k = k + 1) begin
            spi_quad_data_byte(got_arr[k]);
            if (dut.io_oe !== 4'b1111)
               $fatal(1, "FAIL: 6B/CF io_oe dropped during byte %0d: %b",
                      k, dut.io_oe);
         end
         #200 cs_n = 1;
         #50;
         if (dut.io_oe !== 4'b0000)
            $fatal(1, "FAIL: 6B/CF post-CS io_oe=%b", dut.io_oe);
         $write("QUAD trace (6B pattern at addr 0):");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: 6B pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=6b bytes=9", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frames 17--22: high-rate stress at 50 MHz SCLK to verify
      // the redesigned sclk-domain capture path. The fclk is 100
      // MHz (10 ns) in this TB; setting t_q = t_h = 10 ns gives a
      // 30 ns SCLK period (one quarter setup + one half + one
      // quarter low) ~= 33 MHz. Drop t_q/t_h to 5 ns each to push
      // SCLK to 50 MHz.
      t_q = 5;
      t_h = 10;

      // Frame 17: 0x9F at high rate. Confirms shift-out load on
      // byte boundary and miso_out negedge tap both meet timing.
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h9F, 1'b1, got0);
      spi_byte(8'h00, 1'b0, got1);
      spi_byte(8'h00, 1'b0, got2);
      spi_byte(8'h00, 1'b0, got3);
      #200 cs_n = 1;
      $display("HS 9F: %02h %02h %02h %02h", got0, got1, got2, got3);
      if (got1 !== 8'h20 || got2 !== 8'h20 || got3 !== 8'h14)
         $fatal(1, "FAIL: high-rate 9F miso = %02h %02h %02h",
                got1, got2, got3);
      expect_line("op=9f bytes=4", oracle_crc ^ 32'hFFFFFFFF);

      // Frame 18: WREN at high rate.
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h06, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=06 bytes=1", oracle_crc ^ 32'hFFFFFFFF);

      // Frame 19: 0x02 PP at high rate, write 0xA0..0xAF.
      begin : hs_pp
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h02, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_send(8'hA0 + k[7:0], 1'b1);
         #200 cs_n = 1;
         expect_line("op=02 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 20: 0x03 readback at high rate, addr=0 pattern.
      begin : hs_rd
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         $write("HS 03 rd pattern:");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: high-rate 03 data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 20b: long single-lane 0x03 read (40 data bytes)
      // starting at addr LSB 0xF0 so the 8-bit pattern counter
      // wraps from 0xFF back to 0x00 mid-frame. This is the
      // headline streaming integrity check: every emitted byte
      // must equal `(0xF0 + k) mod 256` so any framing or CDC
      // glitch in the long stream is caught byte-by-byte.
      begin : hs_rd_long
         reg [7:0] got_arr [0:39];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'hF0, 1'b1);
         for (k = 0; k < 40; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         $write("HS 03 long pattern from 0xF0:");
         for (k = 0; k < 40; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 40; k = k + 1)
            if (got_arr[k] !== (8'hF0 + k[7:0]))
               $fatal(1, "FAIL: long-03 pattern data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'hF0 + k[7:0]);
         // Total SCLK-bytes = 1 opcode + 3 addr + 40 data = 44.
         // Printer shows modulo 100 => "44".
         expect_line("op=03 bytes=44", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 21: WREN, then 0x32 quad PP at high rate, write
      // 0xE0..0xEF, then 0x03 readback.
      oracle_crc = 32'hFFFFFFFF;
      repeat (200) @(posedge clk);
      @(posedge clk);
      cs_n = 0; #200;
      spi_byte(8'h06, 1'b1, got0);
      #200 cs_n = 1;
      expect_line("op=06 bytes=1", oracle_crc ^ 32'hFFFFFFFF);

      begin : hs_qpp
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h32, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_quad_write_byte(8'hE0 + k[7:0]);
         release_io();
         #200 cs_n = 1;
         expect_line("op=32 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 22: 0x03 readback at high rate, addr=0 pattern.
      begin : hs_qrd
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 16; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         $write("HS 03 pattern after quad-32:");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: high-rate 03 data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=20", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 23: 0x6B Quad Output Read at high rate, addr LSB
      // 0x40 -- pattern starts at 0x40, increments through 0x4F.
      begin : hs_qor
         reg [7:0] got_arr [0:15];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h40, 1'b1);
         spi_dummy_quad();
         for (k = 0; k < 16; k = k + 1)
            spi_quad_data_byte(got_arr[k]);
         #200 cs_n = 1;
         $write("HS 6B pattern from 0x40:");
         for (k = 0; k < 16; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         for (k = 0; k < 16; k = k + 1)
            if (got_arr[k] !== (8'h40 + k[7:0]))
               $fatal(1, "FAIL: high-rate 6B data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'h40 + k[7:0]);
         expect_line("op=6b bytes=9", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 24: 0x5A SFDP Read at offset 0. Drive opcode + 3
      // address bytes (0x00 0x00 0x00) + 1 dummy byte, then read
      // 8 SFDP bytes. The first 4 bytes must be the JESD216
      // signature `S`,`F`,`D`,`P` (0x53 0x46 0x44 0x50).
      begin : sfdp_rd
         reg [7:0] got_dummy;
         reg [7:0] got_arr [0:7];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h5A, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_byte(8'h00, 1'b0, got_dummy);
         for (k = 0; k < 8; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         $display("SFDP dummy byte: %02h", got_dummy);
         if (got_dummy !== 8'h00)
            $fatal(1, "FAIL: 0x5A dummy MISO = %02h, want 00", got_dummy);
         $write("SFDP trace (5A):");
         for (k = 0; k < 8; k = k + 1) $write(" %02h", got_arr[k]);
         $display("");
         if (got_arr[0] !== 8'h53 || got_arr[1] !== 8'h46
          || got_arr[2] !== 8'h44 || got_arr[3] !== 8'h50)
            $fatal(1, "FAIL: SFDP signature = %02h %02h %02h %02h",
                   got_arr[0], got_arr[1], got_arr[2], got_arr[3]);
         expect_line("op=5a bytes=13", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Streaming pattern stress -- mirrors the MP135 host's 1 MiB
      // streaming reads. The pattern source emits `addr[7:0]` and
      // wraps every 256 bytes; these frames check that the wrap
      // remains glitch-free across many mod-256 cycles, on both
      // single-lane (0x03 / 0x0B) and quad-output (0x6B) paths,
      // before hardware comes online. Reuses the high-rate t_q/t_h
      // already in effect (t_q=5, t_h=10 -> ~50 MHz SCLK) so the
      // long bursts complete in tens of microseconds each.
      //
      // The DUT's printer snapshots `byte_cnt` truncated to 8 bits;
      // the displayed value is `byte_cnt mod 256` rendered as
      // 1- or 2-digit decimal. Verified against existing assertions:
      // frame20b above sends 1+3+40 = 44 single-lane bytes and
      // expects "op=03 bytes=44".

      // Frame 25: 0x0B Fast Read, 1024 data bytes from addr 0x000.
      // Total byte_cnt = 1+3+1+1024 = 1029; 1029 mod 256 = 5.
      begin : stream_0b_1k
         reg [7:0] got_dummy;
         reg [7:0] got_arr [0:1023];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h0B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);  // addr LSB = 0x00
         spi_byte(8'h00, 1'b0, got_dummy);
         for (k = 0; k < 1024; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         if (got_dummy !== 8'h00)
            $fatal(1, "FAIL: stream-0B-1k dummy MISO = %02h, want 00", got_dummy);
         for (k = 0; k < 1024; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: stream-0B-1k data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=0b bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 26: 0x0B Fast Read, 256 data bytes from addr 0x0FE.
      // Pattern: 0xFE, 0xFF, 0x00, 0x01, ..., 0xFD.
      // Total byte_cnt = 1+3+1+256 = 261; 261 mod 256 = 5.
      begin : stream_0b_wrap
         reg [7:0] got_dummy;
         reg [7:0] got_arr [0:255];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h0B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'hFE, 1'b1);  // addr LSB = 0xFE -- wrap mid-frame
         spi_byte(8'h00, 1'b0, got_dummy);
         for (k = 0; k < 256; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         if (got_dummy !== 8'h00)
            $fatal(1, "FAIL: stream-0B-wrap dummy MISO = %02h, want 00", got_dummy);
         for (k = 0; k < 256; k = k + 1)
            if (got_arr[k] !== (8'hFE + k[7:0]))
               $fatal(1, "FAIL: stream-0B-wrap data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'hFE + k[7:0]);
         expect_line("op=0b bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 27: 0x6B Quad Output Read, 1024 data bytes from addr 0x000.
      // Each quad data byte = 2 SCLK rises = 0.25 byte_cnt; the dummy
      // contributes 1 (8 SCLK rises). Total byte_cnt = 1+3+1+1024/4
      // = 261; 261 mod 256 = 5.
      begin : stream_6b_1k
         reg [7:0] got_arr [0:1023];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);  // addr LSB = 0x00
         spi_dummy_quad();
         for (k = 0; k < 1024; k = k + 1)
            spi_quad_data_byte(got_arr[k]);
         #200 cs_n = 1;
         for (k = 0; k < 1024; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: stream-6B-1k data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=6b bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 28: 0x6B Quad Output Read, 256 data bytes from addr 0x0FE.
      // Quad pattern wrap: 0xFE, 0xFF, 0x00, ..., 0xFD.
      // Total byte_cnt = 1+3+1+256/4 = 69 -> "bytes=69".
      begin : stream_6b_wrap
         reg [7:0] got_arr [0:255];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'hFE, 1'b1);  // addr LSB = 0xFE -- wrap mid-frame
         spi_dummy_quad();
         for (k = 0; k < 256; k = k + 1)
            spi_quad_data_byte(got_arr[k]);
         #200 cs_n = 1;
         for (k = 0; k < 256; k = k + 1)
            if (got_arr[k] !== (8'hFE + k[7:0]))
               $fatal(1, "FAIL: stream-6B-wrap data[%0d]=%02h want %02h",
                      k, got_arr[k], 8'hFE + k[7:0]);
         expect_line("op=6b bytes=69", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 29: 0x03 Read, 1024 data bytes from addr 0x000. No
      // dummy byte for 0x03. Total byte_cnt = 1+3+1024 = 1028;
      // 1028 mod 256 = 4 -> "bytes=4".
      begin : stream_03_1k
         reg [7:0] got_arr [0:1023];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h03, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         for (k = 0; k < 1024; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         for (k = 0; k < 1024; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: stream-03-1k data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         expect_line("op=03 bytes=4", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 30/31: ULTRA-high SCLK (~91 MHz) streaming stress on
      // both single-lane fast read and quad-output read. Mimics
      // the timing pressure that exposed the data_byte mux bug on
      // hardware: a 41 MHz silicon SCLK saw `data_byte` increment
      // twice between consecutive single-lane bytes because the
      // dispatch case-chain composed a deep adder+mux into the
      // pattern flop. Pulling the increment out of the chain into
      // its own gated assignment shortens the path; this frame
      // runs the resulting design at simulator's t_q = 3 ns,
      // t_h = 5 ns (period 11 ns => ~91 MHz), well into the
      // sclk-domain Fmax envelope.
      t_q = 3;
      t_h = 5;

      // Frame 30: 0x0B Fast Read, 256 data bytes from addr 0x000
      // at ~91 MHz SCLK. The deterministic pattern (k & 0xFF)
      // catches single-lane data_byte cadence faults that the
      // 50 MHz frames above run too slowly to provoke.
      begin : stream_0b_ultra
         reg [7:0] got_dummy;
         reg [7:0] got_arr [0:255];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h0B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_byte(8'h00, 1'b0, got_dummy);
         for (k = 0; k < 256; k = k + 1)
            spi_byte(8'h00, 1'b0, got_arr[k]);
         #200 cs_n = 1;
         if (got_dummy !== 8'h00)
            $fatal(1, "FAIL: stream-0B-ultra dummy MISO = %02h, want 00", got_dummy);
         for (k = 0; k < 256; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: stream-0B-ultra data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         // 1 + 3 + 1 + 256 = 261 bytes; printer renders mod 256 = 5.
         expect_line("op=0b bytes=5", oracle_crc ^ 32'hFFFFFFFF);
      end

      // Frame 31: 0x6B Quad Output Read, 256 data bytes from addr 0
      // at ~91 MHz SCLK. The tightened spi_quad_data_byte sample
      // window (sample at end of high time, not at the rising
      // edge) makes any remaining slave-side cadence skew between
      // the negedge nibble drive and the master's sample show up
      // as a per-byte data error.
      begin : stream_6b_ultra
         reg [7:0] got_arr [0:255];
         integer   k;
         oracle_crc = 32'hFFFFFFFF;
         repeat (200) @(posedge clk);
         release_io();
         @(posedge clk);
         cs_n = 0; #200;
         spi_send(8'h6B, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_send(8'h00, 1'b1);
         spi_dummy_quad();
         for (k = 0; k < 256; k = k + 1)
            spi_quad_data_byte(got_arr[k]);
         #200 cs_n = 1;
         for (k = 0; k < 256; k = k + 1)
            if (got_arr[k] !== k[7:0])
               $fatal(1, "FAIL: stream-6B-ultra data[%0d]=%02h want %02h",
                      k, got_arr[k], k[7:0]);
         // 1 + 3 + 1 + 256/4 = 69 bytes; mod 256 = 69.
         expect_line("op=6b bytes=69", oracle_crc ^ 32'hFFFFFFFF);
      end

      $display("PASS");
      $finish;
   end

   initial begin
      #60_000_000;
      $fatal(1, "timeout");
   end
endmodule
