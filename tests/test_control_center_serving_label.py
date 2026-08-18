#!/usr/bin/env python3
"""Contracts for truthful asynchronous serving-band text in Control Center."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CC_SOURCE = ROOT / "CCNetworkManager.x"
MAKEFILE = ROOT / "Makefile"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"


class ControlCenterServingLabelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = CC_SOURCE.read_text()
        cls.makefile = MAKEFILE.read_text()
        cls.policy = POLICY_SOURCE.read_text()

    def test_cc_bundle_builds_the_reviewed_read_only_serving_stack(self):
        self.assertIn("networkmanagerprefs/CCNMServingStatusProvider.m", self.makefile)
        self.assertIn("networkmanagerprefs/CCNMServingCellSampler.m", self.makefile)
        self.assertIn('#import "networkmanagerprefs/CCNMServingStatusProvider.h"', self.source)

    def test_stable_glyph_uses_fresh_serving_truth_not_policy_name(self):
        self.assertIn("CCNMServingGlyphText", self.source)
        self.assertIn("CCNMServingSummaryBandKey", self.source)
        self.assertIn('stringWithFormat:@"B%@"', self.source)
        self.assertIn('stringWithFormat:@"n%@"', self.source)
        stable = self.source[self.source.index("static NSString *CCNMServingGlyphText"):]
        self.assertNotIn('requested ? @"n78" : @"Auto"', stable)

    def test_unknown_loading_and_policy_priority_are_explicit(self):
        self.assertIn('return @"...";', self.source)
        self.assertIn('return @"?";', self.source)
        self.assertIn("CCNMPolicyIsTransitioning", self.source)
        self.assertIn("CCNMPolicyNeedsRecovery", self.source)
        self.assertIn("policyOperationPending", self.source)

    def test_refresh_is_async_bounded_and_never_writes_modem(self):
        for token in (
            "servingRefreshInProgress",
            "servingRefreshLastAttempt",
            "servingRefreshStartedAt",
            "refreshWithCompletion",
            "CCNMServingSummaryStaleKey",
            "dispatch_get_main_queue",
            "refreshState",
        ):
            self.assertIn(token, self.source)
        self.assertIn("now - self.servingRefreshStartedAt > 20.0", self.source)
        start = self.source.index("- (void)requestServingRefreshIfNeeded")
        end = self.source.index("- (UIImage *)iconGlyph", start)
        refresh = self.source[start:end]
        for forbidden in (
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "setActiveBandInfo",
            "setRatSelection",
            "_CTServerConnectionSetRATSelection",
        ):
            self.assertNotIn(forbidden, refresh)

    def test_cache_notification_reloads_the_live_glyph_without_respring(self):
        for token in (
            "CCNMServingStatusDidChangeDarwinNotification",
            "CCNMServingStatusDidChangeCallback",
            "refreshModulePresentation",
            "contentViewController",
            "respondsToSelector:@selector(reconfigureView)",
            "[controller reconfigureView]",
        ):
            self.assertIn(token, self.source)

    def test_selected_color_remains_policy_truth(self):
        selected = self.source[self.source.index("- (BOOL)isSelected"):self.source.index("- (void)setSelected:")]
        self.assertIn("CCNMPolicyIsRequested", selected)
        self.assertNotIn("CCNMServing", selected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
