module jedec (
      input        clk,
      input        cs_n,
      input        sclk,
      inout  [3:0] io,
      output       tx
   );
   reg [2:0]  bit_cnt;
   reg [6:0]  shift_in;
   reg [7:0]  shift_out;
   reg [7:0]  opcode;
   reg [2:0]  phase_cnt;
   reg [15:0] byte_cnt;
   reg [3:0]  addr_low;
   reg [7:0]  data_byte;
   reg [19:0] quad_in_cnt;
   reg [3:0]  nibble_buf;
   reg        qin_phase;
   reg [6:0]  sfdp_idx;
   
   initial begin
      bit_cnt     = 0;
      shift_in    = 0;
      shift_out   = 0;
      opcode      = 0;
      phase_cnt   = 0;
      byte_cnt    = 0;
      addr_low    = 0;
      data_byte   = 0;
      quad_in_cnt = 0;
      nibble_buf  = 0;
      qin_phase   = 0;
      sfdp_idx    = 0;
   end
   wire [7:0] byte_captured = {shift_in[6:0], io_d_in[0]};
   wire [3:0] new_low       = byte_captured[3:0];
   wire       byte_done     = (bit_cnt == 3'd7);
   wire       quad_in_phase = (opcode == 8'h32) && (phase_cnt >= 3'd4);
   always @(posedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) begin
         bit_cnt     <= 0;
         phase_cnt   <= 0;
         byte_cnt    <= 0;
         opcode      <= 0;
         shift_in    <= 0;
         shift_out   <= 0;
         addr_low    <= 0;
         data_byte   <= 0;
         qin_phase   <= 0;
         quad_in_cnt <= 0;
         nibble_buf  <= 0;
         sfdp_idx    <= 0;
         quad_active       <= 0;
         quad_next_nibble  <= 0;
         quad_data_byte    <= 0;
         quad_data_drive_r <= 0;
         quad_hi_next      <= 0;
         quad_diag_idx     <= 0;
      end else begin
         shift_in <= {shift_in[5:0], io_d_in[0]};
         bit_cnt  <= bit_cnt + 3'd1;
         shift_out <= {shift_out[6:0], 1'b0};
         if (quad_in_phase) begin
            qin_phase <= ~qin_phase;
            if (qin_phase == 1'b0) begin
               nibble_buf <= io_d_in;
            end else begin
               addr_low    <= addr_low + 4'd1;
               quad_in_cnt <= quad_in_cnt + 20'd1;
            end
         end
         if (quad_start) begin
            quad_active       <= 1'b1;
            quad_data_drive_r <= 1'b1;
            if (opcode == 8'h6C) begin
               quad_next_nibble  <= quad_onehot(2'd0);
               quad_diag_idx     <= 4'd1;
               quad_data_byte    <= 8'h00;
            end else if (opcode == 8'h6D) begin
               quad_next_nibble  <= 4'h0;
               quad_diag_idx     <= 4'd1;
            end else if (opcode == 8'h6E) begin
               quad_next_nibble  <= 4'h0;
               quad_diag_idx     <= 4'd0;
               quad_data_byte    <= 8'h00;
            end else if (opcode == 8'h6F) begin
               quad_next_nibble  <= 4'h0;
               quad_diag_idx     <= 4'd0;
               quad_data_byte    <= 8'h00;
            end else begin
               quad_next_nibble  <= quad_data_byte_seed[7:4];
               quad_diag_idx     <= 4'd0;
               quad_data_byte    <= quad_data_byte_seed;
            end
            quad_hi_next      <= 1'b0;
         end else if (quad_data) begin
            quad_data_drive_r <= 1'b1;
            if (opcode == 8'h6C) begin
               quad_next_nibble <= quad_onehot(quad_diag_idx[1:0]);
               quad_diag_idx    <= quad_diag_idx + 4'd1;
            end else if (opcode == 8'h6D) begin
               quad_next_nibble <= quad_diag6d_nibble;
               quad_diag_idx    <= quad_diag_idx + 4'd1;
            end else if (opcode == 8'h6F) begin
               quad_next_nibble <= quad_next_nibble + 4'd1;
            end else if (opcode == 8'h6B) begin
               if (quad_hi_next) begin
                  quad_next_nibble <= quad_data_byte_inc[7:4];
                  quad_data_byte   <= quad_data_byte_inc;
                  quad_hi_next     <= 1'b0;
               end else begin
                  quad_next_nibble <= quad_data_byte[3:0];
                  quad_hi_next     <= 1'b1;
               end
            end else begin
               if (quad_hi_next) begin
                  if (opcode == 8'h6E) begin
                     quad_next_nibble <= quad_hold_byte_inc[7:4];
                     quad_data_byte   <= quad_hold_byte_inc;
                  end else begin
                     quad_next_nibble <= quad_data_byte_inc[7:4];
                     quad_data_byte   <= quad_data_byte_inc;
                  end
                  quad_hi_next     <= 1'b0;
               end else begin
                  quad_next_nibble <= quad_data_byte[3:0];
                  quad_hi_next     <= 1'b1;
               end
            end
         end else begin
            quad_active       <= 1'b0;
            quad_data_drive_r <= 1'b0;
            quad_hi_next      <= 1'b0;
            quad_diag_idx     <= 4'd0;
         end
         if (byte_done && (   (opcode == 8'h03 && phase_cnt >  3'd3)
                           || (opcode == 8'h0B && phase_cnt >= 3'd4)))
            data_byte <= data_byte + 8'd1;
         if (byte_done) begin
            byte_cnt  <= byte_cnt  + 16'd1;
            if (phase_cnt != 3'd7) phase_cnt <= phase_cnt + 3'd1;
            if (phase_cnt == 3'd0) begin
               opcode <= byte_captured;
               if (byte_captured == 8'h9F) shift_out <= 8'h20;
               else if (byte_captured == 8'h05) shift_out <= {6'b0, wel_s, 1'b0};
            end else if (phase_cnt == 3'd1 && opcode == 8'h9F) begin
               shift_out <= 8'h20;
            end else if (phase_cnt == 3'd2 && opcode == 8'h9F) begin
               shift_out <= 8'h14;
            end else if (opcode == 8'h03 && phase_cnt == 3'd3) begin
               shift_out <= byte_captured;
               data_byte <= byte_captured + 8'd1;
            end else if (opcode == 8'h03 && phase_cnt > 3'd3) begin
               shift_out <= data_byte;
            end else if (opcode == 8'h0B && phase_cnt == 3'd3) begin
               data_byte <= byte_captured;
            end else if (opcode == 8'h0B && phase_cnt >= 3'd4) begin
               shift_out <= data_byte;
            end else if (opcode == 8'h02 && phase_cnt == 3'd3) begin
               addr_low <= new_low;
            end else if (opcode == 8'h02 && phase_cnt > 3'd3 && wel) begin
               addr_low <= addr_low + 4'd1;
            end else if (opcode == 8'h32 && phase_cnt == 3'd3) begin
               addr_low <= new_low;
            end else if (opcode == 8'h6B && phase_cnt == 3'd3) begin
               data_byte <= byte_captured;
            end else if (opcode == 8'h5A && phase_cnt == 3'd3) begin
               sfdp_idx <= byte_captured[6:0];
            end else if (opcode == 8'h5A && phase_cnt >= 3'd4) begin
               shift_out <= sfdp_rd;
               sfdp_idx  <= sfdp_idx + 7'd1;
            end
         end
      end
   end
   reg wel_s;
   initial wel_s = 0;
   always @(posedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) wel_s <= 1'b0;
      else      wel_s <= wel;
   end
   reg [7:0] sfdp_rom [0:127];
   integer   _sfdp_i;
   initial begin
      for (_sfdp_i = 0; _sfdp_i < 128; _sfdp_i = _sfdp_i + 1)
         sfdp_rom[_sfdp_i] = 8'hFF;
   
      sfdp_rom[7'h00] = 8'h53;
      sfdp_rom[7'h01] = 8'h46;
      sfdp_rom[7'h02] = 8'h44;
      sfdp_rom[7'h03] = 8'h50;
      sfdp_rom[7'h04] = 8'h06;
      sfdp_rom[7'h05] = 8'h01;
      sfdp_rom[7'h06] = 8'h00;
      sfdp_rom[7'h07] = 8'hFF;
   
      sfdp_rom[7'h08] = 8'h00;
      sfdp_rom[7'h09] = 8'h06;
      sfdp_rom[7'h0A] = 8'h01;
      sfdp_rom[7'h0B] = 8'h10;
      sfdp_rom[7'h0C] = 8'h30;
      sfdp_rom[7'h0D] = 8'h00;
      sfdp_rom[7'h0E] = 8'h00;
      sfdp_rom[7'h0F] = 8'hFF;
   
      sfdp_rom[7'h30] = 8'hFD;
      sfdp_rom[7'h31] = 8'h20;
      sfdp_rom[7'h32] = 8'hC0;
      sfdp_rom[7'h33] = 8'hFF;
   
      sfdp_rom[7'h34] = 8'hFF;
      sfdp_rom[7'h35] = 8'hFF;
      sfdp_rom[7'h36] = 8'h7F;
      sfdp_rom[7'h37] = 8'h00;
   
      sfdp_rom[7'h50] = 8'h0C;
      sfdp_rom[7'h51] = 8'h20;
      sfdp_rom[7'h52] = 8'h10;
      sfdp_rom[7'h53] = 8'hD8;
   
      sfdp_rom[7'h6A] = 8'h8F;
   end
   wire [7:0] sfdp_rd = sfdp_rom[sfdp_idx];
   reg [3:0] quad_next_nibble;
   reg [7:0] quad_data_byte;
   reg       quad_data_drive_r;
   reg       quad_hi_next;
   reg       quad_active;
   reg [3:0] quad_diag_idx;
   wire [3:0] quad_diag6d_nibble =
      quad_diag_idx[0] ? (4'h6 + {1'b0, quad_diag_idx[3:1]}) : 4'h0;
   initial begin
      quad_next_nibble   = 0;
      quad_data_byte     = 0;
      quad_data_drive_r  = 0;
      quad_hi_next        = 0;
      quad_active         = 0;
      quad_diag_idx       = 0;
   end
   
   function automatic [3:0] quad_onehot(input [1:0] idx);
      case (idx)
         2'd0: quad_onehot = 4'h1;
         2'd1: quad_onehot = 4'h2;
         2'd2: quad_onehot = 4'h4;
         default: quad_onehot = 4'h8;
      endcase
   endfunction
   wire       quad_data     = quad_active;
   wire       quad_start    = byte_done && phase_cnt == 3'd4
                           && (opcode == 8'h6B || opcode == 8'h6C
                            || opcode == 8'h6D || opcode == 8'h6E
                            || opcode == 8'h6F);
   wire [7:0] quad_data_byte_seed = data_byte;
   wire [7:0] quad_data_byte_inc = quad_data_byte + 8'd1;
   wire [7:0] quad_hold_byte_inc = (quad_data_byte == 8'hFF)
                                 ? 8'h00 : (quad_data_byte + 8'h11);
   wire [3:0] io_pad_src = {
      quad_next_nibble[3],
      quad_next_nibble[2],
      quad_data_drive ? quad_next_nibble[1] : shift_out[7],
      quad_next_nibble[0]
   };
   reg [3:0] io_pad_out;
   initial begin
      io_pad_out = 0;
   end
   always @(negedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) begin
         io_pad_out <= 0;
      end else begin
         io_pad_out <= io_pad_src;
      end
   end
   wire resp_window = (!cs_n)
                   && ( ((opcode == 8'h9F) && (phase_cnt >= 3'd1) && (phase_cnt <= 3'd3))
                     || ((opcode == 8'h05) && (phase_cnt == 3'd1))
                     || ((opcode == 8'h03) && (phase_cnt >= 3'd4))
                     || ((opcode == 8'h0B) && (phase_cnt >= 3'd5))
                     || ((opcode == 8'h5A) && (phase_cnt >= 3'd5)) );
   wire quad_data_drive = (!cs_n) && quad_data_drive_r;
   wire [3:0] io_pad_selected = io_pad_out;
   wire io_oe_0    = quad_data_drive;
   wire io_oe_1    = quad_data_drive | resp_window;
   wire io_oe_2    = quad_data_drive;
   wire io_oe_3    = quad_data_drive;
   wire io_d_out_0 = io_pad_selected[0];
   wire io_d_out_1 = io_pad_selected[1];
   wire io_d_out_2 = io_pad_selected[2];
   wire io_d_out_3 = io_pad_selected[3];
   wire io_d_in_0;
   wire io_d_in_1;
   wire io_d_in_2;
   wire io_d_in_3;
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io0_iob (
      .PACKAGE_PIN(io[0]),
      .OUTPUT_ENABLE(io_oe_0),
      .D_OUT_0(io_d_out_0),
      .D_IN_0(io_d_in_0)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io1_iob (
      .PACKAGE_PIN(io[1]),
      .OUTPUT_ENABLE(io_oe_1),
      .D_OUT_0(io_d_out_1),
      .D_IN_0(io_d_in_1)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io2_iob (
      .PACKAGE_PIN(io[2]),
      .OUTPUT_ENABLE(io_oe_2),
      .D_OUT_0(io_d_out_2),
      .D_IN_0(io_d_in_2)
   );
   SB_IO #(
      .PIN_TYPE(6'b101001)
   ) io3_iob (
      .PACKAGE_PIN(io[3]),
      .OUTPUT_ENABLE(io_oe_3),
      .D_OUT_0(io_d_out_3),
      .D_IN_0(io_d_in_3)
   );
   wire [3:0] io_oe   = {io_oe_3, io_oe_2, io_oe_1, io_oe_0};
   wire [3:0] io_d_in = {io_d_in_3, io_d_in_2, io_d_in_1, io_d_in_0};
   reg [31:0] crc_reg;
   initial crc_reg = 32'hFFFFFFFF;
   
   function automatic [31:0] crc32_step(input [31:0] c, input bit_in);
      crc32_step = {1'b0, c[31:1]}
                 ^ ((c[0] ^ bit_in) ? 32'hEDB88320 : 32'h00000000);
   endfunction
   
   function automatic [31:0] crc32_byte(input [31:0] c, input [7:0] b);
      crc32_byte = crc32_step(crc32_step(crc32_step(crc32_step(
                     crc32_step(crc32_step(crc32_step(crc32_step(
                        c, b[0]), b[1]), b[2]), b[3]),
                                 b[4]), b[5]), b[6]), b[7]);
   endfunction
   wire master_driven_byte =
        (phase_cnt == 3'd0)                               ? 1'b1 :
        (opcode == 8'h9F || opcode == 8'h05)              ? 1'b0 :
        (opcode == 8'h03)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h0B)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h5A)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6B)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6C)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6D)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6E)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h6F)                                 ? (phase_cnt <= 3'd3) :
        (opcode == 8'h32)                                 ? (phase_cnt <= 3'd3) :
                                                            1'b1;
   wire quad_in_byte_done = quad_in_phase && (qin_phase == 1'b1);
   always @(posedge sclk or posedge cs_async_rst) begin
      if (cs_async_rst) begin
         crc_reg <= 32'hFFFFFFFF;
      end else if ((bit_cnt == 3'd7) && master_driven_byte) begin
         crc_reg <= crc32_byte(crc_reg, {shift_in[6:0], io_d_in[0]});
      end else if (quad_in_byte_done) begin
         crc_reg <= crc32_byte(crc_reg, {nibble_buf, io_d_in});
      end
   end
   reg wel;
   initial begin
      wel = 0;
   end
   /* verilator lint_off SYNCASYNCNET */
   reg [1:0] cs_sync;
   initial cs_sync = 2'b11;
   always @(posedge clk) cs_sync <= {cs_sync[0], cs_n};
   wire cs_s     = cs_sync[1];
   reg  cs_s_d;
   initial cs_s_d = 1'b1;
   always @(posedge clk) cs_s_d <= cs_s;
   wire cs_rise_pulse = !cs_s_d && cs_s;
   
   reg cs_async_rst;
   initial cs_async_rst = 1'b1;
   always @(posedge clk or negedge cs_n) begin
      if (!cs_n)
         cs_async_rst <= 1'b0;
      else
         cs_async_rst <= cs_s_d;
   end
   /* verilator lint_on SYNCASYNCNET */
   always @(posedge clk) begin
      if (frame_done) begin
         if (snap_op == 8'h06 && snap_byte_cnt == 8'd1)
            wel <= 1'b1;
         else if (snap_op == 8'h04 && snap_byte_cnt == 8'd1)
            wel <= 1'b0;
         else if (snap_op == 8'h02 || snap_op == 8'h32)
            wel <= 1'b0;
      end
   end
   wire [15:0] frame_cnt_pre_full = (opcode == 8'h32)
                                  ? (16'd4 + {4'd0, quad_in_cnt[11:0]})
                                  : byte_cnt;
   wire [7:0]  frame_cnt_pre        = frame_cnt_pre_full[7:0];
   wire [7:0]  unused_frame_cnt_hi  = frame_cnt_pre_full[15:8];
   reg [7:0]  frame_op;
   reg [7:0]  frame_cnt;
   reg [31:0] frame_crc_raw;
   initial begin
      frame_op       = 0;
      frame_cnt      = 0;
      frame_crc_raw  = 32'hFFFFFFFF;
   end
   
   always @(posedge clk) begin
      if (cs_rise_pulse) begin
         frame_op      <= opcode;
         frame_cnt     <= frame_cnt_pre[7:0];
         frame_crc_raw <= crc_reg;
      end
   end
   wire [31:0] frame_crc = frame_crc_raw ^ 32'hFFFFFFFF;
   reg         frame_done;
   initial frame_done = 0;
   always @(posedge clk) frame_done <= cs_rise_pulse;
   wire [7:0]  snap_op       = frame_op;
   wire [7:0]  snap_byte_cnt = frame_cnt;
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
   wire [3:0] d1, d0;
   wire [3:0] unused_d1_hi, unused_d0_hi;
   assign {unused_d1_hi, d1} = p_cnt / 8'd10;
   assign {unused_d0_hi, d0} = p_cnt % 8'd10;
   always @(posedge clk) begin
      tx_start <= 1'b0;
      case (pstate)
         P_IDLE: if (frame_done) begin
                    p_op   <= frame_op;
                    p_cnt  <= frame_cnt;
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
