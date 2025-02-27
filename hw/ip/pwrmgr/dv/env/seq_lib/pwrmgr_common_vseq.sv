// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class pwrmgr_common_vseq extends pwrmgr_base_vseq;
  `uvm_object_utils(pwrmgr_common_vseq)

  constraint num_trans_c {num_trans inside {[1 : 2]};}
  `uvm_object_new

  virtual task body();
    run_common_vseq_wrapper(num_trans);
  endtask : body

  // pwrmgr has only two alert events
  // REG_INTG_ERR and ESC_TIMEOUT
  // all others will trigger only reset.
  // So disable wait_alert by skipping super.check_sec_cm_fi_resp()
  virtual task check_sec_cm_fi_resp(sec_cm_base_if_proxy if_proxy);
    string slow_st_to, fast_st_to, msg;
    // to avoid 100 column cut off
    slow_st_to = {"slow state local esc chk timeout:",
                  "fast_state %s, pwr_ast_req.pwr_clamp %0d, pwr_ast_req.main_pd_n %0d"};
    fast_st_to = {"fast state local esc chk timeout:",
                  "pwr_rst_req.rst_lc_req %0d, pwr_rst_req.rst_sys_req %0d, pwr_clk_req %0d"};

    `uvm_info(`gfn, $sformatf("sec_cm_type %s", if_proxy.sec_cm_type.name), UVM_MEDIUM)

    case (if_proxy.sec_cm_type)
      SecCmPrimSparseFsmFlop: begin
        // if slow state is unknown,
        //   wait for
        //     fast_state == FastPwrStateInvalid
        //     tb.dut.pwr_ast_o.pwr_clamp == 1
        //     tb.dut.pwr_ast_o.main_pd_n == 0
        //
        // if fast state is unknown,
        //   wait for
        //     tb.dut.pwr_rst_o.rst_lc_req == 2'b11
        //     tb.dut.pwr_rst_o.rst_sys_req == 2'b11
        //     tb.dut.pwr_clk_o == 3'b0
        if (!uvm_re_match("*.u_slow_fsm.*", if_proxy.path)) begin
          `uvm_info(`gfn, "detect unknown slow state", UVM_MEDIUM)
          msg = $sformatf(slow_st_to,
                          cfg.pwrmgr_vif.fast_state.name,
                          cfg.pwrmgr_vif.pwr_ast_req.pwr_clamp,
                          cfg.pwrmgr_vif.pwr_ast_req.main_pd_n);

          `DV_SPINWAIT(wait(cfg.pwrmgr_vif.fast_state == pwrmgr_pkg::FastPwrStateInvalid &&
                            cfg.pwrmgr_vif.pwr_ast_req.pwr_clamp == 1 &&
                            cfg.pwrmgr_vif.pwr_ast_req.main_pd_n == 0);,
                       msg, 5000)
        end
        if (!uvm_re_match("*.u_fsm.*", if_proxy.path)) begin
          `uvm_info(`gfn, "detect unknown fast state", UVM_MEDIUM)
          msg = $sformatf(fast_st_to,
                          cfg.pwrmgr_vif.pwr_rst_req.rst_lc_req,
                          cfg.pwrmgr_vif.pwr_rst_req.rst_sys_req,
                          cfg.pwrmgr_vif.pwr_clk_req);

          `DV_SPINWAIT(wait(cfg.pwrmgr_vif.pwr_rst_req.rst_lc_req == 2'b11 &&
                            cfg.pwrmgr_vif.pwr_rst_req.rst_sys_req == 2'b11 &&
                            cfg.pwrmgr_vif.pwr_clk_req == 3'h0);,
                       msg, 5000)
        end
      end
      SecCmPrimCount: begin
        // wait for fast state to be FastPwrStateResetPrep
        // before assert reset
        `uvm_info(`gfn, "check rx_clk local esc", UVM_MEDIUM)
        msg = $sformatf("rx clk loc esc chk timeout : fast_state %s",
                        cfg.pwrmgr_vif.fast_state.name);
        `DV_SPINWAIT(wait(cfg.pwrmgr_vif.fast_state == pwrmgr_pkg::FastPwrStateResetPrep);,
                     msg, 5000)
      end
      default: `uvm_fatal(`gfn, $sformatf("unexpected sec_cm_type %s", if_proxy.sec_cm_type.name))
    endcase // case (if_proxy.sec_cm_type)
  endtask // check_sec_cm_fi_resp

  // this function is called in a loop. So 'asserton' should be called
  // to clear 'assertoff' in the previous loop
  virtual function void sec_cm_fi_ctrl_svas(sec_cm_base_if_proxy if_proxy, bit enable);
    if (enable) begin
      $asserton(0, "tb.dut.FpvSecCmSlowFsmCheck_A");
      $asserton(0, "tb.dut.FpvSecCmFsmCheck_A");
      return;
    end
    if (if_proxy.sec_cm_type == SecCmPrimSparseFsmFlop) begin
      $assertoff(0, "tb.dut.FpvSecCmSlowFsmCheck_A");
      $assertoff(0, "tb.dut.FpvSecCmFsmCheck_A");
    end
  endfunction
endclass
