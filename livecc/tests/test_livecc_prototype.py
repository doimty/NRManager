#!/usr/bin/env python3
"""Static and executable contracts for the isolated Live CC prototype."""

from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


LIVECC = Path(__file__).resolve().parents[1]
ROOT = LIVECC.parent
SOURCE = LIVECC / "Sources/NetworkManagerLiveModule.m"
PATH_SHIM = LIVECC / "Sources/CCNMLiveServingPaths.m"
FORMATTER = LIVECC / "Sources/CCNMLiveBandText.c"


class LiveCCPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.makefile = (LIVECC / "Makefile").read_text()
        cls.control = (LIVECC / "control").read_text()
        with (LIVECC / "Resources/Info.plist").open("rb") as handle:
            cls.plist = plistlib.load(handle)

    def test_package_bundle_and_principal_class_are_separate(self):
        self.assertIn("Package: me.nixuge.networkmanager.livecc", self.control)
        self.assertEqual(self.plist["CFBundleIdentifier"], "me.nixuge.networkmanager.livecc")
        self.assertEqual(self.plist["CFBundleExecutable"], "NetworkManagerLive")
        self.assertEqual(self.plist["NSPrincipalClass"], "NetworkManagerLiveModule")
        self.assertEqual(self.plist["CFBundleShortVersionString"], "0.0.4")
        self.assertEqual(self.plist["CFBundleVersion"], "4")
        self.assertIn("Version: 0.0.4", self.control)
        self.assertIn("BUNDLE_NAME = NetworkManagerLive", self.makefile)
        self.assertIn("TARGET := iphone:clang:latest:14.0", self.makefile)
        self.assertNotIn("BUNDLE_NAME = NetworkManager\n", self.makefile)

    def test_local_build_does_not_modify_the_root_workflow(self):
        root_makefile = (ROOT / "Makefile").read_text()
        root_control = (ROOT / "control").read_text()
        root_plist = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        workflow = (ROOT / ".github/workflows/livecc-prototype.yml").read_text()
        self.assertNotIn("livecc", root_makefile.lower())
        self.assertIn("Package: me.nixuge.networkmanager\n", root_control)
        self.assertEqual(root_plist["CFBundleExecutable"], "NetworkManager")
        self.assertEqual(root_plist["NSPrincipalClass"], "CCNetworkManager")
        self.assertIn('cd livecc && make clean package ARCHS="arm64 arm64e"', workflow)
        self.assertIn("THEOS_PACKAGE_SCHEME: roothide", workflow)
        self.assertIn(
            "./Library/ControlCenter/Bundles/NetworkManagerLive.bundle/NetworkManagerLive",
            workflow,
        )
        self.assertNotIn("payload_root/var/jb/Library/ControlCenter", workflow)
        self.assertIn("CCNMCellMonitorAsyncState", workflow)
        self.assertIn("CCNMLiveCellMonitorAsyncState", workflow)
        self.assertIn("CCNMLiveServingStatusProvider", workflow)
        self.assertNotIn("make -C .", workflow)

    def test_bundle_compiles_only_read_only_shared_dependencies(self):
        self.assertIn("../networkmanagerprefs/CCNMServingStatusProvider.m", self.makefile)
        self.assertIn("../networkmanagerprefs/CCNMServingCellSampler.m", self.makefile)
        self.assertNotIn("CCNMN78PolicyController.m", self.makefile)
        self.assertIn("Sources/CCNMLiveServingPaths.m", self.makefile)
        self.assertIn(
            "-DCCNMServingStatusProvider=CCNMLiveServingStatusProvider", self.makefile
        )
        self.assertIn(
            "-DCCNMCellMonitorAsyncState=CCNMLiveCellMonitorAsyncState", self.makefile
        )
        self.assertIn("ifneq ($(THEOS_PACKAGE_SCHEME),roothide)", self.makefile)
        self.assertIn("NetworkManagerLive_PRIVATE_FRAMEWORKS = ControlCenterUIKit", self.makefile)
        self.assertIn("NetworkManagerLive_LDFLAGS += -undefined dynamic_lookup", self.makefile)
        self.assertNotIn("NetworkManagerLive_LIBRARIES = roothide", self.makefile)

    def test_installed_bundle_files_do_not_overlap_the_main_package(self):
        install_root = "/Library/ControlCenter/Bundles"
        main_files = {
            f"{install_root}/NetworkManager.bundle/Info.plist",
            f"{install_root}/NetworkManager.bundle/NetworkManager",
        }
        live_files = {
            f"{install_root}/NetworkManagerLive.bundle/Info.plist",
            f"{install_root}/NetworkManagerLive.bundle/NetworkManagerLive",
        }
        self.assertTrue(main_files.isdisjoint(live_files))
        self.assertIn(
            "NetworkManagerLive_INSTALL_PATH = /Library/ControlCenter/Bundles",
            self.makefile,
        )
        self.assertNotIn("SUBPROJECTS", self.makefile)


class LiveCCStaticSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()
        cls.path_shim = PATH_SHIM.read_text()
        cls.all_live_sources = "\n".join(
            path.read_text() for path in (LIVECC / "Sources").iterdir() if path.is_file()
        )

    def test_uses_owned_button_controller_not_toggle_module(self):
        self.assertIn(
            "NetworkManagerLiveViewController : CCUIButtonModuleViewController", self.source
        )
        self.assertIn("NetworkManagerLiveModule : NSObject <CCUIContentModule>", self.source)
        self.assertIn(
            "_contentViewController = [[NetworkManagerLiveViewController alloc] init]",
            self.source,
        )
        self.assertNotIn("CCUIToggleModule", self.all_live_sources)

    def test_direct_glyph_assignment_has_no_private_refresh_path(self):
        apply_method = self.source[self.source.index("- (void)applySummary:") :]
        self.assertIn("self.glyphImage = CCNMLiveGlyphImage", apply_method)
        for forbidden in (
            "reconfigureView",
            "refreshState",
            "class_getInstanceVariable",
            "object_getIvar",
            "valueForKey:",
            "setValue:forKey:",
        ):
            self.assertNotIn(forbidden, self.all_live_sources)

    def test_no_policy_or_modem_writer_is_reachable_from_live_sources(self):
        for forbidden in (
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "enableWithCompletion:",
            "disableWithCompletion:",
            "recoverWithCompletion:",
            "setActiveBandInfo",
            "setRatSelection",
            "_CTServerConnectionSetRATSelection",
        ):
            self.assertNotIn(forbidden, self.all_live_sources)
        self.assertIn("CCNMN78PolicyStatePath", self.path_shim)
        self.assertIn("CCNMN78PolicyLockPath", self.path_shim)
        self.assertIn("NetworkManagerLive.bundle", self.path_shim)
        self.assertIn("bundleForClass", self.path_shim)
        self.assertIn("/nonexistent/networkmanager-live", self.path_shim)
        for forbidden in ("jbroot(", "libroothide", "roothide.h"):
            self.assertNotIn(forbidden, self.path_shim)

    def test_refresh_timer_debounce_and_lifecycle_are_explicit(self):
        for token in (
            "CCNMLiveRefreshInterval = 15.0",
            "CCNMLiveRATDebounceSeconds = 0.25",
            "CTServiceRadioAccessTechnologyDidChangeNotification",
            "CCNMServingStatusDidChangeDarwinNotification",
            "controlCenterWillPresent",
            "viewWillAppear:",
            "controlCenterDidDismiss",
            "viewDidDisappear:",
            "[self.refreshTimer invalidate]",
            "[self.ratDebounceTimer invalidate]",
            "removeObserversIfNeeded",
        ):
            self.assertIn(token, self.source)
        self.assertEqual(self.source.count("repeats:YES"), 1)
        self.assertEqual(self.source.count("repeats:NO"), 1)
        self.assertGreaterEqual(self.source.count("__weak typeof(self)"), 3)
        self.assertIn("[weakSelf refreshTimerFired:timer]", self.source)
        self.assertIn("[weakDebounceSelf ratDebounceTimerFired:timer]", self.source)
        rat_start = self.source.index("- (void)radioAccessTechnologyDidChange:")
        rat_end = self.source.index("- (void)ratDebounceTimerFired:", rat_start)
        rat_handler = self.source[rat_start:rat_end]
        self.assertIn("dispatch_get_main_queue", rat_handler)
        self.assertIn("!self.visible", rat_handler)

    def test_searching_state_uses_radio_symbol_and_keeps_one_pending_refresh(self):
        for token in (
            "CCNMLiveSearchingGlyphImage",
            "CCNMLiveCenteredSymbolGlyphImage",
            'systemImageNamed:@"antenna.radiowaves.left.and.right"',
            'systemImageNamed:@"magnifyingglass"',
            "CGSizeMake(70.0, 70.0)",
            "CGRectIntegral(drawRect)",
            "UIColor.whiteColor",
            "UIImageRenderingModeAlwaysOriginal",
            "hasFreshServingResult",
            "refreshPending",
            "awaitingCurrentRefresh",
            "refreshGeneration",
            "generation != self.refreshGeneration",
            "if (!superseded)",
            "shouldRefreshAgain",
        ):
            self.assertIn(token, self.source)
        self.assertNotIn('self.glyphImage = CCNMLiveGlyphImage(@"?")', self.source)
        self.assertNotIn("glyphColor = UIColor.blackColor", self.source)
        self.assertIn("glyphColor = UIColor.whiteColor", self.source)

    def test_refresh_has_one_in_flight_guard_and_button_is_read_only(self):
        implementation = self.source.index("@implementation NetworkManagerLiveViewController")
        refresh_start = self.source.index("- (void)requestBoundedServingRefresh", implementation)
        refresh_end = self.source.index("- (void)applyNewerCachedSummary", refresh_start)
        refresh = self.source[refresh_start:refresh_end]
        self.assertIn("self.refreshInProgress", refresh)
        self.assertIn("refreshWithCompletion", refresh)
        button_start = self.source.index("- (void)buttonTapped:", implementation)
        button = self.source[button_start:self.source.index("@end", button_start)]
        self.assertIn("requestBoundedServingRefresh", button)
        self.assertNotIn("setSelected:", button)

    def test_darwin_notification_only_applies_a_newer_cache(self):
        self.assertIn(
            "requireNewerTimestamp && publishedAt <= self.appliedPublishedAtMilliseconds",
            self.source,
        )
        timer_start = self.source.index("- (void)refreshTimerFired:")
        timer_end = self.source.index("- (void)radioAccessTechnologyDidChange:", timer_start)
        self.assertIn("applyCurrentSummary", self.source[timer_start:timer_end])
        self.assertIn("CCNMServingSummaryPublishedAtMillisecondsKey", self.source)
        self.assertIn("requireNewerTimestamp:NO", self.source)
        implementation_end = self.source.index("@end", self.source.index("- (void)buttonTapped:"))
        callback_start = self.source.index(
            "static void CCNMLiveServingStatusDidChangeCallback(", implementation_end
        )
        callback_end = self.source.index("@interface NetworkManagerLiveModule", callback_start)
        callback = self.source[callback_start:callback_end]
        self.assertIn("applyNewerCachedSummary", callback)
        self.assertNotIn("requestBoundedServingRefresh", callback)


class LiveCCBandTextModelTests(unittest.TestCase):
    def test_formatter_maps_stable_serving_truth(self):
        harness = r'''
#include <stdio.h>
#include "CCNMLiveBandText.h"

static void emit(int success, int stale, CCNMLiveRadioKind kind, long long band) {
    char text[32] = {0};
    CCNMLiveFormatBandText(text, sizeof(text), success, stale, kind, band);
    puts(text);
}

int main(void) {
    emit(1, 0, CCNMLiveRadioKindLTE, 3);
    emit(1, 0, CCNMLiveRadioKindNR, 78);
    emit(1, 0, CCNMLiveRadioKindNR, 79);
    emit(0, 0, CCNMLiveRadioKindLTE, 3);
    emit(1, 1, CCNMLiveRadioKindNR, 78);
    emit(1, 0, CCNMLiveRadioKindUnknown, 78);
    emit(1, 0, CCNMLiveRadioKindLTE, 0);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            harness_path = temporary_path / "harness.c"
            binary_path = temporary_path / "formatter-test"
            harness_path.write_text(harness)
            subprocess.run(
                [
                    "cc",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(LIVECC / "Sources"),
                    str(harness_path),
                    str(FORMATTER),
                    "-o",
                    str(binary_path),
                ],
                check=True,
            )
            result = subprocess.run(
                [str(binary_path)], check=True, text=True, capture_output=True
            )
        self.assertEqual(
            result.stdout.splitlines(), ["B3", "n78", "n79", "?", "?", "?", "?"]
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
