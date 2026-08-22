#!/usr/bin/env python3
"""Contracts for the read-only Live Band Control Center module."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CC_SOURCE = ROOT / "CCNetworkManager.x"
CC_HEADER = ROOT / "CCNetworkManager.h"
PRIVATE_HEADER = ROOT / "include/NetworkManagerControlCenterUIKitPrivate.h"
MAKEFILE = ROOT / "Makefile"
PROVIDER = ROOT / "networkmanagerprefs/CCNMServingStatusProvider.m"


class ControlCenterServingLabelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = CC_SOURCE.read_text()
        cls.header = CC_HEADER.read_text()
        cls.makefile = MAKEFILE.read_text()
        cls.provider = PROVIDER.read_text()

    def test_cc_bundle_builds_the_read_only_serving_stack(self):
        files_line = next(
            line for line in self.makefile.splitlines()
            if line.startswith("NetworkManager_FILES =")
        )
        self.assertIn("networkmanagerprefs/CCNMServingStatusProvider.m", files_line)
        self.assertIn("networkmanagerprefs/CCNMServingCellSampler.m", files_line)
        self.assertIn("networkmanagerprefs/CCNMN78PolicyReader.m", files_line)
        self.assertNotIn("networkmanagerprefs/CCNMN78PolicyController.m", files_line)
        self.assertIn("CCNMAutomaticMaintenanceDecision.c", files_line)
        self.assertIn('#import "networkmanagerprefs/CCNMServingStatusProvider.h"', self.source)
        self.assertIn('#import "CCNMN78PolicyReader.h"', self.provider)
        self.assertIn("-Iinclude", self.makefile)
        self.assertTrue(PRIVATE_HEADER.is_file())

    def test_private_declarations_never_import_the_framework_as_a_module(self):
        for text in (self.header, self.source, PRIVATE_HEADER.read_text()):
            self.assertNotIn("#import <ControlCenterUIKit/", text)
            self.assertNotIn('#import "ControlCenterUIKit/', text)
        self.assertIn('#import "NetworkManagerControlCenterUIKitPrivate.h"', self.header)
        private_header = PRIVATE_HEADER.read_text()
        for declaration in (
            "@protocol CCUIContentModuleContentViewController <NSObject>",
            "@protocol CCUIContentModule <NSObject>",
            "@interface CCUIButtonModuleViewController : UIViewController",
            "@property (nonatomic, strong) UIImage *glyphImage;",
            "- (void)buttonTapped:(id)button forEvent:(UIEvent *)event;",
        ):
            self.assertIn(declaration, private_header)

    def test_control_center_is_the_standalone_read_only_live_band_module(self):
        for token in (
            'self.title = @"Live Band";',
            "self.selected = NO;",
            "hasFreshServingResult",
            "awaitingCurrentRefresh",
            "requestBoundedServingRefresh",
            "applySummary:summary requireNewerTimestamp:NO",
        ):
            self.assertIn(token, self.source)
        for forbidden in (
            "CCNMN78PolicyController.h",
            "CCNMReadN78PolicyState",
            "CCNMN78PolicyHasOutstandingSetter",
            "CCNMPolicyIsTransitioning",
            "CCNMPolicyNeedsRecovery",
            "CCNMPolicyIsRequested",
            "CCNMN78PolicyDidChangeDarwinNotification",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "self.selected = requested",
            "iPhone14,3",
            "19B81",
        ):
            self.assertNotIn(forbidden, self.source)

    def test_stable_glyph_uses_fresh_serving_truth(self):
        self.assertIn("CCNMLiveTextForSummary", self.source)
        self.assertIn('stringWithFormat:@"B%lld"', self.source)
        self.assertIn('stringWithFormat:@"n%lld"', self.source)
        text_fn = self.source[
            self.source.index("static NSString *CCNMLiveTextForSummary"):
            self.source.index("static UIImage *CCNMLiveGlyphImage")
        ]
        self.assertNotIn('@"?"', text_fn)
        self.assertIn("band > 1024", text_fn)

    def test_loading_and_unknown_states_use_the_searching_glyph(self):
        self.assertIn("CCNMLiveSearchingGlyphImage", self.source)
        self.assertIn('systemImageNamed:@"antenna.radiowaves.left.and.right"', self.source)
        self.assertIn('systemImageNamed:@"magnifyingglass"', self.source)
        self.assertIn('CCNMLiveSearchingGlyphKey = @"__searching__"', self.source)
        self.assertIn("[self applyGlyphText:nil]", self.source)

    def test_glyph_is_white_and_rendering_is_cached(self):
        self.assertIn("label.textColor = UIColor.whiteColor", self.source)
        self.assertIn("self.glyphColor = UIColor.whiteColor", self.source)
        self.assertIn("self.selectedGlyphColor = UIColor.whiteColor", self.source)
        self.assertIn("drawnGlyphKey", self.source)
        self.assertIn("if ([key isEqualToString:self.drawnGlyphKey])", self.source)
        self.assertIn("self.glyphImage = glyph;", self.source)
        self.assertIn("self.selectedGlyphImage = glyph;", self.source)

    def test_refresh_state_matches_the_standalone_tile(self):
        for token in (
            "refreshInProgress",
            "refreshPending",
            "awaitingCurrentRefresh",
            "hasFreshServingResult",
            "refreshGeneration",
            "appliedPublishedAtMilliseconds",
            "CCNMServingStatusDidChangeDarwinNotification",
        ):
            self.assertIn(token, self.source)
        rat = self.source[self.source.index("- (void)radioAccessTechnologyDidChange:"):]
        self.assertIn("self.awaitingCurrentRefresh = YES", rat)
        self.assertIn("self.hasFreshServingResult = NO", rat)
        tap = self.source[self.source.index("- (void)buttonTapped:"):]
        self.assertIn("self.refreshGeneration++", tap)
        self.assertIn("self.refreshPending = YES", tap)
        self.assertNotIn("[super buttonTapped:", tap)

    def test_refresh_completion_uses_callback_summary_and_handles_superseded_rounds(self):
        start = self.source.index("- (void)requestBoundedServingRefresh {")
        end = self.source.index("- (void)applyNewerCachedSummary", start)
        request = self.source[start:end]
        self.assertIn("refreshWithCompletion", request)
        self.assertIn("[self applySummary:summary requireNewerTimestamp:NO]", request)
        self.assertIn("BOOL superseded = generation != self.refreshGeneration", request)
        self.assertIn("BOOL shouldRefreshAgain", request)
        self.assertNotIn("provider.currentSummary", request)

    def test_refresh_loop_is_visibility_driven_and_timers_use_common_modes(self):
        for token in (
            "- (void)controlCenterWillPresent",
            "- (void)controlCenterDidDismiss",
            "- (void)viewWillAppear:",
            "- (void)viewDidAppear:",
            "- (void)viewDidDisappear:",
            "- (void)beginVisibleSession",
            "- (void)endVisibleSession",
            "timerWithTimeInterval:CCNMLiveRefreshInterval",
            "timerWithTimeInterval:CCNMLiveRATDebounceSeconds",
            "forMode:NSRunLoopCommonModes",
        ):
            self.assertIn(token, self.source)
        begin = self.source[
            self.source.index("- (void)beginVisibleSession"):
            self.source.index("- (void)endVisibleSession")
        ]
        self.assertIn("if (self.visible)", begin)
        self.assertIn("return;", begin)
        self.assertIn("[self requestBoundedServingRefresh]", self.source)
        teardown = self.source[
            self.source.index("- (void)endVisibleSession"):
            self.source.index("- (void)registerObserversIfNeeded")
        ]
        self.assertIn("self.visible = NO", teardown)
        self.assertIn("self.refreshInProgress = NO", teardown)
        self.assertIn("[self.refreshTimer invalidate]", teardown)
        self.assertIn("[self.ratDebounceTimer invalidate]", teardown)
        self.assertIn("[self removeObserversIfNeeded]", teardown)

    def test_cache_notifications_adopt_newer_summary_only(self):
        self.assertIn("CCNMLiveServingStatusDidChangeCallback", self.source)
        self.assertIn("[viewController applyNewerCachedSummary]", self.source)
        self.assertIn("requireNewerTimestamp:YES", self.source)
        self.assertIn("appliedPublishedAtMilliseconds", self.source)
        self.assertIn("if (self.awaitingCurrentRefresh)", self.source)

    def test_refresh_path_never_writes_modem_or_policy(self):
        for forbidden in (
            "setActiveBandInfo",
            "setRatSelection",
            "_CTServerConnectionSetRATSelection",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "CCNMN78PolicyController",
        ):
            self.assertNotIn(forbidden, self.source)

    def test_no_unsafe_private_glyph_refresh_api(self):
        for forbidden in (
            "class_getInstanceVariable",
            "object_getIvar",
            "reconfigureView",
            "refreshState",
            "iconGlyph",
        ):
            self.assertNotIn(forbidden, self.source)
        self.assertNotIn("contentViewController]", self.source)
        self.assertNotIn(".contentViewController", self.source)
        self.assertEqual(self.source.count("*)contentViewController"), 1)

    def test_no_exported_coregraphics_helpers_in_glyph_path(self):
        for forbidden in (
            "CGRectIntegral(",
            "CGRectGetMinX(",
            "CGRectGetMaxX(",
            "CGContextSetFillColorWithColor(",
            "CGColorCreate",
            "CGImageCreate",
        ):
            self.assertNotIn(forbidden, self.source)
        integral = self.source[
            self.source.index("static CGRect CCNMLiveIntegralRect"):
            self.source.index("static UIImage *CCNMLiveCenteredSymbolGlyphImage")
        ]
        self.assertIn("CGFloat minX = floor(rect.origin.x);", integral)
        self.assertIn("CGFloat maxX = ceil(rect.origin.x + rect.size.width);", integral)


if __name__ == "__main__":
    unittest.main(verbosity=2)
