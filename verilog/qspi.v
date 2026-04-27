module qspi_slave (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx
   );
   reg [2:0]  bit_cnt;
   reg [7:0]  shift_in;
   reg [7:0]  shift_out;
   reg [7:0]  opcode;
   // `byte_cnt` is split: a small saturating `phase_cnt` (0..7) drives
   // all per-byte control logic, and a 16-bit `byte_cnt` only serves
   // the printer's `bytes=` field. The printer displays modulo 100 so
   // 16 bits is plenty; saturating phase keeps the wide comparator out
   // of the sclk-domain critical path.
   reg [2:0]  phase_cnt;
   reg [15:0] byte_cnt;
   reg [3:0]  addr_low;
   reg [19:0] quad_in_cnt;
   reg [3:0]  nibble_buf;
   reg        qin_phase;
   
   initial begin
      bit_cnt     = 0;
      shift_in    = 0;
      shift_out   = 0;
      opcode      = 0;
      phase_cnt   = 0;
      byte_cnt    = 0;
      addr_low    = 0;
      quad_in_cnt = 0;
      nibble_buf  = 0;
      qin_phase   = 0;
   end
   
   // just-completed byte and its low nibble.
   wire [7:0] byte_captured = {shift_in[6:0], io_d_in[0]};
   wire [3:0] new_low       = byte_captured[3:0];
   wire       byte_done     = (bit_cnt == 3'd7);
   wire       quad_in_phase = (opcode == 8'h32) && (phase_cnt >= 3'd4);
   
   always @(posedge sclk or posedge cs_n) begin
      if (cs_n) begin
         bit_cnt     <= 0;
         phase_cnt   <= 0;
         byte_cnt    <= 0;
         opcode      <= 0;
         shift_in    <= 0;
         shift_out   <= 0;
         addr_low    <= 0;
         qin_phase   <= 0;
         quad_in_cnt <= 0;
         nibble_buf  <= 0;
      end else begin
         shift_in <= {shift_in[6:0], io_d_in[0]};
         bit_cnt  <= bit_cnt + 3'd1;
   
         // Default: shift `shift_out` left by 1 each SCLK rise so the
         // negedge block sees the correct bit on tap[7]. A byte-boundary
         // load below overrides this.
         shift_out <= {shift_out[6:0], 1'b0};
   
         // RAM writes happen in a single statement with combinationally
         // computed write enable / address / data. This keeps the
         // memory inference clean: yosys sees one write port and one
         // read port -> 16x8 distributed LUT RAM (~8 LUTs) instead of
         // 16 flops + a wide read mux (~200 LCs).
         if (ram_we) ram[ram_waddr] <= ram_wdata;
   
         // 0x32 Quad Page Program data phase: sample io[3:0] every
         // rise, pair into bytes; the actual RAM write happens above.
         if (quad_in_phase) begin
            qin_phase <= ~qin_phase;
            if (qin_phase == 1'b0) begin
               nibble_buf <= io_d_in;
            end else begin
               addr_low    <= addr_low + 4'd1;
               quad_in_cnt <= quad_in_cnt + 20'd1;
            end
         end
   
         if (byte_done) begin
            byte_cnt  <= byte_cnt  + 16'd1;
            // Saturate phase_cnt at 7 so the 8th-and-beyond byte of a
            // long write/read keeps falling into the catch-all `> 4`
            // arms below.
            if (phase_cnt != 3'd7) phase_cnt <= phase_cnt + 3'd1;
   
            if (phase_cnt == 3'd0) begin
               opcode <= byte_captured;
               if (byte_captured == 8'h9F) shift_out <= 8'hAA;
               else if (byte_captured == 8'h05) shift_out <= 8'h00;
            end else if (phase_cnt == 3'd1 && opcode == 8'h9F) begin
               shift_out <= 8'h55;
            end else if (phase_cnt == 3'd2 && opcode == 8'h9F) begin
               shift_out <= 8'h01;
            end else if (opcode == 8'h03 && phase_cnt == 3'd3) begin
               addr_low  <= new_low + 4'd1;
               shift_out <= ram_rd;
            end else if (opcode == 8'h03 && phase_cnt > 3'd3) begin
               addr_low  <= addr_low + 4'd1;
               shift_out <= ram_rd;
            end else if (opcode == 8'h0B && phase_cnt == 3'd3) begin
               addr_low <= new_low;
            end else if (opcode == 8'h0B && phase_cnt == 3'd4) begin
               shift_out <= ram_rd;
               addr_low  <= addr_low + 4'd1;
            end else if (opcode == 8'h0B && phase_cnt > 3'd4) begin
               shift_out <= ram_rd;
               addr_low  <= addr_low + 4'd1;
            end else if (opcode == 8'h02 && phase_cnt == 3'd3) begin
               addr_low <= new_low;
            end else if (opcode == 8'h02 && phase_cnt > 3'd3 && wel) begin
               addr_low <= addr_low + 4'd1;
            end else if (opcode == 8'h32 && phase_cnt == 3'd3) begin
               addr_low <= new_low;
            end else if (opcode == 8'h6B && phase_cnt == 3'd3) begin
               // Capture the address-low nibble so 0x6B respects the
               // master's requested offset. The original step-11 code
               // omitted this; tests that read from address 0 worked
               // by accident because addr_low was 0 from cs_n reset.
               addr_low <= new_low;
            end
         end
      end
   end
   
   // RAM port logic. One write port, one combinational read port.
   // `ram_waddr` / `ram_wdata` / `ram_we` are derived combinationally
   // from the same conditions the shift engine uses, so the actual
   // write statement above is a clean infer-as-RAM construct.
   //
   // `wel_s` mirrors `wel` (fclk domain) into the sclk domain. This
   // removes a long combinational chain from `wel` (set on a fclk
   // edge between frames) into the sclk-clocked RAM write enable
   // that nextpnr otherwise treats as a same-cycle path.
   reg wel_s;
   initial wel_s = 0;
   always @(posedge sclk or posedge cs_n) begin
      if (cs_n) wel_s <= 1'b0;
      else      wel_s <= wel;
   end
   
   wire ram_we = (opcode == 8'h02 && phase_cnt > 3'd3 && byte_done && wel_s)
              || (opcode == 8'h32 && quad_in_phase && qin_phase == 1'b1 && wel_s);
   wire [3:0] ram_waddr = addr_low;
   wire [7:0] ram_wdata = (opcode == 8'h32) ? {nibble_buf, io_d_in}
                                            : byte_captured;
   
   // Combinational RAM read. A single mux on the address selects the
   // right candidate per cycle:
   // - 0x6B data phase: `data_ptr` outside an advance posedge,
   //   `data_ptr + 1` on the advance posedge so the byte we register
   //   into `quad_byte` is the NEXT byte of the stream.
   // - shift engine: `new_low` on the boundary that captures the
   //   address byte; `addr_low` otherwise.
   wire [3:0] ram_raddr = quad_data
                        ? (quad_advance ? (data_ptr + 4'd1) : data_ptr)
                        : (byte_done
                           && (   (opcode == 8'h03 && phase_cnt == 3'd3)
                               || (opcode == 8'h0B && phase_cnt == 3'd3))
                           ? new_low
                           : addr_low);
   wire [7:0] ram_rd = ram[ram_raddr];
   reg [3:0] quad_out;
   reg       quad_phase;  // 0 = upper nibble is next to present
   reg [3:0] data_ptr;
   reg [7:0] quad_byte;
   
   initial begin
      quad_out   = 0;
      quad_phase = 0;
      data_ptr   = 0;
      quad_byte  = 0;
   end
   
   // Active high during the 0x6B data phase (after opcode + 3 addr +
   // dummy = 5 single-lane SCLK-bytes). `phase_cnt` saturates at 7,
   // which still satisfies `>= 5` for all subsequent bytes.
   wire quad_data = (opcode == 8'h6B) && (phase_cnt >= 3'd5);
   
   // Pointer advance cadence. The 0x6B data phase uses TWO negedges
   // per RAM byte: one presents the upper nibble, the next presents
   // the lower nibble. `quad_byte` must stay stable across both
   // negedges of a pair, then refresh to the next RAM byte before the
   // third negedge.
   //
   // The step-12 version gated the advance on `bit_cnt[0]`. That was
   // off by one SCLK: the advance fired on the posedge BETWEEN the
   // upper-nibble negedge and the lower-nibble negedge, causing
   // `quad_byte` to switch to byte N+1 before the lower nibble of
   // byte N had been presented. Master reassembled
   // `{byte_N_upper, byte_{N+1}_lower}` for every pair -- garbage.
   //
   // The fix is a dedicated sclk-domain toggle `quad_byte_phase` that
   // starts at 0 the cycle the data phase begins and flips on every
   // subsequent posedge inside the data phase. The advance fires when
   // `quad_byte_phase == 1` -- i.e., on posedge #3, #5, #7 ... (after
   // two negedges have consumed the current byte). The very first
   // load at posedge #1 is the `!quad_data` branch, which also resets
   // `quad_byte_phase` to 0 so the cadence is aligned with the start
   // of the data phase regardless of what `bit_cnt` happened to be.
   reg        quad_byte_phase;
   initial    quad_byte_phase = 0;
   wire       quad_advance = quad_data && quad_byte_phase;
   
   always @(posedge sclk or posedge cs_n) begin
      if (cs_n) begin
         data_ptr        <= 0;
         quad_byte       <= 0;
         quad_byte_phase <= 0;
      end else begin
         // Always sample the shared RAM read port on posedge sclk;
         // quad_byte holds the byte for the negedge presenter to
         // slice. When `quad_advance` is asserted (or when we just
         // entered the data phase via `!quad_data`), data_ptr and
         // quad_byte refresh. Otherwise quad_byte stays put across
         // the lower-nibble negedge.
         if (!quad_data) begin
            data_ptr        <= addr_low;
            quad_byte       <= ram_rd;
            quad_byte_phase <= 1'b0;
         end else begin
            quad_byte_phase <= ~quad_byte_phase;
            if (quad_advance) begin
               data_ptr  <= data_ptr + 4'd1;
               quad_byte <= ram_rd;
            end
         end
      end
   end
   
   // Negedge presenter: pure registered slice of `quad_byte`. No RAM
   // read on this clock edge; just a 4-bit mux into a flop.
   always @(negedge sclk or posedge cs_n) begin
      if (cs_n) begin
         quad_out   <= 0;
         quad_phase <= 0;
      end else if (quad_data) begin
         if (quad_phase == 1'b0) begin
            quad_out   <= quad_byte[7:4];
            quad_phase <= 1'b1;
         end else begin
            quad_out   <= quad_byte[3:0];
            quad_phase <= 1'b0;
         end
      end else begin
         quad_phase <= 1'b0;
      end
   end
   // Quad-input state (`quad_in_cnt`, `nibble_buf`, `qin_phase`,
   // `quad_in_phase`) is declared and driven inside the sclk-domain
   // shift engine block; this chunk intentionally has no body.
   // `resp_window` is high during single-lane MISO phases on io[1].
   // `quad_data_drive` is high during the 0x6B quad data phase. The
   // raw `cs_n` pin is gated in so io snaps to Hi-Z the instant CS
   // rises, even before the cs_n synchroniser into fclk has settled.
   wire resp_window = (!cs_n)
                   && ( ((opcode == 8'h9F) && (phase_cnt >= 3'd1) && (phase_cnt <= 3'd3))
                     || ((opcode == 8'h05) && (phase_cnt == 3'd1))
                     || ((opcode == 8'h03) && (phase_cnt >= 3'd4))
                     || ((opcode == 8'h0B) && (phase_cnt >= 3'd5)) );
   wire quad_data_drive = (!cs_n) && quad_data;
   
   // Per-lane OEs. Each lane is an independent named wire so yosys
   // keeps four distinct tristate enables in the inferred SB_IO
   // instances. (Step-13 had four `assign io[k] = ... : 1'bz;`
   // statements but yosys collapsed io[0]/io[2]/io[3] OEs into a
   // single $_TBUF_ in some intermediate pass, and one of those
   // lanes ended up without a working OE in the placed bitstream.)
   wire io_oe_0    = quad_data_drive;
   wire io_oe_1    = quad_data_drive | resp_window;
   wire io_oe_2    = quad_data_drive;
   wire io_oe_3    = quad_data_drive;
   wire io_d_out_0 = quad_out[0];
   wire io_d_out_1 = quad_data_drive ? quad_out[1] : shift_out[7];
   wire io_d_out_2 = quad_out[2];
   wire io_d_out_3 = quad_out[3];
   
   // Inferred tristates. Each lane's `assign` references a UNIQUE
   // per-lane OE wire so the inferred SB_IOs cannot share / collapse
   // their OE signals.
   assign io[0] = io_oe_0 ? io_d_out_0 : 1'bz;
   assign io[1] = io_oe_1 ? io_d_out_1 : 1'bz;
   assign io[2] = io_oe_2 ? io_d_out_2 : 1'bz;
   assign io[3] = io_oe_3 ? io_d_out_3 : 1'bz;
   
   // Aggregate the per-lane OE signals as a 4-bit `io_oe` bus for
   // testbench introspection. The `io_d_in` view is just the inout
   // port itself (combinational input).
   wire [3:0] io_oe   = {io_oe_3, io_oe_2, io_oe_1, io_oe_0};
   wire [3:0] io_d_in = io;
   reg [31:0] crc_reg;
   initial crc_reg = 32'hFFFFFFFF;
   
   function [31:0] crc32_step;
      input [31:0] c;
      input        bit_in;
      reg          lsb;
      begin
         lsb = c[0] ^ bit_in;
         crc32_step = {1'b0, c[31:1]} ^ (lsb ? 32'hEDB88320 : 32'h00000000);
      end
   endfunction
   
   function [31:0] crc32_byte;
      input [31:0] c;
      input [7:0]  b;
      reg   [31:0] t;
      begin
         // Reflected input: fold bits LSB-first.
         t = c;
         t = crc32_step(t, b[0]);
         t = crc32_step(t, b[1]);
         t = crc32_step(t, b[2]);
         t = crc32_step(t, b[3]);
         t = crc32_step(t, b[4]);
         t = crc32_step(t, b[5]);
         t = crc32_step(t, b[6]);
         t = crc32_step(t, b[7]);
         crc32_byte = t;
      end
   endfunction
   
   // Master-driven qualifier: combinational from `byte_cnt` (pre-inc at
   // the boundary) and `opcode` (which is updated on this same edge
   // for N==0, but we override that branch to "always driven").
   wire master_driven_byte =
        (phase_cnt == 3'd0)                               ? 1'b1 :
        (opcode == 8'h9F || opcode == 8'h05)              ? 1'b0 :
        (opcode == 8'h03)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h0B)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6B)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h32)                                 ? (phase_cnt <= 3'd3) :
                                                            1'b1;
   
   // For 0x32, the data-phase bytes arrive across IO[3:0] rather than
   // serially on MOSI, so `shift_in` does not hold the completed byte.
   // Instead we fold the reconstructed quad byte `{nibble_buf, io[3:0]}`
   // into the CRC at the instant the lower nibble arrives (qin_phase==1
   // on a quad-in rise).
   wire quad_in_byte_done = quad_in_phase && (qin_phase == 1'b1);
   
   // CRC register lives in the sclk domain alongside the rest of the
   // capture state. Async-cleared on cs_n high so each frame starts
   // from the IEEE init value.
   always @(posedge sclk or posedge cs_n) begin
      if (cs_n) begin
         crc_reg <= 32'hFFFFFFFF;
      end else if ((bit_cnt == 3'd7) && master_driven_byte) begin
         crc_reg <= crc32_byte(crc_reg, {shift_in[6:0], io_d_in[0]});
      end else if (quad_in_byte_done) begin
         crc_reg <= crc32_byte(crc_reg, {nibble_buf, io_d_in});
      end
   end
   reg [7:0] ram [0:15];
   reg       wel;
   integer   _i;
   initial begin
      for (_i = 0; _i < 16; _i = _i + 1) ram[_i] = 8'h00;
      wel = 0;
   end
   
   reg [1:0] cs_sync;
   initial cs_sync = 2'b11;
   always @(posedge clk) cs_sync <= {cs_sync[0], cs_n};
   wire cs_s     = cs_sync[1];
   reg  cs_s_d;
   initial cs_s_d = 1'b1;
   always @(posedge clk) cs_s_d <= cs_s;
   wire cs_rise_pulse = !cs_s_d && cs_s;
   
   always @(posedge clk) begin
      if (cs_rise_pulse) begin
         if (snap_op == 8'h06 && snap_byte_cnt[7:0] == 8'd1)
            wel <= 1'b1;
         else if (snap_op == 8'h02 || snap_op == 8'h32)
            wel <= 1'b0;
      end
   end
   // Snapshot the sclk-domain state on the cs_n rising edge. Using
   // cs_n itself as the clock means the capture flops sample the
   // pre-edge value of `opcode`/`byte_cnt`/`quad_in_cnt`/`crc_reg`
   // exactly when those source flops are being asynchronously cleared
   // by the same cs_n edge. Standard non-blocking semantics: RHS is
   // captured before the reset takes effect, so the snapshot holds
   // the end-of-frame value until the next CS-rise.
   //
   // `frame_cnt_pre` collapses byte_cnt and quad_in_cnt into the value
   // the printer wants to display, so we only carry one 32-bit count
   // in the snapshot (saves ~20 flops vs separate quad_in_cnt
   // snapshot).
   wire [15:0] frame_cnt_pre = (opcode == 8'h32)
                             ? (16'd4 + {4'd0, quad_in_cnt[11:0]})
                             : byte_cnt;
   
   reg [7:0]  frame_op;
   reg [15:0] frame_cnt;
   reg [31:0] frame_crc_raw;
   initial begin
      frame_op       = 0;
      frame_cnt      = 0;
      frame_crc_raw  = 32'hFFFFFFFF;
   end
   
   always @(posedge cs_n) begin
      frame_op      <= opcode;
      frame_cnt     <= frame_cnt_pre;
      frame_crc_raw <= crc_reg;
   end
   
   // Frame-done pulse in the fclk domain: rising edge of the
   // synchronised cs_s. The printer consumes frame_op / frame_cnt /
   // frame_crc on this pulse. `frame_crc` is the finalised (XOR'd)
   // CRC, materialised combinationally from `frame_crc_raw`.
   wire [31:0] frame_crc = frame_crc_raw ^ 32'hFFFFFFFF;
   reg         frame_done;
   initial frame_done = 0;
   always @(posedge clk) frame_done <= cs_rise_pulse;
   
   // Aliases used by the page-buffer/WEL block, which needs to
   // distinguish 0x06 (set WEL) from 0x02/0x32 (clear WEL) using the
   // snapshot opcode / count that survives the sclk-domain reset.
   wire [7:0]  snap_op       = frame_op;
   wire [31:0] snap_byte_cnt = frame_cnt;
   localparam P_IDLE = 6'd0;
   localparam P_O    = 6'd1;
   localparam P_P    = 6'd2;
   localparam P_EQ1  = 6'd3;
   localparam P_HH   = 6'd4;
   localparam P_HL   = 6'd5;
   localparam P_SP   = 6'd6;
   localparam P_B    = 6'd7;
   localparam P_Y    = 6'd8;
   localparam P_T    = 6'd9;
   localparam P_E    = 6'd10;
   localparam P_S    = 6'd11;
   localparam P_EQ2  = 6'd12;
   localparam P_D1   = 6'd13;
   localparam P_D0   = 6'd14;
   localparam P_SP2  = 6'd15;
   localparam P_MM   = 6'd16;
   localparam P_MO   = 6'd17;
   localparam P_MS   = 6'd18;
   localparam P_MI   = 6'd19;
   localparam P_MU   = 6'd20;
   localparam P_MC   = 6'd21;
   localparam P_MR   = 6'd22;
   localparam P_MC2  = 6'd23;
   localparam P_EQ3  = 6'd24;
   localparam P_C7   = 6'd25;
   localparam P_C6   = 6'd26;
   localparam P_C5   = 6'd27;
   localparam P_C4   = 6'd28;
   localparam P_C3   = 6'd29;
   localparam P_C2   = 6'd30;
   localparam P_C1   = 6'd31;
   localparam P_C0   = 6'd32;
   localparam P_CR   = 6'd33;
   localparam P_LF   = 6'd34;
   
   reg [5:0]  pstate;
   reg [7:0]  p_op;
   reg [7:0]  p_cnt;
   reg [31:0] p_crc;
   reg        tx_start;
   reg  [7:0] tx_data;
   wire       tx_busy;
   
   initial begin
      pstate   = P_IDLE;
      p_op     = 0;
      p_cnt    = 0;
      p_crc    = 0;
      tx_start = 0;
      tx_data  = 0;
   end
   
   function [7:0] hexchar(input [3:0] n);
      hexchar = (n < 4'd10) ? (8'h30 + {4'h0, n})
                            : (8'h61 + {4'h0, n} - 8'd10);
   endfunction
   
   wire [3:0] d1 = (p_cnt / 8'd10);
   wire [3:0] d0 = (p_cnt % 8'd10);
   
   always @(posedge clk) begin
      tx_start <= 1'b0;
      case (pstate)
         P_IDLE: if (frame_done) begin
                    p_op   <= frame_op;
                    p_cnt  <= frame_cnt[7:0];
                    p_crc  <= frame_crc;
                    pstate <= P_O;
                 end
         P_O:   if (!tx_busy && !tx_start) begin tx_data <= "o"; tx_start <= 1; pstate <= P_P;   end
         P_P:   if (!tx_busy && !tx_start) begin tx_data <= "p"; tx_start <= 1; pstate <= P_EQ1; end
         P_EQ1: if (!tx_busy && !tx_start) begin tx_data <= "="; tx_start <= 1; pstate <= P_HH;  end
         P_HH:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_op[7:4]); tx_start <= 1; pstate <= P_HL; end
         P_HL:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_op[3:0]); tx_start <= 1; pstate <= P_SP; end
         P_SP:  if (!tx_busy && !tx_start) begin tx_data <= " "; tx_start <= 1; pstate <= P_B;   end
         P_B:   if (!tx_busy && !tx_start) begin tx_data <= "b"; tx_start <= 1; pstate <= P_Y;   end
         P_Y:   if (!tx_busy && !tx_start) begin tx_data <= "y"; tx_start <= 1; pstate <= P_T;   end
         P_T:   if (!tx_busy && !tx_start) begin tx_data <= "t"; tx_start <= 1; pstate <= P_E;   end
         P_E:   if (!tx_busy && !tx_start) begin tx_data <= "e"; tx_start <= 1; pstate <= P_S;   end
         P_S:   if (!tx_busy && !tx_start) begin tx_data <= "s"; tx_start <= 1; pstate <= P_EQ2; end
         P_EQ2: if (!tx_busy && !tx_start) begin tx_data <= "="; tx_start <= 1; pstate <= P_D1;  end
         P_D1:  if (!tx_busy && !tx_start) begin
                    if (d1 != 0) begin
                       tx_data <= hexchar(d1); tx_start <= 1; pstate <= P_D0;
                    end else pstate <= P_D0;
                 end
         P_D0:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(d0); tx_start <= 1; pstate <= P_SP2; end
         P_SP2: if (!tx_busy && !tx_start) begin tx_data <= " "; tx_start <= 1; pstate <= P_MM;  end
         P_MM:  if (!tx_busy && !tx_start) begin tx_data <= "m"; tx_start <= 1; pstate <= P_MO;  end
         P_MO:  if (!tx_busy && !tx_start) begin tx_data <= "o"; tx_start <= 1; pstate <= P_MS;  end
         P_MS:  if (!tx_busy && !tx_start) begin tx_data <= "s"; tx_start <= 1; pstate <= P_MI;  end
         P_MI:  if (!tx_busy && !tx_start) begin tx_data <= "i"; tx_start <= 1; pstate <= P_MU;  end
         P_MU:  if (!tx_busy && !tx_start) begin tx_data <= "_"; tx_start <= 1; pstate <= P_MC;  end
         P_MC:  if (!tx_busy && !tx_start) begin tx_data <= "c"; tx_start <= 1; pstate <= P_MR;  end
         P_MR:  if (!tx_busy && !tx_start) begin tx_data <= "r"; tx_start <= 1; pstate <= P_MC2; end
         P_MC2: if (!tx_busy && !tx_start) begin tx_data <= "c"; tx_start <= 1; pstate <= P_EQ3; end
         P_EQ3: if (!tx_busy && !tx_start) begin tx_data <= "="; tx_start <= 1; pstate <= P_C7;  end
         P_C7:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[31:28]); tx_start <= 1; pstate <= P_C6; end
         P_C6:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[27:24]); tx_start <= 1; pstate <= P_C5; end
         P_C5:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[23:20]); tx_start <= 1; pstate <= P_C4; end
         P_C4:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[19:16]); tx_start <= 1; pstate <= P_C3; end
         P_C3:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[15:12]); tx_start <= 1; pstate <= P_C2; end
         P_C2:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[11: 8]); tx_start <= 1; pstate <= P_C1; end
         P_C1:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[ 7: 4]); tx_start <= 1; pstate <= P_C0; end
         P_C0:  if (!tx_busy && !tx_start) begin tx_data <= hexchar(p_crc[ 3: 0]); tx_start <= 1; pstate <= P_CR; end
         P_CR:  if (!tx_busy && !tx_start) begin tx_data <= 8'h0d; tx_start <= 1; pstate <= P_LF;   end
         P_LF:  if (!tx_busy && !tx_start) begin tx_data <= 8'h0a; tx_start <= 1; pstate <= P_IDLE; end
         default: pstate <= P_IDLE;
      endcase
   end
   uart_tx #(.CLKS_PER_BIT(104)) u_tx (
      .clk  (clk),
      .start(tx_start),
      .data (tx_data),
      .tx   (tx),
      .busy (tx_busy)
   );
endmodule
