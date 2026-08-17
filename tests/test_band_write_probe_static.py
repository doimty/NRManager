#!/usr/bin/env python3
import plistlib
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
CONTROL_CENTER_SOURCE = (ROOT / "CCNetworkManager.x").read_text()
HEADER = (ROOT / "networkmanagerprefs/CCNMRootListController.h").read_text()
PLAN = (ROOT / "docs/same-value-write-probe-plan.md").read_text()
BASELINE = "2947f98ffb2665b000afab2c4db3ae843866d4da"


def method(name: str, next_name: str) -> str:
    return SOURCE[SOURCE.index(name): SOURCE.index(next_name, SOURCE.index(name))]


class BandWriteProbeStaticTests(unittest.TestCase):
    def test_target_is_fail_closed(self):
        for literal in ('@"iPhone14,3"', '@"15.1.1"', '@"19B81"'):
            self.assertIn(literal, SOURCE)
        self.assertGreaterEqual(SOURCE.count("CCNMValidateTargetDevice(result, &failure)"), 5)

    def test_slot_and_subscription_guards(self):
        self.assertIn("presentContextCount != 1", SOURCE)
        self.assertIn("slotID == 1 && isPresent && isGood && uuid.UUIDString.length > 0", SOURCE)
        self.assertIn('snapshot[@"subscriptionUUID"]', SOURCE)
        self.assertIn("requiredUUID.length > 0", SOURCE)

    def test_snapshot_intent_and_marker_are_exclusive_and_durable(self):
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL", SOURCE)
        self.assertIn("F_FULLFSYNC", SOURCE)
        self.assertIn("CCNMSyncParentDirectory", SOURCE)
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
        validator = SOURCE[SOURCE.index("static BOOL CCNMValidateSetterInFlightMarkerHeader"): SOURCE.index("static int CCNMAcquireRecoveryFileLock")]
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
        self.assertIn('expectedOperation = @"nr78_only"', validator)
        self.assertIn('expectedOperation = @"lte_b1_only"', validator)

    def test_only_test_and_restore_helpers_call_setter(self):
        calls = re.findall(r"\[client setActiveBandInfo:context bands:([A-Za-z0-9_]+) error:&([A-Za-z0-9_]+)\]", SOURCE)
        self.assertEqual(
            calls,
            [
                ("restoreInfo", "restoreError"),
                ("sameValueInfo", "setterError"),
                ("removalInfo", "setterError"),
                ("lteB1Info", "setterError"),
            ],
        )
        self.assertNotIn("addActiveBand", SOURCE)
        self.assertNotIn("addActiveBands", SOURCE)

    def test_payload_is_identical_before_every_setter(self):
        self.assertEqual(SOURCE.count('phase[@"payloadEqualBeforeWrite"]'), 1)
        write_methods = (
            method("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            method("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        )
        self.assertEqual(sum(body.count('result[@"payloadEqualBeforeWrite"]') for body in write_methods), 3)
        self.assertIn("CCNMDictionariesEqual(snapshotBands, payloadBands)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(originalBands, payloadBands)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(removalBands, payloadBands) &&", SOURCE)
        self.assertIn("CCNMValidateSingleBandRemoval(originalBands, payloadBands, removedBand, &failure)", SOURCE)
        self.assertIn("CCNMDictionariesEqual(lteB1Bands, payloadBands) &&", SOURCE)
        self.assertIn("CCNMValidateLTEB1OnlyBands(originalBands, payloadBands, &failure)", SOURCE)

    def test_lte_b1_success_requires_error_free_setter_and_finalized_evidence(self):
        b1 = method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot")
        self.assertIn("BOOL setterReturnedWithoutError = setterReturnedNormally && !setterError;", b1)
        self.assertIn('result[@"setterReturnedWithoutError"] = @(setterReturnedWithoutError);', b1)
        self.assertIn('result[@"postWriteB1Observed"] = @(postWriteB1Observed);', b1)
        self.assertIn("BOOL b1ServingConfirmed = transactionCompletedSafely && effectApplied && postWriteB1Observed;", b1)
        self.assertIn("BOOL passed = !failure && transactionCompletedSafely && effectApplied && b1ServingConfirmed;", b1)
        self.assertIn('result[@"passed"] = @(passed);', b1)
        self.assertIn("BOOL diagnosticCompleted = resultSaved && !failure && transactionCompletedSafely;", b1)

    def test_runtime_abi_guard_exists_before_all_operation_setters(self):
        self.assertIn("signature.numberOfArguments == 5", SOURCE)
        self.assertIn("strcmp(returnType, @encode(void)) == 0", SOURCE)
        self.assertIn("errorType[0] == '^' && errorType[1] == '@'", SOURCE)
        self.assertGreaterEqual(SOURCE.count("CCNMValidateSetterABI(client, &failure)"), 4)

    def test_test_setters_hold_lock_and_create_marker_before_call(self):
        for method_start, method_end, setter_call, operation_name in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite", "bands:sameValueInfo", '@"same_value_write"'),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite", "bands:removalInfo", '@"cold_band_removal"'),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot", "bands:lteB1Info", '@"lte_b1_only"'),
        ):
            body = method(method_start, method_end)
            lock = body.index("CCNMAcquireRecoveryFileLock")
            outstanding = body.index("CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)")
            begin = body.index("CCNMBeginTestSetterOperation")
            marker = body.index("CCNMCreateDurablePlistExclusively(setterInFlightRecord")
            started = body.index("CCNMMarkTestSetterCallStarted")
            setter = body.index(setter_call)
            release = body.index("CCNMReleaseRecoveryFileLock(recoveryLockDescriptor)", setter)
            self.assertLess(lock, outstanding)
            self.assertLess(outstanding, begin)
            self.assertLess(begin, marker)
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

    def test_restore_setter_has_its_own_marker_and_watchdog(self):
        restore_start = SOURCE.index("static BOOL CCNMRestoreActiveBands")
        restore = SOURCE[restore_start: SOURCE.index("static void CCNMWriteSetterTimeoutResult", restore_start)]
        create = restore.index("CCNMCreateDurablePlistExclusively(restoreMarkerRecord, CCNMBandRestoreInFlightPath()")
        replace = restore.index("CCNMReplaceDurablePlistExact(staleRestoreMarker, restoreMarkerRecord")
        armed = restore.index("CCNMArmRestoreTimeoutWatchdog(operationGeneration, restoreAttemptToken)")
        setter = restore.index("[client setActiveBandInfo:context bands:restoreInfo")
        self.assertLess(create, armed)
        self.assertLess(replace, armed)
        self.assertLess(armed, setter)
        # A hung, over-deadline, or exceptional restore latches uncertainty and
        # demands a reboot instead of authorizing another setter.
        self.assertIn("CCNMFinishRestoreSetterOperation(operationGeneration,", restore)
        self.assertIn("restoreAttemptToken,", restore)
        self.assertIn("setterReturnedNormally", restore)
        self.assertIn("Reboot the device, then run the saved-snapshot restore again.", restore)
        # Its marker is retired only after the read-back proved equality.
        readback = restore.index('phase[@"readBackEqual"] = @(equal)')
        marker_removed = restore.index("CCNMRemoveRestoreInFlightRecord(restoreMarkerRecord")
        self.assertLess(readback, marker_removed)

        # A stale prior-boot restore marker is atomically handed off to the new
        # current-boot marker. There must never be an unlink-then-create gap.
        stale_validate = restore.index("CCNMValidateRestoreInFlightRecord(staleRestoreMarker, snapshot")
        stale_replace = restore.index("CCNMReplaceDurablePlistExact(staleRestoreMarker, restoreMarkerRecord")
        self.assertLess(stale_validate, stale_replace)
        self.assertNotIn("CCNMRemoveRestoreInFlightRecord(staleRestoreMarker", restore)
        self.assertIn("CCNMMarkerBootRelation(staleRestoreMarker) != CCNMBootRelationEarlierBoot", restore)
        self.assertIn("CCNMValidateSnapshot(snapshot, NULL, failure)", restore)
        self.assertIn("CCNMValidateRestoreInFlightRecord(restoreMarkerRecord, snapshot", restore)
        self.assertIn("CCNMDictionariesEqual(snapshot[@\"activeBands\"], snapshotBands)", restore)

        restore_watchdog_start = SOURCE.rindex("static void CCNMArmRestoreTimeoutWatchdog(NSUInteger operationGeneration,")
        restore_watchdog = SOURCE[restore_watchdog_start: SOURCE.index("@implementation CCNMRootListController", restore_watchdog_start)]
        self.assertIn("restoreAttemptToken", restore_watchdog)
        self.assertIn("CCNMMarkRestoreTimeoutUncertain", restore_watchdog)
        self.assertNotIn("CCNMRestoreActiveBands", restore_watchdog)
        self.assertNotIn("setActiveBandInfo", restore_watchdog)
        self.assertNotIn("CCNMUnlinkIfPresent", restore_watchdog)

    def test_outstanding_setter_exemption_is_narrow(self):
        gate = SOURCE[SOURCE.index("static BOOL CCNMCurrentBootSetterMayBeOutstanding"): SOURCE.index("static BOOL CCNMValidateTargetDevice")]
        # Only the setter marker may be exempted, only by exact dictionary identity.
        self.assertIn("BOOL setterMarker = [path isEqualToString:CCNMBandSetterInFlightPath()]", gate)
        self.assertIn("if (setterMarker &&", gate)
        self.assertIn("[marker isEqualToDictionary:returnedSetterRecord]", gate)
        self.assertIn("CCNMBandRestoreInFlightPath()", gate)
        self.assertIn("CCNMBootRelationUnknown", gate)

        # All automatic restores share the one helper call that passes the exact
        # returned record; every external/pre-write gate passes nil.
        calls = re.findall(r"CCNMCurrentBootSetterMayBeOutstanding\((\w+|nil), &", SOURCE)
        self.assertEqual(calls.count("nil"), 7)
        self.assertEqual(calls.count("exemptSetterRecord"), 1)
        self.assertEqual(len(calls), 8)

        # The exemption requires in-process proof that the call already returned.
        restore_start = SOURCE.index("static BOOL CCNMRestoreActiveBands")
        restore = SOURCE[restore_start: SOURCE.index("static void CCNMWriteSetterTimeoutResult", restore_start)]
        proof = restore.index("CCNMTestSetterProvablyReturned(operationGeneration)")
        assign = restore.index("exemptSetterRecord = returnedSetterRecord")
        use = restore.index("CCNMCurrentBootSetterMayBeOutstanding(exemptSetterRecord")
        self.assertLess(proof, assign)
        self.assertLess(assign, use)
        self.assertIn("The test setter has not provably returned", restore)

        # The proof is only granted by a normal synchronous return inside the
        # monotonic deadline with no latched timeout.
        proved = SOURCE[SOURCE.index("static BOOL CCNMTestSetterProvablyReturned"): SOURCE.index("static BOOL CCNMBeginAutomaticRestoreOperation")]
        for condition in (
            "!CCNMSetterTimeoutUncertain",
            "!CCNMTestSetterCallStarted",
            "!CCNMTestSetterInProgress",
            "CCNMTestSetterReturnedGeneration == operationGeneration",
        ):
            self.assertIn(condition, proved)
        self.assertEqual(SOURCE.count("CCNMTestSetterReturnedGeneration = operationGeneration"), 1)
        finish = SOURCE[SOURCE.index("static BOOL CCNMFinishTestSetterOperation"): SOURCE.index("static BOOL CCNMTestSetterProvablyReturned")]
        self.assertIn("BOOL setterReturnedNormally", finish)
        self.assertIn("finishedMonotonic - CCNMTestSetterStartedMonotonic", finish)
        self.assertIn("elapsed >= CCNMSameValueWriteWatchdogSeconds", finish)
        self.assertIn("if (callWasStarted && setterReturnedNormally && !uncertain)", finish)

    def test_boot_session_uuid_is_the_authority_for_boot_identity(self):
        self.assertIn('CCNMSysctlString("kern.bootsessionuuid")', SOURCE)
        canonical = SOURCE[SOURCE.index("static NSString *CCNMCanonicalUUIDString"): SOURCE.index("static NSString *CCNMBootSessionIdentity")]
        self.assertIn("initWithUUIDString", canonical)
        relation = SOURCE[SOURCE.index("static CCNMBootRelation CCNMMarkerBootRelation"): SOURCE.index("static BOOL CCNMValidateSetterInFlightMarkerHeader")]
        self.assertIn('marker[@"bootSessionUUID"]', relation)
        self.assertIn("CCNMCanonicalUUIDString", relation)
        self.assertIn("CCNMBootRelationUnknown", relation)
        self.assertNotIn("length < 36", relation)
        for builder in (
            "static NSDictionary *CCNMBuildRestoreMarkerRecord",
        ):
            body = SOURCE[SOURCE.index(builder): SOURCE.index("static BOOL CCNMValidateSetterInFlightRecord")]
            self.assertIn("operationGeneration == 0", body)
            self.assertIn('@"bootSessionUUID": bootSession', body)
            self.assertIn('@"bootTimeSeconds": bootSeconds', body)
        for body in (
            method("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            method("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            self.assertIn('@"bootSessionUUID": CCNMBootSessionIdentity() ?: @""', body)
            self.assertIn("BOOL markerIdentityValid", body)
            self.assertIn('setterInFlightRecord[@"bootSessionUUID"] length] > 0', body)
            self.assertIn('setterInFlightRecord[@"bootTimeSeconds"] longLongValue] != 0', body)

    def test_uncertain_latch_blocks_every_path_that_can_reach_a_setter(self):
        # The reviewer-raised P0 is "a timeout leads to a concurrent restore".
        # Pin the opposite: timeout observers and synchronous finish checks may
        # set the one-way latch, which is never cleared before process exit.
        self.assertEqual(SOURCE.count("CCNMSetterTimeoutUncertain = YES"), 4)
        self.assertEqual(SOURCE.count("CCNMSetterTimeoutUncertain = NO"), 1)  # the initializer only
        self.assertIn("static BOOL CCNMSetterTimeoutUncertain = NO;", SOURCE)
        for latch_owner, next_symbol in (
            ("static BOOL CCNMMarkSetterTimeoutUncertain", "static BOOL CCNMFinishTestSetterOperation"),
            ("static BOOL CCNMMarkRestoreTimeoutUncertain", "static BOOL CCNMFinishRestoreSetterOperation"),
        ):
            body = SOURCE[SOURCE.index(latch_owner): SOURCE.index(next_symbol)]
            self.assertIn("CCNMSetterTimeoutUncertain = YES", body)

        for gate in (
            "static BOOL CCNMBeginBandOperation",
            "static BOOL CCNMBeginTestSetterOperation",
            "static BOOL CCNMMarkTestSetterCallStarted",
            "static BOOL CCNMMarkRestoreSetterCallStarted",
            "static BOOL CCNMTestSetterProvablyReturned",
            "static BOOL CCNMBeginAutomaticRestoreOperation",
            "static BOOL CCNMBeginManualRestoreOperation",
        ):
            start = SOURCE.index(gate)
            end = SOURCE.index("\n}", start)
            self.assertIn("CCNMSetterTimeoutUncertain", SOURCE[start:end], gate)

        # A timeout must never delete recovery evidence, and the timeout report
        # must be a separate plist from the snapshot and the intent.
        timeout_writer_start = SOURCE.rindex("static void CCNMWriteSetterTimeoutResult")
        timeout_writer = SOURCE[
            timeout_writer_start:
            SOURCE.index("static void CCNMArmSetterTimeoutWatchdog", timeout_writer_start)
        ]
        self.assertIn("CCNMBandWatchdogResultPath", timeout_writer)
        self.assertIn('@"requiresDeviceReboot": @YES', timeout_writer)
        for forbidden in (
            "CCNMUnlinkIfPresent",
            "CCNMRemoveSetterInFlightRecord",
            "CCNMBandSnapshotPath",
            "CCNMBandWriteIntentPath",
            "CCNMBandSetterInFlightPath",
            "CCNMBandRestoreInFlightPath",
        ):
            self.assertNotIn(forbidden, timeout_writer, forbidden)

    def test_deadline_and_exception_paths_fail_closed_without_automatic_restore(self):
        finish = SOURCE[SOURCE.index("static BOOL CCNMFinishTestSetterOperation"): SOURCE.index("static BOOL CCNMTestSetterProvablyReturned")]
        self.assertIn("!setterReturnedNormally || exceededDeadline", finish)
        self.assertIn("CCNMSetterTimeoutUncertain = YES", finish)

        for method_start, method_end, setter_call in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite", "bands:sameValueInfo"),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite", "bands:removalInfo"),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot", "bands:lteB1Info"),
        ):
            body = method(method_start, method_end)
            setter = body.index(setter_call)
            normal = body.index("setterReturnedNormally = YES", setter)
            catch = body.index("@catch", setter)
            finish_call = body.index("CCNMFinishTestSetterOperation(operationGeneration,", setter)
            restore_guard = body.index("if (setterWasInvoked && markerWasCreated && !setterStateUncertain)", finish_call)
            self.assertLess(setter, normal)
            self.assertLess(normal, catch)
            self.assertLess(catch, finish_call)
            self.assertLess(finish_call, restore_guard)
            self.assertIn("setterDeadlineExceeded", body[finish_call:restore_guard])
            self.assertIn("exception left its server-side outcome uncertain", body[finish_call:restore_guard])

    def test_restore_watchdogs_use_unique_attempt_tokens(self):
        globals_block = SOURCE[:SOURCE.index("static NSSet<NSString *> *CCNMRequiredRATKeys")]
        self.assertIn("CCNMRestoreSetterAttemptSerial", globals_block)
        self.assertIn("CCNMActiveRestoreSetterAttemptToken", globals_block)
        start = SOURCE[SOURCE.index("static BOOL CCNMMarkRestoreSetterCallStarted"): SOURCE.index("static BOOL CCNMMarkRestoreTimeoutUncertain")]
        self.assertIn("CCNMRestoreSetterAttemptSerial++", start)
        self.assertIn("*restoreAttemptToken", start)
        timeout = SOURCE[SOURCE.index("static BOOL CCNMMarkRestoreTimeoutUncertain"): SOURCE.index("static BOOL CCNMFinishRestoreSetterOperation")]
        self.assertIn("CCNMActiveRestoreSetterAttemptToken != restoreAttemptToken", timeout)

    def test_automatic_restore_flag_is_always_released(self):
        for method_start, method_end in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            body = method(method_start, method_end)
            begin = body.index("if (CCNMBeginAutomaticRestoreOperation(operationGeneration))")
            try_start = body.index("@try", begin)
            phase_allocation = body.index("[NSMutableDictionary dictionary]", begin)
            finally_start = body.index("@finally", try_start)
            end = body.index("CCNMEndRecoveryOperation()", finally_start)
            self.assertLess(try_start, phase_allocation)
            self.assertLess(phase_allocation, finally_start)
            self.assertLess(finally_start, end)

    def test_normal_marker_cleanup_requires_verified_restore(self):
        for method_start, method_end in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            body = method(method_start, method_end)
            self.assertIn("BOOL automaticRestoreVerified = NO", body)
            self.assertIn("automaticRestoreVerified = restored", body)
            cleanup_guard = body.index("if (automaticRestoreVerified)")
            record_cleanup = body.index("CCNMRemoveVerifiedBandRecoveryRecords", cleanup_guard)
            self.assertLess(cleanup_guard, record_cleanup)
            self.assertIn('result[@"setterInFlightPreserved"] = @YES', body)

    def test_every_exposed_write_retires_or_preserves_the_complete_recovery_set(self):
        for method_start, method_end in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            body = method(method_start, method_end)
            cleanup_guard = body.index("if (automaticRestoreVerified)")
            verified_cleanup = body.index("CCNMRemoveVerifiedBandRecoveryRecords", cleanup_guard)
            self.assertLess(cleanup_guard, verified_cleanup)
            self.assertIn("CCNMRemoveUnattemptedBandRecoveryRecords", body)
            self.assertIn("BOOL recoveryPending = restorePending || cleanupPending;", body)
            self.assertIn("recoveryRecordsRemoved && !recoveryPending", body)

    def test_lte_b1_serving_evidence_uses_a_full_window_sampler(self):
        b1_body = method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot")
        self.assertEqual(b1_body.count("CCNMRunFullWindowServingCellSampler"), 2)
        self.assertNotIn("CCNMRunAdaptiveServingCellSampler", b1_body)

    def test_incomplete_post_write_observation_blocks_same_boot_restore(self):
        b1_body = method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot")
        observation_gate = b1_body.index("BOOL postWriteObservationComplete = !matchedRequest;")
        observation_assignment = b1_body.index("postWriteObservationComplete = observationCompleted;", observation_gate)
        restore_skip = b1_body.index("else if (!postWriteObservationComplete)", observation_assignment)
        restore_begin = b1_body.index("CCNMBeginAutomaticRestoreOperation", restore_skip)
        self.assertLess(observation_gate, observation_assignment)
        self.assertLess(observation_assignment, restore_skip)
        self.assertLess(restore_skip, restore_begin)
        self.assertIn('@"automaticRestoreSkippedReason"] = @"cell_monitor_observation_incomplete"', b1_body[restore_skip:restore_begin])
        self.assertIn("no same-boot automatic restore was issued", b1_body[restore_skip:restore_begin])

    def test_untracked_recovery_paths_are_checked_before_pre_setter_cleanup(self):
        helper = SOURCE[SOURCE.index("static BOOL CCNMRecoveryRecordMatchesExpected"): SOURCE.index("static BOOL CCNMRemoveExpectedRecoveryRecord")]
        self.assertIn("if (!expectedRecord)", helper)
        self.assertIn("fileExistsAtPath:path", helper)
        self.assertIn("An unexpected %@ exists", helper)

    def test_manual_restore_requires_valid_marker_from_an_earlier_boot(self):
        confirm = method("- (void)confirmRestoreBandSnapshot", "- (void)confirmColdBandRemovalWrite")
        self.assertIn("CCNMValidateSetterInFlightRecord", confirm)
        self.assertIn("CCNMValidateRestoreInFlightRecord", confirm)
        self.assertIn("CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)", confirm)
        self.assertIn("validIntent && validInFlight && validRestoreInFlight && !outstanding", confirm)
        self.assertIn("Reboot the device", confirm)

        manual = method("- (void)restoreSavedBandSnapshot", "- (void)resumeRecoveryCleanup")
        self.assertIn("CCNMAcquireRecoveryFileLock", manual)
        self.assertIn("CCNMValidateWriteIntent(writeIntent, snapshot, &failure)", manual)
        self.assertIn("CCNMValidateSetterInFlightRecord", manual)
        self.assertIn("if (!failure && !inFlightExists)", manual)
        self.assertIn("A recovery setter is not authorized", manual)
        self.assertIn("CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)", manual)
        self.assertIn('result[@"deviceRebootRequiredForInFlight"] = @YES', manual)
        self.assertIn("CCNMValidateSetterABI(client, &failure)", manual)
        self.assertIn("CCNMSafeSlotOneContext", manual)
        self.assertIn("CCNMRestoreActiveBands", manual)
        # Manual restore never exempts a marker and uses its own generation.
        self.assertIn("restoreMarker, nil, manualRestoreGeneration", manual)
        self.assertIn("CCNMBeginManualRestoreOperation(&manualRestoreGeneration)", manual)

    def test_unverified_recovery_always_states_the_reboot_procedure(self):
        for method_start, method_end, phrase in (
            (
                "- (void)runSameValueBandWrite",
                "- (void)runColdBandRemovalWrite",
                "The write was issued and the original set was not verified as restored.",
            ),
            (
                "- (void)runColdBandRemovalWrite",
                "- (void)runLTEB1BandWrite",
                "The removal write was issued and the original set was not verified as restored.",
            ),
            (
                "- (void)runLTEB1BandWrite",
                "- (void)restoreSavedBandSnapshot",
                "The LTE B1-only write was issued and the original set was not verified as restored.",
            ),
        ):
            body = method(method_start, method_end)
            self.assertIn("BOOL recoveryRecordsCreated = snapshotWasCreated || writeIntentWasCreated || markerWasCreated;", body)
            self.assertIn("BOOL recoveryPending = restorePending || cleanupPending;", body)
            self.assertIn('result[@"recoveryPending"] = @(recoveryPending)', body)
            self.assertIn(phrase, body)
            self.assertIn("Reboot the device, reopen Preferences, then run Restore Saved Band Snapshot.", body)
            self.assertIn("Recovery records were preserved.", body)

        b1_body = method("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot")
        self.assertIn("BOOL recoveryPending = restorePending || cleanupPending;", b1_body)
        self.assertIn("[result[@\"setterReturnedWithoutError\"] boolValue]", b1_body)
        self.assertIn("BOOL b1ServingConfirmed = transactionCompletedSafely && effectApplied && postWriteB1Observed;", b1_body)
        self.assertIn("recoveryRecordsRemoved && !recoveryPending", b1_body)

    def test_manual_restore_avoids_an_unnecessary_setter(self):
        manual = method("- (void)restoreSavedBandSnapshot", "- (void)resumeRecoveryCleanup")
        self.assertIn("CCNMDictionariesEqual(snapshotBands, liveBands)", manual)
        self.assertIn('result[@"restoreWasNeeded"]', manual)
        live_compare = manual.index("CCNMDictionariesEqual(snapshotBands, liveBands)")
        stale_marker_cleanup = manual.index("CCNMRemoveRestoreInFlightRecord(restoreInFlight", live_compare)
        restored_without_setter = manual.index("restored = YES", stale_marker_cleanup)
        restore_call = manual.index("CCNMRestoreActiveBands")
        self.assertLess(live_compare, stale_marker_cleanup)
        self.assertLess(stale_marker_cleanup, restored_without_setter)
        self.assertLess(restored_without_setter, restore_call)

    def test_clear_is_boot_gated_and_requires_live_snapshot_equality(self):
        clear = method("- (void)clearSavedProbeState", "- (void)runSameValueBandWrite")
        self.assertIn("CCNMAcquireRecoveryFileLock", clear)
        self.assertIn("CCNMValidateSetterInFlightRecord", clear)
        self.assertIn("CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)", clear)
        self.assertIn("CCNMDictionariesEqual(snapshotBands, liveBands)", clear)
        self.assertIn('result[@"liveMatchedSnapshot"] = @(matched)', clear)
        self.assertIn("The setter-in-flight record is missing", clear)
        self.assertNotIn("setActiveBandInfo", clear)

        live_guard = clear.index("CCNMDictionariesEqual(snapshotBands, liveBands)")
        cleanup_kind = clear.index("NSString *cleanupKind = legacyNR78MarkerlessMigration", live_guard)
        cleanup_handoff = clear.index("CCNMInstallRecoveryCleanupMarker(cleanupKind", cleanup_kind)
        cleanup_resume = clear.index("CCNMResumeRecoveryCleanupMarker", cleanup_handoff)
        self.assertLess(live_guard, cleanup_kind)
        self.assertLess(cleanup_kind, cleanup_handoff)
        self.assertLess(cleanup_handoff, cleanup_resume)

    def test_restore_marker_cannot_be_bypassed_by_new_writes_or_cleanup(self):
        # A restore marker represents a recovery setter, so no new test setter may
        # begin while it remains. It must also be verified and retired as the last
        # recovery record after a known-good live read-back.
        for method_start, method_end in (
            ("- (void)confirmSameValueBandWrite", "- (void)confirmRestoreBandSnapshot"),
            ("- (void)confirmColdBandRemovalWrite", "- (void)confirmLTEB1BandWrite"),
            ("- (void)confirmLTEB1BandWrite", "- (void)confirmClearProbeState"),
        ):
            confirm = method(method_start, method_end)
            self.assertIn("CCNMBandRestoreInFlightPath()", confirm)

        for method_start, method_end in (
            ("- (void)runSameValueBandWrite", "- (void)runColdBandRemovalWrite"),
            ("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite"),
            ("- (void)runLTEB1BandWrite", "- (void)restoreSavedBandSnapshot"),
        ):
            run = method(method_start, method_end)
            preflight_start = run.index("if (!failure && ([[NSFileManager defaultManager]")
            preflight_end = run.index('failure = @"Saved Band probe state already exists.', preflight_start)
            self.assertIn("CCNMBandRestoreInFlightPath()", run[preflight_start:preflight_end])

        clear_confirm = method("- (void)confirmClearProbeState", "- (void)clearSavedProbeState")
        self.assertIn("NSDictionary *restoreInFlight", clear_confirm)
        self.assertIn("CCNMValidateRestoreInFlightRecord", clear_confirm)

        clear = method("- (void)clearSavedProbeState", "- (void)runSameValueBandWrite")
        manual = method("- (void)restoreSavedBandSnapshot", "- (void)resumeRecoveryCleanup")
        self.assertIn("NSDictionary *restoreInFlight", clear)
        self.assertIn("CCNMValidateRestoreInFlightRecord", clear)
        self.assertIn("CCNMRemoveRestoreInFlightRecord", clear)
        live_guard = clear.index("CCNMDictionariesEqual(snapshotBands, liveBands)")
        restore_remove = clear.index("CCNMRemoveRestoreInFlightRecord")
        cleanup_handoff = clear.index("CCNMInstallRecoveryCleanupMarker(cleanupKind")
        self.assertLess(live_guard, restore_remove)
        self.assertLess(restore_remove, cleanup_handoff)

        self.assertIn("NSDictionary *restoreInFlight", manual)
        self.assertIn("CCNMValidateRestoreInFlightRecord", manual)
        self.assertIn("CCNMRestoreActiveBands", manual)
        self.assertIn("CCNMRemoveVerifiedBandRecoveryRecords", manual)
        verified_cleanup = SOURCE[
            SOURCE.index("static BOOL CCNMRemoveVerifiedBandRecoveryRecords"):
            SOURCE.index("static const char *CCNMSkipTypeQualifiers")
        ]
        self.assertIn("CCNMInstallRecoveryCleanupMarker", verified_cleanup)
        self.assertIn("CCNMResumeRecoveryCleanupMarker", verified_cleanup)

    def test_manual_cleanup_uses_durable_handoff_before_payload_removal(self):
        manual = method("- (void)restoreSavedBandSnapshot", "- (void)resumeRecoveryCleanup")
        self.assertIn("CCNMRemoveVerifiedBandRecoveryRecords", manual)
        verified_cleanup = SOURCE[
            SOURCE.index("static BOOL CCNMRemoveVerifiedBandRecoveryRecords"):
            SOURCE.index("static const char *CCNMSkipTypeQualifiers")
        ]
        install = verified_cleanup.index('CCNMInstallRecoveryCleanupMarker(@"verified_restore"')
        resume = verified_cleanup.index("CCNMResumeRecoveryCleanupMarker", install)
        self.assertLess(install, resume)

        cleanup_resume = SOURCE[
            SOURCE.index("static BOOL CCNMResumeRecoveryCleanupMarker"):
            SOURCE.index("static BOOL CCNMRemoveUnattemptedBandRecoveryRecords")
        ]
        snapshot_remove = cleanup_resume.index('CCNMRemoveExpectedRecoveryRecordDuringCleanup(cleanupMarker[@"snapshot"]')
        intent_remove = cleanup_resume.index('CCNMRemoveExpectedRecoveryRecordDuringCleanup(cleanupMarker[@"writeIntent"]')
        marker_remove = cleanup_resume.index("CCNMRemoveExpectedRecoveryRecord(cleanupMarker")
        self.assertLess(snapshot_remove, intent_remove)
        self.assertLess(intent_remove, marker_remove)

    def test_removal_experiment_is_narrow_and_reversible(self):
        self.assertIn('static NSString *const CCNMRemovalRATKey = @"kCTRegistrationRadioAccessTechnologyLTE"', SOURCE)
        self.assertIn("return @[@48, @46];", SOURCE)
        self.assertIn("CCNMValidateSingleBandRemoval", SOURCE)
        self.assertIn("CCNMBuildSingleRemovalBands(originalBands, supportedBands", SOURCE)
        removal = method("- (void)runColdBandRemovalWrite", "- (void)runLTEB1BandWrite")
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

    def test_ui_does_not_promise_uninterrupted_service(self):
        confirm = method("- (void)confirmColdBandRemovalWrite", "- (void)confirmLTEB1BandWrite")
        # The build never reads the serving band, so it must not claim service is safe.
        for forbidden in (
            "so service should not drop",
            "cannot carry a primary registration",
        ):
            self.assertNotIn(forbidden, confirm)
        self.assertIn("does not read the serving band", confirm)
        self.assertIn("may temporarily lose cellular service", confirm)
        self.assertIn("Restore Saved Band Snapshot", confirm)
        self.assertNotIn("cannot carry a primary registration", SOURCE)
        self.assertNotIn("cannot drop service even if every recovery path fails", PLAN)
        self.assertIn("never reads the serving band", PLAN)

    def test_ui_requires_explicit_confirmation(self):
        plist = plistlib.loads((ROOT / "networkmanagerprefs/Resources/Root.plist").read_bytes())
        actions = [item.get("action") for item in plist["items"] if item.get("action")]
        self.assertEqual(actions.count("confirmSameValueBandWrite:"), 1)
        self.assertEqual(actions.count("confirmColdBandRemovalWrite:"), 1)
        self.assertEqual(actions.count("confirmLTEB1BandWrite:"), 1)
        self.assertEqual(actions.count("confirmRestoreBandSnapshot:"), 1)
        self.assertEqual(actions.count("confirmClearProbeState:"), 1)
        self.assertIn("UIAlertActionStyleDestructive", SOURCE)

    def test_control_center_radio_setter_shares_the_recovery_fence(self):
        setter = CONTROL_CENTER_SOURCE[CONTROL_CENTER_SOURCE.index("- (void)setSelected:"): CONTROL_CENTER_SOURCE.index("@end")]
        lock = setter.index("CCNMAcquireBandRecoveryLock")
        marker_gate = setter.index("CCNMBandRecoveryStateExists")
        rat_setter = setter.index("_CTServerConnectionSetRATSelection")
        release = setter.index("CCNMReleaseBandRecoveryLock", rat_setter)
        self.assertLess(lock, marker_gate)
        self.assertLess(marker_gate, rat_setter)
        self.assertLess(rat_setter, release)
        self.assertIn("LOCK_EX | LOCK_NB", CONTROL_CENTER_SOURCE)
        for suffix in (
            "bandwrite.snapshot.plist",
            "bandwrite.intent.plist",
            "bandwrite.setter-inflight.plist",
            "bandwrite.restore-inflight.plist",
        ):
            self.assertIn(suffix, CONTROL_CENTER_SOURCE)

    def test_build_baseline_is_unchanged(self):
        subprocess.run(
            ["git", "diff", "--exit-code", BASELINE, "--", "Makefile", ".github/workflows/build.yml"],
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
        self.assertIn("A restore marker is never exempt", PLAN)
        self.assertIn("snapshot-mismatched markers block new test writes", PLAN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
