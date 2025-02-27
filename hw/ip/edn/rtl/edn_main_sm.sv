// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: edn csrng application request state machine module
//
//   does hardware-based csrng app interface command requests

module edn_main_sm #(
  localparam int StateWidth = 9
) (
  input logic                   clk_i,
  input logic                   rst_ni,

  input logic                   edn_enable_i,
  input logic                   boot_req_mode_i,
  input logic                   auto_req_mode_i,
  input logic                   sw_cmd_req_load_i,
  output logic                  boot_wr_cmd_reg_o,
  output logic                  boot_wr_cmd_genfifo_o,
  output logic                  auto_set_intr_gate_o,
  output logic                  auto_clr_intr_gate_o,
  output logic                  auto_first_ack_wait_o,
  output logic                  main_sm_done_pulse_o,
  input logic                   csrng_cmd_ack_i,
  output logic                  capt_gencmd_fifo_cnt_o,
  output logic                  boot_send_gencmd_o,
  output logic                  send_gencmd_o,
  input logic                   max_reqs_cnt_zero_i,
  output logic                  capt_rescmd_fifo_cnt_o,
  output logic                  send_rescmd_o,
  input logic                   cmd_sent_i,
  input logic                   local_escalate_i,
  output logic                  auto_req_mode_busy_o,
  output logic                  main_sm_busy_o,
  output logic [StateWidth-1:0] main_sm_state_o,
  output logic                  main_sm_err_o
);
//
// Hamming distance histogram:
//
//  0: --
//  1: --
//  2: --
//  3: ||||||||||| (17.54%)
//  4: |||||||||||||||||||| (29.82%)
//  5: ||||||||||||||||| (26.32%)
//  6: ||||||||||| (17.54%)
//  7: ||||| (7.60%)
//  8:  (1.17%)
//  9: --
//
// Minimum Hamming distance: 3
// Maximum Hamming distance: 8
// Minimum Hamming weight: 2
// Maximum Hamming weight: 7
//

  typedef enum logic [StateWidth-1:0] {
    Idle              = 9'b110000101, // idle
    BootLoadIns       = 9'b110110111, // boot: load the instantiate command
    BootLoadGen       = 9'b000000011, // boot: load the generate command
    BootInsAckWait    = 9'b011010010, // boot: wait for instantiate command ack
    BootCaptGenCnt    = 9'b010111010, // boot: capture the gen fifo count
    BootSendGenCmd    = 9'b011100100, // boot: send the generate command
    BootGenAckWait    = 9'b101101100, // boot: wait for generate command ack
    BootPulse         = 9'b100001010, // boot: signal a done pulse
    BootDone          = 9'b011011111, // boot: stay in done state until reset
    AutoLoadIns       = 9'b001110000, // auto: load the instantiate command
    AutoFirstAckWait  = 9'b001001101, // auto: wait for first instantiate command ack
    AutoAckWait       = 9'b101100011, // auto: wait for instantiate command ack
    AutoDispatch      = 9'b110101110, // auto: determine next command to be sent
    AutoCaptGenCnt    = 9'b000110101, // auto: capture the gen fifo count
    AutoSendGenCmd    = 9'b111111000, // auto: send the generate command
    AutoCaptReseedCnt = 9'b000100110, // auto: capture the reseed fifo count
    AutoSendReseedCmd = 9'b101010110, // auto: send the reseed command
    SWPortMode        = 9'b100111001, // swport: no hw request mode
    Error             = 9'b010010001  // illegal state reached and hang
  } state_e;

  state_e state_d, state_q;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Idle)

  assign main_sm_state_o = state_q;

  assign main_sm_busy_o = (state_q != Idle) && (state_q != BootPulse) &&
         (state_q != BootDone) && (state_q != SWPortMode);

  always_comb begin
    state_d = state_q;
    boot_wr_cmd_reg_o = 1'b0;
    boot_wr_cmd_genfifo_o = 1'b0;
    boot_send_gencmd_o = 1'b0;
    auto_set_intr_gate_o = 1'b0;
    auto_clr_intr_gate_o = 1'b0;
    auto_first_ack_wait_o = 1'b0;
    auto_req_mode_busy_o = 1'b0;
    capt_gencmd_fifo_cnt_o = 1'b0;
    send_gencmd_o = 1'b0;
    capt_rescmd_fifo_cnt_o = 1'b0;
    send_rescmd_o = 1'b0;
    main_sm_done_pulse_o = 1'b0;
    main_sm_err_o = 1'b0;
    unique case (state_q)
      Idle: begin
        if (boot_req_mode_i && edn_enable_i) begin
          state_d = BootLoadIns;
        end else if (auto_req_mode_i && edn_enable_i) begin
          state_d = AutoLoadIns;
        end else if (edn_enable_i) begin
          main_sm_done_pulse_o = 1'b1;
          state_d = SWPortMode;
        end
      end
      BootLoadIns: begin
        boot_wr_cmd_reg_o = 1'b1;
        state_d = BootLoadGen;
      end
      BootLoadGen: begin
        boot_wr_cmd_genfifo_o = 1'b1;
        state_d = BootInsAckWait;
      end
      BootInsAckWait: begin
        if (csrng_cmd_ack_i) begin
          state_d = BootCaptGenCnt;
        end
      end
      BootCaptGenCnt: begin
        capt_gencmd_fifo_cnt_o = 1'b1;
        state_d = BootSendGenCmd;
      end
      BootSendGenCmd: begin
        boot_send_gencmd_o = 1'b1;
        if (cmd_sent_i) begin
          state_d = BootGenAckWait;
        end
      end
      BootGenAckWait: begin
        if (csrng_cmd_ack_i) begin
          state_d = BootPulse;
        end
      end
      BootPulse: begin
        main_sm_done_pulse_o = 1'b1;
        state_d = BootDone;
      end
      BootDone: begin
        if (!edn_enable_i) begin
          state_d = Idle;
        end
      end
      //-----------------------------------
      AutoLoadIns: begin
        auto_set_intr_gate_o = 1'b1;
        auto_first_ack_wait_o = 1'b1;
        if (sw_cmd_req_load_i) begin
          state_d = AutoFirstAckWait;
        end
      end
      AutoFirstAckWait: begin
        auto_first_ack_wait_o = 1'b1;
        if (csrng_cmd_ack_i) begin
          auto_clr_intr_gate_o = 1'b1;
          state_d = AutoDispatch;
        end
      end
      AutoAckWait: begin
        auto_req_mode_busy_o = 1'b1;
        if (csrng_cmd_ack_i) begin
          state_d = AutoDispatch;
        end
      end
      AutoDispatch: begin
        auto_req_mode_busy_o = 1'b1;
        if (!auto_req_mode_i) begin
          main_sm_done_pulse_o = 1'b1;
          state_d = Idle;
        end else begin
          if (max_reqs_cnt_zero_i) begin
            state_d = AutoCaptReseedCnt;
          end else begin
            state_d = AutoCaptGenCnt;
          end
        end
      end
      AutoCaptGenCnt: begin
        auto_req_mode_busy_o = 1'b1;
        capt_gencmd_fifo_cnt_o = 1'b1;
        state_d = AutoSendGenCmd;
      end
      AutoSendGenCmd: begin
        auto_req_mode_busy_o = 1'b1;
        send_gencmd_o = 1'b1;
        if (cmd_sent_i) begin
          state_d = AutoAckWait;
        end
      end
      AutoCaptReseedCnt: begin
        auto_req_mode_busy_o = 1'b1;
        capt_rescmd_fifo_cnt_o = 1'b1;
        state_d = AutoSendReseedCmd;
      end
      AutoSendReseedCmd: begin
        auto_req_mode_busy_o = 1'b1;
        send_rescmd_o = 1'b1;
        if (cmd_sent_i) begin
          state_d = AutoAckWait;
        end
      end
      SWPortMode: begin
        if (!edn_enable_i) begin
          state_d = Idle;
        end
      end
      Error: begin
        main_sm_err_o = 1'b1;
      end
      default: state_d = Error;
    endcase
    if (local_escalate_i) begin
      state_d = Error;
    end
  end

endmodule
