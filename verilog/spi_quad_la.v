/* In-FPGA logic analyzer for the 4-lane QSPI slave emit path.
 *
 * Functionally identical to `spi.v` (LANES=4) — same 3-LUT SCLK
 * glitch filter, same negedge-launched counter emit, same registered
 * IOB output — so the data the master sees over QSPI is exactly the
 * same as production.  In addition, on every negedge of the
 * post-filter sclk_g during the data phase, this module snapshots:
 *
 *   - `dout_quad[3:0]` (= the nibble the fabric just committed to
 *     the IOB output flop's D-input, which the IOB will then drive
 *     onto the pad at the next negedge),
 *   - `phase_lo` (= 0: this emit is the HIGH nibble of data_byte,
 *     1: LOW nibble), and
 *   - `data_byte[7:0]` low byte (= which counter byte was being
 *     emitted).
 *
 * Buffer depth = 64 entries × 16 bits.  The first ~40 entries cover
 * the prefix-phase emits (all zeros, used to confirm the state
 * machine doesn't tick spuriously); the remaining ones cover the
 * data phase.  After CS↑, the captured buffer is streamed out a
 * UART pin (115200 baud over the iCEstick's onboard FTDI USB-UART,
 * pin 8) as ASCII hex, one entry per line:
 *
 *   <data_byte hex> <phase_lo 0/1> <dout_quad hex>
 *
 * Followed by a sentinel "LA END\r\n" line so the bench framework
 * can stop reading.
 *
 * This lets us answer empirically, *from inside the FPGA*, whether
 * the state machine actually advanced to and emitted the right
 * nibble at every negedge during a problematic read — i.e. whether
 * a byte-11 drop is the FPGA failing to emit B or whether the FPGA
 * did emit B but the master saw something else.
 */
module spi_quad_la (
      input        clk,    // 12 MHz iCEstick oscillator (fabric clock)
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx      // UART TX (iCEstick pin 8 → onboard FTDI)
   );

   /* ---------- SCLK distribution (no filter — bug-exposing) ---------- */
   /* The point of this LA build is to capture what the FPGA emits
    * when the SI bug fires.  So skip the LUT-chain glitch filter
    * that production spi.v has — route raw sclk straight to the
    * global buffer.  At presc=31 with a counter read, this triggers
    * the byte-11/15 drop and the LA buffer reveals whether the state
    * machine actually emitted nibble B at the right negedge or
    * whether it skipped (= advanced past it due to a coupled-back
    * SCLK glitch). */
   wire sclk_g;
   SB_GB sclk_gbuf (
      .USER_SIGNAL_TO_GLOBAL_BUFFER(sclk),
      .GLOBAL_BUFFER_OUTPUT(sclk_g)
   );

   /* ---------- CS debounce (verbatim from spi.v) ---------- */
   localparam CS_HIGH_RESET_BITS = 2;
   reg [CS_HIGH_RESET_BITS-1:0] cs_high_count;
   reg                          cs_debounced_high;
   initial cs_high_count     = {CS_HIGH_RESET_BITS{1'b0}};
   initial cs_debounced_high = 1'b1;
   always @(negedge cs_n or posedge clk) begin
      if (!cs_n) begin
         cs_high_count     <= {CS_HIGH_RESET_BITS{1'b0}};
         cs_debounced_high <= 1'b0;
      end else if (!cs_debounced_high) begin
         cs_high_count <= cs_high_count +
                          {{(CS_HIGH_RESET_BITS-1){1'b0}}, 1'b1};
         if (cs_high_count[0])
            cs_debounced_high <= 1'b1;
      end
   end

   /* ---------- Counter emit (verbatim from spi.v g_quad) ---------- */
   reg [5:0] prefix_cnt;
   reg       data_phase;
   reg       phase_lo;
   reg [7:0] data_byte;
   reg [3:0] dout_quad;
   initial prefix_cnt = 6'd0;
   initial data_phase = 1'b0;
   initial phase_lo   = 1'b0;
   initial data_byte  = 8'd0;
   initial dout_quad  = 4'd0;

   wire oe = ~cs_debounced_high && data_phase;

   always @(posedge cs_debounced_high or negedge sclk_g) begin
      if (cs_debounced_high) begin
         prefix_cnt <= 6'd0;
         data_phase <= 1'b0;
         phase_lo   <= 1'b0;
         data_byte  <= 8'd0;
         dout_quad  <= 4'd0;
      end else if (!data_phase) begin
         prefix_cnt <= prefix_cnt + 6'd1;
         if (prefix_cnt == 6'd37)
            data_phase <= 1'b1;
         dout_quad <= 4'd0;
      end else begin
         if (!phase_lo) begin
            dout_quad <= data_byte[7:4];
            phase_lo  <= 1'b1;
         end else begin
            dout_quad <= data_byte[3:0];
            phase_lo  <= 1'b0;
            data_byte <= data_byte + 8'd1;
         end
      end
   end

   /* ---------- IOB outputs (verbatim from spi.v g_quad_io) ---------- */
   genvar g;
   wire [3:0] io_d_in_unused;
   generate for (g = 0; g < 4; g = g + 1) begin : g_io
      SB_IO #(
         .PIN_TYPE(6'b100101),
         .NEG_TRIGGER(1'b1)
      ) iob (
         .PACKAGE_PIN(io[g]),
         .OUTPUT_CLK(sclk_g),
         .OUTPUT_ENABLE(oe),
         .D_OUT_0(dout_quad[g]),
         .D_IN_0(io_d_in_unused[g])
      );
   end endgenerate

   /* ---------- Capture buffer ----------
    *
    * On every negedge of sclk_g (data-phase only, because that's
    * when the emit branch updates dout_quad), snapshot:
    *   {data_byte[7:0], phase_lo, dout_quad[3:0]}  // 13 bits
    * into cap_buf.  Stop after 64 entries (more than enough for the
    * 24-nibble data phase of a 12-byte read, with safety margin
    * for longer reads).  cap_done latches HIGH when full so the
    * UART dumper knows to start. */
   localparam CAP_DEPTH_LOG2 = 5;
   localparam CAP_DEPTH      = 1 << CAP_DEPTH_LOG2;
   reg [3:0] cap_buf [0:CAP_DEPTH-1];
   reg [CAP_DEPTH_LOG2-1:0] cap_widx;
   reg                       cap_full;
   integer init_i;
   initial begin
      for (init_i = 0; init_i < CAP_DEPTH; init_i = init_i + 1)
         cap_buf[init_i] = 4'd0;
      cap_widx = {CAP_DEPTH_LOG2{1'b0}};
      cap_full = 1'b0;
   end

   always @(posedge cs_debounced_high or negedge sclk_g) begin
      if (cs_debounced_high) begin
         /* don't reset cap_widx — we want to PRESERVE the buffer for
          * the UART dumper to read after the transaction ends */
      end else if (data_phase && !cap_full) begin
         cap_buf[cap_widx] <= dout_quad;
         if (cap_widx == CAP_DEPTH-1)
            cap_full <= 1'b1;
         else
            cap_widx <= cap_widx + 1'b1;
      end
   end

   /* ---------- UART dumper ----------
    *
    * Runs on the 12 MHz fabric clock.  Waits for cs_debounced_high
    * to be HIGH (= transaction over) AND cap_widx > 0 (= captured
    * something), then sequentially formats each entry into an ASCII
    * line:  "BB P H\r\n"  where BB = data_byte hex, P = phase_lo,
    * H = dout_quad hex.  After the last entry sends "LA END\r\n".
    * After dumping, idles until cs_debounced_high goes LOW again
    * (= next transaction) and then waits for the new buffer to fill
    * before re-dumping. */
   localparam CLKS_PER_BIT = 104;  // 12 MHz / 115200 ≈ 104

   /* uart_tx engine */
   reg       u_start;
   reg [7:0] u_data;
   wire      u_busy;
   uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
      .clk(clk), .start(u_start), .data(u_data),
      .tx(tx), .busy(u_busy)
   );

   /* Dumper FSM */
   localparam D_IDLE  = 3'd0;
   localparam D_HEAD  = 3'd1;  // emit "LA ...\r\n" header
   localparam D_ENTRY = 3'd2;  // emit one cap_buf entry
   localparam D_TAIL  = 3'd3;  // emit "LA END\r\n" trailer
   localparam D_WAIT  = 3'd4;  // wait for next transaction

   reg [2:0]                  d_state;
   reg [CAP_DEPTH_LOG2-1:0]   d_ridx;
   reg [3:0]                  d_field;   // which field within entry/header
   reg [7:0]                  d_char_buf;
   reg                        d_kick;
   reg                        d_armed;   // 1 → dump after CS↑

   initial begin
      d_state    = D_IDLE;
      d_ridx     = {CAP_DEPTH_LOG2{1'b0}};
      d_field    = 4'd0;
      d_char_buf = 8'd0;
      d_kick     = 1'b0;
      d_armed    = 1'b0;
      u_start    = 1'b0;
      u_data     = 8'd0;
   end

   function [7:0] hex_char;
      input [3:0] n;
      begin
         hex_char = (n < 4'd10) ? (8'h30 + {4'd0, n})
                                : (8'h57 + {4'd0, n});
      end
   endfunction

   /* Each entry is just dout_quad[3:0] — one hex char + CR/LF. */
   wire [3:0] cur_dq = cap_buf[d_ridx];

   /* Header is "LA <count>\r\n" — we just emit fixed "LA\r\n". */
   reg [3:0] hd_idx;
   reg [3:0] tl_idx;

   /* Arm the dumper when the buffer fills (cap_full) OR when CS goes
    * HIGH with any captures (cap_widx > 0) — either ends the
    * transaction. */
   reg cap_full_q;
   reg cs_high_q;
   always @(posedge clk) begin
      cap_full_q <= cap_full;
      cs_high_q  <= cs_debounced_high;
      if (!d_armed && (cap_full || cs_debounced_high) &&
          (cap_widx != 0 || cap_full))
         d_armed <= 1'b1;
   end

   /* UART driver state machine */
   always @(posedge clk) begin
      u_start <= 1'b0;
      case (d_state)
         D_IDLE: begin
            if (d_armed && !u_busy) begin
               d_state <= D_HEAD;
               hd_idx  <= 4'd0;
            end
         end
         D_HEAD: begin
            if (!u_busy && !u_start) begin
               case (hd_idx)
                  4'd0: u_data <= "L";
                  4'd1: u_data <= "A";
                  4'd2: u_data <= 8'h0d; // CR
                  4'd3: u_data <= 8'h0a; // LF
                  default: u_data <= 8'h00;
               endcase
               u_start <= 1'b1;
               if (hd_idx == 4'd3) begin
                  d_state <= D_ENTRY;
                  d_ridx  <= {CAP_DEPTH_LOG2{1'b0}};
                  d_field <= 4'd0;
               end else begin
                  hd_idx <= hd_idx + 4'd1;
               end
            end
         end
         D_ENTRY: begin
            if (!u_busy && !u_start) begin
               case (d_field)
                  4'd0: u_data <= hex_char(cur_dq);
                  4'd1: u_data <= 8'h0d;
                  4'd2: u_data <= 8'h0a;
                  default: u_data <= 8'h00;
               endcase
               u_start <= 1'b1;
               if (d_field == 4'd2) begin
                  d_field <= 4'd0;
                  if (d_ridx == CAP_DEPTH-1 ||
                      (!cap_full && d_ridx + 1 >= cap_widx)) begin
                     d_state <= D_TAIL;
                     tl_idx  <= 4'd0;
                  end else begin
                     d_ridx <= d_ridx + 1'b1;
                  end
               end else begin
                  d_field <= d_field + 4'd1;
               end
            end
         end
         D_TAIL: begin
            if (!u_busy && !u_start) begin
               case (tl_idx)
                  4'd0: u_data <= "L";
                  4'd1: u_data <= "A";
                  4'd2: u_data <= " ";
                  4'd3: u_data <= "E";
                  4'd4: u_data <= "N";
                  4'd5: u_data <= "D";
                  4'd6: u_data <= 8'h0d;
                  4'd7: u_data <= 8'h0a;
                  default: u_data <= 8'h00;
               endcase
               u_start <= 1'b1;
               if (tl_idx == 4'd7)
                  d_state <= D_WAIT;
               else
                  tl_idx <= tl_idx + 4'd1;
            end
         end
         D_WAIT: begin
            /* idle forever — one shot.  The mission only needs one
             * capture; if the test wants multiple, it has to reset
             * the FPGA between captures. */
         end
         default: d_state <= D_IDLE;
      endcase
   end

endmodule
