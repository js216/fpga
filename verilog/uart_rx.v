module uart_rx #(
      parameter CLKS_PER_BIT = 104
   )(
      input            clk,
      input            rx,
      output reg       ready,
      output reg [7:0] data
   );
   localparam S_IDLE  = 3'd0;
   localparam S_START = 3'd1;
   localparam S_DATA  = 3'd2;
   localparam S_STOP  = 3'd3;
   localparam S_DONE  = 3'd4;
   reg  [2:0] state;
   reg  [$clog2(CLKS_PER_BIT)-1:0] count;
   reg  [2:0] bit_idx;
   initial begin
      state   = S_IDLE;
      ready   = 0;
      data    = 0;
      count   = 0;
      bit_idx = 0;
   end
   always @(posedge clk) begin
      case (state)
         S_IDLE: begin
            ready   <= 0;
            count   <= 0;
            bit_idx <= 0;
            if (rx == 1'b0)
               state <= S_START;
         end
         S_START: begin
            if (count == CLKS_PER_BIT/2 - 1) begin
               count <= 0;
               if (rx == 1'b0)
                  state <= S_DATA;
               else
                  state <= S_IDLE;
            end else begin
               count <= count + 1;
            end
         end
         S_DATA: begin
            if (count == CLKS_PER_BIT - 1) begin
               count           <= 0;
               data[bit_idx]   <= rx;
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
            if (count == CLKS_PER_BIT - 1) begin
               ready <= 1'b1;
               count <= 0;
               state <= S_DONE;
            end else begin
               count <= count + 1;
            end
         end
         S_DONE: begin
            ready <= 0;
            state <= S_IDLE;
         end
         default: state <= S_IDLE;
      endcase
   end
`ifdef FORMAL
   always @(posedge clk) assert(state <= S_DONE);
   always @(posedge clk) begin
      if (state == S_START)
         assert(count < CLKS_PER_BIT/2);
      if (state == S_DATA || state == S_STOP)
         assert(count < CLKS_PER_BIT);
   end
   always @(posedge clk) assert(bit_idx <= 3'd7);
   always @(posedge clk) begin
      if (state == S_IDLE) begin
         assert(count == 0);
         assert(bit_idx == 0);
      end
   end
   always @(posedge clk) begin
      if (ready)
         assert(state == S_DONE);
   end
   reg f_past_valid;
   initial f_past_valid = 0;
   always @(posedge clk) f_past_valid <= 1;
   
   always @(posedge clk) begin
      if (f_past_valid && $past(ready))
         assert(!ready);
   end
`endif
endmodule
