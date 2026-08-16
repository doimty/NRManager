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


def method(name: str, next_name: str) -> str:
    return SOURCE[SOURCE.index(name): SOURCE.index(next_name, SOURCE.index(name))]


class BandWriteProbeStaticTests(unittest.TestCase):
    def test_target_is_fail_closed(self):
        for literal in ('@"iPhone14,3"', '@"15.1.1"', '@"19B81"'):
            self.assertIn(literal, SOURCE)
        self.assertGreaterEqual(SOURCE.count("CCNMValidateTargetDevice(result, &failure)"), 4)

    def test_slot_and_subscription_guards(self):
        self.assertIn("presentContextCount != 1", SOURCE)
        self.assertIn("slotID == 1 && isPresent && isGood && uuid.UUIDString.length > 0", SOURCE)
        self.assertIn('snapshot[@"subscriptionUUID"]', SOURCE)
        self.assertIn("requiredUUID.length > 0", SOURCE)

    def test_snapshot_intent_and_marker_are_exclusive_and_durable(self):
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL", SOURCE)
        self.assertIn("fsync(fileDescriptor)", SOURCE)
        self.assertIn("CCNMCreateDurablePlistExclusively", SOURCE)
        for path in (
            "CCNMBandSnapshotPath()",
            "CCNMBandWriteIntentPath()",
            "CCNMBandSetterInFlightPath()",
        ):
            self.assertIn(path, SOURCE)
        self.assertNotIn("CCNMWritePlistAtomically", SOURCE)

    def test_boot_identity_and_cross_process_lock_are_present(self):
        self.assertIn('#include <sys/file.h>', SOURCE)
        self.assertIn('sysctlbyname("kern.boottime"', SOURCE)
        self.assertIn("flock(fileDescriptor, operation)", SOURCE)
        self.assertIn("LOCK_EX | (nonBlocking ? LOCK_NB : 0)", SOURCE)
        self.assertIn("CCNMBandRecoveryLockPath", SOURCE)

    def test_setter_inflight_record_is_strictly_bound(self):
        validator = SOURCE[SOURCE.index("static BOOL CCNMValidateSetterInFlightRecord"): SOURCE.index("static int CCNMAcquireRecoveryFileLock")]
        for field in (
            '@"setter_in_flight"',
            '@"processID"',
            '@"bootTimeSeconds"',
            '@"operationGeneration"',
            '@"slotID"',
            '@"subscriptionUUID"',
            '@"snapshotCreatedAt"',
            '@"writeIntentCreatedAt"',
        ):
            self.assertIn(field, validator)
        self.assertIn('expectedOperation = @"same_value_write"', validator)
        self.assertIn('expectedOperation = @"cold_band_removal"', validator)

    def test_only_test_and_restore_helpers_call_setter(self):
        calls = re.findall(r"\[client setActiveBandInfo:context bands:([A-Za-z0-9_]+) error:&([A-Za-z0-9_]+)\]", SOURCE)
        self.assertEqual(
            calls,
            [
                ("restoreInfo", "restoreError"),
                ("sameValueInfo", "setterError"),
                ("removalInfo", "setterError"),
            ],
        )
        self.assertNotIn("addActiveBand", SOURCE)
        self.assertNotIn("addActiveBands", SOURCE)

    def test_payload_is_identical_before_every_setter(self):
        self.assertEqual(SOURCE.count('phase[@"payloadEqualBeforeWrite"]'), 1)
        self.assertEqual(SOURCE.count('result[@"payloadEqualBeforeWrite"]'), 2)
        self.assertIn("CCNMDictionariesEqual(snapshotBands, payloadBands)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(originalBands, payloadBands)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(removalBands, payloadBands) &&", SOURCE)
        self.assertIn("CCNMValidateSingleBandRemoval(originalBands, payloadBands, removedBand, &failure)", SOURCE)

    def test_runtime_abi_guard_exists_before_all_operation_setters(self):
        self.assertIn("signature.numberOfArguments == 5", SOURCE)
        self.assertIn("strcmp(returnType, @encode(void)) == 0", SOURCE)
        self.assertIn("errorType[0] == '^' && errorType[1] == '@'", SOURCE)
        self.assertGreaterEqual(SOURCE.count("CCNMValidateSetterABI(client, &failure)"), 3)

    def test_test_setters_hold_lock_and_create_marker_before_call(self):
        for method_start, method_end, setter_call, operation_name in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite", "bands:sameValueInfo", '@"same_value_write"'),
            ("- (void)runColdBandRemovalWrite", "- (void)restoreSavedBandSnapshot", "bands:removalInfo", '@"cold_band_removal"'),
        ):
            body = method(method_start, method_end)
            lock = body.index("CCNMAcquireRecoveryFileLock")
            marker = body.index("CCNMCreateDurablePlistExclusively(setterInFlightRecord")
            started = body.index("CCNMMarkTestSetterCallStarted")
            setter = body.index(setter_call)
            release = body.index("CCNMReleaseRecoveryFileLock(recoveryLockDescriptor)", setter)
            self.assertLess(lock, marker)
            self.assertLess(marker, started)
            self.assertLess(started, setter)
            self.assertLess(setter, release)
            self.assertIn(operation_name, body)
            # The single lock acquired before the setter must still be held by the
            # automatic restore, so no second acquisition can interleave.
            self.assertEqual(body.count("CCNMAcquireRecoveryFileLock"), 1)
            self.assertIn("if (recoveryLockDescriptor >= 0) {", body[body.index("CCNMBeginAutomaticRestoreOperation"):])

    def test_watchdog_only_marks_uncertain_and_never_restores(self):
        watchdog = SOURCE[SOURCE.index("static void CCNMArmSetterTimeoutWatchdog"): SOURCE.index("@implementation CCNMRootListController")]
        self.assertIn("dispatch_after(", watchdog)
        self.assertIn("CCNMMarkSetterTimeoutUncertain", watchdog)
        self.assertIn("CCNMWriteSetterTimeoutResult", watchdog)
        self.assertNotIn("CCNMRestoreActiveBands", watchdog)
        self.assertNotIn("setActiveBandInfo", watchdog)
        for obsolete in (
            "CCNMRunWatchdogRestore",
            "CCNMRecoveryOperationStartedAt",
            "CCNMMonotonicTime",
            "CCNMEndTestSetterOperation",
            "CCNMMarkSetterStateUncertain",
            "operationFinished",
            "restoreStarted",
        ):
            self.assertNotIn(obsolete, SOURCE)

    def test_normal_marker_cleanup_requires_verified_restore(self):
        for method_start, method_end in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            ("- (void)runColdBandRemovalWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            body = method(method_start, method_end)
            self.assertIn("BOOL automaticRestoreVerified = NO", body)
            self.assertIn("automaticRestoreVerified = restored", body)
            cleanup_guard = body.index("if (automaticRestoreVerified)")
            marker_remove = body.index("CCNMRemoveSetterInFlightRecord", cleanup_guard)
            self.assertLess(cleanup_guard, marker_remove)
            self.assertIn('result[@"setterInFlightPreserved"] = @YES', body)

    def test_manual_restore_requires_valid_marker_from_an_earlier_boot(self):
        confirm = method("- (void)confirmRestoreBandSnapshot", "- (void)confirmColdBandRemovalWrite")
        self.assertIn("CCNMValidateSetterInFlightRecord", confirm)
        self.assertIn("sameBootInFlight", confirm)
        self.assertIn("validInFlight && !sameBootInFlight", confirm)
        self.assertIn("Reboot the device", confirm)

        manual = method("- (void)restoreSavedBandSnapshot", "- (void)viewWillAppear:")
        self.assertIn("CCNMAcquireRecoveryFileLock", manual)
        self.assertIn("CCNMValidateWriteIntent(writeIntent, snapshot, &failure)", manual)
        self.assertIn("CCNMValidateSetterInFlightRecord", manual)
        self.assertIn("if (!failure && !inFlightExists)", manual)
        self.assertIn("A recovery setter is not authorized", manual)
        self.assertIn("} else if (!currentBoot) {", manual)
        self.assertIn('inFlight[@"bootTimeSeconds"] isEqual:currentBoot', manual)
        self.assertIn("CCNMValidateSetterABI(client, &failure)", manual)
        self.assertIn("CCNMSafeSlotOneContext", manual)
        self.assertIn("CCNMRestoreActiveBands", manual)

    def test_manual_restore_avoids_an_unnecessary_setter(self):
        manual = method("- (void)restoreSavedBandSnapshot", "- (void)viewWillAppear:")
        self.assertIn("CCNMDictionariesEqual(snapshotBands, liveBands)", manual)
        self.assertIn('result[@"restoreWasNeeded"]', manual)
        live_compare = manual.index("CCNMDictionariesEqual(snapshotBands, liveBands)")
        restore_call = manual.index("CCNMRestoreActiveBands")
        self.assertLess(live_compare, restore_call)

    def test_clear_is_boot_gated_and_requires_live_snapshot_equality(self):
        clear = method("- (void)clearSavedProbeState", "- (void)runSameValueBandWrite")
        self.assertIn("CCNMAcquireRecoveryFileLock", clear)
        self.assertIn("CCNMValidateSetterInFlightRecord", clear)
        self.assertIn('inFlight[@"bootTimeSeconds"] isEqual:currentBoot', clear)
        self.assertIn("CCNMDictionariesEqual(snapshotBands, liveBands)", clear)
        self.assertIn('result[@"liveMatchedSnapshot"] = @(matched)', clear)
        self.assertNotIn("setActiveBandInfo", clear)

        live_guard = clear.index("CCNMDictionariesEqual(snapshotBands, liveBands)")
        snapshot_remove = clear.index("CCNMUnlinkIfPresent(CCNMBandSnapshotPath()")
        intent_remove = clear.index("CCNMUnlinkIfPresent(CCNMBandWriteIntentPath()")
        marker_remove = clear.index("CCNMRemoveSetterInFlightRecord")
        self.assertLess(live_guard, snapshot_remove)
        self.assertLess(snapshot_remove, intent_remove)
        self.assertLess(intent_remove, marker_remove)

    def test_manual_cleanup_order_removes_payload_before_marker(self):
        manual = method("- (void)restoreSavedBandSnapshot", "- (void)viewWillAppear:")
        snapshot_remove = manual.index("CCNMUnlinkIfPresent(CCNMBandSnapshotPath()")
        intent_remove = manual.index("CCNMUnlinkIfPresent(CCNMBandWriteIntentPath()")
        marker_remove = manual.index("CCNMRemoveSetterInFlightRecord")
        self.assertLess(snapshot_remove, intent_remove)
        self.assertLess(intent_remove, marker_remove)

    def test_removal_experiment_is_narrow_and_reversible(self):
        self.assertIn('static NSString *const CCNMRemovalRATKey = @"kCTRegistrationRadioAccessTechnologyLTE"', SOURCE)
        self.assertIn("return @[@48, @46];", SOURCE)
        self.assertIn("CCNMValidateSingleBandRemoval", SOURCE)
        self.assertIn("CCNMBuildSingleRemovalBands(originalBands, supportedBands", SOURCE)
        removal = method("- (void)runColdBandRemovalWrite", "- (void)restoreSavedBandSnapshot")
        for required in (
            "supportedBandsAtSelection",
            "preWriteSupportedBandsEqual",
            "readBackMatchedRequest",
            "readBackMatchedOriginal",
            "effectApplied",
            "CCNMRestoreActiveBands",
            "CCNMBandRemovalResultPath()",
        ):
            self.assertIn(required, removal)

    def test_ui_requires_explicit_confirmation(self):
        plist = plistlib.loads((ROOT / "networkmanagerprefs/Resources/Root.plist").read_bytes())
        actions = [item.get("action") for item in plist["items"] if item.get("action")]
        self.assertEqual(actions.count("confirmSameValueBandWrite:"), 1)
        self.assertEqual(actions.count("confirmColdBandRemovalWrite:"), 1)
        self.assertEqual(actions.count("confirmRestoreBandSnapshot:"), 1)
        self.assertEqual(actions.count("confirmClearProbeState:"), 1)
        self.assertIn("UIAlertActionStyleDestructive", SOURCE)

    def test_control_center_and_build_baseline_are_unchanged(self):
        subprocess.run(
            ["git", "diff", "--exit-code", BASELINE, "--", "CCNetworkManager.x", "Makefile", ".github/workflows/build.yml"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_plan_documents_device_reboot_boundary_and_residual_risk(self):
        self.assertIn("device reboot", PLAN.lower())
        self.assertIn("same boot", PLAN.lower())
        self.assertIn("never issues a concurrent restore", PLAN)
        self.assertNotIn("restarting Preferences", PLAN.replace("not on restarting Preferences", ""))
        self.assertIn("synchronous recovery setter", PLAN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
