module uart_hello #(
      parameter PERIOD_CYCLES = 12_000_000
   )(
      input            clk,
      input            tx_ready,
      output           tx_valid,
      output     [7:0] tx_data
   );
   reg [$clog2(PERIOD_CYCLES)-1:0] timer;
   reg [5:0]                       msg_idx;
   reg                             active;
   
   initial begin
      timer   = 0;
      msg_idx = 0;
      active  = 0;
   end
   localparam MSG_LEN = 6'd18;
   
   reg [7:0] msg_byte;
   always @* begin
      case (msg_idx)
         6'd0:  msg_byte = "H";
         6'd1:  msg_byte = "e";
         6'd2:  msg_byte = "l";
         6'd3:  msg_byte = "l";
         6'd4:  msg_byte = "o";
         6'd5:  msg_byte = " ";
         6'd6:  msg_byte = "f";
         6'd7:  msg_byte = "r";
         6'd8:  msg_byte = "o";
         6'd9:  msg_byte = "m";
         6'd10: msg_byte = " ";
         6'd11: msg_byte = "i";
         6'd12: msg_byte = "C";
         6'd13: msg_byte = "E";
         6'd14: msg_byte = "4";
         6'd15: msg_byte = "0";
         6'd16: msg_byte = 8'h0d;
         6'd17: msg_byte = 8'h0a;
         default: msg_byte = 8'h00;
      endcase
   end
   assign tx_valid = active;
   assign tx_data  = msg_byte;
   always @(posedge clk) begin
      if (timer == PERIOD_CYCLES - 1) begin
         timer <= 0;
         if (!active) begin
            active  <= 1'b1;
            msg_idx <= 0;
         end
      end else begin
         timer <= timer + 1;
      end
   
      if (active && tx_ready) begin
         if (msg_idx == MSG_LEN - 1) begin
            active  <= 1'b0;
            msg_idx <= 0;
         end else begin
            msg_idx <= msg_idx + 1;
         end
      end
   end
endmodule
