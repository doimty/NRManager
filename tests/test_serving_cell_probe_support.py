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
CONTROLLER_PATH = ROOT / "networkmanagerprefs/CCNMRootListController.m"
SAMPLER_HEADER = ROOT / "networkmanagerprefs/CCNMServingCellSampler.h"
SAMPLER_PATH = ROOT / "networkmanagerprefs/CCNMServingCellSampler.m"
CONTROLLER_SOURCE = CONTROLLER_PATH.read_text()
SAMPLER_SOURCE = SAMPLER_PATH.read_text() if SAMPLER_PATH.exists() else ""
SOURCE = CONTROLLER_SOURCE + "\n" + SAMPLER_SOURCE
ROOT_PLIST = ROOT / "networkmanagerprefs/Resources/Root.plist"
CONTROL = ROOT / "control"


def source_method(start: str, end: str) -> str:
    start_index = SOURCE.index(start)
    return SOURCE[start_index:SOURCE.index(end, start_index)]


def sampler_method(start: str, end: str) -> str:
    start_index = SAMPLER_SOURCE.index(start)
    return SAMPLER_SOURCE[start_index:SAMPLER_SOURCE.index(end, start_index)]


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
    if (CCNMClassifyAdaptiveCellMonitorSamplingStatus(10, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0) != CCNMCellMonitorSamplingComplete) return 10;
    if (CCNMClassifyAdaptiveCellMonitorSamplingStatus(10, 2, 10, 10, 10, 10, 10, 10, 10, 0, 1) != CCNMCellMonitorSamplingComplete) return 11;
    if (CCNMClassifyAdaptiveCellMonitorSamplingStatus(10, 2, 10, 10, 10, 10, 10, 9, 9, 0, 1) != CCNMCellMonitorSamplingPartial) return 12;
    if (CCNMClassifyAdaptiveCellMonitorSamplingStatus(10, 2, 2, 2, 2, 1, 1, 1, 1, 0, 0) != CCNMCellMonitorSamplingPartial) return 13;
    if (CCNMClassifyAdaptiveCellMonitorSamplingStatus(10, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0) != CCNMCellMonitorSamplingFailed) return 14;
    if (CCNMCellMonitorRATIsNR(NULL)) return 15;
    if (CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyLTE")) return 16;
    if (!CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyNR")) return 17;
    if (!CCNMCellMonitorRATIsNR("kCTCellMonitorRadioAccessTechnologyNRNSA")) return 18;
    if (CCNMCellMonitorRATIsNR("prefixRadioAccessTechnologyNRsuffix")) return 34;
    if (!CCNMPrivateAsyncAttemptRequiresAbort(1, 0)) return 35;
    if (!CCNMPrivateAsyncAttemptRequiresAbort(0, 1)) return 36;
    if (CCNMPrivateAsyncAttemptRequiresAbort(0, 0)) return 37;
    if (!CCNMCellMonitorClassificationSymbolsAvailable(1, 1, 1)) return 45;
    if (CCNMCellMonitorClassificationSymbolsAvailable(0, 1, 1)) return 46;
    if (CCNMCellMonitorClassificationSymbolsAvailable(1, 0, 1)) return 47;
    if (CCNMCellMonitorClassificationSymbolsAvailable(1, 1, 0)) return 48;
    if (!CCNMCellMonitorEntryIsStructurallyClassifiable(1, 1)) return 49;
    if (CCNMCellMonitorEntryIsStructurallyClassifiable(0, 1)) return 50;
    if (CCNMCellMonitorEntryIsStructurallyClassifiable(1, 0)) return 51;
    if (!CCNMCellMonitorServingEntryHasClassifiableRAT(0, 0)) return 52;
    if (!CCNMCellMonitorServingEntryHasClassifiableRAT(1, 1)) return 53;
    if (CCNMCellMonitorServingEntryHasClassifiableRAT(1, 0)) return 54;
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

    def test_adaptive_sampling_reducer_requires_confirmed_nr_or_full_window(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "host C compiler is unavailable")

        program = r'''
#include "networkmanagerprefs/CCNMServingCellProbeSupport.h"

int main(void) {
    CCNMAdaptiveSamplerState lte = CCNMAdaptiveSamplerStart(10, 2);
    for (size_t index = 0; index < 10; index++) {
        if (!CCNMAdaptiveSamplerShouldContinue(&lte)) return 1;
        if (!CCNMAdaptiveSamplerObserve(&lte, 1, 0)) return 2;
    }
    if (CCNMAdaptiveSamplerShouldContinue(&lte)) return 3;
    if (lte.stopReason != CCNMAdaptiveSamplerStopWindowExhausted) return 4;
    if (lte.consumedSampleCount != 10 || lte.consecutiveNRSampleCount != 0) return 5;

    CCNMAdaptiveSamplerState nr = CCNMAdaptiveSamplerStart(10, 2);
    if (!CCNMAdaptiveSamplerObserve(&nr, 1, 1)) return 6;
    if (!CCNMAdaptiveSamplerShouldContinue(&nr)) return 7;
    if (!CCNMAdaptiveSamplerObserve(&nr, 1, 1)) return 8;
    if (CCNMAdaptiveSamplerShouldContinue(&nr)) return 9;
    if (nr.stopReason != CCNMAdaptiveSamplerStopExplicitNRConfirmed) return 10;
    if (nr.consumedSampleCount != 2 || nr.consecutiveNRSampleCount != 2) return 11;

    CCNMAdaptiveSamplerState interrupted = CCNMAdaptiveSamplerStart(10, 2);
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 1, 1)) return 12;
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 1, 0)) return 13;
    if (interrupted.consecutiveNRSampleCount != 0) return 14;
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 1, 1)) return 15;
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 0, 0)) return 16;
    if (interrupted.consecutiveNRSampleCount != 0) return 17;
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 1, 1)) return 18;
    if (!CCNMAdaptiveSamplerObserve(&interrupted, 1, 1)) return 19;
    if (interrupted.stopReason != CCNMAdaptiveSamplerStopExplicitNRConfirmed) return 20;
    if (interrupted.consumedSampleCount != 6) return 21;

    CCNMAdaptiveSamplerState timeout = CCNMAdaptiveSamplerStart(10, 2);
    if (!CCNMAdaptiveSamplerAbort(&timeout, 1, 0)) return 22;
    if (timeout.stopReason != CCNMAdaptiveSamplerStopTimedOut) return 23;
    if (CCNMAdaptiveSamplerShouldContinue(&timeout)) return 24;
    if (CCNMAdaptiveSamplerObserve(&timeout, 1, 1)) return 25;

    CCNMAdaptiveSamplerState exception = CCNMAdaptiveSamplerStart(10, 2);
    if (!CCNMAdaptiveSamplerAbort(&exception, 0, 1)) return 26;
    if (exception.stopReason != CCNMAdaptiveSamplerStopInvocationException) return 27;

    CCNMAdaptiveSamplerState invalid = CCNMAdaptiveSamplerStart(0, 0);
    if (CCNMAdaptiveSamplerShouldContinue(&invalid)) return 28;
    if (invalid.stopReason != CCNMAdaptiveSamplerStopInvalidConfiguration) return 29;
    if (CCNMAdaptiveSamplerStoppedEarly(&lte)) return 30;
    if (!CCNMAdaptiveSamplerStoppedEarly(&nr)) return 31;

    CCNMAdaptiveSamplerState finalSampleNR = CCNMAdaptiveSamplerStart(10, 2);
    for (size_t index = 0; index < 8; index++) {
        if (!CCNMAdaptiveSamplerObserve(&finalSampleNR, 1, 0)) return 32;
    }
    if (!CCNMAdaptiveSamplerObserve(&finalSampleNR, 1, 1)) return 33;
    if (!CCNMAdaptiveSamplerObserve(&finalSampleNR, 1, 1)) return 34;
    if (finalSampleNR.stopReason != CCNMAdaptiveSamplerStopExplicitNRConfirmed) return 35;
    if (CCNMAdaptiveSamplerStoppedEarly(&finalSampleNR)) return 36;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp_dir:
            executable = Path(temp_dir) / "adaptive-cell-monitor-test"
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

    def test_full_window_policy_does_not_stop_after_explicit_nr(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "host C compiler is unavailable")

        program = r'''
#include "networkmanagerprefs/CCNMServingCellProbeSupport.h"

int main(void) {
    CCNMAdaptiveSamplerState full = CCNMAdaptiveSamplerStartWithPolicy(
        10, 2, CCNMAdaptiveSamplerPolicyFullWindow);
    if (!CCNMAdaptiveSamplerObserve(&full, 1, 1)) return 1;
    if (!CCNMAdaptiveSamplerObserve(&full, 1, 1)) return 2;
    if (full.stopReason != CCNMAdaptiveSamplerStopRunning) return 3;
    if (!CCNMAdaptiveSamplerShouldContinue(&full)) return 4;
    if (full.consumedSampleCount != 2 || full.consecutiveNRSampleCount != 2) return 5;
    for (size_t index = 2; index < 10; index++) {
        if (!CCNMAdaptiveSamplerObserve(&full, 1, 0)) return 6;
    }
    if (full.stopReason != CCNMAdaptiveSamplerStopWindowExhausted) return 7;
    if (full.consumedSampleCount != 10) return 8;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temp_dir:
            executable = Path(temp_dir) / "full-window-adaptive-cell-monitor-test"
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
        rat_selection = sampler_method(
            "static NSMutableDictionary *CCNMRunServingCellRatSelectionAttemptInternal",
            "NSDictionary *CCNMRunServingCellRatSelectionAttempt",
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
        self.assertIn("CCNMRunServingCellRatSelectionAttempt(client, context)", body)

    def test_cell_monitor_symbols_use_c_names_and_missing_keys_are_safe(self):
        symbols = sampler_method(
            "static NSArray<NSString *> *CCNMCellMonitorSymbolNames",
            "static id CCNMTypedPropertyListEvidenceInternal",
        )
        parser = sampler_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        self.assertIn("dlsym(ctHandle, symbolName.UTF8String)", symbols)
        self.assertNotIn('"_" #name', symbols)
        self.assertIn("dispatch_once(&onceToken", symbols)
        self.assertIn("missingSymbols", symbols)
        self.assertIn('report[@"cellMonitorMissingSymbols"]', SAMPLER_SOURCE)
        self.assertIn("CCNMCellMonitorCriticalClassificationSymbolNames", parser)
        self.assertIn("CCNMCellMonitorClassificationSymbolsAvailable", parser)
        self.assertIn('snapshot[@"cellMonitorCriticalMissingSymbols"]', parser)
        self.assertIn('snapshot[@"cellMonitorClassificationAvailable"]', parser)
        self.assertIn(
            'snapshot[@"cellMonitorSucceeded"] = @(classificationAvailable && entriesStructurallyValid)',
            parser,
        )
        self.assertIn("CCNMCellMonitorValue(cellDict, cellMonitorSymbols", parser)
        self.assertNotIn("cellDict[(__bridge NSString *)CCMK_", SAMPLER_SOURCE)

    def test_ios15_legacy_lte_keys_are_resolved_and_normalized(self):
        parser = sampler_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        symbols = sampler_method(
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

    def test_adaptive_sampler_owns_refresh_copy_parsing_and_bounded_evidence(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        makefile = (ROOT / "networkmanagerprefs/Makefile").read_text()
        self.assertTrue(SAMPLER_HEADER.exists(), "sampler public header is missing")
        self.assertTrue(SAMPLER_PATH.exists(), "sampler implementation is missing")
        self.assertIn("CCNMServingCellSampler.m", makefile)
        self.assertIn("CCNMServingCellMaximumSampleCount = 10", SAMPLER_SOURCE)
        self.assertIn("CCNMServingCellRequiredConsecutiveNRSamples = 2", SAMPLER_SOURCE)
        self.assertIn("CCNMServingCellAttemptTimeoutSeconds = 5", SAMPLER_SOURCE)
        self.assertIn("CCNMServingCellInterSampleDelayMicroseconds = 500000", SAMPLER_SOURCE)
        self.assertIn("CCNMServingCellRefreshSettleMicroseconds = 500000", SAMPLER_SOURCE)
        self.assertIn('CCNMServingCellSamplerEmptyReport()', body)
        self.assertIn('CCNMRunAdaptiveServingCellSampler(client, context, ctHandle)', body)
        self.assertIn('[@"schemaVersion"] = @4', body)
        self.assertIn('[@"operation"] = @"serving_cell_adaptive"', body)
        self.assertNotIn("CCNMRunCellMonitorRefreshAttempt", body)
        self.assertNotIn("CCNMRunCellMonitorCopyAttempt", body)
        self.assertNotIn("CCNMParseCellMonitorSnapshot", CONTROLLER_SOURCE)
        self.assertNotIn("CCNMCellMonitorPhase", SOURCE)
        self.assertNotIn("singleRefreshRepeatedCopy", SOURCE)
        self.assertNotIn("refreshBeforeEachCopy", SOURCE)

        for token in (
            "CCNMAdaptiveSamplerStart",
            "CCNMAdaptiveSamplerObserve",
            "CCNMAdaptiveSamplerAbort",
            "CCNMRunCellMonitorRefreshAttempt",
            "CCNMRunCellMonitorCopyAttempt",
            "CCNMClassifyAdaptiveCellMonitorSamplingStatus",
        ):
            self.assertIn(token, SAMPLER_SOURCE)
        self.assertIn("for (NSUInteger sampleIndex = 0; sampleIndex < CCNMServingCellMaximumSampleCount; sampleIndex++)", SAMPLER_SOURCE)
        self.assertIn("CCNMServingCellRefreshSettleMicroseconds", SAMPLER_SOURCE)
        self.assertIn("CCNMPrivateAsyncAttemptRequiresAbort", SAMPLER_SOURCE)

        for key in (
            "cellMonitorSamplingMode",
            "cellMonitorPlan",
            "cellMonitorResolvedSymbols",
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
            "cellMonitorNotAttemptedOperations",
            "cellMonitorSamplingStatus",
            "cellMonitorStopReason",
            "cellMonitorStoppedEarly",
            "cellMonitorSamplingPartial",
            "cellMonitorSamplingFailures",
            "cellMonitorSamplingFailure",
            "cellMonitorSamplingAbortedAfterTimeout",
            "cellMonitorSamplingAbortedAfterInvocationException",
            "observedServingCells",
            "nrServingCellObserved",
            "nrObservationStatus",
            "explicitNRConfirmationCount",
        ):
            self.assertIn(f'@"{key}"', SAMPLER_SOURCE)
        self.assertIn('sample[@"cellMonitorCopyStatus"]', SAMPLER_SOURCE)
        self.assertIn('sample[@"explicitNRServingCellObserved"]', SAMPLER_SOURCE)
        self.assertIn('notAttempted[@"reason"]', SAMPLER_SOURCE)
        for failure_key in ('@"stage"', '@"kind"', '@"message"', '@"reason"'):
            self.assertIn(failure_key, SAMPLER_SOURCE)
        self.assertNotIn('currentRat', sampler_method(
            "NSDictionary *CCNMRunAdaptiveServingCellSampler",
            "BOOL CCNMServingCellSamplerHasUnsafeOutstandingAttempt",
        ))

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
        self.assertIn("CCNMServingCellSamplerHasUnsafeOutstandingAttempt()", begin_serving)
        self.assertIn("CCNMServingCellProbeInProgress", begin_band)
        self.assertIn("CCNMServingCellSamplerHasUnsafeOutstandingAttempt()", begin_band)
        self.assertIn("CCNMServingCellProbeInProgress", begin_manual)
        self.assertIn("CCNMServingCellSamplerHasUnsafeOutstandingAttempt()", begin_manual)
        self.assertNotIn("CCNMCellMonitorUnsafeOutstanding", CONTROLLER_SOURCE)
        self.assertIn("CCNMMarkCellMonitorUnsafeOutstanding", SAMPLER_SOURCE)
        self.assertIn("CCNMResolveCellMonitorUnsafeOutstanding", SAMPLER_SOURCE)
        self.assertIn("Close and reopen Settings before retrying", body)

    def test_refresh_and_copy_attempt_helpers_record_bounded_async_evidence(self):
        refresh = sampler_method(
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
            "static NSMutableDictionary *CCNMRunCellMonitorCopyAttempt",
        )
        copy = sampler_method(
            "static NSMutableDictionary *CCNMRunCellMonitorCopyAttempt",
            "NSDictionary *CCNMServingCellSamplerEmptyReport",
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

    def test_adaptive_probe_ui_and_package_version_are_explicit(self):
        with ROOT_PLIST.open("rb") as plist_file:
            root = plistlib.load(plist_file)
        buttons = [
            item
            for item in root.get("items", [])
            if isinstance(item, dict) and item.get("action") == "showServingCellProbe:"
        ]
        self.assertEqual(len(buttons), 1)
        self.assertEqual(buttons[0].get("label"), "Sample Serving Cell")
        groups = [
            item
            for item in root.get("items", [])
            if isinstance(item, dict) and item.get("label") == "Serving Cell Telemetry"
        ]
        self.assertEqual(len(groups), 1)
        footer = groups[0].get("footerText", "")
        self.assertIn("adaptive", footer.lower())
        self.assertIn("10", footer)
        self.assertIn("Version: 1.4.3-2+lteb1probe1", CONTROL.read_text())

    def test_raw_cell_monitor_evidence_preserves_runtime_types_and_unknown_entries(self):
        parser = sampler_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        evidence = sampler_method(
            "static id CCNMTypedPropertyListEvidenceInternal",
            "static NSDictionary *CCNMNSErrorEvidence",
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
        self.assertIn('snapshot[@"cellMonitorStructurallyInvalidEntryCount"]', parser)
        self.assertIn('snapshot[@"cellMonitorMissingServingRATCount"]', parser)
        self.assertIn('snapshot[@"cellMonitorEntriesStructurallyValid"]', parser)
        self.assertIn("BOOL hasClassifiableCellType = [cellType isKindOfClass:[NSString class]]", parser)
        self.assertIn(
            "CCNMCellMonitorEntryIsStructurallyClassifiable(YES, hasClassifiableCellType)",
            parser,
        )
        self.assertIn("BOOL hasClassifiableRAT = [rat isKindOfClass:[NSString class]]", parser)
        self.assertIn(
            "CCNMCellMonitorServingEntryHasClassifiableRAT(isServingEntry, hasClassifiableRAT)",
            parser,
        )
        self.assertNotIn("if (![cellDict isKindOfClass:[NSDictionary class]]) continue", parser)

    def test_async_callbacks_are_consumed_only_after_completed_waits(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        rat_selection = sampler_method(
            "static NSMutableDictionary *CCNMRunServingCellRatSelectionAttemptInternal",
            "NSDictionary *CCNMRunServingCellRatSelectionAttempt",
        )
        self.assertIn("CCNMCellMonitorAsyncState *state", rat_selection)
        self.assertIn("completeWithResult:", rat_selection)
        self.assertIn("markUnsafeOutstanding", rat_selection)
        self.assertNotIn("__block", rat_selection)
        self.assertIn("long waitResult = dispatch_semaphore_wait", rat_selection)
        self.assertIn("if (!CCNMProbeWaitCompleted(waitResult))", rat_selection)
        self.assertIn('attempt[@"ratSelectionTimedOut"] = @YES', rat_selection)
        self.assertIn("@catch (NSException *exception)", rat_selection)
        self.assertIn("CCNMRunServingCellRatSelectionAttempt(client, context)", body)
        self.assertIn("CCNMPrivateAsyncAttemptRequiresAbort", body)
        self.assertIn("if (abortAfterUnsafeAsyncAttempt)", body)
        self.assertIn('result[@"slot1"] = report;\n                                return;', body)
        self.assertLess(
            body.index("if (abortAfterUnsafeAsyncAttempt)"),
            body.index("// RAT Selection Mask (sync, service-descriptor scoped)"),
        )
        self.assertIn("CCNMRunAdaptiveServingCellSampler(client, context, ctHandle)", body)
        self.assertNotIn("\n                                dispatch_semaphore_wait(", body)

    def test_unsafe_outstanding_tracker_counts_each_unresolved_attempt(self):
        globals_block = SAMPLER_SOURCE[:SAMPLER_SOURCE.index("@interface CCNMCellMonitorAsyncState")]
        mark = sampler_method(
            "static void CCNMMarkCellMonitorUnsafeOutstanding",
            "static void CCNMResolveCellMonitorUnsafeOutstanding",
        )
        resolve = sampler_method(
            "static void CCNMResolveCellMonitorUnsafeOutstanding",
            "@interface CCNMCellMonitorAsyncState",
        )
        query = SAMPLER_SOURCE[SAMPLER_SOURCE.index(
            "BOOL CCNMServingCellSamplerHasUnsafeOutstandingAttempt"
        ):]
        self.assertIn("static NSUInteger CCNMCellMonitorUnsafeOutstandingCount = 0;", globals_block)
        self.assertNotIn("static BOOL CCNMCellMonitorUnsafeOutstanding", globals_block)
        self.assertIn("CCNMCellMonitorUnsafeOutstandingCount++", mark)
        self.assertIn("CCNMCellMonitorUnsafeOutstandingCount > 0", resolve)
        self.assertIn("CCNMCellMonitorUnsafeOutstandingCount--", resolve)
        self.assertIn("return CCNMCellMonitorUnsafeOutstandingCount > 0", query)

    def test_private_async_selectors_are_sampler_abi_checked_before_invocation(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        abi = sampler_method(
            "static BOOL CCNMValidateAsyncSelectorABI",
            "static NSMutableDictionary *CCNMRunServingCellRatSelectionAttemptInternal",
        )
        self.assertIn("signature.numberOfArguments == 4", abi)
        self.assertIn("strcmp(returnType, @encode(void)) == 0", abi)
        self.assertIn("argumentType[0] == '@'", abi)
        self.assertIn("completionType[0] == '@' && completionType[1] == '?'", abi)
        rat_wrapper = sampler_method(
            "NSDictionary *CCNMRunServingCellRatSelectionAttempt",
            "static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt",
        )
        adaptive = sampler_method(
            "static NSDictionary *CCNMRunServingCellSampler",
            "NSDictionary *CCNMRunAdaptiveServingCellSampler",
        )
        self.assertIn("@selector(getRatSelection:completion:)", rat_wrapper)
        self.assertLess(
            rat_wrapper.index("CCNMValidateAsyncSelectorABI"),
            rat_wrapper.index("CCNMRunServingCellRatSelectionAttemptInternal"),
        )
        for selector in ("refreshCellMonitor:completion:", "copyCellInfo:completion:"):
            self.assertIn(f"@selector({selector})", adaptive)
        loop_index = adaptive.index("for (NSUInteger sampleIndex")
        self.assertLess(adaptive.index("refreshABIValid"), loop_index)
        self.assertLess(adaptive.index("copyABIValid"), loop_index)
        self.assertNotIn("CCNMValidateAsyncSelectorABI", body)

    def test_private_sync_selectors_are_abi_checked_before_invocation(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        abi = source_method(
            "static BOOL CCNMValidateObjectErrorSelectorABI",
            "static BOOL CCNMValidateSetterABI",
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
