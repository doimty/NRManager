#!/usr/bin/env python3
"""Behavioral host tests for serving-cell probe support logic."""

import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUPPORT_HEADER = ROOT / "networkmanagerprefs/CCNMServingCellProbeSupport.h"
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
ROOT_PLIST = ROOT / "networkmanagerprefs/Resources/Root.plist"
CONTROL = ROOT / "control"


def source_method(start: str, end: str) -> str:
    start_index = SOURCE.index(start)
    return SOURCE[start_index:SOURCE.index(end, start_index)]


class ServingCellProbeSupportTests(unittest.TestCase):
    def test_public_nr_frequency_range_uses_known_ios_bitmask_values(self):
        self.assertTrue(SUPPORT_HEADER.exists(), "serving-cell support header is missing")
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "host C compiler is unavailable")

        program = r'''
#include "networkmanagerprefs/CCNMServingCellProbeSupport.h"

int main(void) {
    if (CCNMClassifyPublicNRFrequencyRange(0) != CCNMPublicNRFrequencyRangeUnknown) return 1;
    if (CCNMClassifyPublicNRFrequencyRange(4) != CCNMPublicNRFrequencyRangeSub6) return 2;
    if (CCNMClassifyPublicNRFrequencyRange(8) != CCNMPublicNRFrequencyRangeMmWave) return 3;
    if (CCNMClassifyPublicNRFrequencyRange(12) != CCNMPublicNRFrequencyRangeSub6AndMmWave) return 4;
    if (CCNMClassifyPublicNRFrequencyRange(1) != CCNMPublicNRFrequencyRangeUnknown) return 5;
    if (CCNMClassifyPublicNRFrequencyRange(5) != CCNMPublicNRFrequencyRangeUnknown) return 6;
    if (!CCNMProbeWaitCompleted(0)) return 7;
    if (CCNMProbeWaitCompleted(1)) return 8;
    if (CCNMProbeWaitCompleted(-1)) return 9;
    if (CCNMClassifyCellMonitorSamplingStatus(10, 10, 10) != CCNMCellMonitorSamplingComplete) return 10;
    if (CCNMClassifyCellMonitorSamplingStatus(10, 2, 1) != CCNMCellMonitorSamplingPartial) return 11;
    if (CCNMClassifyCellMonitorSamplingStatus(10, 10, 9) != CCNMCellMonitorSamplingPartial) return 12;
    if (CCNMClassifyCellMonitorSamplingStatus(10, 1, 0) != CCNMCellMonitorSamplingFailed) return 13;
    if (CCNMClassifyCellMonitorSamplingStatus(0, 0, 0) != CCNMCellMonitorSamplingFailed) return 14;
    if (CCNMCellMonitorRATIsNR(NULL)) return 15;
    if (CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyLTE")) return 16;
    if (!CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyNR")) return 17;
    if (!CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyNRNSA")) return 18;
    if (CCNMCellMonitorRATIsNR("prefixRadioAccessTechnologyNRsuffix")) return 34;
    if (!CCNMCellMonitorShouldRefresh(CCNMCellMonitorRefreshOncePerPhase, 0)) return 19;
    if (CCNMCellMonitorShouldRefresh(CCNMCellMonitorRefreshOncePerPhase, 1)) return 20;
    if (!CCNMCellMonitorShouldRefresh(CCNMCellMonitorRefreshBeforeEachCopy, 0)) return 21;
    if (!CCNMCellMonitorShouldRefresh(CCNMCellMonitorRefreshBeforeEachCopy, 4)) return 22;
    if (CCNMCellMonitorShouldRefresh((CCNMCellMonitorRefreshPolicy)99, 0)) return 23;
    if (CCNMCellMonitorRequiredRefreshCount(CCNMCellMonitorRefreshOncePerPhase, 5) != 1) return 24;
    if (CCNMCellMonitorRequiredRefreshCount(CCNMCellMonitorRefreshBeforeEachCopy, 5) != 5) return 25;
    if (CCNMCellMonitorRequiredRefreshCount(CCNMCellMonitorRefreshBeforeEachCopy, 0) != 0) return 26;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 10, 10, 10, 10, 6, 6, 6, 6) != CCNMCellMonitorSamplingComplete) return 27;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 10, 10, 10, 10, 6, 6, 6, 5) != CCNMCellMonitorSamplingPartial) return 28;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 10, 10, 10, 9, 6, 6, 6, 6) != CCNMCellMonitorSamplingPartial) return 29;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 2, 2, 1, 1, 6, 1, 1, 1) != CCNMCellMonitorSamplingPartial) return 30;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 3, 3, 3, 3, 6, 2, 2, 2) != CCNMCellMonitorSamplingPartial) return 31;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 9, 9, 9, 9, 6, 6, 6, 6) != CCNMCellMonitorSamplingPartial) return 32;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 0, 0, 0, 0, 6, 1, 1, 1) != CCNMCellMonitorSamplingFailed) return 33;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 9, 10, 10, 10, 6, 6, 6, 6) != CCNMCellMonitorSamplingPartial) return 42;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 10, 10, 9, 10, 6, 6, 6, 6) != CCNMCellMonitorSamplingPartial) return 43;
    if (CCNMClassifyCellMonitorABSamplingStatus(10, 10, 10, 10, 10, 6, 5, 6, 6) != CCNMCellMonitorSamplingPartial) return 44;
    if (!CCNMPrivateAsyncAttemptRequiresAbort(1, 0)) return 35;
    if (!CCNMPrivateAsyncAttemptRequiresAbort(0, 1)) return 36;
    if (CCNMPrivateAsyncAttemptRequiresAbort(0, 0)) return 37;
    if (!CCNMCellMonitorClassificationSymbolsAvailable(1, 1, 1)) return 45;
    if (CCNMCellMonitorClassificationSymbolsAvailable(0, 1, 1)) return 46;
    if (CCNMCellMonitorClassificationSymbolsAvailable(1, 0, 1)) return 47;
    if (CCNMCellMonitorClassificationSymbolsAvailable(1, 1, 0)) return 48;
    if (CCNMClassifyNRObservationStatus(1, CCNMCellMonitorSamplingPartial) != CCNMNRObservationObserved) return 38;
    if (CCNMClassifyNRObservationStatus(0, CCNMCellMonitorSamplingComplete) != CCNMNRObservationNotObservedComplete) return 39;
    if (CCNMClassifyNRObservationStatus(0, CCNMCellMonitorSamplingPartial) != CCNMNRObservationIndeterminatePartial) return 40;
    if (CCNMClassifyNRObservationStatus(0, CCNMCellMonitorSamplingFailed) != CCNMNRObservationIndeterminatePartial) return 41;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp_dir:
            executable = Path(temp_dir) / "nr-frequency-range-test"
            compile_result = subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(ROOT),
                    "-x",
                    "c",
                    "-",
                    "-o",
                    str(executable),
                ],
                input=program,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(run_result.returncode, 0, run_result.stderr)

    def test_ab_orchestration_reducer_executes_required_traces_and_abort_policy(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "host C compiler is unavailable")

        program = r'''
#include <string.h>
#include "networkmanagerprefs/CCNMServingCellProbeSupport.h"

static int append_operation(char *trace, size_t *length, CCNMCellMonitorOrchestrationOperation operation) {
    if (*length >= 31) return 0;
    trace[(*length)++] = operation == CCNMCellMonitorOrchestrationRefresh ? 'R' : 'C';
    trace[*length] = '\0';
    return 1;
}

int main(void) {
    CCNMCellMonitorOrchestrationState normal = CCNMCellMonitorOrchestrationStart(5);
    char trace[32] = {0};
    size_t traceLength = 0;
    size_t refreshCount = 0;
    size_t copyCount = 0;
    while (!CCNMCellMonitorOrchestrationIsDone(&normal)) {
        if (!append_operation(trace, &traceLength, normal.nextOperation)) return 1;
        if (normal.nextOperation == CCNMCellMonitorOrchestrationRefresh) refreshCount++;
        if (normal.nextOperation == CCNMCellMonitorOrchestrationCopy) copyCount++;
        if (!CCNMCellMonitorOrchestrationAdvance(&normal, CCNMCellMonitorOrchestrationSucceeded)) return 2;
    }
    if (strcmp(trace, "RCCCCCRCRCRCRCRC") != 0) return 3;
    if (refreshCount != 6 || copyCount != 10) return 4;
    if (normal.abortedAfterTimeout || normal.abortedAfterInvocationException) return 5;

    CCNMCellMonitorOrchestrationState phaseAFailure = CCNMCellMonitorOrchestrationStart(5);
    if (!CCNMCellMonitorOrchestrationMatches(&phaseAFailure, 0, 0, CCNMCellMonitorOrchestrationRefresh)) return 6;
    if (!CCNMCellMonitorOrchestrationAdvance(&phaseAFailure, CCNMCellMonitorOrchestrationRecoverableFailure)) return 7;
    if (!CCNMCellMonitorOrchestrationMatches(&phaseAFailure, 1, 0, CCNMCellMonitorOrchestrationRefresh)) return 8;
    refreshCount = 1;
    copyCount = 0;
    while (!CCNMCellMonitorOrchestrationIsDone(&phaseAFailure)) {
        if (phaseAFailure.nextOperation == CCNMCellMonitorOrchestrationRefresh) refreshCount++;
        if (phaseAFailure.nextOperation == CCNMCellMonitorOrchestrationCopy) copyCount++;
        if (!CCNMCellMonitorOrchestrationAdvance(&phaseAFailure, CCNMCellMonitorOrchestrationSucceeded)) return 9;
    }
    if (refreshCount != 6 || copyCount != 5) return 10;

    CCNMCellMonitorOrchestrationState phaseBFailure = CCNMCellMonitorOrchestrationStart(5);
    while (!CCNMCellMonitorOrchestrationMatches(
        &phaseBFailure, 1, 0, CCNMCellMonitorOrchestrationRefresh)) {
        if (!CCNMCellMonitorOrchestrationAdvance(&phaseBFailure, CCNMCellMonitorOrchestrationSucceeded)) return 11;
    }
    if (!CCNMCellMonitorOrchestrationAdvance(&phaseBFailure, CCNMCellMonitorOrchestrationRecoverableFailure)) return 12;
    if (!CCNMCellMonitorOrchestrationMatches(&phaseBFailure, 1, 1, CCNMCellMonitorOrchestrationRefresh)) return 13;

    CCNMCellMonitorOrchestrationState copyTimeout = CCNMCellMonitorOrchestrationStart(5);
    if (!CCNMCellMonitorOrchestrationAdvance(&copyTimeout, CCNMCellMonitorOrchestrationSucceeded)) return 14;
    if (!CCNMCellMonitorOrchestrationMatches(&copyTimeout, 0, 0, CCNMCellMonitorOrchestrationCopy)) return 15;
    if (!CCNMCellMonitorOrchestrationAdvance(&copyTimeout, CCNMCellMonitorOrchestrationTimedOut)) return 16;
    if (!CCNMCellMonitorOrchestrationIsDone(&copyTimeout) || !copyTimeout.abortedAfterTimeout) return 17;
    if (CCNMCellMonitorOrchestrationAdvance(&copyTimeout, CCNMCellMonitorOrchestrationSucceeded)) return 18;

    CCNMCellMonitorOrchestrationState refreshException = CCNMCellMonitorOrchestrationStart(5);
    if (!CCNMCellMonitorOrchestrationAdvance(
        &refreshException, CCNMCellMonitorOrchestrationInvocationException)) return 19;
    if (!CCNMCellMonitorOrchestrationIsDone(&refreshException) ||
        !refreshException.abortedAfterInvocationException) return 20;

    CCNMCellMonitorOrchestrationState empty = CCNMCellMonitorOrchestrationStart(0);
    if (!CCNMCellMonitorOrchestrationIsDone(&empty)) return 21;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp_dir:
            executable = Path(temp_dir) / "cell-monitor-orchestration-test"
            compile_result = subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(ROOT),
                    "-x",
                    "c",
                    "-",
                    "-o",
                    str(executable),
                ],
                input=program,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(run_result.returncode, 0, run_result.stderr)

    def test_probe_records_raw_frequency_range_and_scope(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        self.assertIn('#include "CCNMServingCellProbeSupport.h"', SOURCE)
        self.assertIn("CCNMClassifyPublicNRFrequencyRange(rawValue)", SOURCE)
        self.assertIn("CCNMDescribePublicNRFrequencyRange(frRange)", body)
        self.assertIn('report[@"publicNrFrequencyRangeRaw"] = @(frRange)', body)
        self.assertIn('report[@"publicNrFrequencyRange"]', body)
        self.assertIn('report[@"publicNrFrequencyRangeSyncOut"]', body)
        self.assertIn('report[@"publicNrFrequencyRangeScope"]', body)
        self.assertIn("id frequencyRangeOutput = nil", body)
        self.assertIn("[client getPublicNrFrequencyRangeSync:&frequencyRangeOutput]", body)
        self.assertNotIn("NSError *frError", body)
        self.assertNotIn("if (frRange == 1)", body)
        self.assertNotIn("else if (frRange == 2)", body)
        self.assertNotIn("else if (frRange == 3)", body)

    def test_descriptor_only_selectors_receive_a_service_descriptor(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        rat_selection = source_method(
            "static NSMutableDictionary *CCNMRunRatSelectionAttempt",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        self.assertIn("@protocol CCNMServiceDescriptorFactory", SOURCE)
        self.assertIn("+ (id)descriptorWithSubscriptionContext:(id)context;", SOURCE)
        self.assertIn("CCNMServiceDescriptorForContext(context, &descriptorFailure)", body)
        self.assertNotIn("- (id)descriptor;", SOURCE)
        for call in (
            "[client getCurrentRat:descriptor error:&ratError]",
            "[client getSupports5GStandalone:descriptor error:&saError]",
            "[client getNRDisableStatus:descriptor error:&nrStatusError]",
            "[client getRatSelectionMask:descriptor error:&maskError]",
        ):
            self.assertIn(call, body)
        self.assertNotIn("getNRDisableStatus:completion:", body)
        self.assertIn("[client copyRadioAccessTechnology:context error:&ratTechError]", body)
        self.assertIn("[client getRatSelection:context completion:", rat_selection)

    def test_cell_monitor_symbols_use_c_names_and_missing_keys_are_safe(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        symbols = source_method(
            "static NSArray<NSString *> *CCNMCellMonitorSymbolNames",
            "static NSString *CCNMSysctlString",
        )
        parser = source_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSString *CCNMSysctlString",
        )
        self.assertIn("dlsym(ctHandle, symbolName.UTF8String)", symbols)
        self.assertNotIn('"_" #name', symbols)
        self.assertIn("dispatch_once(&onceToken", symbols)
        self.assertIn("missingSymbols", symbols)
        self.assertIn('report[@"cellMonitorMissingSymbols"]', body)
        self.assertIn("CCNMCellMonitorCriticalClassificationSymbolNames", parser)
        self.assertIn("CCNMCellMonitorClassificationSymbolsAvailable", parser)
        self.assertIn('snapshot[@"cellMonitorCriticalMissingSymbols"]', parser)
        self.assertIn('snapshot[@"cellMonitorClassificationAvailable"]', parser)
        self.assertIn('snapshot[@"cellMonitorSucceeded"] = @(classificationAvailable)', parser)
        self.assertIn("CCNMCellMonitorValue(cellDict, cellMonitorSymbols", parser)
        self.assertNotIn("cellDict[(__bridge NSString *)CCMK_", body)

    def test_ios15_legacy_lte_keys_are_resolved_and_normalized(self):
        parser = source_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSString *CCNMSysctlString",
        )
        symbols = source_method(
            "static NSArray<NSString *> *CCNMCellMonitorSymbolNames",
            "static NSDictionary<NSString *, NSString *> *CCNMCellMonitorSymbols",
        )
        for symbol in (
            "kCTCellMonitorPID",
            "kCTCellMonitorUARFCN",
            "kCTCellMonitorDeploymentType",
        ):
            self.assertIn(f'@"{symbol}"', symbols)
            self.assertIn(
                f'CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"{symbol}")',
                parser,
            )

        self.assertIn("id physicalCellId = pci ?: pid", parser)
        self.assertIn("id frequency = nrarfcn ?: channel ?: uarfcn", parser)
        for field in (
            "pid",
            "uarfcn",
            "deploymentType",
            "physicalCellId",
            "physicalCellIdSource",
            "frequency",
            "frequencySource",
        ):
            self.assertIn(f'CCNMSetProbeField(parsed, @"{field}"', parser)

    def test_ab_sampling_preserves_phase_refresh_copy_and_nr_evidence(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        self.assertIn("CCNMCellMonitorPhaseSampleCount = 5", SOURCE)
        self.assertIn("CCNMCellMonitorPhaseCount = 2", SOURCE)
        self.assertIn("CCNMCellMonitorAttemptTimeoutSeconds = 5", SOURCE)
        self.assertIn("CCNMCellMonitorRefreshBeforeCopyDelayMicroseconds = 500000", SOURCE)
        self.assertIn(
            "CCNMCellMonitorSampleCount = CCNMCellMonitorPhaseSampleCount * CCNMCellMonitorPhaseCount",
            SOURCE,
        )
        self.assertIn('CCNMCellMonitorPhaseDefinitions()', body)
        self.assertIn("[context slotID] != 1) return;\n                            *stop = YES;", body)
        self.assertIn('singleRefreshRepeatedCopy', SOURCE)
        self.assertIn('refreshBeforeEachCopy', SOURCE)
        self.assertIn('@"schemaVersion": @3', body)
        self.assertIn('@"operation": @"serving_cell_refresh_ab"', body)
        self.assertIn('report[@"cellMonitorPlan"]', body)
        self.assertIn("CCNMCellMonitorShouldRefresh", body)
        self.assertIn("CCNMCellMonitorRequiredRefreshCount", body)
        self.assertIn("CCNMCellMonitorOrchestrationStart", body)
        self.assertIn("CCNMCellMonitorOrchestrationMatches", body)
        self.assertGreaterEqual(body.count("CCNMCellMonitorOrchestrationAdvance"), 2)
        self.assertIn(
            "phaseIndex > 0 && refreshPolicy == CCNMCellMonitorRefreshBeforeEachCopy",
            body,
        )
        self.assertIn(
            "refreshPolicy == CCNMCellMonitorRefreshBeforeEachCopy\n"
            "                                                ? CCNMCellMonitorRefreshBeforeCopyDelayMicroseconds\n"
            "                                                : CCNMCellMonitorSampleIntervalMicroseconds",
            body,
        )
        self.assertIn("CCNMRunCellMonitorRefreshAttempt", body)
        self.assertIn("CCNMRunCellMonitorCopyAttempt", body)
        for key in (
            "cellMonitorSamplingMode",
            "cellMonitorRefreshBeforeCopyDelaySeconds",
            "cellMonitorPhaseResults",
            "cellMonitorRefreshAttempts",
            "cellMonitorRequestedRefreshCount",
            "cellMonitorAttemptedRefreshCount",
            "cellMonitorCompletedRefreshCount",
            "cellMonitorSuccessfulRefreshCount",
            "cellMonitorNotAttemptedRefreshCount",
            "cellMonitorSamples",
            "cellMonitorRequestedSampleCount",
            "cellMonitorAttemptedSampleCount",
            "cellMonitorCompletedSampleCount",
            "cellMonitorSuccessfulCopyCount",
            "cellMonitorSuccessfulSampleCount",
            "cellMonitorNotAttemptedSampleCount",
            "cellMonitorSamplingStatus",
            "cellMonitorSamplingPartial",
            "cellMonitorSamplingFailures",
            "cellMonitorSamplingFailure",
            "cellMonitorSamplingAbortedAfterTimeout",
            "cellMonitorSamplingAbortedAfterInvocationException",
            "cellMonitorComparisonEligible",
            "cellMonitorComparisonStatus",
            "cellMonitorComparisonReason",
            "cellMonitorComparison",
            "observedServingCells",
            "nrServingCellObserved",
            "nrObservationStatus",
        ):
            self.assertIn(f'report[@"{key}"]', body)
        self.assertIn("CCNMClassifyCellMonitorABSamplingStatus", body)
        self.assertIn("samplingStatus == CCNMCellMonitorSamplingComplete", body)
        self.assertIn("samplingStatus == CCNMCellMonitorSamplingPartial", body)
        self.assertNotIn("successfulSampleCount > 0", body)
        self.assertIn("CCNMCellMonitorRATIsNR", body)
        self.assertIn("CCNMCellMonitorAllPayloadsEqual", body)
        self.assertIn("descriptiveOnly", body)
        self.assertIn("notAttemptedRefreshSampleIndexes", body)
        self.assertIn("notAttemptedCopySampleIndexes", body)
        self.assertIn('sample[@"cellMonitorCopyStatus"]', body)
        self.assertEqual(body.count("nrServingCellObserved = YES;"), 1)
        self.assertNotIn('slotReport[@"currentRat"]', body[body.index("BOOL nrServingCellObserved"):])
        self.assertIn('NR observation status: %@', body)
        self.assertNotIn("failure ?: CCNMReadableObject(slotReport)", body)
        self.assertIn(
            "phaseSampleIndex < CCNMCellMonitorPhaseSampleCount && !stopSampling",
            body,
        )
        self.assertGreaterEqual(body.count("CCNMCellMonitorOrchestrationTimedOut"), 2)
        self.assertGreaterEqual(body.count("CCNMCellMonitorOrchestrationInvocationException"), 2)
        self.assertGreaterEqual(
            body.count("stopSampling = abortAfterTimeout || abortAfterInvocationException"),
            2,
        )
        refresh_branch = body.index("if (refreshRequired)")
        attempted_copy = body.index("attemptedSampleCount++", refresh_branch)
        copy_call = body.index("CCNMRunCellMonitorCopyAttempt", attempted_copy)
        self.assertLess(refresh_branch, attempted_copy)
        self.assertLess(attempted_copy, copy_call)
        normalized_body = " ".join(body.split())
        self.assertIn("if (stopSampling) { break; } continue;", normalized_body)
        self.assertNotIn("[report addEntriesFromDictionary:copyAttempt]", body)

    def test_serving_probe_gate_excludes_reentry_and_band_operations(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        self.assertIn("static BOOL CCNMBeginServingCellProbe", SOURCE)
        self.assertIn("static void CCNMEndServingCellProbe", SOURCE)
        self.assertIn("if (!CCNMBeginServingCellProbe())", body)
        self.assertIn("@finally", body)
        self.assertIn("CCNMEndServingCellProbe();", body)
        begin_serving = source_method("static BOOL CCNMBeginServingCellProbe", "static void CCNMEndServingCellProbe")
        begin_band = source_method("static BOOL CCNMBeginBandOperation", "static BOOL CCNMBeginTestSetterOperation")
        begin_manual = source_method("static BOOL CCNMBeginManualRestoreOperation", "static void CCNMEndRecoveryOperation")
        self.assertIn("CCNMCellMonitorUnsafeOutstanding", begin_serving)
        self.assertIn("CCNMServingCellProbeInProgress", begin_band)
        self.assertIn("CCNMCellMonitorUnsafeOutstanding", begin_band)
        self.assertIn("CCNMServingCellProbeInProgress", begin_manual)
        self.assertIn("CCNMCellMonitorUnsafeOutstanding", begin_manual)
        self.assertIn("CCNMMarkCellMonitorUnsafeOutstanding", SOURCE)
        self.assertIn("CCNMResolveCellMonitorUnsafeOutstanding", SOURCE)
        self.assertIn("Close and reopen Settings before retrying", body)

    def test_refresh_and_copy_attempt_helpers_record_bounded_async_evidence(self):
        refresh = source_method(
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
            "static NSMutableDictionary *CCNMRunCellMonitorCopyAttempt",
        )
        copy = source_method(
            "static NSMutableDictionary *CCNMRunCellMonitorCopyAttempt",
            "static NSString *CCNMSysctlString",
        )
        for token in (
            'refreshRequestedAt',
            'refreshRequestedMonotonic',
            'refreshCallbackAt',
            'refreshCallbackMonotonic',
            'refreshWaitFinishedAt',
            'refreshWaitFinishedMonotonic',
            'refreshElapsedMilliseconds',
            'refreshCallbackLatencyMilliseconds',
            'refreshWaitResult',
            'status',
            'cellMonitorRefreshWaitCompleted',
            'cellMonitorRefreshTimedOut',
            'cellMonitorRefreshCallbackErrorRaw',
            'cellMonitorRefreshError',
            'cellMonitorRefreshErrorEvidence',
            'cellMonitorRefreshInvocationException',
            'cellMonitorRefreshSucceeded',
        ):
            self.assertIn(token, refresh)
        for token in (
            'copyRequestedAt',
            'copyRequestedMonotonic',
            'copyCallbackAt',
            'copyCallbackMonotonic',
            'copyWaitFinishedAt',
            'copyWaitFinishedMonotonic',
            'copyElapsedMilliseconds',
            'copyCallbackLatencyMilliseconds',
            'copyWaitResult',
            'status',
            'cellMonitorCopyWaitCompleted',
            'cellMonitorCopyTimedOut',
            'cellMonitorCopySucceeded',
            'cellMonitorCopyResultRuntimeClass',
            'cellMonitorCopyResultRaw',
            'cellMonitorError',
            'cellMonitorCopyErrorEvidence',
            'cellMonitorCopyInvocationException',
            'cellMonitorResult',
        ):
            self.assertIn(token, copy)
        self.assertIn("CCNMCellMonitorAsyncState *state", refresh)
        self.assertIn("completeWithResult:", refresh)
        self.assertIn("markUnsafeOutstanding", refresh)
        self.assertIn("CCNMCellMonitorAsyncState *state", copy)
        self.assertIn("completeWithResult:", copy)
        self.assertIn("markUnsafeOutstanding", copy)
        self.assertNotIn("__block", refresh)
        self.assertNotIn("__block", copy)
        self.assertIn("if (!CCNMProbeWaitCompleted(refreshWaitResult))", refresh)
        self.assertIn("if (!CCNMProbeWaitCompleted(copyWaitResult))", copy)
        self.assertLess(
            refresh.index("if (!CCNMProbeWaitCompleted(refreshWaitResult))"),
            refresh.index("if (refreshError)"),
        )
        self.assertLess(
            copy.index("if (!CCNMProbeWaitCompleted(copyWaitResult))"),
            copy.index("if (cellInfoError)"),
        )

    def test_ab_probe_ui_and_package_version_are_explicit(self):
        with ROOT_PLIST.open("rb") as plist_file:
            root = plistlib.load(plist_file)
        buttons = [
            item
            for item in root.get("items", [])
            if isinstance(item, dict) and item.get("action") == "showServingCellProbe:"
        ]
        self.assertEqual(len(buttons), 1)
        self.assertEqual(buttons[0].get("label"), "Compare Serving Cell Refresh (A/B)")
        groups = [
            item
            for item in root.get("items", [])
            if isinstance(item, dict) and item.get("label") == "Serving Cell Telemetry"
        ]
        self.assertEqual(len(groups), 1)
        self.assertIn("two-phase", groups[0].get("footerText", ""))
        self.assertIn("Version: 1.4.3-2+cellmonprobe3", CONTROL.read_text())

    def test_raw_cell_monitor_evidence_preserves_runtime_types_and_unknown_entries(self):
        parser = source_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        evidence = source_method(
            "static id CCNMTypedPropertyListEvidence",
            "static NSString *CCNMSysctlString",
        )
        for token in (
            '@"class"',
            '@"kind"',
            '@"entries"',
            '@"key"',
            '@"value"',
            '@"elements"',
            '@"description"',
        ):
            self.assertIn(token, evidence)
        self.assertIn('snapshot[@"cellInfoRaw"] = CCNMTypedPropertyListEvidence(cellInfoResult)', parser)
        self.assertIn('snapshot[@"legacyInfoRaw"] = CCNMTypedPropertyListEvidence(legacyInfo)', parser)
        self.assertIn("for (id legacyEntry in legacyInfo)", parser)
        self.assertIn('entryResult[@"parsed"] = @NO', parser)
        self.assertIn('snapshot[@"cellMonitorEntryResults"]', parser)
        self.assertNotIn("if (![cellDict isKindOfClass:[NSDictionary class]]) continue", parser)

    def test_async_callbacks_are_consumed_only_after_completed_waits(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        rat_selection = source_method(
            "static NSMutableDictionary *CCNMRunRatSelectionAttempt",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        self.assertIn("CCNMCellMonitorAsyncState *state", rat_selection)
        self.assertIn("completeWithResult:", rat_selection)
        self.assertIn("markUnsafeOutstanding", rat_selection)
        self.assertNotIn("__block", rat_selection)
        self.assertIn("long waitResult = dispatch_semaphore_wait", rat_selection)
        self.assertIn("if (!CCNMProbeWaitCompleted(waitResult))", rat_selection)
        self.assertIn('attempt[@"ratSelectionTimedOut"] = @YES', rat_selection)
        self.assertIn("@catch (NSException *exception)", rat_selection)
        self.assertIn("CCNMRunRatSelectionAttempt(client, context)", body)
        self.assertIn("CCNMPrivateAsyncAttemptRequiresAbort", body)
        self.assertIn("if (abortAfterUnsafeAsyncAttempt)", body)
        self.assertIn('result[@"slot1"] = report;\n                                return;', body)
        self.assertLess(
            body.index("if (abortAfterUnsafeAsyncAttempt)"),
            body.index("// RAT Selection Mask (sync, service-descriptor scoped)"),
        )
        self.assertIn('report[@"cellMonitorSucceeded"] = @(samplingStatus == CCNMCellMonitorSamplingComplete)', body)
        self.assertIn('report[@"cellMonitorSamplingPartial"] = @(samplingStatus == CCNMCellMonitorSamplingPartial)', body)
        self.assertNotIn("\n                                dispatch_semaphore_wait(", body)

    def test_private_async_selectors_are_outer_abi_checked_before_invocation(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        abi = source_method(
            "static BOOL CCNMValidateAsyncSelectorABI",
            "static BOOL CCNMValidateSetterABI",
        )
        self.assertIn("signature.numberOfArguments == 4", abi)
        self.assertIn("strcmp(returnType, @encode(void)) == 0", abi)
        self.assertIn("argumentType[0] == '@'", abi)
        self.assertIn("completionType[0] == '@' && completionType[1] == '?'", abi)
        for selector in (
            "getRatSelection:completion:",
            "refreshCellMonitor:completion:",
            "copyCellInfo:completion:",
        ):
            self.assertIn(f"CCNMValidateAsyncSelectorABI(client, @selector({selector})", body)

    def test_private_sync_selectors_are_abi_checked_before_invocation(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        abi = source_method(
            "static BOOL CCNMValidateObjectErrorSelectorABI",
            "static BOOL CCNMValidateAsyncSelectorABI",
        )
        self.assertIn("returnType[0] == '@'", abi)
        self.assertIn("outType[0] == '^' && outType[1] == '@'", abi)
        self.assertIn("unsigned int(id *)", abi)
        self.assertIn("objectArgumentCount", abi)
        self.assertIn(
            "CCNMValidateObjectErrorSelectorABI(client, @selector(getSubscriptionInfoWithError:), 0",
            body,
        )
        for selector in (
            "getCurrentRat:error:",
            "copyRadioAccessTechnology:error:",
            "copyRegistrationStatus:error:",
            "copyRegistrationDisplayStatus:error:",
            "getSupports5GStandalone:error:",
            "getNRDisableStatus:error:",
            "getRatSelectionMask:error:",
            "getSignalStrengthInfo:error:",
            "getBandInfo:error:",
        ):
            self.assertIn(
                f"CCNMValidateObjectErrorSelectorABI(client, @selector({selector}), 1",
                body,
            )
        self.assertIn(
            "CCNMValidatePublicNRFrequencyRangeSelectorABI(client, &frequencyRangeABIFailure)",
            body,
        )

    def test_missing_slot_cell_monitor_and_persistence_cannot_report_success(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        self.assertIn('NSDictionary *slotReport = result[@"slot1"]', body)
        self.assertIn("if (!slotReport)", body)
        self.assertIn('slotReport[@"cellMonitorSucceeded"]', body)
        self.assertIn('BOOL saved = [result writeToFile:CCNMCellMonitorProbePath() atomically:YES]', body)
        self.assertIn("if (!saved)", body)
        self.assertIn('result[@"error"] = failure ?: @""', body)
        self.assertLess(
            body.index('result[@"error"] = failure ?: @""'),
            body.index("BOOL saved = [result writeToFile:CCNMCellMonitorProbePath() atomically:YES]"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
