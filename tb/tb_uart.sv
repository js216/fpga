`timescale 1ns/1ps

module tb_uart;
   localparam CLKS_PER_BIT = 10;
   localparam HELLO_PERIOD = 2000;
   reg clk;
   initial clk = 0;
   always #5 clk <= ~clk;
   reg  rx;
   wire tx;
   wire [7:0] led;
   
   uart #(
      .CLKS_PER_BIT(CLKS_PER_BIT),
      .HELLO_PERIOD(HELLO_PERIOD)
   ) dut (
      .clk(clk), .rx(rx), .tx(tx), .led(led)
   );
   
   initial rx = 1;
   
   wire       sniff_ready;
   wire [7:0] sniff_data;
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) sniffer (
      .clk  (clk),
      .rx   (tx),
      .ready(sniff_ready),
      .data (sniff_data)
   );
   
   reg [7:0] rx_queue [0:63];
   reg [5:0] rx_head, rx_tail;
   
   initial begin
      rx_head = 0;
      rx_tail = 0;
   end
   
   always @(posedge clk) begin
      if (sniff_ready) begin
         rx_queue[rx_head] <= sniff_data;
         rx_head <= rx_head + 1;
      end
   end
   task automatic send_byte(input [7:0] b);
      integer i;
      begin
         @(negedge clk);
         rx = 1'b0;
         repeat (CLKS_PER_BIT) @(negedge clk);
         for (i = 0; i < 8; i = i + 1) begin
            rx = b[i];
            repeat (CLKS_PER_BIT) @(negedge clk);
         end
         rx = 1'b1;
         repeat (CLKS_PER_BIT) @(negedge clk);
      end
   endtask
   task automatic recv_byte(output [7:0] b);
      begin
         while (rx_head === rx_tail) @(posedge clk);
         b = rx_queue[rx_tail];
         rx_tail = rx_tail + 1;
      end
   endtask
   task automatic xfer(input [7:0] sent, output [7:0] got);
      begin
         send_byte(sent);
         recv_byte(got);
      end
   endtask
   task automatic expect_heartbeat();
      integer i;
      reg [7:0] b;
      reg [7:0] expected [0:17];
      begin
         expected[0]  = "H";
         expected[1]  = "e";
         expected[2]  = "l";
         expected[3]  = "l";
         expected[4]  = "o";
         expected[5]  = " ";
         expected[6]  = "f";
         expected[7]  = "r";
         expected[8]  = "o";
         expected[9]  = "m";
         expected[10] = " ";
         expected[11] = "i";
         expected[12] = "C";
         expected[13] = "E";
         expected[14] = "4";
         expected[15] = "0";
         expected[16] = 8'h0d;
         expected[17] = 8'h0a;
         for (i = 0; i < 18; i = i + 1) begin
            recv_byte(b);
            if (b !== expected[i])
               $fatal(1, "FAIL heartbeat[%0d]: got 0x%02h want 0x%02h",
                      i, b, expected[i]);
         end
      end
   endtask
   reg [7:0] got;
   initial begin
      repeat (20) @(negedge clk);
   
      xfer(8'h61, got); // 'a'
      if (got !== 8'h61) $fatal(1, "FAIL 'a': got 0x%02h", got);
      
      xfer(8'h5a, got); // 'Z'
      if (got !== 8'h5a) $fatal(1, "FAIL 'Z': got 0x%02h", got);
      
      xfer(8'h35, got); // '5'
      if (got !== 8'h35) $fatal(1, "FAIL '5': got 0x%02h", got);
      
      xfer(8'h00, got); // NUL
      if (got !== 8'h00) $fatal(1, "FAIL NUL: got 0x%02h", got);
      if (led !== 8'h00)
         $fatal(1, "FAIL led: got %b, want %b (NUL)", led, 8'h00);
      expect_heartbeat();
   
      $display("PASS: echo and heartbeat paths both correct");
      $finish;
   end
endmodule
