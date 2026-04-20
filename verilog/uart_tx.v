module uart_tx #(
      parameter CLKS_PER_BIT = 104
   )(
      input            clk,
      input            start,
      input      [7:0] data,
      output reg       tx,
      output           busy
   );
   localparam S_IDLE  = 2'd0;
   localparam S_START = 2'd1;
   localparam S_DATA  = 2'd2;
   localparam S_STOP  = 2'd3;
   reg  [1:0] state;
   reg  [$clog2(CLKS_PER_BIT)-1:0] count;
   reg  [2:0] bit_idx;
   reg  [7:0] shift;
   initial begin
      state   = S_IDLE;
      tx      = 1'b1;
      count   = 0;
      bit_idx = 0;
      shift   = 0;
   end
   assign busy = (state != S_IDLE);
   always @(posedge clk) begin
      case (state)
         S_IDLE: begin
            tx      <= 1'b1;
            count   <= 0;
            bit_idx <= 0;
            if (start) begin
               shift <= data;
               state <= S_START;
            end
         end
         S_START: begin
            tx <= 1'b0;
            if (count == CLKS_PER_BIT - 1) begin
               count <= 0;
               state <= S_DATA;
            end else begin
               count <= count + 1;
            end
         end
         S_DATA: begin
            tx <= shift[bit_idx];
            if (count == CLKS_PER_BIT - 1) begin
               count <= 0;
               if (bit_idx == 3'd7) begin
                  bit_idx <= 0;
                  state   <= S_STOP;
               end else begin
                  bit_idx <= bit_idx + 1;
               end
            end else begin
               count <= count + 1;
            end
         end
         S_STOP: begin
            tx <= 1'b1;
            if (count == CLKS_PER_BIT - 1) begin
               count <= 0;
               state <= S_IDLE;
            end else begin
               count <= count + 1;
            end
         end
         default: state <= S_IDLE;
      endcase
   end
`ifdef FORMAL
   always @(posedge clk) assert(state <= S_STOP);
   always @(posedge clk) begin
      if (state != S_IDLE)
         assert(count < CLKS_PER_BIT);
   end
   always @(posedge clk) assert(bit_idx <= 3'd7);
   always @(posedge clk) begin
      if (state == S_IDLE) begin
         assert(count == 0);
         assert(bit_idx == 0);
      end
   end
   reg f_past_valid;
   initial f_past_valid = 0;
   always @(posedge clk) f_past_valid <= 1;
   
   always @(posedge clk) begin
      if (state == S_IDLE)
         assert(tx == 1'b1);
      if (f_past_valid && state == S_START && $past(state) == S_START)
         assert(tx == 1'b0);
   end
   always @(posedge clk) assert(busy == (state != S_IDLE));
`endif
endmodule
