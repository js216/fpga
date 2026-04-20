module uart #(
      parameter CLKS_PER_BIT = 104,
      parameter HELLO_PERIOD = 12_000_000
   )(
      input        clk,
      input        rx,
      output       tx,
      output [4:0] led
   );
   wire       rx_ready;
   wire [7:0] rx_data;
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
      .clk  (clk),
      .rx   (rx),
      .ready(rx_ready),
      .data (rx_data)
   );
   wire       hello_valid;
   wire [7:0] hello_data;
   reg        hello_ready;
   initial hello_ready = 0;
   
   uart_hello #(.PERIOD_CYCLES(HELLO_PERIOD)) u_hello (
      .clk     (clk),
      .tx_ready(hello_ready),
      .tx_valid(hello_valid),
      .tx_data (hello_data)
   );
   reg       tx_start;
   reg [7:0] tx_data;
   wire      tx_busy;
   
   initial begin
      tx_start = 0;
      tx_data  = 0;
   end
   
   always @(posedge clk) begin
      tx_start    <= 1'b0;
      hello_ready <= 1'b0;
      if (!tx_busy && !tx_start) begin
         if (hello_valid) begin
            tx_start    <= 1'b1;
            tx_data     <= hello_data;
            hello_ready <= 1'b1;
         end else if (rx_ready) begin
            tx_start <= 1'b1;
            tx_data  <= rx_data;
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
   reg [4:0] led_reg;
   initial led_reg = 0;
   always @(posedge clk)
      if (rx_ready)
         led_reg <= rx_data[4:0];
   assign led = led_reg;
endmodule
