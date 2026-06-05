// SPDX-License-Identifier: MIT
// gpioscan.v --- watch-ALL-balls input snapshot for FPGA<->DSP
// connectivity discovery.
//
// Every usable I/O ball (except the UART clk/rx/tx) is brought in
// as a pulled-up input. On the ASCII command 'S' the design latches
// all NPINS ball levels and streams them back over the UART as
// NHEX hex digits (MSB ball first) terminated by CR/LF. The host
// drives one DSP pin high, sends 'S', drives it low, sends 'S', and
// XORs the two snapshots: whichever ball bit changed is the ball
// physically jumpered to that DSP pin. No wiring map is assumed --
// the design simply watches the whole device and lets the toggle
// reveal the connection.
//
// '?' replies "OK\r\n" (liveness). There is no drive/output mode;
// pins are inputs only, so the design never contends the DSP boot
// bus or anything else.

module gpioscan #(
      parameter CLKS_PER_BIT = 104,
      parameter NPINS        = 203
   )(
      input              clk,
      input              rx,
      inout  [NPINS-1:0] pins,
      output             tx
   );
   localparam integer NHEX   = (NPINS + 3) / 4; // hex digits per snapshot
   localparam integer NCHARS = NHEX + 2;        // + CR + LF

   // Pulled-up input buffers: an unconnected ball reads constant 1
   // (no spurious flip); a jumpered ball follows the DSP drive.
   wire [NPINS-1:0] pins_in;
   genvar g;
   generate
      for (g = 0; g < NPINS; g = g + 1) begin : gin
         SB_IO #(
            .PIN_TYPE (6'b0000_01),  // simple input, not registered
            .PULLUP   (1'b1)
         ) io (
            .PACKAGE_PIN (pins[g]),
            .D_IN_0      (pins_in[g])
         );
      end
   endgenerate

   function [7:0] hex_digit;
      input [3:0] n;
      hex_digit = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h57 + {4'd0, n});
   endfunction

   // snapshot is padded up to NHEX*4 bits so the MSB nibble select
   // is always in range; the padding bits are always 0.
   reg [NHEX*4-1:0] snapshot;
   reg [7:0]  char_idx;
   reg        active;
   reg        line_is_query;
   reg        snap_pending;
   reg        query_pending;
   reg        tx_start;
   reg [7:0]  tx_data;
   wire       tx_busy;
   wire       rx_ready;
   wire [7:0] rx_data;

   initial begin
      snapshot      = 0;
      char_idx      = 0;
      active        = 0;
      line_is_query = 0;
      snap_pending  = 0;
      query_pending = 0;
      tx_start      = 0;
      tx_data       = 0;
   end

   reg [7:0] cur_char;
   always @* begin
      if (line_is_query) begin
         case (char_idx)
            8'd0:    cur_char = "O";
            8'd1:    cur_char = "K";
            8'd2:    cur_char = 8'h0d;
            default: cur_char = 8'h0a;
         endcase
      end else if (char_idx < NHEX[7:0]) begin
         cur_char = hex_digit(snapshot[(NHEX-1-char_idx)*4 +: 4]);
      end else if (char_idx == NHEX[7:0]) begin
         cur_char = 8'h0d;
      end else begin
         cur_char = 8'h0a;
      end
   end

   always @(posedge clk) begin
      tx_start <= 1'b0;
      if (!active && snap_pending) begin
         char_idx      <= 0;
         active        <= 1'b1;
         line_is_query <= 1'b0;
         snap_pending  <= 1'b0;
      end else if (!active && query_pending) begin
         char_idx      <= 0;
         active        <= 1'b1;
         line_is_query <= 1'b1;
         query_pending <= 1'b0;
      end
      if (rx_ready && rx_data == "?")
         query_pending <= 1'b1;
      if (rx_ready && rx_data == "S") begin
         snap_pending <= 1'b1;
         snapshot     <= {{(NHEX*4-NPINS){1'b0}}, pins_in};
      end
      if (active && !tx_busy && !tx_start) begin
         tx_start <= 1'b1;
         tx_data  <= cur_char;
         if (char_idx == (line_is_query ? 8'd3 : (NCHARS[7:0] - 8'd1))) begin
            active        <= 1'b0;
            char_idx      <= 0;
            line_is_query <= 1'b0;
         end else begin
            char_idx <= char_idx + 8'd1;
         end
      end
   end

   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk(clk), .start(tx_start), .data(tx_data), .tx(tx), .busy(tx_busy));
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
      .clk(clk), .rx(rx), .ready(rx_ready), .data(rx_data));
endmodule
