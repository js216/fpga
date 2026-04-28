module spi_debug #(
      parameter CLKS_PER_BIT = 104
   ) (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx
   );
   spi #(.LANES(1)) dut (.cs_n(cs_n), .sclk(sclk), .io(io));

   reg        cs_meta, cs_sync;
   reg        selected_prev;
   reg        sclk_meta, sclk_sync, sclk_prev;
   reg        io1_meta, io1_sync;
   reg [15:0] edge_count;
   reg [15:0] last_edges;
   reg [31:0] samples;
   reg [31:0] last_samples;
   reg [5:0]  sample_count;
   reg        frame_done;
   wire       selected = !cs_sync;
   wire       sclk_rise = selected && sclk_sync && !sclk_prev;
   wire       cs_start = selected && !selected_prev;
   wire       cs_stop = !selected && selected_prev;

   initial begin
      cs_meta      = 1'b1;
      cs_sync      = 1'b1;
      selected_prev = 1'b0;
      sclk_meta    = 1'b0;
      sclk_sync    = 1'b0;
      sclk_prev    = 1'b0;
      io1_meta     = 1'b0;
      io1_sync     = 1'b0;
      edge_count   = 16'd0;
      last_edges   = 16'd0;
      samples      = 32'd0;
      last_samples = 32'd0;
      sample_count = 6'd0;
      frame_done   = 1'b0;
   end

   always @(posedge clk) begin
      cs_meta   <= cs_n;
      cs_sync   <= cs_meta;
      sclk_meta <= sclk;
      sclk_sync <= sclk_meta;
      sclk_prev <= sclk_sync;
      io1_meta  <= io[1];
      io1_sync  <= io1_meta;
      selected_prev <= selected;

      if (cs_start) begin
         edge_count   <= 16'd0;
         samples      <= 32'd0;
         sample_count <= 6'd0;
         frame_done   <= 1'b0;
      end else if (sclk_rise) begin
         edge_count <= edge_count + 16'd1;
         if (sample_count < 6'd32) begin
            samples <= {samples[30:0], io1_sync};
            sample_count <= sample_count + 6'd1;
         end
      end else if (cs_stop) begin
         last_edges <= edge_count;
         last_samples <= samples;
         frame_done <= 1'b1;
      end
   end

   reg pending;
   reg report_sent;
   reg [4:0] char_idx;
   reg tx_start;
   reg [7:0] tx_data;
   wire tx_busy;
   
   initial begin
      pending    = 1'b0;
      report_sent = 1'b0;
      char_idx   = 5'd0;
      tx_start   = 1'b0;
      tx_data    = 8'h00;
   end
   
   always @(posedge clk) begin
      tx_start   <= 1'b0;
      if (cs_start)
         report_sent <= 1'b0;
      if (frame_done && !report_sent && !pending && char_idx == 5'd0)
         pending <= 1'b1;
      if (pending && !tx_busy && !tx_start) begin
         tx_data  <= debug_char(char_idx);
         tx_start <= 1'b1;
         if (char_idx == 5'd22) begin
            pending <= 1'b0;
            report_sent <= 1'b1;
            char_idx <= 5'd0;
         end else begin
            char_idx <= char_idx + 5'd1;
         end
      end
   end
   
   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk(clk),
      .start(tx_start),
      .data(tx_data),
      .tx(tx),
      .busy(tx_busy)
   );
   
   function [7:0] hex_digit;
      input [3:0] n;
      begin
         hex_digit = (n < 4'd10) ? (8'h30 + {4'd0, n})
                                 : (8'h57 + {4'd0, n});
      end
   endfunction
   
   function [7:0] debug_char;
      input [4:0] idx;
      begin
         case (idx)
            5'd0:  debug_char = "S";
            5'd1:  debug_char = "P";
            5'd2:  debug_char = "I";
            5'd3:  debug_char = " ";
            5'd4:  debug_char = "E";
            5'd5:  debug_char = "=";
            5'd6:  debug_char = hex_digit(last_edges[15:12]);
            5'd7:  debug_char = hex_digit(last_edges[11:8]);
            5'd8:  debug_char = hex_digit(last_edges[7:4]);
            5'd9:  debug_char = hex_digit(last_edges[3:0]);
            5'd10: debug_char = " ";
            5'd11: debug_char = "S";
            5'd12: debug_char = "=";
            5'd13: debug_char = hex_digit(last_samples[31:28]);
            5'd14: debug_char = hex_digit(last_samples[27:24]);
            5'd15: debug_char = hex_digit(last_samples[23:20]);
            5'd16: debug_char = hex_digit(last_samples[19:16]);
            5'd17: debug_char = hex_digit(last_samples[15:12]);
            5'd18: debug_char = hex_digit(last_samples[11:8]);
            5'd19: debug_char = hex_digit(last_samples[7:4]);
            5'd20: debug_char = hex_digit(last_samples[3:0]);
            5'd21: debug_char = 8'h0d;
            5'd22: debug_char = 8'h0a;
            default: debug_char = 8'h00;
         endcase
      end
   endfunction
endmodule
