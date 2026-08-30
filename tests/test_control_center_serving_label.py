#!/usr/bin/env python3
"""Contracts for the formal NR Manager Control Center module."""

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
        cls.wrapper = CC_SOURCE.read_text()
        cls.live_source = (ROOT / "livecc/Sources/NetworkManagerLiveModule.m").read_text()
        cls.source = cls.wrapper + "\n" + cls.live_source
        cls.header = CC_HEADER.read_text()
        cls.makefile = MAKEFILE.read_text()
        cls.provider = PROVIDER.read_text()

    def test_formal_bundle_keeps_the_button_and_reads_policy_without_writing(self):
        self.assertIn("BUNDLE_NAME = NetworkManager", self.makefile)
        self.assertIn("NetworkManager_FILES", self.makefile)
        self.assertIn("NetworkManager_INSTALL_PATH = /Library/ControlCenter/Bundles", self.makefile)
        self.assertNotIn("networkmanagerprefs/CCNMN78PolicyReader.m", self.makefile)
        self.assertNotIn("networkmanagerprefs/CCNMN78PolicySupport.m", self.makefile)
        self.assertIn("CCNM_LIVE_MAIN_BUNDLE=1", self.makefile)
        self.assertIn("CCNMN78PolicyStatePath", self.source)
        self.assertIn("CCNMLivePolicyDidChangeCallback", self.source)
        self.assertNotIn("retire_formal_control_center_bundle", (ROOT / "package-actions/postinst.sh.in").read_text())

    def test_private_declarations_cover_button_and_expansion_contract(self):
        for text in (self.header, PRIVATE_HEADER.read_text()):
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
            "- (BOOL)shouldBeginTransitionToExpandedContentModule;",
        ):
            self.assertIn(declaration, private_header)

    def test_formal_policy_state_controls_selection_only(self):
        for token in (
            'self.title = @"NR Manager";',
            "CCNMLivePolicyRequested()",
            "self.selected = requested",
            "CCNMN78PolicyStatePath",
            "CCNMLivePolicyDidChangeCallback",
            "CCNMLivePolicyChangedNotification",
        ):
            self.assertIn(token, self.source)
        for forbidden in (
            "CCNMN78PolicyController.h",
            "CCNMN78PolicyHasOutstandingSetter",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "setActiveBandInfo",
            "setRatSelection",
            "_CTServerConnectionSetRATSelection",
        ):
            self.assertNotIn(forbidden, self.source)

    def test_selected_state_uses_the_original_orange_accent_and_readable_glyph(self):
        self.assertIn("CCNMLivePolicyAccentColor", self.source)
        self.assertIn("colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0", self.source)
        self.assertIn("self.glyphColor = UIColor.whiteColor", self.source)
        self.assertIn("self.selectedGlyphColor = CCNMLivePolicyAccentColor()", self.source)
        self.assertIn("self.glyphImage = glyph", self.source)
        self.assertIn("self.selectedGlyphImage = selectedGlyph", self.source)

    def test_long_press_cannot_enter_the_redundant_expanded_preview(self):
        marker = "- (BOOL)shouldBeginTransitionToExpandedContentModule"
        self.assertIn(marker, self.source)
        method = self.source[self.source.index(marker):]
        self.assertIn("return NO;", method)
        self.assertNotIn("contentModuleContext", method)

    def test_stable_glyph_uses_fresh_serving_truth(self):
        self.assertIn("CCNMLiveTextForSummary", self.source)
        self.assertIn('stringWithFormat:@"B%lld"', self.source)
        self.assertIn('stringWithFormat:@"n%lld"', self.source)
        self.assertIn("band > 1024", self.source)
        text_fn = self.source[
            self.source.index("static NSString *CCNMLiveTextForSummary"):
            self.source.index("static UIImage *CCNMLiveGlyphImageWithColor")
        ]
        self.assertNotIn('@"?"', text_fn)

    def test_loading_and_unknown_states_use_the_searching_glyph(self):
        for token in (
            "CCNMLiveSearchingGlyphImageWithColor",
            'systemImageNamed:@"antenna.radiowaves.left.and.right"',
            'systemImageNamed:@"magnifyingglass"',
            "self.glyphImage = glyph",
        ):
            self.assertIn(token, self.source)

    def test_refresh_state_matches_the_standalone_tile(self):
        for token in (
            "refreshInProgress",
            "refreshPending",
            "awaitingCurrentRefresh",
            "hasFreshServingResult",
            "refreshGeneration",
            "appliedPublishedAtMilliseconds",
            "CCNMServingStatusDidChangeDarwinNotification",
            "shouldRefreshAgain",
        ):
            self.assertIn(token, self.source)
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

    def test_refresh_loop_is_visibility_driven_and_uses_standalone_timer_modes(self):
        for token in (
            "- (void)controlCenterWillPresent",
            "- (void)controlCenterDidDismiss",
            "- (void)viewWillAppear:",
            "- (void)viewDidDisappear:",
            "- (void)beginVisibleSession",
            "- (void)endVisibleSession",
            "scheduledTimerWithTimeInterval:CCNMLiveRefreshInterval",
            "scheduledTimerWithTimeInterval:CCNMLiveRATDebounceSeconds",
        ):
            self.assertIn(token, self.source)
        self.assertNotIn("NSRunLoopCommonModes", self.source)
        teardown = self.source[
            self.source.index("- (void)endVisibleSession"):
            self.source.index("- (void)registerObserversIfNeeded")
        ]
        self.assertIn("self.visible = NO", teardown)
        self.assertIn("[self.refreshTimer invalidate]", teardown)
        self.assertIn("[self.ratDebounceTimer invalidate]", teardown)
        self.assertIn("[self removeObserversIfNeeded]", teardown)

    def test_cache_notifications_adopt_newer_summary_only(self):
        self.assertIn("CCNMLiveServingStatusDidChangeCallback", self.source)
        self.assertIn("[viewController applyNewerCachedSummary]", self.source)
        self.assertIn("requireNewerTimestamp:YES", self.source)
        self.assertIn("appliedPublishedAtMilliseconds", self.source)

    def test_no_unsafe_private_glyph_refresh_api(self):
        for forbidden in (
            "class_getInstanceVariable",
            "object_getIvar",
            "reconfigureView",
            "refreshState",
            "iconGlyph",
            ".contentViewController",
        ):
            self.assertNotIn(forbidden, self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
