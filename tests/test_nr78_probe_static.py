#!/usr/bin/env python3
"""Static contract for the temporary NR n78-only device experiment."""
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
HEADER = (ROOT / "networkmanagerprefs/CCNMRootListController.h").read_text()
CONTROL_CENTER = (ROOT / "CCNetworkManager.x").read_text()


class NR78ProbeStaticTests(unittest.TestCase):
    def test_payload_changes_only_nr_to_exact_n78(self):
        helper = SOURCE[
            SOURCE.index("static BOOL CCNMValidateNR78OnlyBands"):
            SOURCE.index("static NSDictionary *CCNMBandDictionaryDifference")
        ]
        self.assertIn(
            'static NSString *const CCNMNRRATKey = @"kCTRegistrationRadioAccessTechnologyNR"',
            SOURCE,
        )
        self.assertIn("static NSNumber *CCNMNR78Band(void)", SOURCE)
        self.assertIn("draft[CCNMNRRATKey] = @[CCNMNR78Band()]", helper)
        self.assertIn("[modifiedValues isEqualToArray:@[CCNMNR78Band()]]", helper)
        self.assertIn("[modifiedValues isEqualToArray:originalValues]", helper)
        self.assertIn("[activeNR containsObject:CCNMNR78Band()]", helper)
        self.assertIn("[supportedNR containsObject:CCNMNR78Band()]", helper)
        self.assertIn("[activeNR isEqualToArray:@[CCNMNR78Band()]]", helper)

    def test_nr78_operation_is_bound_through_intent_and_markers(self):
        for token in (
            '@"nr78_only"',
            '@"nr78_only_intent"',
            '@"nr78_only_automatic_restore"',
        ):
            self.assertIn(token, SOURCE)
        validator = SOURCE[
            SOURCE.index("static BOOL CCNMValidateWriteIntent"):
            SOURCE.index("static BOOL CCNMSyncParentDirectory")
        ]
        self.assertIn("CCNMBuildNR78OnlyBands", validator)
        self.assertIn("CCNMValidateNR78OnlyBands", validator)
        self.assertIn('[intent[@"observationSeconds"] isKindOfClass:[NSNumber class]]', validator)

    def test_device_run_has_full_recovery_and_sixty_second_hold(self):
        body = SOURCE[
            SOURCE.index("- (void)runNR78BandWrite"):
            SOURCE.index("- (void)restoreSavedBandSnapshot")
        ]
        for required in (
            "CCNMAcquireRecoveryFileLock",
            "CCNMValidateTargetDevice",
            "CCNMSafeSlotOneContext",
            "CCNMValidateSetterABI",
            "CCNMBuildNR78OnlyBands",
            "CCNMCreateDurablePlistExclusively",
            "CCNMMarkTestSetterCallStarted",
            "bands:nr78Info",
            "CCNMWaitForExpectedBandReadBack",
            "CCNMNR78ObservationSeconds",
            "CCNMRestoreActiveBands",
            "CCNMBandNR78ResultPath()",
        ):
            self.assertIn(required, body)
        readback = body.index("CCNMWaitForExpectedBandReadBack")
        hold = body.index("CCNMNR78ObservationSeconds", readback)
        restore = body.index("CCNMRestoreActiveBands", hold)
        self.assertLess(readback, hold)
        self.assertLess(hold, restore)
        self.assertIn('result[@"observationCompleted"] = @YES', body)
        self.assertIn('result[@"recoveryPending"]', body)

    def test_ui_requires_explicit_destructive_confirmation(self):
        self.assertIn("confirmNR78BandWrite", HEADER)
        plist = plistlib.loads((ROOT / "networkmanagerprefs/Resources/Root.plist").read_bytes())
        actions = [item.get("action") for item in plist["items"] if item.get("action")]
        self.assertEqual(actions.count("confirmNR78BandWrite:"), 1)
        confirm = SOURCE[
            SOURCE.index("- (void)confirmNR78BandWrite"):
            SOURCE.index("- (void)confirmClearProbeState")
        ]
        self.assertIn("UIAlertActionStyleDestructive", confirm)
        self.assertIn("NR band n78", confirm)
        self.assertIn("may fall back to LTE", confirm)
        self.assertIn("60 seconds", confirm)

    def test_control_center_rat_setter_cannot_race_band_recovery(self):
        setter = CONTROL_CENTER[
            CONTROL_CENTER.index("- (void)setSelected:"):
            CONTROL_CENTER.index("@end")
        ]
        lock = setter.index("CCNMAcquireBandRecoveryLock")
        gate = setter.index("CCNMBandRecoveryStateExists")
        modem_write = setter.index("_CTServerConnectionSetRATSelection")
        release = setter.index("CCNMReleaseBandRecoveryLock", modem_write)
        self.assertLess(lock, gate)
        self.assertLess(gate, modem_write)
        self.assertLess(modem_write, release)
        self.assertIn("LOCK_EX | LOCK_NB", CONTROL_CENTER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
