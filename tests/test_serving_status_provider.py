#!/usr/bin/env python3
"""Contracts for the truthful formal serving-status provider."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SUPPORT = ROOT / "networkmanagerprefs/CCNMServingStatusSupport.h"
HEADER = ROOT / "networkmanagerprefs/CCNMServingStatusProvider.h"
SOURCE = ROOT / "networkmanagerprefs/CCNMServingStatusProvider.m"
SAMPLER = ROOT / "networkmanagerprefs/CCNMServingCellSampler.m"
MAKEFILE = ROOT / "networkmanagerprefs/Makefile"


class ServingStatusProviderTests(unittest.TestCase):
    def test_nr_arfcn_frequency_conversion_matches_3gpp_ranges(self):
        self.assertTrue(SUPPORT.exists())
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler)
        program = r'''
#include <math.h>
#include "networkmanagerprefs/CCNMServingStatusSupport.h"

static int near(double a, double b) { return fabs(a - b) < 0.0001; }
int main(void) {
    if (!near(CCNMNRARFCNToMHz(0), 0.0)) return 1;
    if (!near(CCNMNRARFCNToMHz(599999), 2999.995)) return 2;
    if (!near(CCNMNRARFCNToMHz(600000), 3000.0)) return 3;
    if (!near(CCNMNRARFCNToMHz(633984), 3509.760)) return 4;
    if (!near(CCNMNRARFCNToMHz(2016666), 24249.990)) return 5;
    if (!near(CCNMNRARFCNToMHz(2016667), 24250.080)) return 6;
    if (!near(CCNMNRARFCNToMHz(3279165), 99999.960)) return 7;
    if (CCNMNRARFCNToMHz(-1) >= 0.0) return 8;
    if (CCNMNRARFCNToMHz(3279166) >= 0.0) return 9;
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "nr-arfcn"
            result = subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT), "-x", "c", "-", "-lm", "-o", str(executable)],
                input=program,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)

    def test_provider_uses_reviewed_adaptive_sampler_and_build_includes_it(self):
        source = SOURCE.read_text()
        makefile = MAKEFILE.read_text()
        self.assertTrue(HEADER.exists())
        self.assertTrue(SAMPLER.exists())
        self.assertIn('#import "CCNMServingCellSampler.h"', source)
        self.assertIn("CCNMRunAdaptiveServingCellSampler", source)
        self.assertNotIn("CCNMRunFullWindowServingCellSampler", source)
        for filename in ("CCNMServingStatusProvider.m", "CCNMServingCellSampler.m"):
            self.assertIn(filename, makefile)

    def test_sampler_and_policy_share_exclusive_lock(self):
        source = SOURCE.read_text()
        self.assertIn("CCNMN78PolicyLockPath()", source)
        self.assertIn("flock", source)
        self.assertIn("LOCK_EX | LOCK_NB", source)
        self.assertIn("CCNMServingCellSamplerHasUnsafeOutstandingAttempt", source)
        self.assertIn("retainedSamplerLockDescriptor", source)
        self.assertIn("retainedSamplerClient", source)
        self.assertIn("retainedSamplerContext", source)
        self.assertNotIn("dlclose", source)

    def test_provider_never_writes_modem_or_infers_from_policy(self):
        combined = SOURCE.read_text() + SAMPLER.read_text()
        for forbidden in (
            "setActiveBandInfo",
            "_CTServerConnectionSetRATSelection",
            "setRatSelection:",
            "setRatSelectionMask:",
            "CCNMRequestedModeN78Preferred",
            "CCNMAppliedPolicyVerifiedN78Only",
        ):
            self.assertNotIn(forbidden, combined)

    def test_summary_domains_and_freshness_are_explicit(self):
        header = HEADER.read_text()
        source = SOURCE.read_text()
        for token in (
            "CCNMServingStateNRN78",
            "CCNMServingStateNROther",
            "CCNMServingStateLTE",
            "CCNMServingStateOther",
            "CCNMServingStateUnknown",
            "sampledAtMilliseconds",
            "stale",
            "frequencyMHz",
            "dataLine",
        ):
            self.assertIn(token, header + source)
        self.assertIn("CCNMServingFreshnessLifetimeMilliseconds", source)
        self.assertIn("me.nixuge.networkmanager.serving-status.plist", source)
        self.assertIn("CCNMServingReadCachedSummary", source)
        self.assertIn("CCNMServingPersistCachedSummary", source)
        self.assertIn("writeToFile:CCNMServingCachePath() atomically:YES", source)
        self.assertIn("CCNMServingStatusDidChangeDarwinNotification", header + source)
        self.assertIn("CFNotificationCenterPostNotification", source)
        self.assertIn("CCNMServingReadCachedSummary", source)
        self.assertIn("nrObservationStatus", source)
        self.assertIn("cellMonitorSamplingStatus", source)

    def test_nr_is_preferred_over_lte_only_from_explicit_cell_monitor_evidence(self):
        source = SOURCE.read_text()
        self.assertIn("latestNR", source)
        self.assertIn("latestLTE", source)
        self.assertIn("CCNMCellMonitorRATKind", source)
        self.assertIn('[@"nrObservationStatus"] isEqual:@"observed"', source)
        self.assertIn('[@"cellMonitorSamplingStatus"] isEqual:@"complete"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
