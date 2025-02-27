// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/dif/dif_base.h"
#include "sw/device/lib/dif/dif_clkmgr.h"
#include "sw/device/lib/dif/dif_otbn.h"
#include "sw/device/lib/irq.h"
#include "sw/device/lib/runtime/ibex.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/runtime/otbn.h"
#include "sw/device/lib/testing/check.h"
#include "sw/device/lib/testing/clkmgr_testutils.h"
#include "sw/device/lib/testing/entropy_testutils.h"
#include "sw/device/lib/testing/rv_plic_testutils.h"
#include "sw/device/lib/testing/test_framework/ottf.h"

#include "hw/top_earlgrey/sw/autogen/top_earlgrey.h"

OTBN_DECLARE_APP_SYMBOLS(randomness);
OTBN_DECLARE_SYMBOL_ADDR(randomness, rv);
OTBN_DECLARE_SYMBOL_ADDR(randomness, fail_idx);
OTBN_DECLARE_SYMBOL_ADDR(randomness, rnd_out);
OTBN_DECLARE_SYMBOL_ADDR(randomness, urnd_out);

static const otbn_app_t kOtbnAppCfiTest = OTBN_APP_T_INIT(randomness);
static const otbn_addr_t kVarRv = OTBN_ADDR_T_INIT(randomness, rv);
static const otbn_addr_t kVarFailIdx = OTBN_ADDR_T_INIT(randomness, fail_idx);
static const otbn_addr_t kVarRndOut = OTBN_ADDR_T_INIT(randomness, rnd_out);
static const otbn_addr_t kVarUrndOut = OTBN_ADDR_T_INIT(randomness, urnd_out);

const test_config_t kTestConfig;

static dif_clkmgr_t clkmgr;
static const dif_clkmgr_hintable_clock_t kOtbnClock =
    kTopEarlgreyHintableClocksMainOtbn;

static dif_rv_plic_t plic;
static otbn_t otbn_ctx;
/**
 * These variables are used for ISR communication hence they are volatile.
 */
static volatile top_earlgrey_plic_peripheral_t plic_peripheral;
static volatile dif_rv_plic_irq_id_t irq_id;
static volatile dif_otbn_irq_t irq;

/**
 * Provides external IRQ handling for otbn tests.
 *
 * This function overrides the default OTTF external ISR.
 *
 * It performs the following:
 * 1. Claims the IRQ fired (finds PLIC IRQ index).
 * 2. Compute the OTBN peripheral.
 * 3. Compute the otbn irq.
 * 4. Clears the IRQ at the peripheral.
 * 5. Completes the IRQ service at PLIC.
 */
void ottf_external_isr(void) {
  CHECK_DIF_OK(dif_rv_plic_irq_claim(&plic, kTopEarlgreyPlicTargetIbex0,
                                     (dif_rv_plic_irq_id_t *)&irq_id));

  plic_peripheral = (top_earlgrey_plic_peripheral_t)
      top_earlgrey_plic_interrupt_for_peripheral[irq_id];

  irq = (dif_otbn_irq_t)(irq_id -
                         (dif_rv_plic_irq_id_t)kTopEarlgreyPlicIrqIdOtbnDone);

  // Otbn clock is disabled, so we can not acknowledge the irq. Disabling it to
  // avoid an infinite loop here.
  irq_global_ctrl(false);
  irq_external_ctrl(false);

  // Complete the IRQ by writing the IRQ source to the Ibex register.
  CHECK_DIF_OK(
      dif_rv_plic_irq_complete(&plic, kTopEarlgreyPlicTargetIbex0, irq_id));
}

static void otbn_wait_for_done_irq(otbn_t *otbn_ctx) {
  // Clear the otbn irq variable: we'll set it in the interrupt handler when
  // we see the Done interrupt fire.
  irq = UINT32_MAX;
  irq_id = UINT32_MAX;
  plic_peripheral = UINT32_MAX;
  CHECK_DIF_OK(dif_otbn_irq_set_enabled(&otbn_ctx->dif, kDifOtbnIrqDone,
                                        kDifToggleEnabled));

  // OTBN should be running. Wait for an interrupt that says
  // it's done.
  while (true) {
    // This looks a bit odd, but is needed to avoid a race condition where the
    // OTBN interrupt comes in after we load the otbn_finished flag but before
    // we run the WFI instruction. The trick is that WFI returns when an
    // interrupt comes in even if interrupts are globally disabled, which means
    // that the WFI can actually sit *inside* the critical section.
    irq_global_ctrl(false);
    if (plic_peripheral != UINT32_MAX) {
      break;
    }

    wait_for_interrupt();
    irq_global_ctrl(true);
  }

  CHECK(plic_peripheral == kTopEarlgreyPlicPeripheralOtbn,
        "Interrupt from incorrect peripheral: (exp: %d, obs: %s)",
        kTopEarlgreyPlicPeripheralOtbn, plic_peripheral);

  // Check this is the interrupt we expected.
  CHECK(irq_id == kTopEarlgreyPlicIrqIdOtbnDone);
}

static void otbn_init_irq(void) {
  mmio_region_t plic_base_addr =
      mmio_region_from_addr(TOP_EARLGREY_RV_PLIC_BASE_ADDR);
  CHECK_DIF_OK(dif_rv_plic_init(plic_base_addr, &plic));

  // Set interrupt priority to be positive.
  dif_rv_plic_irq_id_t irq_id = kTopEarlgreyPlicIrqIdOtbnDone;
  CHECK_DIF_OK(dif_rv_plic_irq_set_priority(&plic, irq_id, 0x1));

  CHECK_DIF_OK(dif_rv_plic_irq_set_enabled(
      &plic, irq_id, kTopEarlgreyPlicTargetIbex0, kDifToggleEnabled));

  CHECK_DIF_OK(dif_rv_plic_target_set_threshold(
      &plic, kTopEarlgreyPlicTargetIbex0, 0x0));

  irq_global_ctrl(true);
  irq_external_ctrl(true);
}

/**
 * LOG_INFO with a 256b unsigned integer as hexadecimal number with a prefix.
 */
static void print_uint256(otbn_t *ctx, const otbn_addr_t var,
                          const char *prefix) {
  uint32_t data[32 / sizeof(uint32_t)];
  CHECK(otbn_copy_data_from_otbn(ctx, /*len_bytes=*/32, var, &data) == kOtbnOk);
  LOG_INFO("%s0x%08x%08x%08x%08x%08x%08x%08x%08x", prefix, data[7], data[6],
           data[5], data[4], data[3], data[2], data[1], data[0]);
}

void initialize_clkmgr(void) {
  mmio_region_t addr = mmio_region_from_addr(TOP_EARLGREY_CLKMGR_AON_BASE_ADDR);
  CHECK_DIF_OK(dif_clkmgr_init(addr, &clkmgr));

  // Get initial hint and enable for OTBN clock and check both are enabled.
  dif_toggle_t clock_hint_state;
  CHECK_DIF_OK(dif_clkmgr_hintable_clock_get_hint(&clkmgr, kOtbnClock,
                                                  &clock_hint_state));
  CHECK(clock_hint_state == kDifToggleEnabled);
  CLKMGR_TESTUTILS_CHECK_CLOCK_HINT(clkmgr, kOtbnClock, kDifToggleEnabled);
}

bool test_main() {
  entropy_testutils_boot_mode_init();

  initialize_clkmgr();

  mmio_region_t addr = mmio_region_from_addr(TOP_EARLGREY_OTBN_BASE_ADDR);
  CHECK(otbn_init(&otbn_ctx, addr) == kOtbnOk);

  otbn_init_irq();

  // Write the OTBN clk hint to 0 within clkmgr to indicate OTBN clk can be
  // gated and verify that the OTBN clk hint status within clkmgr reads 0 (OTBN
  // is idle).
  CLKMGR_TESTUTILS_SET_AND_CHECK_CLOCK_HINT(
      clkmgr, kOtbnClock, kDifToggleDisabled, kDifToggleDisabled);

  // Write the OTBN clk hint to 1 within clkmgr to indicate OTBN clk can be
  // enabled.
  CLKMGR_TESTUTILS_SET_AND_CHECK_CLOCK_HINT(
      clkmgr, kOtbnClock, kDifToggleEnabled, kDifToggleEnabled);

  // Start an OTBN operation, write the OTBN clk hint to 0 within clkmgr and
  // verify that the OTBN clk hint status within clkmgr reads 1 (OTBN is not
  // idle).
  CHECK(otbn_load_app(&otbn_ctx, kOtbnAppCfiTest) == kOtbnOk);
  CHECK(otbn_execute(&otbn_ctx) == kOtbnOk);

  CLKMGR_TESTUTILS_SET_AND_CHECK_CLOCK_HINT(
      clkmgr, kOtbnClock, kDifToggleDisabled, kDifToggleEnabled);

  // After the OTBN operation is complete, verify that the OTBN clk hint status
  // within clkmgr now reads 0 again (OTBN is idle).
  otbn_wait_for_done_irq(&otbn_ctx);
  CLKMGR_TESTUTILS_CHECK_CLOCK_HINT(clkmgr, kOtbnClock, kDifToggleDisabled);

  // Write the OTBN clk hint to 1, read and check the OTBN output for
  // correctness.
  CLKMGR_TESTUTILS_SET_AND_CHECK_CLOCK_HINT(
      clkmgr, kOtbnClock, kDifToggleEnabled, kDifToggleEnabled);

  // Check for successful test execution (self-reported).
  uint32_t rv;
  CHECK(otbn_copy_data_from_otbn(&otbn_ctx, /*len_bytes=*/4, kVarRv, &rv) ==
        kOtbnOk);

  // Log some of the random numbers we got (for manual checks).
  print_uint256(&otbn_ctx, kVarRndOut, "rnd = ");
  print_uint256(&otbn_ctx, kVarUrndOut, "urnd = ");

  if (rv != 0) {
    uint32_t fail_idx;
    CHECK(otbn_copy_data_from_otbn(&otbn_ctx, /*len_bytes=*/4, kVarFailIdx,
                                   &fail_idx) == kOtbnOk,
          "ERROR: Test with index %d failed.", fail_idx);
    return false;
  }

  return true;
}
