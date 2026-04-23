`timescale 1ns/1ps

module tb_gpio;
   localparam CLKS_PER_BIT = 10;
   localparam TICK_CYCLES  = 2000;
   reg clk;
   initial clk = 0;
   always #5 clk <= ~clk;
   reg  [15:0] gpio_drv;
   wire        tx;
   
   gpio #(
      .CLKS_PER_BIT(CLKS_PER_BIT),
      .TICK_CYCLES (TICK_CYCLES)
   ) dut (
      .clk(clk), .gpio(gpio_drv), .tx(tx)
   );
   
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
   task automatic recv_byte(output [7:0] b);
      begin
         while (rx_head === rx_tail) @(posedge clk);
         b = rx_queue[rx_tail];
         rx_tail = rx_tail + 1;
      end
   endtask
   function [7:0] oracle_hex;
      input [3:0] n;
      begin
         case (n)
            4'h0: oracle_hex = "0"; 4'h1: oracle_hex = "1";
            4'h2: oracle_hex = "2"; 4'h3: oracle_hex = "3";
            4'h4: oracle_hex = "4"; 4'h5: oracle_hex = "5";
            4'h6: oracle_hex = "6"; 4'h7: oracle_hex = "7";
            4'h8: oracle_hex = "8"; 4'h9: oracle_hex = "9";
            4'ha: oracle_hex = "a"; 4'hb: oracle_hex = "b";
            4'hc: oracle_hex = "c"; 4'hd: oracle_hex = "d";
            4'he: oracle_hex = "e"; 4'hf: oracle_hex = "f";
         endcase
      end
   endfunction
   
   task automatic expect_line(input [15:0] expected);
      reg [7:0] b;
      reg [7:0] want [0:5];
      integer i;
      begin
         want[0] = oracle_hex(expected[15:12]);
         want[1] = oracle_hex(expected[11:8]);
         want[2] = oracle_hex(expected[7:4]);
         want[3] = oracle_hex(expected[3:0]);
         want[4] = 8'h0d;
         want[5] = 8'h0a;
         for (i = 0; i < 6; i = i + 1) begin
            recv_byte(b);
            if (b !== want[i])
               $fatal(1, "FAIL line[%0d]: got 0x%02h want 0x%02h",
                      i, b, want[i]);
         end
      end
   endtask
   initial begin
      gpio_drv = 16'ha5c3;
      expect_line(16'ha5c3);
   
      gpio_drv = 16'h0000;
      expect_line(16'h0000);
   
      $display("PASS: gpio heartbeat lines correct");
      $finish;
   end
endmodule
