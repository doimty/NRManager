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

    def test_glyph_is_white_in_every_state(self):
        """The split-out prototype's glyph is white, and so are the stock tiles
        beside it.

        The amber in the original pre-n78 release was the toggle's
        -selectedColor, which fills the tile background while a toggle is on; it
        was never the glyph tint. CCUIButtonModuleViewController has no such
        property, and tinting the glyph amber instead forced the selected state
        to pick a second colour that could be told apart from it, which produced
        the black text the user reported. Control Center draws its own selection
        treatment, so one white glyph serves both states.
        """
        self.assertIn("return UIColor.whiteColor;", self.source)
        self.assertNotIn("colorWithRed:1.00 green:0.58 blue:0.00", self.source)
        # No state may reach a dark glyph. Both tints and both images are the
        # same white, so it cannot matter which one the framework picks.
        self.assertNotIn("UIColor.blackColor", self.source)
        self.assertNotIn("blackColor", self.source)
        self.assertIn("self.glyphColor = CCNMServingGlyphColor();", self.source)
        self.assertIn("self.selectedGlyphColor = CCNMServingGlyphColor();", self.source)
        presentation = self.source[
            self.source.index("- (void)refreshModulePresentation {"):
            self.source.index("@implementation CCNetworkManager {")
        ]
        self.assertIn("CCNMServingGlyphImage(text, CCNMServingGlyphColor())", presentation)
        self.assertIn(
            "CCNMServingSearchingGlyphImage(CCNMServingGlyphColor())", presentation
        )
        # One rendered image feeds both properties; a second tint would
        # reintroduce the two-colour split this test exists to prevent.
        self.assertIn("self.glyphImage = glyph;", presentation)
        self.assertIn("self.selectedGlyphImage = glyph;", presentation)

    def test_presentation_does_no_filesystem_or_drawing_work_per_call(self):
        """Presentation runs on adoption, every timer tick, every notification and
        every completion, and those land during the Control Center open
        animation. It must be cheap.

        Reading the policy is up to five plist loads on the main thread, and
        rendering a glyph is an offscreen bitmap context plus a layer render or a
        symbol draw. Neither may happen on a pass where nothing changed.
        """
        presentation = self.source[
            self.source.index("- (void)refreshModulePresentation {"):
            self.source.index("@implementation CCNetworkManager {")
        ]
        # The policy comes from the cached snapshot, never from a fresh read.
        self.assertNotIn("CCNMReadN78PolicyState()", presentation)
        self.assertIn("self.policySnapshot ?: [self refreshPolicySnapshot]", presentation)
        # The snapshot is refreshed exactly where the policy can have changed:
        # the change notification and the sampling guard. It is dropped on
        # dismissal, because the notification is not observed off screen, so the
        # next session cannot draw from a stale copy.
        self.assertEqual(self.source.count("CCNMReadN78PolicyState()"), 1)
        self.assertIn("[module refreshPolicySnapshot];", self.source)
        end = self.source[self.source.index("- (void)endVisibleSession {"):]
        self.assertIn("self.policySnapshot = nil;", end)
        # Redrawing an unchanged glyph is pure jank, so the rendered string is
        # cached and compared.
        self.assertIn("drawnGlyphKey", self.source)
        self.assertIn('CCNMServingSearchingGlyphKey = @"__searching__"', self.source)
        self.assertIn(
            "if (![glyphKey isEqualToString:self.drawnGlyphKey]) {", presentation
        )
        self.assertIn("self.drawnGlyphKey = glyphKey;", presentation)
        # The glyph properties are passthroughs to a framework-owned button view,
        # so a reloaded view has no glyph installed. The cache must be dropped
        # there or the very next presentation would skip the draw and leave the
        # tile blank.
        load = self.source[
            self.source.index("- (void)viewDidLoad {"):
            self.source.index("#pragma mark - Visible session")
        ]
        self.assertIn("self.drawnGlyphKey = nil;", load)
        # -setSelected: makes the framework run its own state-change pass, so it
        # is assigned only on an actual change.
        self.assertIn("if (self.selected != requested) {", presentation)

    def test_visible_session_is_idempotent_not_merely_harmless(self):
        """Three callbacks lead to -beginVisibleSession because which one Control
        Center delivers depends on how the tile is hosted. Without an early
        return, opening Control Center paid for three cache reads, three policy
        reads and three presentation passes during the open animation.
        """
        begin = self.source[
            self.source.index("- (void)beginVisibleSession {"):
            self.source.index("- (void)endVisibleSession {")
        ]
        self.assertIn("if (self.visible) {", begin)
        self.assertIn("return;", begin[:begin.index("self.visible = YES;")])
        # The early return is only correct because the flag is cleared on the way
        # out; otherwise the next presentation would be skipped entirely.
        end = self.source[self.source.index("- (void)endVisibleSession {"):]
        self.assertIn("self.visible = NO;", end)

    def test_refresh_completion_uses_provider_summary_without_a_second_cache_read(self):
        start = self.source.index("- (void)requestServingRefreshIfNeeded {")
        end = self.source.index("// Adopts whatever the shared provider last published.", start)
        request = self.source[start:end]
        callback = request[request.index("[provider refreshWithCompletion:"):]
        self.assertIn(
            "[strongSelf applyPublishedSummary:summary requireNewerTimestamp:NO];",
            callback,
        )
        self.assertNotIn("provider.currentSummary", callback)

    def test_refresh_wait_state_matches_the_standalone_tile(self):
        self.assertIn("awaitingCurrentRefresh", self.source)
        self.assertIn(
            "CCNMServingGlyphText(self.servingSummary, self.awaitingCurrentRefresh)",
            self.source,
        )
        start = self.source.index("- (void)radioAccessTechnologyDidChange:")
        end = self.source.index("- (void)ratDebounceTimerFired", start)
        self.assertIn("strongSelf.awaitingCurrentRefresh = YES;", self.source[start:end])
        start = self.source.index("- (void)buttonTapped:")
        end = self.source.index("#pragma mark - Refresh", start)
        self.assertIn("self.awaitingCurrentRefresh = YES;", self.source[start:end])
        teardown = self.source[
            self.source.index("- (void)endVisibleSession {"):
            self.source.index("- (void)registerObserversIfNeeded {")
        ]
        self.assertIn("self.awaitingCurrentRefresh = NO;", teardown)
        request_start = self.source.index("- (void)requestServingRefreshIfNeeded {")
        request_end = self.source.index("// Adopts whatever the shared provider last published.", request_start)
        request = self.source[request_start:request_end]
        self.assertIn("BOOL refreshAgain = strongSelf.refreshPending && strongSelf.visible;", request)
        self.assertIn("strongSelf.awaitingCurrentRefresh = refreshAgain;", request)
        self.assertIn("[strongSelf applyPublishedSummary:summary requireNewerTimestamp:NO];", request)

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
        # A sampler round that never reports back must not pin the tile forever,
        # but the budget must clear the sampler's own worst case. Ten rounds at
        # 0.5 s delay + 5 s refresh wait + 0.5 s settle + 5 s copy wait is about
        # 110 s, so a 20 s budget declared ordinary slow rounds stalled and threw
        # their results away.
        self.assertIn("CCNMServingRefreshStallTimeout = 120.0", self.source)
        self.assertIn(
            "now - self.servingRefreshStartedAt > CCNMServingRefreshStallTimeout",
            self.source,
        )
        stall = self.source[
            self.source.index("- (void)clearStalledRefreshIfNeeded {"):
            self.source.index("- (void)requestServingRefreshIfNeeded {")
        ]
        # Abandoning a round must not also charge it against the rate floor, or
        # the immediate retry is swallowed and nothing is in flight for a whole
        # timer period.
        self.assertIn("self.servingRefreshLastAttempt = 0;", stall)
        self.assertNotIn("self.servingRefreshLastAttempt = now;", stall)
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
            "- (void)viewDidAppear:",
            "- (void)viewDidDisappear:",
            "- (void)beginVisibleSession",
            "- (void)endVisibleSession",
            "timerWithTimeInterval:CCNMServingVisibleRefreshInterval",
            "timerWithTimeInterval:CCNMServingRATDebounceSeconds",
            "CTServiceRadioAccessTechnologyDidChangeNotification",
        ):
            self.assertIn(token, self.source)
        # iconGlyph was the old lazy trigger. Nothing may refresh from a draw.
        self.assertNotIn("iconGlyph", self.source)
        # An off-screen tile must not keep sampling.
        request = self.source[
            self.source.index("- (void)requestServingRefreshIfNeeded {"):
            self.source.index("// Adopts whatever the shared provider last published.")
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

    def test_cc_bundle_links_nothing_beyond_the_device_verified_baseline(self):
        """This bundle loads into SpringBoard, so its dependency set is pinned to the
        device-verified roothide baseline and any addition fails the release gate.

        CGRectMake and CGSizeMake are static inline in CGGeometry.h and are free.
        CGRectIntegral is a real exported symbol, and calling it made the bundle
        link CoreGraphics, which failed cloud run 32477871435 after the host tests
        had already passed. This test moves that failure to the host.
        """
        # Exported CoreGraphics entry points that a glyph-drawing path might reach
        # for. Each one pulls in the framework; the inline CG*Make constructors do
        # not, which is why they are deliberately absent from this list.
        for exported in (
            "CGRectIntegral(",
            "CGRectGetMinX(",
            "CGRectGetMinY(",
            "CGRectGetMaxX(",
            "CGRectGetMaxY(",
            "CGRectGetWidth(",
            "CGRectGetHeight(",
            "CGRectInset(",
            "CGRectOffset(",
            "CGRectStandardize(",
            "CGContextSetFillColorWithColor(",
            "CGColorCreate",
            "CGImageCreate",
        ):
            self.assertNotIn(exported, self.source)
        # The replacement must reproduce CGRectIntegral's semantics rather than
        # quietly rounding differently.
        integral = self.source[
            self.source.index("static CGRect CCNMServingIntegralRect(CGRect rect) {"):
            self.source.index("static UIImage *CCNMServingCenteredSymbolGlyphImage(")
        ]
        self.assertIn("CGFloat minX = floor(rect.origin.x);", integral)
        self.assertIn("CGFloat minY = floor(rect.origin.y);", integral)
        self.assertIn("CGFloat maxX = ceil(rect.origin.x + rect.size.width);", integral)
        self.assertIn("CGFloat maxY = ceil(rect.origin.y + rect.size.height);", integral)
        self.assertIn("return CGRectMake(minX, minY, maxX - minX, maxY - minY);", integral)
        self.assertIn("[tinted drawInRect:CCNMServingIntegralRect(drawRect)]", self.source)

    def test_timers_run_in_common_modes_so_gestures_cannot_stall_them(self):
        """Control Center is gesture driven, so its run loop spends real time in
        tracking mode. NSTimer's scheduled* convenience installs into the default
        mode only, where a timer does not fire during tracking, which made the tile
        look like it refreshed only when touched.
        """
        self.assertNotIn("scheduledTimerWithTimeInterval", self.source)
        self.assertEqual(2, self.source.count("forMode:NSRunLoopCommonModes"))
        self.assertIn("addTimer:self.visibleRefreshTimer", self.source)
        self.assertIn("addTimer:strongSelf.ratDebounceTimer", self.source)

    def test_a_presentation_is_not_charged_against_the_rate_floor(self):
        """Opening Control Center is a user-initiated event like a tap.

        Charging it against CCNMServingRefreshMinimumInterval silently skipped the
        fresh sample whenever the previous round had just run, so the tile kept
        showing whatever the cache held until the user tapped it.
        """
        begin = self.source[
            self.source.index("- (void)beginVisibleSession {"):
            self.source.index("- (void)endVisibleSession {")
        ]
        self.assertIn("self.servingRefreshLastAttempt = 0;", begin)
        self.assertIn("[self adoptPublishedServingSummary]", begin)
        self.assertIn("[self requestServingRefreshIfNeeded]", begin)

    def test_dismissal_clears_any_in_flight_round(self):
        """A leaked in-flight flag blocked every later trigger, including a tap,
        until the stall budget expired. The provider round keeps running and still
        publishes to the shared cache; only its report into this tile is dropped.
        """
        teardown = self.source[
            self.source.index("- (void)endVisibleSession {"):
            self.source.index("- (void)registerObserversIfNeeded {")
        ]
        self.assertIn("if (self.servingRefreshInProgress) {", teardown)
        self.assertIn("self.servingRefreshInProgress = NO;", teardown)
        self.assertIn("self.refreshGeneration++;", teardown)

    def test_published_samples_are_adopted_even_while_a_round_is_in_flight(self):
        """The provider publishes and posts its Darwin notification before this
        tile's completion block runs, and a superseded or stalled round drops its
        result entirely. Refusing the publish while busy therefore discarded good
        samples. The monotonic published-at gate is what makes this safe.
        """
        adopt = self.source[
            self.source.index("- (void)adoptPublishedServingSummary {"):
            self.source.index("#pragma mark - Presentation")
        ]
        self.assertNotIn("if (self.servingRefreshInProgress)", adopt)
        self.assertIn("requireNewerTimestamp:YES", adopt)
        self.assertIn(
            "if (requireNewerTimestamp && publishedAt <= self.appliedPublishedAtMilliseconds)",
            adopt,
        )
        self.assertIn("CCNMServingSummaryPublishedAtMillisecondsKey", adopt)
        # A policy change invalidates the drawn sample, so the gate must reset or
        # the next publish would be rejected as not newer.
        invalidate = self.source[
            self.source.index("- (void)invalidateServingStatus {"):
            self.source.index("- (void)clearStalledRefreshIfNeeded {")
        ]
        self.assertIn("self.appliedPublishedAtMilliseconds = -1;", invalidate)
        self.assertIn("_appliedPublishedAtMilliseconds = -1;", self.source)
        # The completion block owns the freshest result for its own round, so it
        # must not be rejected by its own timestamp gate.
        self.assertIn("requireNewerTimestamp:NO", self.source)

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
            "CCNMServingGlyphImage(text, CCNMServingGlyphColor())",
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
