// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class edn_scoreboard extends cip_base_scoreboard #(
    .CFG_T(edn_env_cfg),
    .RAL_T(edn_reg_block),
    .COV_T(edn_env_cov)
  );
  `uvm_component_utils(edn_scoreboard)

  virtual edn_cov_if   cov_vif;

  // TLM agent fifos
  uvm_tlm_analysis_fifo#(push_pull_item#(.HostDataWidth(csrng_pkg::CSRNG_CMD_WIDTH)))
      cs_cmd_fifo;
  uvm_tlm_analysis_fifo#(push_pull_item#(.HostDataWidth(csrng_pkg::FIPS_GENBITS_BUS_WIDTH)))
      genbits_fifo;
  uvm_tlm_analysis_fifo#(push_pull_item#(.HostDataWidth(FIPS_ENDPOINT_BUS_WIDTH)))
      endpoint_fifo[MAX_NUM_ENDPOINTS];

  // local queues to hold incoming packets pending comparison
  bit[FIPS_ENDPOINT_BUS_WIDTH - 1:0]   endpoint_data_q[$];

  `uvm_component_new

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    genbits_fifo = new("genbits_fifo", this);
    cs_cmd_fifo  = new("cs_cmd_fifo", this);

    for (int i = 0; i < cfg.num_endpoints; i++) begin
      endpoint_fifo[i] = new($sformatf("endpoint_fifo[%0d]", i), this);
    end

    if (!uvm_config_db#(virtual edn_cov_if)::get(null, "*.env" , "edn_cov_if", cov_vif)) begin
      `uvm_fatal(`gfn, $sformatf("Failed to get edn_cov_if from uvm_config_db"))
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);

    fork
      process_genbits_fifo();
    join_none

    for (int i = 0; i < cfg.num_endpoints; i++) begin
      automatic int j = i;
      fork
        begin
          process_endpoint_fifo(j);
        end
      join_none;
    end
  endtask

  virtual task process_tl_access(tl_seq_item item, tl_channels_e channel, string ral_name);
    uvm_reg csr;
    bit     do_read_check   = 1'b1;
    bit     write           = item.is_write();
    uvm_reg_addr_t csr_addr = cfg.ral_models[ral_name].get_word_aligned_addr(item.a_addr);

    bit addr_phase_read   = (!write && channel == AddrChannel);
    bit addr_phase_write  = (write && channel == AddrChannel);
    bit data_phase_read   = (!write && channel == DataChannel);
    bit data_phase_write  = (write && channel == DataChannel);

    // if access was to a valid csr, get the csr handle
    if (csr_addr inside {cfg.ral_models[ral_name].csr_addrs}) begin
      csr = cfg.ral_models[ral_name].default_map.get_reg_by_offset(csr_addr);
      `DV_CHECK_NE_FATAL(csr, null)
    end
    else begin
      `uvm_fatal(`gfn, $sformatf("Access unexpected addr 0x%0h", csr_addr))
    end

    // if incoming access is a write to a valid csr, then make updates right away
    if (addr_phase_write) begin
      void'(csr.predict(.value(item.a_data), .kind(UVM_PREDICT_WRITE), .be(item.a_mask)));
    end

    // process the csr req
    // for write, update local variable and fifo at address phase
    // for read, update predication at address phase and compare at data phase
    case (csr.get_name())
      // add individual case item for each csr
      "intr_state": begin
        // FIXME
        do_read_check = 1'b0;
      end
      "intr_enable": begin
        // FIXME
      end
      "intr_test": begin
        // FIXME
      end
      "ctrl": begin
      end
      "sw_cmd_req": begin
      end
      "sw_cmd_sts": begin
        do_read_check = 1'b0;
      end
      "boot_ins_cmd": begin
      end
      "boot_gen_cmd": begin
      end
      "sum_sts": begin
      end
      "generate_cmd": begin
      end
      "reseed_cmd": begin
      end
      "max_num_reqs_between_reseeds": begin
      end
      "recov_alert_sts": begin
      end
      default: begin
        `uvm_fatal(`gfn, $sformatf("invalid csr: %0s", csr.get_full_name()))
      end
    endcase

    // On reads, if do_read_check, is set, then check mirrored_value against item.d_data
    if (data_phase_read) begin
      if (do_read_check) begin
        `DV_CHECK_EQ(csr.get_mirrored_value(), item.d_data,
                     $sformatf("reg name: %0s", csr.get_full_name()))
      end
      void'(csr.predict(.value(item.d_data), .kind(UVM_PREDICT_READ)));
    end
  endtask

  task process_genbits_fifo();
    push_pull_item#(.HostDataWidth(csrng_pkg::FIPS_GENBITS_BUS_WIDTH))   genbits_item;
    bit[ENDPOINT_BUS_WIDTH - 1:0]   endpoint_data;
    bit                             fips;

    forever begin
      genbits_fifo.get(genbits_item);
      fips = genbits_item.h_data[csrng_pkg::GENBITS_BUS_WIDTH];
      for (int i = 0; i < csrng_pkg::GENBITS_BUS_WIDTH/ENDPOINT_BUS_WIDTH; i++) begin
        endpoint_data = genbits_item.h_data >> (i * ENDPOINT_BUS_WIDTH);
        endpoint_data_q.push_back({fips, endpoint_data});
      end
    end
  endtask

  task process_endpoint_fifo(uint endpoint);
    push_pull_item#(.HostDataWidth(FIPS_ENDPOINT_BUS_WIDTH))   endpoint_item;
    uint   index, q_size;
    bit    match;

    forever begin
      endpoint_fifo[endpoint].get(endpoint_item);
      index = 0;
      match = 0;
      q_size = endpoint_data_q.size();
      do begin
        if (endpoint_item.d_data == endpoint_data_q[index]) begin
          match = 1;
          endpoint_data_q.delete(index);
        end
        else if (index == q_size - 1) begin
          `uvm_fatal(`gfn, $sformatf("No match for endpoint_data: %h", endpoint_item.d_data))
        end
        else begin
          index++;
        end
      end
      while (!match);
    end
  endtask

  virtual function void reset(string kind = "HARD");
    super.reset(kind);
    // reset local fifos queues and variables
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);

    if (endpoint_data_q.size()) begin
      `uvm_fatal(`gfn, $sformatf("endpoint_data_q.size = %0d at EOT", endpoint_data_q.size()))
    end
    // TODO: post test checks - ensure that all local fifos and queues are empty
  endfunction

endclass
