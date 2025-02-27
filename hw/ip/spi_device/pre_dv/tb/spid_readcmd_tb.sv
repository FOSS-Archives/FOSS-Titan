// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Testbench module for spid_readcmd
//  - SFDP
//  - Read commands
//  - Mailbox

module tb;
  import spi_device_pkg::*;

  import spid_common::*;

  // clock generation
  localparam time ClkPeriod = 10000; // 10ns
  localparam time SckPeriod = 14000; // 14ns

  wire clk, rst_n;
  clk_rst_if main_clk (
    .clk,
    .rst_n
  );
  logic sw_clk;
  assign sw_clk = clk;

  wire sck, sck_rst_n;
  clk_rst_if sck_clk (
    .clk   (sck),
    .rst_n (sck_rst_n)
  );

  spi_if sif(sck);

  virtual spi_if.tb  tb_sif  = sif.tb;
  virtual spi_if.dut dut_sif = sif.dut;

  logic [3:0] dut_sd_en, dut_sd;
  logic [3:0] tb_sd_en,  tb_sd;

  for (genvar i = 0 ; i < 4 ; i++) begin : g_dut_sif
    assign sif.sd_out[i] = dut_sd_en[i] ? dut_sd[i] : 1'b Z;
  end

  wire sck_en, gated_sck, gated_sck_inverted;

  assign gated_sck          = (sck_en) ? sck : 1'b 0;
  assign gated_sck_inverted = ~gated_sck;

  assign sck_en = ~sif.csb;

  logic rst_spi_n;
  assign rst_spi_n = sck_rst_n && ~sif.csb;

  sel_datapath_e dut_sel_dp;

  logic [CmdInfoIdxW-1:0] cmd_info_idx;
  cmd_info_t cmd_info;

  spi_mode_e spi_mode;

  logic               s2p_valid;
  logic [7:0]         s2p_data;
  logic [BitCntW-1:0] s2p_bitcnt;

  logic               p2s_valid;
  logic [7:0]         p2s_data;
  logic               p2s_sent;

  // Memory interface
  logic              bus_mem_req;
  logic              bus_mem_write;
  logic [SramAw-1:0] bus_mem_addr;
  logic [SramDw-1:0] bus_mem_wdata;
  logic [SramDw-1:0] bus_mem_wmask;
  logic              bus_mem_rvalid;
  logic [SramDw-1:0] bus_mem_rdata;
  logic [1:0]        bus_mem_rerror;

  logic              spi_mem_req;
  logic              spi_mem_write;
  logic [SramAw-1:0] spi_mem_addr;
  logic [SramDw-1:0] spi_mem_wdata;
  logic [SramDw-1:0] spi_mem_wmask;
  logic              spi_mem_rvalid;
  logic [SramDw-1:0] spi_mem_rdata;
  logic [1:0]        spi_mem_rerror;

  spi_device_pkg::sram_l2m_t sck_l2m;
  spi_device_pkg::sram_m2l_t sck_m2l;

  // Connection sck <-> spi_mem
  assign spi_mem_req   = sck_l2m.req;
  assign spi_mem_write = sck_l2m.we;
  assign spi_mem_addr  = sck_l2m.addr;
  assign spi_mem_wdata = sck_l2m.wdata;
  assign spi_mem_wmask = spi_device_pkg::sram_strb2mask(sck_l2m.wstrb);

  assign sck_m2l = '{
    rvalid: spi_mem_rvalid,
    rdata:  spi_mem_rdata,
    rerror: spi_mem_rerror
  };

  spi_device_pkg::sram_l2m_t sw_l2m;
  spi_device_pkg::sram_m2l_t sw_m2l;

  assign bus_mem_req   = sw_l2m.req;
  assign bus_mem_write = sw_l2m.we;
  assign bus_mem_addr  = sw_l2m.addr;
  assign bus_mem_wdata = sw_l2m.wdata;
  assign bus_mem_wmask = spi_device_pkg::sram_strb2mask(sw_l2m.wstrb);

  assign sw_m2l = '{
    rvalid: bus_mem_rvalid,
    rdata:  bus_mem_rdata,
    rerror: bus_mem_rerror
  };

  // Control & Configuration signals
  logic        cfg_addr_4b_en;
  logic        cfg_mailbox_en;
  logic        cfg_intercept_en_mbx;
  logic [31:0] cfg_mailbox_addr; // Assume the size of mailbox 1kB
  logic [7:0]  cfg_readbuf_threshold;

  logic mailbox_assumed;
  logic [31:0] readbuf_address;

  logic event_read_watermark;
  logic event_read_flip;

  io_mode_e dut_iomode, s2p_iomode;

  ///////////////////
  // Test Sequence //
  ///////////////////
  event init_done; // SW to host
  initial begin
    sck_clk.set_period_ps(SckPeriod);
    sck_clk.set_active();

    main_clk.set_period_ps(ClkPeriod);
    main_clk.set_active();

    sif.csb = 1'b 1;

    // Driving default inactive values on the interface
    sw_l2m.req = 1'b 0;

    cfg_addr_4b_en        = 1'b 0;
    cfg_mailbox_en        = 1'b 0;
    cfg_mailbox_addr      = '0;
    cfg_readbuf_threshold = 8'h 80;

    spi_mode = FlashMode;

    sck_clk.apply_reset();
    main_clk.apply_reset();

    fork
      begin
        #20us
        $display("TEST TIMED OUT!!");
      end
      host();
      sw();
    join_any

    $finish();
  end

  static task host();
    automatic spi_data_t sfdp_data [$];
    bit test_passed;
    test_passed = 1'b 1;

    wait(init_done.triggered);
    // SW initializatio completed. Issues sequences

    // Issue SFDP: 4 byte read @ 0x80
    $display("Sending a SFDP command");
    spiflash_readsfdp(tb_sif, 8'h 5A, 24'h 00_0080, 4, sfdp_data);

    // Complete the simulation
    if (test_passed) begin
      $display("TEST PASSED CHECKS");
    end else begin
      // Add error log
    end
  endtask : host

  static task sw();
    automatic logic sw_gnt; // sram grant signal. always 1 in this test
    // Driving default

    // Initialize the DPSRAM
    sw_gnt = 1'b 1;
    for (int i = 0 ; i < SramDepth ; i++) begin
      sram_writeword(sw_clk, sw_l2m, sw_gnt, sw_m2l, SramAw'(i), $urandom());
    end

    // Configure

    #100ns ->init_done;

    forever begin
      @(posedge clk);
    end
  endtask : sw

  /////////
  // DUT //
  /////////
  spi_readcmd dut (
    .clk_i      (gated_sck),
    .rst_ni     (rst_spi_n),
    .clk_out_i  (gated_sck_inverted),
    .sys_rst_ni (rst_n),

    .sel_dp_i (dut_sel_dp),

    .sram_l2m_o (sck_l2m),
    .sram_m2l_i (sck_m2l),

    .s2p_valid_i  (s2p_valid),
    .s2p_byte_i   (s2p_data),
    .s2p_bitcnt_i (s2p_bitcnt),

    .p2s_valid_o (p2s_valid),
    .p2s_byte_o  (p2s_data),
    .p2s_sent_i  (p2s_sent),

    .spi_mode_i  (spi_mode),

    .cmd_info_i     (cmd_info),
    .cmd_info_idx_i (cmd_info_idx),

    .readbuf_threshold_i (cfg_readbuf_threshold),

    .addr_4b_en_i (cfg_addr_4b_en),

    .mailbox_en_i           (cfg_mailbox_en),
    .cfg_intercept_en_mbx_i (cfg_intercept_en_mbx),
    .mailbox_addr_i         (cfg_mailbox_addr),

    .mailbox_assumed_o (mailbox_assumed),

    .readbuf_address_o (readbuf_address),

    .io_mode_o (dut_iomode),  // SCK or iSCK ?

    .sck_read_watermark_o (event_read_watermark),
    .sck_read_flip_o      (event_read_flip)
  );


  ///////////////
  // Instances //
  ///////////////
  spi_cmdparse cmdparse (
    .clk_i  (gated_sck),
    .rst_ni (rst_spi_n),

    .data_valid_i (s2p_valid),
    .data_i       (s2p_data ),

    .spi_mode_i   (spi_mode),

    .cmd_info_i   (spid_common::CmdInfo),

    .io_mode_o    (s2p_iomode),

    .sel_dp_o       (dut_sel_dp),
    .cmd_info_o     (cmd_info),
    .cmd_info_idx_o (cmd_info_idx),

    .cmd_config_req_o (),
    .cmd_config_idx_o ()
  );

  spi_s2p s2p (
    .clk_i  (gated_sck),
    .rst_ni (rst_spi_n),

    .s_i    (sif.sd_in),

    .data_valid_o (s2p_valid),
    .data_o       (s2p_data),
    .bitcnt_o     (s2p_bitcnt),

    .order_i      (1'b 0),
    .io_mode_i    (s2p_iomode)
  );

  spi_p2s p2s (
    .clk_i  (gated_sck_inverted),
    .rst_ni (rst_spi_n),

    .data_valid_i (p2s_valid),
    .data_i       (p2s_data),
    .data_sent_o  (p2s_sent),

    .csb_i        (sif.csb),
    .s_en_o       (dut_sd_en),
    .s_o          (dut_sd),

    .cpha_i       (1'b 0),

    .order_i      (1'b 0),

    .io_mode_i    (dut_iomode)
  );

  // Memory (DPSRAM)
  prim_ram_2p_async_adv #(
    .Depth (1024),      // 4kB
    .Width (SramDw),    // 32
    .DataBitsPerMask (8),

    .EnableECC           (0),
    .EnableParity        (1),
    .EnableInputPipeline (0),
    .EnableOutputPipeline(0)
  ) u_memory_2p (
    .clk_a_i    (clk),
    .rst_a_ni   (rst_n),

    .clk_b_i    (gated_sck),
    .rst_b_ni   (rst_n),

    .a_req_i    (bus_mem_req),
    .a_write_i  (bus_mem_write),
    .a_addr_i   (bus_mem_addr),
    .a_wdata_i  (bus_mem_wdata),
    .a_wmask_i  (bus_mem_wmask),
    .a_rvalid_o (bus_mem_rvalid),
    .a_rdata_o  (bus_mem_rdata),
    .a_rerror_o (bus_mem_rerror),

    .b_req_i    (spi_mem_req),
    .b_write_i  (spi_mem_write),
    .b_addr_i   (spi_mem_addr),
    .b_wdata_i  (spi_mem_wdata),
    .b_wmask_i  (spi_mem_wmask),
    .b_rvalid_o (spi_mem_rvalid),
    .b_rdata_o  (spi_mem_rdata),
    .b_rerror_o (spi_mem_rerror),

    .cfg_i      ('0)
  );



endmodule : tb
