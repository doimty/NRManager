#!/usr/bin/env python3
"""Behavioral host tests for serving-cell probe support logic."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUPPORT_HEADER = ROOT / "networkmanagerprefs/CCNMServingCellProbeSupport.h"
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()


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
        self.assertIn("[client getRatSelection:context completion:", body)

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

    def test_bounded_sampling_preserves_each_snapshot_and_nr_observation(self):
        body = source_method("- (void)showServingCellProbe:", "- (void)confirmSameValueBandWrite:")
        self.assertIn("CCNMCellMonitorSampleCount = 10", SOURCE)
        self.assertIn("CCNMCellMonitorSampleIntervalMicroseconds = 1000000", SOURCE)
        self.assertIn(
            "for (NSUInteger sampleIndex = 0; sampleIndex < CCNMCellMonitorSampleCount; sampleIndex++)",
            body,
        )
        for key in (
            "cellMonitorSamples",
            "cellMonitorRequestedSampleCount",
            "cellMonitorCompletedSampleCount",
            "cellMonitorSuccessfulSampleCount",
            "cellMonitorSamplingStatus",
            "cellMonitorSamplingPartial",
            "cellMonitorSamplingFailure",
            "observedServingCells",
            "nrServingCellObserved",
        ):
            self.assertIn(f'report[@"{key}"]', body)
        self.assertIn('sample[@"cellMonitorCopyTimedOut"] = @YES', body)
        self.assertIn('sample[@"cellMonitorError"]', body)
        self.assertIn('sample[@"cellMonitorResult"] = @"(nil)"', body)
        self.assertIn("CCNMClassifyCellMonitorSamplingStatus", body)
        self.assertIn("samplingStatus == CCNMCellMonitorSamplingComplete", body)
        self.assertIn("samplingStatus == CCNMCellMonitorSamplingPartial", body)
        self.assertNotIn("successfulSampleCount > 0", body)
        self.assertIn("CCNMCellMonitorRATIsNR", body)
        self.assertEqual(body.count("nrServingCellObserved = YES;"), 1)
        self.assertNotIn('slotReport[@"currentRat"]', body[body.index("BOOL nrServingCellObserved"):])
        self.assertIn('NR serving cell observed: %@', body)
        self.assertNotIn("failure ?: CCNMReadableObject(slotReport)", body)
        self.assertIn("break;", body)

    def test_raw_cell_monitor_evidence_preserves_runtime_types_and_unknown_entries(self):
        parser = source_method(
            "static NSMutableDictionary *CCNMParseCellMonitorSnapshot",
            "static NSString *CCNMSysctlString",
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
        for wait_name, timeout_key in (
            ("ratSelectionWaitResult", "ratSelectionTimedOut"),
            ("refreshWaitResult", "cellMonitorRefreshTimedOut"),
            ("copyWaitResult", "cellMonitorCopyTimedOut"),
        ):
            self.assertIn(f"long {wait_name} = dispatch_semaphore_wait", body)
            self.assertIn(f"if (!CCNMProbeWaitCompleted({wait_name}))", body)
            self.assertIn(f'report[@"{timeout_key}"] = @YES', body)
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
