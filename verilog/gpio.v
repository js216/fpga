module gpio #(
      parameter CLKS_PER_BIT = 104,
      parameter TICK_CYCLES  = 1_200_000
   )(
      input         clk,
      input  [15:0] gpio,
      output        tx
   );
   reg [$clog2(TICK_CYCLES)-1:0] timer;
   reg [15:0] snapshot;
   reg [2:0]  char_idx;
   reg        active;
   reg        tx_start;
   reg  [7:0] tx_data;
   wire       tx_busy;
   
   localparam LAST_IDX = 3'd5;
   initial begin
      timer    = 0;
      snapshot = 0;
      char_idx = 0;
      active   = 0;
      tx_start = 0;
      tx_data  = 0;
   end
   function [7:0] hex_digit;
      input [3:0] n;
      begin
         hex_digit = (n < 4'd10) ? (8'h30 + {4'd0, n})
                                 : (8'h57 + {4'd0, n});
      end
   endfunction
   reg [7:0] cur_char;
   always @* begin
      case (char_idx)
         3'd0: cur_char = hex_digit(snapshot[15:12]);
         3'd1: cur_char = hex_digit(snapshot[11:8]);
         3'd2: cur_char = hex_digit(snapshot[7:4]);
         3'd3: cur_char = hex_digit(snapshot[3:0]);
         3'd4: cur_char = 8'h0d;
         3'd5: cur_char = 8'h0a;
         default: cur_char = 8'h00;
      endcase
   end
   always @(posedge clk) begin
      tx_start <= 1'b0;
      if (timer == TICK_CYCLES - 1) begin
         timer <= 0;
         if (!active) begin
            snapshot <= gpio;
            char_idx <= 0;
            active   <= 1'b1;
         end
      end else begin
         timer <= timer + 1;
      end
      if (active && !tx_busy && !tx_start) begin
         tx_start <= 1'b1;
         tx_data  <= cur_char;
         if (char_idx == LAST_IDX) begin
            active   <= 1'b0;
            char_idx <= 0;
         end else begin
            char_idx <= char_idx + 1;
         end
      end
   end
   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk  (clk),
      .start(tx_start),
      .data (tx_data),
      .tx   (tx),
      .busy (tx_busy)
   );
`ifdef FORMAL
   always @(posedge clk) assert(timer < TICK_CYCLES);
   always @(posedge clk) assert(char_idx <= LAST_IDX);
   always @(posedge clk) begin
      if (!active)
         assert(char_idx == 0);
   end
   reg f_past_valid;
   initial f_past_valid = 0;
   always @(posedge clk) f_past_valid <= 1;
   
   always @(posedge clk) begin
      if (f_past_valid && $past(tx_start))
         assert(!tx_start);
   end
`endif
endmodule
