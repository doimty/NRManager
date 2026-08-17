#!/usr/bin/env python3
"""Static contracts for the LTE B1 experiment and legacy n78 recovery."""
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
HEADER = (ROOT / "networkmanagerprefs/CCNMRootListController.h").read_text()
CONTROL_CENTER = (ROOT / "CCNetworkManager.x").read_text()
PLAN = (ROOT / "docs/lte-b1-lock-probe-plan.md").read_text()


def source_slice(start: str, end: str) -> str:
    start_index = SOURCE.index(start)
    return SOURCE[start_index: SOURCE.index(end, start_index)]


class LTEB1ProbeStaticTests(unittest.TestCase):
    def test_payload_changes_only_lte_to_exact_b1(self):
        helper = source_slice(
            "static BOOL CCNMValidateLTEB1OnlyBands",
            "static NSDictionary *CCNMBandDictionaryDifference",
        )
        self.assertIn(
            'static NSString *const CCNMLTERATKey = @"kCTRegistrationRadioAccessTechnologyLTE"',
            SOURCE,
        )
        self.assertIn("static NSNumber *CCNMLTEB1Band(void)", SOURCE)
        self.assertIn("requested[CCNMLTERATKey] = @[CCNMLTEB1Band()]", helper)
        self.assertIn("[requestedLTEBands isEqualToArray:@[CCNMLTEB1Band()]]", helper)
        self.assertIn("[originalBands[key] isEqual:requestedBands[key]]", helper)
        self.assertIn("[activeLTEBands containsObject:CCNMLTEB1Band()]", helper)
        self.assertIn("[supportedLTEBands containsObject:CCNMLTEB1Band()]", helper)
        self.assertIn("already exactly [1]", helper)

    def test_lte_b1_operation_is_bound_through_intent_and_markers(self):
        for token in (
            '@"lte_b1_only"',
            '@"lte_b1_only_intent"',
            '@"lte_b1_only_automatic_restore"',
        ):
            self.assertIn(token, SOURCE)
        validator = source_slice(
            "static BOOL CCNMValidateWriteIntent",
            "static BOOL CCNMSyncParentDirectory",
        )
        self.assertIn("CCNMBuildLTEB1OnlyBands", validator)
        self.assertIn("CCNMValidateLTEB1OnlyBands", validator)
        self.assertIn('[intent[@"preWriteServingBand"] isEqual:CCNMLTEB3Band()]', validator)
        self.assertIn("requiredConsecutiveServingSamples", validator)

    def test_device_run_requires_b3_then_observes_b1_before_restore(self):
        body = source_slice(
            "- (void)runLTEB1BandWrite",
            "- (void)restoreSavedBandSnapshot",
        )
        for required in (
            "CCNMAcquireRecoveryFileLock",
            "CCNMValidateTargetDevice",
            "CCNMSafeSlotOneContext",
            "CCNMValidateSetterABI",
            "CCNMBuildLTEB1OnlyBands",
            "CCNMCreateDurablePlistExclusively",
            "CCNMMarkTestSetterCallStarted",
            "bands:lteB1Info",
            "CCNMWaitForExpectedBandReadBack",
            "CCNMRunFullWindowServingCellSampler",
            "CCNMTrailingConsecutiveExactServingBandSamples",
            "CCNMRestoreActiveBands",
            "CCNMBandLTEB1ResultPath()",
        ):
            self.assertIn(required, body)

        pre_sample = body.index("NSDictionary *preWriteServingReport")
        snapshot = body.index("CCNMCreateDurablePlistExclusively(snapshot")
        setter = body.index("bands:lteB1Info")
        readback = body.index("CCNMWaitForExpectedBandReadBack", setter)
        post_sample = body.index("NSDictionary *postWriteServingReport", readback)
        restore = body.index("CCNMRestoreActiveBands", post_sample)
        self.assertLess(pre_sample, snapshot)
        self.assertLess(snapshot, setter)
        self.assertLess(setter, readback)
        self.assertLess(readback, post_sample)
        self.assertLess(post_sample, restore)
        self.assertIn("preWriteServingB3Confirmed", body)
        self.assertIn("b1ServingConfirmed", body)
        self.assertIn("transactionCompletedSafely", body)
        self.assertIn("hypothesisConfirmed", body)

    def test_trailing_serving_evidence_is_exact_and_resets_on_last_mismatch(self):
        helper = source_slice(
            "static NSUInteger CCNMTrailingConsecutiveExactServingBandSamples",
            "static NSDictionary *CCNMBandDictionaryDifference",
        )
        self.assertIn('report[@"cellMonitorSucceeded"]', helper)
        self.assertIn('report[@"cellMonitorSamplingStatus"]', helper)
        self.assertIn('sample[@"cellMonitorCopyStatus"]', helper)
        self.assertIn('cell[@"rat"]', helper)
        self.assertNotIn('cell[@"radioAccessTechnology"]', helper)
        self.assertIn('CCNMNSNumberIsExactInteger(cell[@"band"])', helper)
        self.assertIn("cellsStructurallyValid", helper)
        self.assertIn("sawTargetRAT", helper)
        self.assertIn("for (NSDictionary *sample in [samples reverseObjectEnumerator])", helper)
        self.assertIn("if (!cellsStructurallyValid || !sawTargetRAT)", helper)
        self.assertIn("break;", helper)

    def test_lte_b1_recovery_cleanup_has_only_two_explicit_authorizations(self):
        body = source_slice(
            "- (void)runLTEB1BandWrite",
            "- (void)restoreSavedBandSnapshot",
        )
        definite_no_call = source_slice(
            "static BOOL CCNMTestSetterDefinitelyNotCalled",
            "static BOOL CCNMRemoveUnattemptedBandRecoveryRecords",
        )
        cleanup_resume = source_slice(
            "static BOOL CCNMResumeRecoveryCleanupMarker",
            "static BOOL CCNMRemoveUnattemptedBandRecoveryRecords",
        )
        unattempted_cleanup = source_slice(
            "static BOOL CCNMRemoveUnattemptedBandRecoveryRecords",
            "static BOOL CCNMRemoveVerifiedBandRecoveryRecords",
        )
        verified_cleanup = source_slice(
            "static BOOL CCNMRemoveVerifiedBandRecoveryRecords",
            "static const char *CCNMSkipTypeQualifiers",
        )

        self.assertIn("!CCNMTestSetterCallStarted", definite_no_call)
        self.assertIn("!CCNMSetterTimeoutUncertain", definite_no_call)
        self.assertIn("CCNMTestSetterDefinitelyNotCalled", unattempted_cleanup)
        self.assertIn('CCNMInstallRecoveryCleanupMarker(@"pre_setter"', unattempted_cleanup)
        self.assertIn("CCNMResumeRecoveryCleanupMarker", unattempted_cleanup)

        self.assertIn("restoreReadBackEqual", verified_cleanup)
        self.assertIn('CCNMInstallRecoveryCleanupMarker(@"verified_restore"', verified_cleanup)
        self.assertIn("CCNMResumeRecoveryCleanupMarker", verified_cleanup)

        self.assertIn("CCNMRemoveExpectedRecoveryRecordDuringCleanup", cleanup_resume)
        snapshot_remove = cleanup_resume.index('cleanupMarker[@"snapshot"]')
        intent_remove = cleanup_resume.index('cleanupMarker[@"writeIntent"]')
        marker_remove = cleanup_resume.index("CCNMRemoveExpectedRecoveryRecord(cleanupMarker")
        self.assertLess(snapshot_remove, intent_remove)
        self.assertLess(intent_remove, marker_remove)

        verified_guard = body.index("if (automaticRestoreVerified)")
        verified_call = body.index("CCNMRemoveVerifiedBandRecoveryRecords", verified_guard)
        self.assertLess(verified_guard, verified_call)
        self.assertIn("CCNMRemoveUnattemptedBandRecoveryRecords", body)
        self.assertLess(
            body.index("CCNMRemoveUnattemptedBandRecoveryRecords"),
            body.index("CCNMReleaseRecoveryFileLock"),
        )
        for ownership_check in (
            "snapshotWasCreated = snapshotSaved ||",
            "writeIntentWasCreated = writeIntentSaved ||",
            "markerWasCreated = markerSaved ||",
        ):
            self.assertIn(ownership_check, body)
        self.assertGreaterEqual(body.count("CCNMRecoveryRecordMatchesExpected"), 3)
        self.assertIn('result[@"recoveryRecordsRemoved"]', body)
        self.assertIn("recoveryRecordsRemoved", body[body.index("BOOL transactionCompletedSafely"):])

    def test_unresolved_post_write_async_call_blocks_same_boot_restore(self):
        body = source_slice(
            "- (void)runLTEB1BandWrite",
            "- (void)restoreSavedBandSnapshot",
        )
        outstanding = body.index("postWriteAsyncOutstanding = CCNMServingCellSamplerHasUnsafeOutstandingAttempt()")
        gate = body.index("if (postWriteAsyncOutstanding)", outstanding)
        restore_begin = body.index("CCNMBeginAutomaticRestoreOperation", gate)
        restore = body.index("CCNMRestoreActiveBands", restore_begin)
        self.assertLess(outstanding, gate)
        self.assertLess(gate, restore_begin)
        self.assertLess(restore_begin, restore)
        self.assertIn('result[@"automaticRestoreSkippedReason"] = @"cell_monitor_async_outstanding"', body)
        self.assertIn("No same-boot automatic restore was issued", body)
        self.assertIn("Restore Saved Band Snapshot", body)

    def test_ui_requires_explicit_destructive_confirmation(self):
        self.assertIn("confirmLTEB1BandWrite", HEADER)
        plist = plistlib.loads((ROOT / "networkmanagerprefs/Resources/Root.plist").read_bytes())
        actions = [item.get("action") for item in plist["items"] if item.get("action")]
        self.assertEqual(actions.count("confirmLTEB1BandWrite:"), 1)
        self.assertEqual(actions.count("confirmNR78BandWrite:"), 0)
        confirm = source_slice(
            "- (void)confirmLTEB1BandWrite",
            "- (void)confirmClearProbeState",
        )
        self.assertIn("UIAlertActionStyleDestructive", confirm)
        self.assertIn("LTE B3", confirm)
        self.assertIn("exactly [1]", confirm)
        self.assertIn("actually ends on LTE B1", confirm)
        self.assertIn("may temporarily lose cellular service", confirm)

    def test_legacy_n78_records_remain_recoverable_without_exposing_old_write_ui(self):
        self.assertIn("intentionally replaces the completed n78 write action", PLAN)
        for token in (
            '@"nr78_only"',
            '@"nr78_only_intent"',
            '@"nr78_only_automatic_restore"',
            "CCNMBuildNR78OnlyBands",
            "CCNMValidateNR78OnlyBands",
            "CCNMLegacyNR78ResultPath",
            "CCNMValidateLegacyNR78CompletedResult",
            '@"verified_legacy_nr78_live_match"',
        ):
            self.assertIn(token, SOURCE)
        legacy_validator = source_slice(
            "static BOOL CCNMValidateLegacyNR78CompletedResult",
            "static BOOL CCNMSyncParentDirectory",
        )
        for proof in (
            '@"nr78_only"',
            '@"nr78_only_intent"',
            '@"operationGeneration"',
            '@"targetSubscriptionUUID"',
            '@"originalActiveBands"',
            '@"requestedActiveBands"',
            '@"readBackActiveBands"',
            '@"readBackPhase"',
            '@"effectApplied"',
            '@"observationPhase"',
            '@"restoreReadBackEqual"',
            '@"restorePhase"',
            '@"readBackEqual"',
            '@"restoreInFlightRemoved"',
            '@"setterInFlightRemoved"',
            '@"recoveryPending"',
            '@"setterStartedAt"',
            '@"setterFinishedAt"',
            '@"completedAt"',
            "readBackEvidenceValid",
            "observationEvidenceValid",
            "restorePhaseValid",
            "timestampsStrictlyOrdered",
        ):
            self.assertIn(proof, legacy_validator)
        self.assertIn("matchedRequest != matchedOriginal", legacy_validator)
        self.assertIn("effectApplied == matchedRequest", legacy_validator)
        self.assertIn("CCNMDictionariesEqual(readBackBands, expectedReadBackBands)", legacy_validator)
        self.assertIn("CCNMDictionariesEqual(restoreReadBackBands, snapshotBands)", legacy_validator)
        clear_confirm = source_slice("- (void)confirmClearProbeState", "- (void)clearSavedProbeState")
        clear = source_slice("- (void)clearSavedProbeState", "- (void)runSameValueBandWrite")
        self.assertIn("CCNMValidateLegacyNR78CompletedResult", clear_confirm)
        self.assertIn("CCNMValidateLegacyNR78CompletedResult", clear)
        self.assertIn('@"verified_legacy_nr78_live_match"', clear)
        self.assertNotIn("runNR78BandWrite", SOURCE)
        self.assertNotIn("confirmNR78BandWrite", HEADER)

    def test_control_center_rat_setter_cannot_race_band_recovery(self):
        setter = CONTROL_CENTER[
            CONTROL_CENTER.index("- (void)setSelected:"):
            CONTROL_CENTER.index("@end")
        ]
        lock = setter.index("CCNMAcquireBandRecoveryLock")
        gate = setter.index("CCNMBandRecoveryStateExists")
        modem_write = setter.index("_CTServerConnectionSetRATSelection")
        release = setter.index("CCNMReleaseBandRecoveryLock", modem_write)
        self.assertLess(lock, gate)
        self.assertLess(gate, modem_write)
        self.assertLess(modem_write, release)
        self.assertIn("LOCK_EX | LOCK_NB", CONTROL_CENTER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
