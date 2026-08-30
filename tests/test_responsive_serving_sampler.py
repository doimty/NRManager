#!/usr/bin/env python3
"""Latency and convergence contracts for UI serving-band sampling."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "nrmanagerprefs/CCNMServingCellProbeSupport.h"
SAMPLER = ROOT / "nrmanagerprefs/CCNMServingCellSampler.m"
PROVIDER = ROOT / "nrmanagerprefs/CCNMServingStatusProvider.m"
LIVECC = ROOT / "livecc/Sources/NRManagerLiveModule.m"
WORKFLOW = ROOT / ".github/workflows/livecc-prototype.yml"


class ResponsiveServingSamplerTests(unittest.TestCase):
    def test_responsive_reducer_requires_two_matching_clean_samples(self):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler)
        program = r'''
#include "nrmanagerprefs/CCNMServingCellProbeSupport.h"

int main(void) {
    CCNMAdaptiveSamplerState stable = CCNMAdaptiveSamplerStartWithPolicy(
        10, 2, CCNMAdaptiveSamplerPolicyStableServing);
    if (!CCNMAdaptiveSamplerObserveServing(&stable, 1, 1, 0)) return 1;
    if (!CCNMAdaptiveSamplerShouldContinue(&stable)) return 2;
    if (stable.consecutiveStableServingSampleCount != 1) return 3;
    if (!CCNMAdaptiveSamplerObserveServing(&stable, 1, 1, 1)) return 4;
    if (CCNMAdaptiveSamplerShouldContinue(&stable)) return 5;
    if (stable.stopReason != CCNMAdaptiveSamplerStopStableServingConfirmed) return 6;
    if (stable.consumedSampleCount != 2) return 7;

    CCNMAdaptiveSamplerState flap = CCNMAdaptiveSamplerStartWithPolicy(
        10, 2, CCNMAdaptiveSamplerPolicyStableServing);
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 1, 1, 0)) return 8;  /* n78 */
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 1, 1, 0)) return 9;  /* B3 */
    if (!CCNMAdaptiveSamplerShouldContinue(&flap)) return 10;
    if (flap.consecutiveStableServingSampleCount != 1) return 11;
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 1, 1, 0)) return 12; /* n78 */
    if (!CCNMAdaptiveSamplerShouldContinue(&flap)) return 13;
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 0, 0, 0)) return 14;
    if (flap.consecutiveStableServingSampleCount != 0) return 15;
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 1, 1, 0)) return 16; /* B3 */
    if (!CCNMAdaptiveSamplerObserveServing(&flap, 1, 1, 1)) return 17; /* B3 */
    if (flap.stopReason != CCNMAdaptiveSamplerStopStableServingConfirmed) return 18;
    if (flap.consumedSampleCount != 6) return 19;

    CCNMAdaptiveSamplerState diagnostic = CCNMAdaptiveSamplerStart(10, 2);
    if (!CCNMAdaptiveSamplerObserve(&diagnostic, 1, 1)) return 20;
    if (!CCNMAdaptiveSamplerObserve(&diagnostic, 1, 1)) return 21;
    if (diagnostic.stopReason != CCNMAdaptiveSamplerStopExplicitNRConfirmed) return 22;

    CCNMAdaptiveSamplerState noStable = CCNMAdaptiveSamplerStartWithPolicy(
        3, 2, CCNMAdaptiveSamplerPolicyStableServing);
    if (!CCNMAdaptiveSamplerObserveServing(&noStable, 1, 1, 0)) return 23;
    if (!CCNMAdaptiveSamplerObserveServing(&noStable, 0, 0, 0)) return 24;
    if (!CCNMAdaptiveSamplerObserveServing(&noStable, 1, 1, 0)) return 25;
    if (noStable.stopReason != CCNMAdaptiveSamplerStopWindowExhausted) return 26;
    if (CCNMClassifyStableServingSamplingStatus(2, 3, 3, 3, 2, 2, 2, 2, 0)
        != CCNMCellMonitorSamplingPartial) return 27;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "responsive-serving-reducer"
            compiled = subprocess.run(
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
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_ui_profile_removes_full_lte_window_and_redundant_delay(self):
        sampler = SAMPLER.read_text()
        provider = PROVIDER.read_text()
        workflow = WORKFLOW.read_text()
        self.assertGreaterEqual(workflow.count("nrmanagerprefs/CCNMServingCellProbeSupport.h"), 2)
        self.assertIn("CCNMServingCellResponsiveInterSampleDelayMicroseconds = 0", sampler)
        self.assertIn("CCNMRunResponsiveServingCellSampler", sampler)
        self.assertIn("CCNMRunResponsiveServingCellSampler", provider)
        self.assertIn('report[@"confirmedServingCell"]', sampler)
        self.assertIn('report[@"servingObservationConfirmed"]', sampler)
        self.assertIn("CCNMServingBandIdentity", sampler)
        self.assertIn('@[ @"band", @"lte", @"nr", @"n", @"b" ]', sampler)
        self.assertIn("CCNMServingCellRATTier", sampler)
        self.assertIn("winningTier", sampler)
        self.assertIn("invalidWinningTier", sampler)
        self.assertIn("previousResponsiveAttemptUsable", sampler)
        self.assertIn('servingConfirmationScope', sampler)
        self.assertIn('confirmedServingSampledAt', sampler)
        self.assertIn("fullCleanWindow", sampler)
        self.assertIn("observedExplicitNRSampleCount", sampler)
        self.assertIn("consecutiveExplicitNRSampleCount", sampler)
        self.assertIn("CCNMNRObservationIndeterminatePartial", sampler)
        self.assertIn("responsiveMode && complete && servingConfirmed", provider)
        self.assertNotIn("latestNR", provider)
        self.assertNotIn("latestLTE", provider)
        self.assertNotIn("latestOther", provider)
        self.assertIn('report[@"confirmedServingSampledAt"]', provider)
        for telemetry in (
            "cellMonitorSamplingElapsedMilliseconds",
            "cellMonitorScheduledDelayMilliseconds",
            "cellMonitorRefreshCallbackLatencyMilliseconds",
            "cellMonitorCopyCallbackLatencyMilliseconds",
        ):
            self.assertIn(telemetry, sampler)
            self.assertIn(telemetry, provider)
        self.assertIn('summary[telemetryKey] = value', provider)

        nr = "kCTCellMonitorRadioAccessTechnologyNR"
        nrnsa = "kCTCellMonitorRadioAccessTechnologyNRNSA"
        lte = "kCTCellMonitorRadioAccessTechnologyLTE"

        def canonical_band(value):
            if isinstance(value, bool):
                return None
            if isinstance(value, int):
                return str(value) if 0 < value <= 1024 else None
            if not isinstance(value, str):
                return None
            normalized = value.strip().lower()
            for prefix in ("band", "lte", "nr", "n", "b"):
                if normalized.startswith(prefix):
                    normalized = normalized[len(prefix):].strip()
                    break
            return str(int(normalized)) if normalized.isdigit() and 0 < int(normalized) <= 1024 else None

        def select(cells):
            def tier(cell):
                rat = cell.get("rat")
                if rat in (nr, nrnsa):
                    return 3
                if rat == lte:
                    return 2
                return 1 if isinstance(rat, str) and rat else 0

            winning = max((tier(cell) for cell in cells), default=0)
            selected = None
            identity = None
            invalid = False
            for cell in cells:
                if tier(cell) != winning:
                    continue
                band = canonical_band(cell.get("band"))
                candidate = (cell.get("rat"), band) if band else None
                if not candidate or (identity and candidate != identity):
                    invalid = True
                    continue
                selected = cell
                identity = candidate
            return None if invalid else selected

        self.assertEqual(canonical_band(78), "78")
        self.assertEqual(canonical_band(" Band 78 "), "78")
        self.assertEqual(canonical_band("n78"), "78")
        for invalid in (True, 3.5, 0, 1025, "n3.5", ""):
            self.assertIsNone(canonical_band(invalid))
        nr_cell = {"rat": nr, "band": "n78", "id": "nr"}
        lte_cell = {"rat": lte, "band": "B3", "id": "lte"}
        self.assertEqual(select([nr_cell, lte_cell]), nr_cell)
        self.assertEqual(select([lte_cell, nr_cell]), nr_cell)
        self.assertIsNone(select([{"rat": nr, "band": None}, lte_cell]))
        self.assertIsNone(select([nr_cell, {"rat": nr, "band": 79}]))
        self.assertIsNone(select([nr_cell, {"rat": nrnsa, "band": 78}]))
        latest_nr = {"rat": nr, "band": 78, "id": "latest"}
        self.assertEqual(select([nr_cell, latest_nr]), latest_nr)

        def constant(name):
            match = re.search(rf"{name} = (\d+);", sampler)
            self.assertIsNotNone(match, name)
            return int(match.group(1))

        maximum = constant("CCNMServingCellMaximumSampleCount")
        required = constant("CCNMServingCellRequiredConsecutiveServingSamples")
        settle_us = constant("CCNMServingCellRefreshSettleMicroseconds")
        diagnostic_inter_us = constant("CCNMServingCellInterSampleDelayMicroseconds")
        responsive_inter_us = constant("CCNMServingCellResponsiveInterSampleDelayMicroseconds")
        old_lte_delay_ms = (maximum * settle_us + (maximum - 1) * diagnostic_inter_us) // 1000
        responsive_delay_ms = (required * settle_us + (required - 1) * responsive_inter_us) // 1000
        self.assertEqual(old_lte_delay_ms, 9500)
        self.assertLessEqual(responsive_delay_ms, 1000)

    def test_rat_debounce_is_short_but_still_coalesces_notifications(self):
        source = LIVECC.read_text()
        self.assertIn("CCNMLiveRATDebounceSeconds = 0.25", source)
        self.assertIn("awaitingCurrentRefresh", source)
        self.assertIn("generation != self.refreshGeneration", source)
        self.assertIn("if (self.awaitingCurrentRefresh)", source)
        self.assertIn("if (self.ratDebounceTimer)", source)
        self.assertIn("[self.ratDebounceTimer invalidate]", source)
        self.assertNotIn("afterDelay:2.0", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
