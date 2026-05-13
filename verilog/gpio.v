module gpio #(
      parameter CLKS_PER_BIT = 104,
      parameter TICK_CYCLES  = 1_200_000
   )(
      input          clk,
      input          rx,
      inout  [15:0]  pins,
      output         tx
   );
   reg [$clog2(TICK_CYCLES)-1:0] timer;
   reg [15:0] snapshot;
   reg [2:0]  char_idx;
   reg        active;
   reg        line_is_query;
   reg        query_pending;
   reg        snap_pending;
   reg        tx_start;
   reg  [7:0] tx_data;
   wire       tx_busy;

   reg [15:0] gpio_out;
   reg [15:0] gpio_oe;

   // Bench cursor for the connectivity-test counter commands
   // (see "Per-pin cursor commands" below).
   reg [4:0]  cursor;

   reg [2:0]  rx_state;
   reg        cmd_is_enable;
   reg [11:0] accum;
   wire       rx_ready;
   wire [7:0] rx_data;

   localparam LAST_IDX = 3'd5;

   localparam RX_IDLE = 3'd0;
   localparam RX_D0   = 3'd1;
   localparam RX_D1   = 3'd2;
   localparam RX_D2   = 3'd3;
   localparam RX_D3   = 3'd4;
   initial begin
      timer         = 0;
      snapshot      = 0;
      char_idx      = 0;
      active        = 0;
      line_is_query = 0;
      query_pending = 0;
      snap_pending  = 0;
      tx_start      = 0;
      tx_data       = 0;
      gpio_out      = 0;
      gpio_oe       = 0;
      cursor        = 0;
      rx_state      = RX_IDLE;
      cmd_is_enable = 0;
      accum         = 0;
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
         3'd0: cur_char = line_is_query ? "O" : hex_digit(snapshot[15:12]);
         3'd1: cur_char = line_is_query ? "K" : hex_digit(snapshot[11:8]);
         3'd2: cur_char = line_is_query ? 8'h0d : hex_digit(snapshot[7:4]);
         3'd3: cur_char = line_is_query ? 8'h0a : hex_digit(snapshot[3:0]);
         3'd4: cur_char = 8'h0d;
         3'd5: cur_char = 8'h0a;
         default: cur_char = 8'h00;
      endcase
   end
   always @(posedge clk) begin
      tx_start <= 1'b0;
      if (timer == TICK_CYCLES - 1) begin
         timer <= 0;
         if (!active && !query_pending && !snap_pending) begin
            snapshot <= pins_in;
            char_idx <= 0;
            active   <= 1'b1;
            line_is_query <= 1'b0;
         end
      end else begin
         timer <= timer + 1;
      end
      if (!active && snap_pending) begin
         snapshot      <= pins_in;
         char_idx      <= 0;
         active        <= 1'b1;
         line_is_query <= 1'b0;
         snap_pending  <= 1'b0;
      end
      if (!active && !snap_pending && query_pending) begin
         char_idx      <= 0;
         active        <= 1'b1;
         line_is_query <= 1'b1;
         query_pending <= 1'b0;
      end
      if (rx_ready && rx_state == RX_IDLE && rx_data == "?")
         query_pending <= 1'b1;
      if (rx_ready && rx_state == RX_IDLE && rx_data == "S") begin
         snap_pending <= 1'b1;
         snapshot     <= pins_in;
      end
      if (active && !tx_busy && !tx_start) begin
         tx_start <= 1'b1;
         tx_data  <= cur_char;
         if (char_idx == (line_is_query ? 3'd3 : LAST_IDX)) begin
            active        <= 1'b0;
            char_idx      <= 0;
            line_is_query <= 1'b0;
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
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
      .clk  (clk),
      .rx   (rx),
      .ready(rx_ready),
      .data (rx_data)
   );
   wire rx_is_dec = (rx_data >= "0") && (rx_data <= "9");
   wire rx_is_lc  = (rx_data >= "a") && (rx_data <= "f");
   wire rx_is_uc  = (rx_data >= "A") && (rx_data <= "F");
   wire rx_nib_valid = rx_is_dec | rx_is_lc | rx_is_uc;
   wire [3:0] rx_nib =
      rx_is_dec ? rx_data[3:0]
                : (rx_data[3:0] + 4'd9);
   always @(posedge clk) begin
      if (rx_ready) begin
         case (rx_state)
            RX_IDLE: begin
               if (rx_data == "W") begin
                  rx_state      <= RX_D0;
                  cmd_is_enable <= 1'b0;
               end else if (rx_data == "E") begin
                  rx_state      <= RX_D0;
                  cmd_is_enable <= 1'b1;
               end else if (rx_data == "N") begin
                  if (cursor < 5'd16) begin
                     gpio_oe  <= gpio_oe  | (16'd1 << cursor[3:0]);
                     gpio_out <= gpio_out | (16'd1 << cursor[3:0]);
                  end
               end else if (rx_data == "n") begin
                  if (cursor < 5'd16) begin
                     gpio_oe  <= gpio_oe  | (16'd1 << cursor[3:0]);
                     gpio_out <= gpio_out & ~(16'd1 << cursor[3:0]);
                  end
               end else if (rx_data == "R") begin
                  if (cursor < 5'd16) begin
                     gpio_oe  <= gpio_oe  & ~(16'd1 << cursor[3:0]);
                     gpio_out <= gpio_out & ~(16'd1 << cursor[3:0]);
                  end
                  cursor <= cursor + 5'd1;
               end else if (rx_data == "Z") begin
                  gpio_oe  <= 16'h0000;
                  gpio_out <= 16'h0000;
                  cursor   <= 5'd0;
               end
            end
            RX_D0, RX_D1, RX_D2: begin
               if (rx_nib_valid) begin
                  accum    <= {accum[7:0], rx_nib};
                  rx_state <= rx_state + 1;
               end else begin
                  rx_state <= RX_IDLE;
               end
            end
            RX_D3: begin
               if (rx_nib_valid) begin
                  if (cmd_is_enable)
                     gpio_oe  <= {accum, rx_nib};
                  else
                     gpio_out <= {accum, rx_nib};
               end
               rx_state <= RX_IDLE;
            end
            default: rx_state <= RX_IDLE;
         endcase
      end
   end
   genvar g;
   wire [15:0] pins_in;
   generate
      for (g = 0; g < 16; g = g + 1) begin : gpio_tri
         SB_IO #(
            .PIN_TYPE (6'b101001),
            .PULLUP   (1'b1)
         ) io_inst (
            .PACKAGE_PIN  (pins[g]),
            .OUTPUT_CLK   (clk),
            .OUTPUT_ENABLE(gpio_oe[g]),
            .D_OUT_0      (gpio_out[g]),
            .D_IN_0       (pins_in[g])
         );
      end
   endgenerate
`ifdef FORMAL
   initial begin
      assert(gpio_oe  == 16'h0000);
      assert(gpio_out == 16'h0000);
   end
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
   always @(posedge clk) begin
      if (tx_start)
         assert(!tx_busy);
   end
   always @(posedge clk) begin
      if (f_past_valid && tx_busy)
         assert(tx_data == $past(tx_data));
   end
   always @(posedge clk) begin
      if (f_past_valid) begin
         if ($past(rx_state) == RX_IDLE)
            assert(rx_state == RX_IDLE || rx_state == RX_D0);
         if ($past(rx_state) == RX_D0)
            assert(rx_state == RX_D0   || rx_state == RX_D1 ||
                   rx_state == RX_IDLE);
         if ($past(rx_state) == RX_D1)
            assert(rx_state == RX_D1   || rx_state == RX_D2 ||
                   rx_state == RX_IDLE);
         if ($past(rx_state) == RX_D2)
            assert(rx_state == RX_D2   || rx_state == RX_D3 ||
                   rx_state == RX_IDLE);
         if ($past(rx_state) == RX_D3)
            assert(rx_state == RX_IDLE);
      end
   end
   always @(posedge clk) begin
      if (f_past_valid) begin
         if (gpio_out != $past(gpio_out))
            assert(
               ($past(rx_state) == RX_D3 &&
                $past(rx_ready)          &&
                $past(rx_nib_valid)      &&
                !$past(cmd_is_enable))
               || ($past(rx_state) == RX_IDLE &&
                   $past(rx_ready)            &&
                   ($past(rx_data) == "N" ||
                    $past(rx_data) == "n" ||
                    $past(rx_data) == "R" ||
                    $past(rx_data) == "Z")));
         if (gpio_oe != $past(gpio_oe))
            assert(
               ($past(rx_state) == RX_D3 &&
                $past(rx_ready)          &&
                $past(rx_nib_valid)      &&
                $past(cmd_is_enable))
               || ($past(rx_state) == RX_IDLE &&
                   $past(rx_ready)            &&
                   ($past(rx_data) == "N" ||
                    $past(rx_data) == "n" ||
                    $past(rx_data) == "R" ||
                    $past(rx_data) == "Z")));
      end
   end
   always @(posedge clk) begin
      if (f_past_valid && $past(rx_ready) && $past(rx_state) == RX_IDLE &&
          $past(rx_data) == "?") begin
         assert(gpio_out == $past(gpio_out));
         assert(gpio_oe  == $past(gpio_oe));
      end
   end
`endif
endmodule
