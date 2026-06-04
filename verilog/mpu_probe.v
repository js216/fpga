module mpu_probe #(
      parameter CLKS_PER_BIT = 104,
      parameter TICK_CYCLES  = 1_200_000_000,
      parameter NPINS        = 203
   )(
      input               clk,
      input               rx,
      inout  [NPINS-1:0]  pins,
      output              tx
   );
   localparam NIBBLES   = (NPINS + 3) / 4;
   localparam FRAME_LEN = NIBBLES + 2;
   localparam QUERY_LEN = 4;
   localparam IDXW      = $clog2(FRAME_LEN + 1);

   wire [NPINS-1:0] pins_in;
   genvar gi;
   generate
      for (gi = 0; gi < NPINS; gi = gi + 1) begin : g_in
         SB_IO #(
            .PIN_TYPE(6'b0000_01),
            .PULLUP(1'b1)
         ) io_cell (
            .PACKAGE_PIN(pins[gi]),
            .D_IN_0(pins_in[gi])
         );
      end
   endgenerate

   reg [$clog2(TICK_CYCLES)-1:0] timer;
   reg [NPINS-1:0] snapshot;
   reg [IDXW-1:0]  char_idx;
   reg             active;
   reg             is_query;
   reg             query_pending;
   reg             snap_pending;
   reg             tx_start;
   reg  [7:0]      tx_data;
   wire            tx_busy;
   wire            rx_ready;
   wire [7:0]      rx_data;

   initial begin
      timer = 0; snapshot = 0; char_idx = 0; active = 0; is_query = 0;
      query_pending = 0; snap_pending = 0; tx_start = 0; tx_data = 0;
   end

   function [3:0] nib_at;
      input [IDXW-1:0] i;
      integer n;
      begin
         n = NIBBLES - 1 - i;
         nib_at = snapshot[4*n +: 4];
      end
   endfunction

   function [7:0] hexchar;
      input [3:0] v;
      begin
         hexchar = (v < 4'd10) ? (8'h30 + v) : (8'h61 + (v - 4'd10));
      end
   endfunction

   function [7:0] byte_at;
      input [IDXW-1:0] i;
      input            q;
      begin
         if (q) begin
            case (i)
               0:       byte_at = "O";
               1:       byte_at = "K";
               2:       byte_at = 8'h0D;
               default: byte_at = 8'h0A;
            endcase
         end else if (i < NIBBLES[IDXW-1:0])
            byte_at = hexchar(nib_at(i));
         else if (i == NIBBLES[IDXW-1:0])
            byte_at = 8'h0D;
         else
            byte_at = 8'h0A;
      end
   endfunction

   always @(posedge clk) begin
      tx_start <= 1'b0;

      if (rx_ready) begin
         if (rx_data == "S")      snap_pending  <= 1'b1;
         else if (rx_data == "?") query_pending <= 1'b1;
      end

      if (!active) begin
         if (timer == TICK_CYCLES - 1) begin
            timer    <= 0;
            snapshot <= pins_in;
            is_query <= 1'b0;
            char_idx <= 0;
            active   <= 1'b1;
         end else begin
            timer <= timer + 1'b1;
            if (snap_pending) begin
               snap_pending <= 1'b0;
               snapshot     <= pins_in;
               is_query     <= 1'b0;
               char_idx     <= 0;
               active       <= 1'b1;
            end else if (query_pending) begin
               query_pending <= 1'b0;
               is_query      <= 1'b1;
               char_idx      <= 0;
               active        <= 1'b1;
            end
         end
      end else begin
         if (!tx_busy && !tx_start) begin
            tx_data  <= byte_at(char_idx, is_query);
            tx_start <= 1'b1;
            if (char_idx == (is_query ? QUERY_LEN[IDXW-1:0] - 1'b1
                                      : FRAME_LEN[IDXW-1:0] - 1'b1))
               active <= 1'b0;
            else
               char_idx <= char_idx + 1'b1;
         end
      end
   end

   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk(clk), .start(tx_start), .data(tx_data), .tx(tx), .busy(tx_busy));
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
      .clk(clk), .rx(rx), .ready(rx_ready), .data(rx_data));
endmodule
