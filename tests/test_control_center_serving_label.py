#!/usr/bin/env python3
"""Contracts for truthful asynchronous serving-band text in Control Center."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CC_SOURCE = ROOT / "CCNetworkManager.x"
CC_HEADER = ROOT / "CCNetworkManager.h"
PRIVATE_HEADER = ROOT / "include/NetworkManagerControlCenterUIKitPrivate.h"
MAKEFILE = ROOT / "Makefile"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"


class ControlCenterServingLabelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = CC_SOURCE.read_text()
        cls.header = CC_HEADER.read_text()
        cls.makefile = MAKEFILE.read_text()
        cls.policy = POLICY_SOURCE.read_text()

    def test_cc_bundle_builds_the_reviewed_read_only_serving_stack(self):
        self.assertIn("networkmanagerprefs/CCNMServingStatusProvider.m", self.makefile)
        self.assertIn("networkmanagerprefs/CCNMServingCellSampler.m", self.makefile)
        self.assertIn('#import "networkmanagerprefs/CCNMServingStatusProvider.h"', self.source)
        # CCUIButtonModuleViewController is exported by the private framework but
        # is absent from the vendored headers, so the bundle declares it locally.
        self.assertIn("-Iinclude", self.makefile)
        self.assertTrue(PRIVATE_HEADER.is_file())

    def test_private_declarations_never_import_the_framework_as_a_module(self):
        """Regression guard for the pinned macOS runner build failure.

        The vendored ControlCenterUIKit headers carry a module.modulemap, while
        the CCSupport templates install a second overlapping copy into
        $(THEOS)/include. Any angle-bracket import of the framework makes the
        build depend on which copy Clang finds first, which failed on the runner
        with duplicate protocol definitions, ambiguous protocol references, and
        an incomplete umbrella, all promoted to errors by -Werror. The bundle
        must therefore use one self-contained local header.
        """
        self.assertNotIn("#import <ControlCenterUIKit/", self.header)
        self.assertNotIn("#import <ControlCenterUIKit/", self.source)
        self.assertNotIn('#import "ControlCenterUIKit/', self.header)
        self.assertNotIn('#import "ControlCenterUIKit/', self.source)
        self.assertIn('#import "NetworkManagerControlCenterUIKitPrivate.h"', self.header)
        # A local directory named ControlCenterUIKit would reintroduce the
        # ambiguity it is meant to avoid.
        self.assertFalse((ROOT / "include/ControlCenterUIKit").exists())
        private_header = PRIVATE_HEADER.read_text()
        for declaration in (
            "@protocol CCUIContentModuleContentViewController <NSObject>",
            "@protocol CCUIContentModule <NSObject>",
            "@interface CCUIButtonModuleViewController : UIViewController",
            "@property (nonatomic, strong) UIImage *glyphImage;",
            "- (void)buttonTapped:(id)button forEvent:(UIEvent *)event;",
        ):
            self.assertIn(declaration, private_header)
        self.assertNotIn("#import <ControlCenterUIKit/", private_header)

    def test_stable_glyph_uses_fresh_serving_truth_not_policy_name(self):
        self.assertIn("CCNMServingGlyphText", self.source)
        self.assertIn("CCNMServingSummaryBandKey", self.source)
        self.assertIn('stringWithFormat:@"B%@"', self.source)
        self.assertIn('stringWithFormat:@"n%@"', self.source)
        stable = self.source[self.source.index("static NSString *CCNMServingGlyphText"):]
        self.assertNotIn('requested ? @"n78" : @"Auto"', stable)

    def test_unknown_loading_and_policy_priority_are_explicit(self):
        """No serving band means the searching antenna, never a question mark.

        CCNMServingGlyphText returns nil for every no-band case so the single
        caller can pick the searching glyph, matching the split-out prototype.
        """
        text_fn = self.source[
            self.source.index("static NSString *CCNMServingGlyphText"):
            self.source.index("static UIImage *CCNMServingGlyphImage")
        ]
        self.assertNotIn('@"?"', text_fn)
        self.assertEqual(3, text_fn.count("return nil;"))
        self.assertIn("CCNMServingSearchingGlyphImage", self.source)
        self.assertIn('systemImageNamed:@"antenna.radiowaves.left.and.right"', self.source)
        self.assertIn('systemImageNamed:@"magnifyingglass"', self.source)
        self.assertIn("CCNMPolicyIsTransitioning", self.source)
        self.assertIn("CCNMPolicyNeedsRecovery", self.source)
        self.assertNotIn("policyOperationPending", self.source)

    def test_glyph_uses_the_original_release_accent_colour(self):
        """The pre-n78 release drew this colour through the toggle's
        -selectedColor, which CCUIButtonModuleViewController does not have. It
        now belongs to the glyph, so both the text and the searching antenna
        carry it.
        """
        self.assertIn(
            "return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];",
            self.source,
        )
        self.assertIn("self.glyphColor = CCNMServingGlyphColor();", self.source)
        presentation = self.source[
            self.source.index("- (void)refreshModulePresentation {"):
            self.source.index("@implementation CCNetworkManager {")
        ]
        self.assertIn(
            "self.glyphImage = CCNMServingGlyphImage(text, CCNMServingGlyphColor());",
            presentation,
        )
        self.assertIn(
            "self.glyphImage = CCNMServingSearchingGlyphImage(CCNMServingGlyphColor());",
            presentation,
        )
        # Nothing in the tile may fall back to the old plain white glyph.
        self.assertNotIn("UIColor.whiteColor", self.source)

    def test_refresh_is_async_bounded_and_never_writes_modem(self):
        for token in (
            "servingRefreshInProgress",
            "servingRefreshLastAttempt",
            "servingRefreshStartedAt",
            "refreshWithCompletion",
            "CCNMServingSummaryStaleKey",
            "dispatch_get_main_queue",
            "refreshModulePresentation",
        ):
            self.assertIn(token, self.source)
        # A sampler round that never reports back must not pin the tile forever.
        self.assertIn("CCNMServingRefreshStallTimeout = 20.0", self.source)
        self.assertIn(
            "now - self.servingRefreshStartedAt > CCNMServingRefreshStallTimeout",
            self.source,
        )
        start = self.source.index("- (void)requestServingRefreshIfNeeded {")
        end = self.source.index("- (void)adoptPublishedServingSummary {", start)
        refresh = self.source[start:end]
        # The tile must never sample while the settings page owns the modem.
        self.assertIn("CCNMN78PolicyHasOutstandingSetter()", refresh)
        self.assertIn("CCNMPolicyIsTransitioning(policy)", refresh)
        self.assertIn("CCNMPolicyNeedsRecovery(policy)", refresh)
        for forbidden in (
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "setActiveBandInfo",
            "setRatSelection",
            "_CTServerConnectionSetRATSelection",
        ):
            self.assertNotIn(forbidden, refresh)

    def test_refresh_loop_is_driven_by_visibility_not_by_drawing(self):
        """The tile refreshes itself while Control Center is on screen.

        The previous CCUIToggleModule implementation only refreshed when the
        framework happened to re-read its read-only iconGlyph, so the displayed
        band lagged behind reality. Refresh triggers must now be visibility,
        a timer, radio-technology changes, and taps.
        """
        self.assertIn("CCNMServingVisibleRefreshInterval = 15.0", self.source)
        self.assertIn("CCNMServingRATDebounceSeconds = 0.25", self.source)
        self.assertIn("CCNMServingRefreshMinimumInterval", self.source)
        for token in (
            "- (void)controlCenterWillPresent",
            "- (void)controlCenterDidDismiss",
            "- (void)viewWillAppear:",
            "- (void)viewDidDisappear:",
            "- (void)beginVisibleSession",
            "- (void)endVisibleSession",
            "scheduledTimerWithTimeInterval:CCNMServingVisibleRefreshInterval",
            "scheduledTimerWithTimeInterval:CCNMServingRATDebounceSeconds",
            "CTServiceRadioAccessTechnologyDidChangeNotification",
        ):
            self.assertIn(token, self.source)
        # iconGlyph was the old lazy trigger. Nothing may refresh from a draw.
        self.assertNotIn("iconGlyph", self.source)
        # An off-screen tile must not keep sampling.
        request = self.source[
            self.source.index("- (void)requestServingRefreshIfNeeded {"):
            self.source.index("- (void)adoptPublishedServingSummary {")
        ]
        self.assertIn("if (!self.visible || self.servingRefreshInProgress)", request)
        teardown = self.source[
            self.source.index("- (void)endVisibleSession {"):
            self.source.index("- (void)registerObserversIfNeeded {")
        ]
        self.assertIn("self.visible = NO", teardown)
        self.assertIn("[self.visibleRefreshTimer invalidate]", teardown)
        self.assertIn("[self.ratDebounceTimer invalidate]", teardown)
        self.assertIn("[self removeObserversIfNeeded]", teardown)

    def test_superseded_refresh_result_cannot_publish(self):
        """A stalled round that reports back late must not overwrite newer state."""
        self.assertIn("refreshGeneration", self.source)
        self.assertIn("NSUInteger generation = ++self.refreshGeneration", self.source)
        self.assertIn("if (generation != strongSelf.refreshGeneration)", self.source)

    def test_cache_notification_uses_only_safe_public_refresh(self):
        for token in (
            "CCNMServingStatusDidChangeDarwinNotification",
            "CCNMServingStatusDidChangeCallback",
            "refreshModulePresentation",
            "self.glyphImage = CCNMServingGlyphImage",
        ):
            self.assertIn(token, self.source)
        for forbidden in (
            "class_getInstanceVariable",
            "object_getIvar",
            "reconfigureView",
        ):
            self.assertNotIn(forbidden, self.source)

    def test_module_only_vends_the_serving_tile_view_controller(self):
        self.assertIn("@interface CCNetworkManager : NSObject <CCUIContentModule>", self.header)
        self.assertIn(
            "@interface CCNetworkManagerViewController : CCUIButtonModuleViewController",
            self.header,
        )
        self.assertNotIn("CCUIToggleModule", self.header)
        self.assertNotIn("CCUIToggleModule", self.source)
        module = self.source[self.source.index("@implementation CCNetworkManager {"):]
        self.assertIn("_servingTileViewController", module)
        self.assertIn(
            "- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController",
            module,
        )

    def test_content_view_controller_is_implemented_never_sent(self):
        """Regression guard for the three SpringBoard SIGABRT crashes.

        Sending -contentViewController to the framework's module object aborted on
        iOS 15.1.1 because CCUIToggleModule does not expose that getter. The
        module now owns and implements the accessor, so it must never appear as a
        message send or property access anywhere in the bundle source.
        """
        self.assertNotIn("contentViewController]", self.source)
        self.assertNotIn(".contentViewController", self.source)
        self.assertEqual(
            self.source.count("*)contentViewController"),
            1,
            "contentViewController must appear exactly once, as the implementation",
        )
        self.assertNotIn("_viewController", self.source)
        self.assertNotIn("reconfigureView", self.source)
        self.assertNotIn("refreshState", self.source)

    def test_tap_only_forces_a_sample_and_never_writes_policy(self):
        start = self.source.index("- (void)buttonTapped:")
        callback = self.source[start:self.source.index("#pragma mark - Refresh", start)]
        # The tap must not reach the framework's own selection handling, which
        # would flip the displayed state without any policy change behind it.
        self.assertNotIn("[super buttonTapped:", callback)
        self.assertIn("[self requestServingRefreshIfNeeded]", callback)
        for writer in (
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
        ):
            self.assertNotIn(writer, callback)
            self.assertNotIn(writer, self.source)

    def test_selection_mirrors_policy_truth_and_is_display_only(self):
        presentation = self.source[self.source.index("- (void)refreshModulePresentation {"):]
        self.assertIn("BOOL requested = CCNMPolicyIsRequested(state)", presentation)
        self.assertIn("self.selected = requested", presentation)
        self.assertNotIn("CCNMServingSummarySuccessKey", presentation)


if __name__ == "__main__":
    unittest.main(verbosity=2)
