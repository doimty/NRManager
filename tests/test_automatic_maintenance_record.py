#!/usr/bin/env python3
"""
Tests for CCNMAutomaticMaintenanceRecord: record building, persistence,
status construction, validation, and identity drift detection.
"""
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "networkmanagerprefs" / "CCNMAutomaticMaintenanceRecord.m"
HEADER = ROOT / "networkmanagerprefs" / "CCNMAutomaticMaintenanceRecord.h"
READER_SOURCE = ROOT / "networkmanagerprefs" / "CCNMN78PolicyReader.m"
SUPPORT_SOURCE = ROOT / "networkmanagerprefs" / "CCNMN78PolicySupport.m"
DECISION_SOURCE = ROOT / "networkmanagerprefs" / "CCNMAutomaticMaintenanceDecision.c"
HEADER_DIR = ROOT / "networkmanagerprefs"

# Check if Foundation is available on this host for ObjC compilation tests.
# A bounded probe timeout means this host cannot provide a usable Foundation
# toolchain for these optional host-side tests; package builds still compile
# their Objective-C sources in the pinned macOS lane.
try:
    _foundation_check = subprocess.run(
        ["clang", "-x", "objective-c", "-E", "-", "-framework", "Foundation"],
        input="#import <Foundation/Foundation.h>\n",
        capture_output=True,
        text=True,
        timeout=5,
    )
    _FOUNDATION_AVAILABLE = _foundation_check.returncode == 0
except subprocess.TimeoutExpired:
    _FOUNDATION_AVAILABLE = False

skip_unless_foundation = unittest.skipIf(
    not _FOUNDATION_AVAILABLE,
    "Foundation framework is not available on this host; skipping ObjC compilation tests.",
)

HARNESS = r'''
#import <Foundation/Foundation.h>
#import "CCNMAutomaticMaintenanceRecord.h"
#import "CCNMN78PolicyReader.h"

static CCNMAutomaticMaintenanceSample makeSample(BOOL valid, BOOL stale,
    BOOL unsafe, CCNMAutomaticMaintenanceRAT rat, int band) {
    CCNMAutomaticMaintenanceSample s = { valid, stale, unsafe, rat, band };
    return s;
}

static NSDictionary *makePolicySummary(BOOL success, NSString *requested,
    NSString *applied, NSString *recovery, BOOL baselinePresent,
    BOOL baselineValid, BOOL transitionPresent, BOOL removalGuardPresent,
    BOOL uncertain) {
    return @{
        CCNMN78PolicySummarySuccessKey: @(success),
        CCNMN78PolicySummaryRequestedModeKey: requested ?: CCNMRequestedModeSystemDefault,
        CCNMN78PolicySummaryAppliedPolicyKey: applied ?: CCNMAppliedPolicyVerifiedSystemDefault,
        CCNMN78PolicySummaryRecoveryStateKey: recovery ?: CCNMRecoveryStateClean,
        @"baselinePresent": @(baselinePresent),
        @"baselineValid": @(baselineValid),
        @"transitionPresent": @(transitionPresent),
        @"removalGuardPresent": @(removalGuardPresent),
        @"uncertain": @(uncertain),
        @"operationGeneration": @1,
        @"statePath": @"/tmp/test-state.plist",
        @"baselinePath": @"/tmp/test-baseline.plist",
        @"intentPath": @"/tmp/test-intent.plist",
        @"inFlightPath": @"/tmp/test-inflight.plist",
        @"lockPath": @"/tmp/test-lock",
        @"removalGuardPath": @"/tmp/test-removal-guard.plist",
        CCNMN78PolicySummaryStateKey: @{
            @"operationGeneration": @1,
            @"requestedMode": requested ?: CCNMRequestedModeSystemDefault,
            @"appliedPolicy": applied ?: CCNMAppliedPolicyVerifiedSystemDefault,
            @"recoveryState": recovery ?: CCNMRecoveryStateClean
        }
    };
}

static NSDictionary *makeIdentity(NSString *device, NSString *version,
    NSString *build, NSString *uuid) {
    return @{
        @"deviceModel": device ?: @"iPhone14,3",
        @"systemVersion": version ?: @"15.1.1",
        @"systemBuild": build ?: @"19B81",
        @"subscriptionUUID": uuid ?: @"00000000-0000-0000-0000-000000000001",
        @"slotID": @1,
        CCNMARecordCapabilityReadSuccessKey: @YES,
        CCNMARecordCapabilityN78SupportedKey: @YES,
        CCNMARecordCapabilityN78ActiveKey: @YES,
        CCNMARecordCapabilitySupportedNRBandsKey: @[ @28, @41, @78 ],
        CCNMARecordCapabilityActiveNRBandsKey: @[ @78 ],
        CCNMARecordCapabilitySupportedRATKeysKey: @[
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid",
            @"kCTRegistrationRadioAccessTechnologyGSM",
            @"kCTRegistrationRadioAccessTechnologyLTE",
            @"kCTRegistrationRadioAccessTechnologyNR",
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA",
            @"kCTRegistrationRadioAccessTechnologyUTRAN"
        ]
    };
}

int main(void) {
    // test 1: CCNMABuildRecord with valid inputs
    NSDictionary *policy = makePolicySummary(YES, CCNMRequestedModeN78Preferred,
        CCNMAppliedPolicyVerifiedN78Only, CCNMRecoveryStateEnabledWithBaseline,
        YES, YES, NO, NO, NO);
    NSDictionary *identity = makeIdentity(nil, nil, nil, nil);
    CCNMAutomaticMaintenanceSample prev = makeSample(YES, NO, NO,
        CCNMAutomaticMaintenanceRATLTE, 1);
    CCNMAutomaticMaintenanceSample curr = makeSample(YES, NO, NO,
        CCNMAutomaticMaintenanceRATLTE, 3);
    NSDictionary *record = CCNMABuildRecord(policy, identity, prev, curr,
        1, @1234567890000, CCNMAutomaticMaintenanceAwaitEvidence, nil);
    if (!record) return 1;
    if (![record[CCNMARecordSchemaVersionKey] isEqual:@2]) return 2;
    if (![record[CCNMARecordOwnerKey] isEqual:@"com.doimty.nrmanager.automatic-maintenance"]) return 3;
    if (![record[CCNMARecordDeviceModelKey] isEqual:@"iPhone14,3"]) return 4;
    if (![record[CCNMARecordSystemVersionKey] isEqual:@"15.1.1"]) return 5;
    if (![record[CCNMARecordSystemBuildKey] isEqual:@"19B81"]) return 6;
    if (![record[CCNMARecordDropGenerationKey] isEqual:@0]) return 7;
    if (![record[CCNMARecordAttemptConsumedKey] isEqual:@NO]) return 8;
    if (![record[CCNMARecordLastDecisionKey] isEqual:@"awaitEvidence"]) return 9;
    NSDictionary *sampleDict = record[CCNMARecordCurrentSampleKey];
    if (![sampleDict isKindOfClass:NSDictionary.class]) return 10;
    if (![sampleDict[CCNMARecordSampleValidKey] isEqual:@YES]) return 11;
    if (![sampleDict[CCNMARecordSampleBandKey] isEqual:@3]) return 12;
    // Cache identity from existing record
    NSDictionary *record2 = CCNMABuildRecord(policy, identity, prev, curr,
        1, @1234567890000, CCNMAutomaticMaintenanceAwaitEvidence, record);
    if (!record2) return 13;
    if (![record2[CCNMARecordDropGenerationKey] isEqual:@0]) return 14;
    // CorrectOnce -> new drop
    CCNMAutomaticMaintenanceSample nr41 = makeSample(YES, NO, NO,
        CCNMAutomaticMaintenanceRATNR, 41);
    CCNMAutomaticMaintenanceSample nr41b = makeSample(YES, NO, NO,
        CCNMAutomaticMaintenanceRATNR, 41);
    NSDictionary *record3 = CCNMABuildRecord(policy, identity, nr41, nr41b,
        1, @1234567890000, CCNMAutomaticMaintenanceCorrectOnce, record2);
    if (!record3) return 15;
    if (![record3[CCNMARecordDropGenerationKey] isEqual:@1]) return 16;
    if (![record3[CCNMARecordDropRATKey] isEqual:@(CCNMAutomaticMaintenanceRATNR)]) return 17;
    if (![record3[CCNMARecordDropBandKey] isEqual:@41]) return 18;
    if (![record3[CCNMARecordVerificationPendingKey] isEqual:@NO]) return 19;
    // A second identical refresh feeds the pending bit back into the decision and
    // must preserve the original drop generation rather than inventing another.
    if (!CCNMARecordMatchesCurrentContext(record3, identity,
            1, @1234567890000)) return 60;
    if (CCNMARecordMatchesCurrentContext(record3, identity,
            2, @1234567890000)) return 61;
    if (CCNMARecordMatchesCurrentContext(record3, identity,
            1, @1234567890001)) return 62;
    NSDictionary *record4 = CCNMABuildRecord(policy, identity, nr41, nr41b,
        1, @1234567890000, CCNMAutomaticMaintenanceDropRecorded, record3);
    if (![record4[CCNMARecordDropGenerationKey] isEqual:@1]) return 63;
    if (![record4[CCNMARecordVerificationPendingKey] isEqual:@NO]) return 64;
    if (![record4[CCNMARecordLastDecisionKey] isEqual:@"dropRecorded"]) return 68;
    // CCNMAValidateRecord
    if (!CCNMAValidateRecord(record)) return 20;
    if (!CCNMAValidateRecord(record3)) return 21;
    // bad: wrong schema version
    NSMutableDictionary *bad = [record mutableCopy];
    bad[CCNMARecordSchemaVersionKey] = @999;
    if (CCNMAValidateRecord(bad)) return 22;
    // bad: missing owner
    bad = [record mutableCopy];
    [bad removeObjectForKey:CCNMARecordOwnerKey];
    if (CCNMAValidateRecord(bad)) return 23;
    // bad: empty device model
    bad = [record mutableCopy];
    bad[CCNMARecordDeviceModelKey] = @"";
    if (CCNMAValidateRecord(bad)) return 24;
    bad = [record mutableCopy];
    bad[CCNMARecordVerificationPendingKey] = @"yes";
    if (CCNMAValidateRecord(bad)) return 65;
    bad = [record mutableCopy];
    bad[CCNMARecordCooldownUntilKey] = @"later";
    if (CCNMAValidateRecord(bad)) return 66;
    bad = [record mutableCopy];
    [bad removeObjectForKey:CCNMARecordLastDecisionAtKey];
    if (CCNMAValidateRecord(bad)) return 67;
    // CCNMAValidateStatus
    NSDictionary *emptyServing = @{
        @"state": @"",
        @"band": @0,
        @"success": @NO
    };
    CCNMAutomaticMaintenanceSample empty = {0};
    NSDictionary *status = CCNMABuildStatus(policy, emptyServing, record3,
        CCNMAutomaticMaintenanceCorrectOnce, empty, empty, NO);
    if (!status) return 25;
    if (!CCNMAValidateStatus(status)) return 26;
    if (![status[CCNMAStatusLastDecisionKey] isEqual:@"correctOnce"]) return 27;
    if (![status[CCNMAStatusDropGenerationKey] isEqual:@1]) return 28;
    if (![status[CCNMAStatusAttemptConsumedKey] isEqual:@NO]) return 29;
    // CCNMARecordMatchesCurrentIdentity
    if (!CCNMARecordMatchesCurrentIdentity(record, identity)) return 30;
    // mismatch: different device model
    NSDictionary *diffIdentity = makeIdentity(@"iPhone15,2", @"16.0", @"20A357", nil);
    if (CCNMARecordMatchesCurrentIdentity(record, diffIdentity)) return 31;
    // mismatch: different system version
    diffIdentity = makeIdentity(@"iPhone14,3", @"16.0", @"19B81", nil);
    if (CCNMARecordMatchesCurrentIdentity(record, diffIdentity)) return 32;
    // Missing current SIM identity must fail closed.
    NSDictionary *identityNoUUID = makeIdentity(@"iPhone14,3", @"15.1.1", @"19B81", @"");
    if (CCNMARecordMatchesCurrentIdentity(record, identityNoUUID)) return 33;
    // CCNMADecisionName and CCNMARATName
    if (![CCNMADecisionName(CCNMAutomaticMaintenanceAwaitEvidence) isEqual:@"awaitEvidence"]) return 34;
    if (![CCNMADecisionName(CCNMAutomaticMaintenanceCorrectOnce) isEqual:@"correctOnce"]) return 35;
    if (![CCNMADecisionName(CCNMAutomaticMaintenanceTargetStable) isEqual:@"targetStable"]) return 36;
    if (![CCNMARATName(CCNMAutomaticMaintenanceRATLTE) isEqual:@"lte"]) return 37;
    if (![CCNMARATName(CCNMAutomaticMaintenanceRATNR) isEqual:@"nr"]) return 38;
    if (![CCNMARATName((CCNMAutomaticMaintenanceRAT)99) isEqual:@"unknown"]) return 39;
    // Status with disabled policy
    NSDictionary *disabledPolicy = makePolicySummary(YES, CCNMRequestedModeSystemDefault,
        CCNMAppliedPolicyVerifiedSystemDefault, CCNMRecoveryStateClean, NO, NO, NO, NO, NO);
    NSDictionary *disabledStatus = CCNMABuildStatus(disabledPolicy, emptyServing, nil,
        CCNMAutomaticMaintenanceDisabled, empty, empty, NO);
    if (!disabledStatus) return 40;
    if (![disabledStatus[CCNMAStatusPolicyEnabledKey] isEqual:@NO]) return 41;
    if (![disabledStatus[CCNMAStatusLastDecisionKey] isEqual:@"disabled"]) return 42;
    return 0;
}
'''

HARNESS_DECISION_NAMES = r'''
#import <Foundation/Foundation.h>
#import "CCNMAutomaticMaintenanceRecord.h"

int main(void) {
    for (CCNMAutomaticMaintenanceDecision d = 0; d <= CCNMAutomaticMaintenanceStopUnsafe; d++) {
        NSString *name = CCNMADecisionName(d);
        if (![name isKindOfClass:NSString.class] || name.length == 0) return (int)d + 1;
    }
    return 0;
}
'''


class AutomaticMaintenanceRecordTests(unittest.TestCase):
    @skip_unless_foundation
    def test_record_module_compiles(self):
        self.assertTrue(SOURCE.exists(), SOURCE)
        self.assertTrue(HEADER.exists(), HEADER)

    @skip_unless_foundation
    def test_record_building_and_validation(self):
        self.assertTrue(SOURCE.exists(), SOURCE)
        with tempfile.TemporaryDirectory() as temporary:
            harness = pathlib.Path(temporary) / "record_harness.c"
            executable = pathlib.Path(temporary) / "record_harness"
            harness.write_text(textwrap.dedent(HARNESS))
            compiled = subprocess.run(
                [
                    "clang", "-std=c11", "-x", "objective-c",
                    "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                    "-Wno-unused-variable",
                    "-I", str(HEADER_DIR),
                    "-fno-objc-arc",
                    "-framework", "Foundation",
                    str(harness),
                    str(SOURCE),
                    str(READER_SOURCE),
                    str(SUPPORT_SOURCE),
                    str(DECISION_SOURCE),
                    "-o", str(executable),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0,
                f"compile failed:\n{compiled.stderr}\n{compiled.stdout}")
            result = subprocess.run([str(executable)],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0,
                f"run failed code {result.returncode}:\n{result.stderr}\n{result.stdout}")

    @skip_unless_foundation
    def test_all_decision_names_are_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            harness = pathlib.Path(temporary) / "decision_names_harness.c"
            executable = pathlib.Path(temporary) / "decision_names_harness"
            harness.write_text(textwrap.dedent(HARNESS_DECISION_NAMES))
            compiled = subprocess.run(
                [
                    "clang", "-std=c11", "-x", "objective-c",
                    "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                    "-I", str(HEADER_DIR),
                    "-fno-objc-arc",
                    "-framework", "Foundation",
                    str(harness),
                    str(SOURCE),
                    str(READER_SOURCE),
                    str(SUPPORT_SOURCE),
                    str(DECISION_SOURCE),
                    "-o", str(executable),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0,
                f"compile failed:\n{compiled.stderr}")
            result = subprocess.run([str(executable)],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0,
                f"run failed code {result.returncode}")

    def test_record_is_linked_into_daemon_makefile(self):
        makefile = (ROOT / "maintenance-daemon" / "Makefile").read_text()
        self.assertIn("CCNMAutomaticMaintenanceRecord.m", makefile)

    def test_daemon_persists_record_and_status(self):
        source = (ROOT / "maintenance-daemon" / "main.m").read_text()
        record_source = SOURCE.read_text()
        self.assertIn("CCNMAWriteRecord", source)
        self.assertIn("CCNMAWriteStatus", source)
        self.assertIn("CCNMAReadRecord", source)
        self.assertIn("CCNMABuildStatus", source)
        self.assertIn("CCNMABuildRecord", source)
        self.assertIn("CCNMServingStatusEmptySummary", source)
        self.assertIn("CCNMARecordCapabilitySupportedNRBandsKey", record_source)
        self.assertIn("CCNMAIdentitySnapshotMatchesRecord", record_source)
        self.assertIn("sameContext &&", record_source)
        self.assertIn("CCNMARecordMatchesCurrentContext", record_source)
        self.assertIn("Missing current SIM identity", HARNESS)

    def test_header_exports_path_functions(self):
        header = HEADER.read_text()
        for key in (
            "CCNMARecordCapabilityReadSuccessKey",
            "CCNMARecordCapabilityN78SupportedKey",
            "CCNMARecordCapabilityN78ActiveKey",
            "CCNMARecordCapabilitySupportedNRBandsKey",
            "CCNMARecordCapabilityActiveNRBandsKey",
            "CCNMARecordCapabilitySupportedRATKeysKey",
        ):
            self.assertIn(key, header)
        self.assertIn("CCNMAutomaticMaintenanceRecordPath", header)
        self.assertIn("CCNMAutomaticMaintenanceStatusPath", header)
        self.assertIn("CCNMAValidateRecord", header)
        self.assertIn("CCNMAValidateStatus", header)
        self.assertIn("CCNMARecordMatchesCurrentIdentity", header)

    def test_record_context_includes_policy_and_baseline_identity(self):
        header = HEADER.read_text()
        source = SOURCE.read_text()
        self.assertIn("static const long long CCNMASchemaVersion = 2", source)
        self.assertIn("CCNMARecordMatchesCurrentContext", header)
        context = source[source.index("BOOL CCNMARecordMatchesCurrentContext"):]
        self.assertIn("CCNMARecordPolicyGenerationKey", context)
        self.assertIn("CCNMARecordBaselineCreatedAtKey", context)
        self.assertIn("CCNMARecordMatchesCurrentIdentity", context)
        builder = source[source.index("NSDictionary *CCNMABuildRecord"):]
        self.assertIn("CCNMARecordMatchesCurrentContext", builder)

    def test_decision_feedback_fields_are_required_by_record_validation(self):
        source = SOURCE.read_text()
        validation = source[source.index("BOOL CCNMAValidateRecord"):source.index(
            "BOOL CCNMAValidateStatus")]
        self.assertIn("CCNMARecordVerificationPendingKey", validation)
        self.assertIn("CCNMARecordCooldownUntilKey", validation)
        self.assertIn("CCNMARecordLastDecisionAtKey", validation)

    def test_record_contains_no_writer_code(self):
        source = SOURCE.read_text()
        for forbidden in (
            "setActiveBandInfo",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "CCNMAcquirePolicyLock",
            "CCNMReleasePolicyLock",
            "CCNMCreateDurableRecord",
            "CCNMReplaceDurableRecord",
            "CCNMBeginSetter",
            "CCNMCallSetter",
            "CCNMSetterUncertainLatch",
        ):
            self.assertNotIn(forbidden, source,
                f"Record module contains forbidden: {forbidden}")


if __name__ == "__main__":
    unittest.main(verbosity=2)