#!/usr/bin/env python3
import plistlib
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
HEADER = (ROOT / "networkmanagerprefs/CCNMRootListController.h").read_text()
PLAN = (ROOT / "docs/same-value-write-probe-plan.md").read_text()
BASELINE = "2947f98ffb2665b000afab2c4db3ae843866d4da"


class BandWriteProbeStaticTests(unittest.TestCase):
    def test_target_is_fail_closed(self):
        for literal in ('@"iPhone14,3"', '@"15.1.1"', '@"19B81"'):
            self.assertIn(literal, SOURCE)
        self.assertIn("CCNMValidateTargetDevice(result, &failure)", SOURCE)

    def test_slot_and_subscription_guards(self):
        self.assertIn("presentContextCount != 1", SOURCE)
        self.assertIn("slotID == 1 && isPresent && isGood && uuid.UUIDString.length > 0", SOURCE)
        self.assertIn('snapshot[@"subscriptionUUID"]', SOURCE)
        self.assertIn("requiredUUID.length > 0", SOURCE)

    def test_snapshot_is_exclusive_and_durable(self):
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL", SOURCE)
        self.assertIn("fsync(fileDescriptor)", SOURCE)
        self.assertIn("CCNMCreateDurablePlistExclusively", SOURCE)
        self.assertNotIn("CCNMWritePlistAtomically", SOURCE)

    def test_payload_is_identical_before_every_setter(self):
        self.assertEqual(SOURCE.count('phase[@"payloadEqualBeforeWrite"]'), 1)
        self.assertEqual(SOURCE.count('result[@"payloadEqualBeforeWrite"]'), 1)
        self.assertIn("CCNMDictionariesEqual(snapshotBands, payloadBands)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(originalBands, payloadBands)", SOURCE)

    def test_only_test_and_restore_call_setter(self):
        calls = re.findall(r"\[client setActiveBandInfo:context bands:([A-Za-z0-9_]+) error:&([A-Za-z0-9_]+)\]", SOURCE)
        self.assertEqual(calls, [("restoreInfo", "restoreError"), ("sameValueInfo", "setterError")])
        self.assertNotIn("addActiveBand", SOURCE)
        self.assertNotIn("addActiveBands", SOURCE)

    def test_failure_before_setter_does_not_restore_write(self):
        self.assertIn("__block BOOL setterWasInvoked = NO", SOURCE)
        self.assertIn("if (setterWasInvoked) {", SOURCE)
        self.assertIn("setterWasInvoked &&", SOURCE)
        self.assertIn("!operationFinished &&", SOURCE)
        self.assertIn("!restoreStarted &&", SOURCE)
        self.assertIn("CCNMBeginTestSetterOperation(operationGeneration, manualRecoveryGeneration, &failure)", SOURCE)
        self.assertIn("CCNMEndBandOperation();", SOURCE)
        self.assertIn("operationException", SOURCE)

    def test_final_prewrite_state_is_revalidated(self):
        self.assertIn('context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure)', SOURCE)
        self.assertIn('restoreContext = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &restoreFailure)', SOURCE)
        self.assertIn('result[@"preWriteActiveBandsEqual"]', SOURCE)
        self.assertIn("CCNMDictionariesEqual(originalBands, preWriteBands)", SOURCE)

    def test_runtime_abi_guard_exists(self):
        self.assertIn("CCNMValidateSetterABI", SOURCE)
        self.assertIn("signature.numberOfArguments == 5", SOURCE)
        self.assertIn("strcmp(returnType, @encode(void)) == 0", SOURCE)
        self.assertIn("errorType[0] == '^' && errorType[1] == '@'", SOURCE)

    def test_watchdog_uses_fresh_client_and_context(self):
        watchdog = SOURCE[SOURCE.index("static void CCNMRunWatchdogRestore"):SOURCE.index("@implementation CCNMRootListController")]
        self.assertIn("CCNMCreateCoreTelephonyClient", watchdog)
        self.assertIn("CCNMSafeSlotOneContext", watchdog)
        self.assertIn("CCNMBandWatchdogResultPath", watchdog)
        self.assertIn("subscriptionUUID", watchdog)
        self.assertIn("CCNMEndRecoveryOperation", SOURCE)
        self.assertIn("restoreStarted = YES", SOURCE)
        begin = SOURCE.index("CCNMBeginTestSetterOperation(operationGeneration")
        timer = SOURCE.index("dispatch_after(", begin)
        invoked = SOURCE.index("setterWasInvoked = YES", timer)
        setter = SOURCE.index("[client setActiveBandInfo:context bands:sameValueInfo", invoked)
        self.assertLess(begin, timer)
        self.assertLess(timer, invoked)
        self.assertLess(invoked, setter)

    def test_manual_restore_has_independent_result_and_recovery_lock(self):
        self.assertIn("CCNMBandManualRestoreResultPath", SOURCE)
        self.assertIn('@"operation": @"manual_restore"', SOURCE)
        self.assertIn("CCNMBeginManualRestoreOperation()", SOURCE)
        self.assertIn("CCNMEndManualRestoreOperation()", SOURCE)
        self.assertIn("CCNMBandOperationStartedAt", SOURCE)
        self.assertIn("CCNMRecoveryOperationStartedAt", SOURCE)
        self.assertIn("CCNMMonotonicTime()", SOURCE)
        self.assertIn("CCNMManualRecoveryGeneration++", SOURCE)
        self.assertIn("CCNMTestSetterStartedAt", SOURCE)

    def test_manual_restore_requires_matching_durable_write_intent(self):
        self.assertIn("CCNMBandWriteIntentPath", SOURCE)
        self.assertIn("CCNMValidateWriteIntent", SOURCE)
        self.assertIn('@"operation": @"same_value_write_intent"', SOURCE)
        self.assertIn('@"snapshotActiveBands": snapshot[@"activeBands"]', SOURCE)
        intent_create = SOURCE.index("CCNMCreateDurablePlistExclusively(writeIntent")
        begin_setter = SOURCE.index("CCNMBeginTestSetterOperation(operationGeneration", intent_create)
        setter = SOURCE.index("[client setActiveBandInfo:context bands:sameValueInfo")
        self.assertLess(intent_create, begin_setter)
        self.assertLess(begin_setter, setter)
        manual = SOURCE[SOURCE.index("- (void)restoreSavedBandSnapshot"):SOURCE.index("- (void)viewWillAppear:")]
        self.assertIn("CCNMValidateWriteIntent(writeIntent, snapshot, &failure)", manual)

    def test_ui_requires_explicit_confirmation_and_restore(self):
        plist = plistlib.loads((ROOT / "networkmanagerprefs/Resources/Root.plist").read_bytes())
        actions = [item.get("action") for item in plist["items"] if item.get("action")]
        self.assertEqual(actions.count("confirmSameValueBandWrite:"), 1)
        self.assertEqual(actions.count("confirmRestoreBandSnapshot:"), 1)
        self.assertIn("UIAlertActionStyleDestructive", SOURCE)

    def test_control_center_and_build_baseline_are_unchanged(self):
        subprocess.run(
            ["git", "diff", "--exit-code", BASELINE, "--", "CCNetworkManager.x", "Makefile", ".github/workflows/build.yml"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_plan_states_in_process_watchdog_limit(self):
        self.assertIn("cannot survive a Preferences process crash", PLAN)
        self.assertIn("manual-restore", PLAN.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
