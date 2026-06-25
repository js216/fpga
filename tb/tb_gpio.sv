`timescale 1ns/1ps

module tb_gpio;
   localparam CLKS_PER_BIT = 10;
   localparam TICK_CYCLES  = 4000;
   reg clk;
   initial clk = 0;
   always #5 clk <= ~clk;
   wire        tx;
   wire        rx_line;
   wire [15:0] gpio_line;
   
   gpio #(
      .CLKS_PER_BIT(CLKS_PER_BIT),
      .TICK_CYCLES (TICK_CYCLES)
   ) dut (
      .clk(clk), .rx(rx_line), .pins(gpio_line), .tx(tx)
   );
   wire       sniff_ready;
   wire [7:0] sniff_data;
   uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) sniffer (
      .clk  (clk),
      .rx   (tx),
      .ready(sniff_ready),
      .data (sniff_data)
   );
   reg        tb_tx_start;
   reg  [7:0] tb_tx_data;
   wire       tb_tx_busy;
   initial begin
      tb_tx_start = 0;
      tb_tx_data  = 0;
   end
   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) sender (
      .clk  (clk),
      .start(tb_tx_start),
      .data (tb_tx_data),
      .tx   (rx_line),
      .busy (tb_tx_busy)
   );
   reg  [15:0] ext_en;
   reg  [15:0] ext_drv;
   initial begin
      ext_en  = 0;
      ext_drv = 0;
   end
   
   genvar i;
   generate
      for (i = 0; i < 16; i = i + 1) begin : ext_tri
         assign gpio_line[i] = ext_en[i] ? ext_drv[i] : 1'bz;
      end
   endgenerate
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
      integer k;
      begin
         want[0] = oracle_hex(expected[15:12]);
         want[1] = oracle_hex(expected[11:8]);
         want[2] = oracle_hex(expected[7:4]);
         want[3] = oracle_hex(expected[3:0]);
         want[4] = 8'h0d;
         want[5] = 8'h0a;
         for (k = 0; k < 6; k = k + 1) begin
            recv_byte(b);
            if (b !== want[k])
               $fatal(1, "FAIL line[%0d]: got 0x%02h want 0x%02h",
                      k, b, want[k]);
            end
         end
      endtask
      task automatic expect_ok;
         reg [7:0] b;
         reg [7:0] want [0:3];
         integer k;
         begin
            want[0] = "O";
            want[1] = "K";
            want[2] = 8'h0d;
            want[3] = 8'h0a;
            for (k = 0; k < 4; k = k + 1) begin
               recv_byte(b);
               if (b !== want[k])
                  $fatal(1, "FAIL ok[%0d]: got 0x%02h want 0x%02h",
                         k, b, want[k]);
            end
         end
      endtask
   task automatic send_char(input [7:0] c);
      begin
         @(negedge clk);
         while (tb_tx_busy) @(negedge clk);
         tb_tx_data  = c;
         tb_tx_start = 1;
         @(negedge clk);
         tb_tx_start = 0;
         while (!tb_tx_busy) @(negedge clk);
         while (tb_tx_busy)  @(negedge clk);
         repeat (CLKS_PER_BIT) @(negedge clk);
      end
   endtask
   localparam SEND_STRING_MAX = 16;
   
   task automatic send_string(input [8*SEND_STRING_MAX-1:0] s);
      integer k;
      reg [7:0] c;
      begin
         for (k = SEND_STRING_MAX - 1; k >= 0; k = k - 1) begin
            c = s[k*8 +: 8];
            if (c != 8'h00)
               send_char(c);
         end
      end
   endtask
   initial begin
      ext_en  = 16'hffff;
      ext_drv = 16'ha5c3;
      expect_line(16'ha5c3);
   
      ext_en  = 16'hff00;
      ext_drv = 16'h3300;
      send_string("E00FF");
      send_string("W0042");
      expect_line(16'h3342);
   
      send_string("E0000");
      ext_en  = 16'hffff;
      ext_drv = 16'hbeef;
      expect_line(16'hbeef);
   
      ext_en  = 16'hff00;
      ext_drv = 16'h9900;
      send_string("E00FF");
      send_string("W0A");
      send_char("!");
      send_string("WabCD");
      expect_line(16'h99cd);
   
      send_string("W123");
      send_char("!");
      expect_line(16'h99cd);
   
      ext_en  = 16'h5555;
      ext_drv = 16'h5555;
      send_string("EAAAA");
      send_string("WAAAA");
      expect_line(16'hffff);
   
      send_string("E0000");
      ext_en  = 16'hff00;
      ext_drv = 16'h7700;
      send_string("E00FFW0042");
      expect_line(16'h7742);
   
      @(posedge dut.active);
         send_string("W1234");
         expect_line(16'h7742);
         expect_line(16'h7734);
         send_char("?");
         expect_ok();
         expect_line(16'h7734);
         $display("PASS: heartbeat + command-drive paths both correct");
         $finish;
   end
endmodule
