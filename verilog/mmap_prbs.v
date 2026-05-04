module mmap_prbs (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io
   );
   reg [5:0]  sclk_cnt;
   reg [31:0] cmd_sr;
   reg [7:0]  opcode_q;
   reg [23:0] addr_q;
   reg [7:0]  cur_byte;
   reg [3:0]  quad_next_nibble;
   reg        quad_hi_next;
   reg        quad_active;
   
   initial begin
      sclk_cnt         = 6'd0;
      cmd_sr           = 32'd0;
      opcode_q         = 8'd0;
      addr_q           = 24'd0;
      cur_byte         = 8'd0;
      quad_next_nibble = 4'd0;
      quad_hi_next     = 1'b0;
      quad_active      = 1'b0;
   end
   
   wire [7:0] cur_byte_inc = cur_byte + 8'd1;
   /* verilator lint_off SYNCASYNCNET */
   reg [1:0] cs_sync;
   initial cs_sync = 2'b11;
   always @(posedge clk) cs_sync <= {cs_sync[0], cs_n};
   wire cs_s = cs_sync[1];
   reg  cs_s_d;
   initial cs_s_d = 1'b1;
   always @(posedge clk) cs_s_d <= cs_s;
   
   reg cs_async_rst;
   initial cs_async_rst = 1'b1;
   always @(posedge clk or negedge cs_n) begin
      if (!cs_n)
         cs_async_rst <= 1'b0;
      else
         cs_async_rst <= cs_s_d;
   end
   /* verilator lint_on SYNCASYNCNET */
   /* verilator lint_off SYNCASYNCNET */
   always @(posedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) begin
         sclk_cnt         <= 6'd0;
         cmd_sr           <= 32'd0;
         opcode_q         <= 8'd0;
         addr_q           <= 24'd0;
         cur_byte         <= 8'd0;
         quad_next_nibble <= 4'd0;
         quad_hi_next     <= 1'b0;
         quad_active      <= 1'b0;
      end else begin
         if (sclk_cnt < 6'd32) begin
            cmd_sr <= {cmd_sr[30:0], io_d_in_0};
         end
         /* iter18: address-derived incrementing-byte pattern for c-command CRC
          * test (no alt-byte, 9 dummy = 41 cycles before data, master samples
          * at rise 42). Boundary at sclk_cnt==40 fires at rise 41 - quad_active
          * one cycle ahead of master's first data sample. cur_byte loaded with
          * addr_q[7:0] so byte 0 = addr LSB, matching c command's expected
          * `i & 0xFF` ramp when chunk_size is a multiple of 256 with addr 0. */
         if (sclk_cnt == 6'd40) begin
            opcode_q <= cmd_sr[31:24];
            addr_q   <= cmd_sr[23:0];
            if (cmd_sr[31:24] == 8'h6B) begin
               quad_active      <= 1'b1;
               cur_byte         <= cmd_sr[7:0];
               quad_next_nibble <= cmd_sr[7:4];
               quad_hi_next     <= 1'b0;
            end
         end
         /* iter19: simplest test - increment quad_next_nibble each cycle.
          * Master should read bytes 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF.
          * If we see this pattern, the data path works and cur_byte logic is the bug. */
         if (quad_active && sclk_cnt == 6'd41) begin
            quad_next_nibble <= quad_next_nibble + 4'd1;
         end
         if (sclk_cnt < 6'd41) begin
            sclk_cnt <= sclk_cnt + 6'd1;
         end
      end
   end
   /* verilator lint_on SYNCASYNCNET */
   /* iter20: drive sclk_cnt[3:0] directly. If sclk_cnt is stuck at 41 (= 9),
    * we get nibble 9 = byte 0x99. If sclk_cnt advances, we get varying. */
   wire [3:0] io_pad_src = sclk_cnt[3:0];
   /* verilator lint_off SYNCASYNCNET */
   reg [3:0] io_pad_out;
   initial io_pad_out = 4'b0;
   always @(negedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) io_pad_out <= 4'b0;
      else io_pad_out <= io_pad_src;
   end
   /* verilator lint_on SYNCASYNCNET */
   wire io_oe = (!cs_n) && quad_active && (opcode_q == 8'h6B);
   
   wire io_d_in_0;
   wire io_d_in_1;
   wire io_d_in_2;
   wire io_d_in_3;
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io0_iob (
      .PACKAGE_PIN(io[0]),
      .OUTPUT_ENABLE(io_oe),
      .D_OUT_0(io_pad_out[0]),
      .D_IN_0(io_d_in_0)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io1_iob (
      .PACKAGE_PIN(io[1]),
      .OUTPUT_ENABLE(io_oe),
      .D_OUT_0(io_pad_out[1]),
      .D_IN_0(io_d_in_1)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io2_iob (
      .PACKAGE_PIN(io[2]),
      .OUTPUT_ENABLE(io_oe),
      .D_OUT_0(io_pad_out[2]),
      .D_IN_0(io_d_in_2)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io3_iob (
      .PACKAGE_PIN(io[3]),
      .OUTPUT_ENABLE(io_oe),
      .D_OUT_0(io_pad_out[3]),
      .D_IN_0(io_d_in_3)
   );
endmodule
