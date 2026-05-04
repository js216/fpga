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
   reg [3:0]  quad_next_nibble;
   reg        quad_hi_next;
   reg        quad_active;
   
   initial begin
      sclk_cnt         = 6'd0;
      cmd_sr           = 32'd0;
      opcode_q         = 8'd0;
      addr_q           = 24'd0;
      quad_next_nibble = 4'd0;
      quad_hi_next     = 1'b0;
      quad_active      = 1'b0;
   end
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
         quad_next_nibble <= 4'd0;
         quad_hi_next     <= 1'b0;
         quad_active      <= 1'b0;
      end else begin
         if (sclk_cnt < 6'd32) begin
            cmd_sr <= {cmd_sr[30:0], io_d_in_0};
         end
         /* iter16: assert OE early (after opcode+addr captured at sclk_cnt==32)
          * so io_pad_out has setup time before master's data sample on cycle 50. */
         if (sclk_cnt == 6'd32) begin
            opcode_q <= cmd_sr[31:24];
            addr_q   <= cmd_sr[23:0];
            if (cmd_sr[31:24] == 8'h6B) begin
               quad_active      <= 1'b1;
               quad_next_nibble <= 4'hA;       /* constant 0xA */
               quad_hi_next     <= 1'b1;
            end
         end
         if (quad_active && sclk_cnt == 6'd33) begin
            quad_next_nibble <= 4'hA;
         end
         if (sclk_cnt < 6'd33) begin
            sclk_cnt <= sclk_cnt + 6'd1;
         end
      end
   end
   /* verilator lint_on SYNCASYNCNET */
   wire [3:0] io_pad_src = quad_next_nibble;
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
