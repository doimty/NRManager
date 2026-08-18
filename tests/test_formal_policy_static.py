#!/usr/bin/env python3
"""Static release contracts for the formal n78 policy module."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "networkmanagerprefs/CCNMN78PolicyController.h"
SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
SUPPORT = ROOT / "networkmanagerprefs/CCNMN78PolicySupport.h"
CC_SOURCE = ROOT / "CCNetworkManager.x"


class FormalPolicyStaticTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(HEADER.exists(), HEADER)
        self.assertTrue(SOURCE.exists(), SOURCE)
        self.assertTrue(SUPPORT.exists(), SUPPORT)
        self.header = HEADER.read_text()
        self.source = SOURCE.read_text()
        self.support = SUPPORT.read_text()
        self.cc_source = CC_SOURCE.read_text()

    def test_requested_applied_serving_and_recovery_domains_are_distinct(self):
        for token in (
            "CCNMRequestedModeSystemDefault",
            "CCNMRequestedModeN78Preferred",
            "CCNMAppliedPolicyUnknown",
            "CCNMAppliedPolicyVerifiedN78Only",
            "CCNMServingStateNRN78",
            "CCNMServingStateLTE",
            "CCNMRecoveryStateClean",
            "CCNMRecoveryStateRebootRequired",
        ):
            self.assertIn(token, self.support)

    def test_policy_paths_are_separate_from_diagnostic_namespace(self):
        self.assertIn("n78-policy.baseline.plist", self.source)
        self.assertIn("n78-policy.intent.plist", self.source)
        self.assertIn("n78-policy.inflight.plist", self.source)
        self.assertIn("n78-policy.lock", self.source)
        for forbidden in (
            "bandwrite.removal",
            "bandwrite.lte-b1",
            "same_value_write",
            "cold_band_removal",
            "lte_b1_only",
        ):
            self.assertNotIn(forbidden, self.source)

    def test_enable_payload_is_exact_nr_n78_and_non_nr_identity(self):
        self.assertIn('kCTRegistrationRadioAccessTechnologyNR', self.source)
        self.assertIn("@[ @78 ]", self.source.replace("@[@78]", "@[ @78 ]"))
        self.assertIn("CCNMValidateN78OnlyPayload", self.source)
        self.assertIn("CCNMDictionariesEqual", self.source)

    def test_policy_controller_never_writes_rat_selection(self):
        combined = self.source + self.cc_source
        for forbidden in (
            "_CTServerConnectionSetRATSelection",
            "setRatSelection:",
            "setRatSelectionMask:",
        ):
            self.assertNotIn(forbidden, combined)

    def test_cross_process_lock_and_uncertain_state_are_present(self):
        self.assertIn("flock", self.source)
        self.assertIn("LOCK_EX", self.source)
        self.assertIn("CCNMSetterOutcomeUncertain", self.source)
        self.assertIn("CCNMRecoveryStateRebootRequired", self.source)

    def test_setter_deadline_is_bounded_and_retains_lock_until_late_return(self):
        self.assertIn("dispatch_semaphore_wait(setterFinished", self.source)
        self.assertIn("CCNMSetterDeadlineSeconds * NSEC_PER_SEC", self.source)
        self.assertIn("CCNMRetainPolicyLockForTimedOutSetter", self.source)
        self.assertIn("CCNMSetterRetainedPolicyLockDescriptor", self.source)
        self.assertIn("CCNMReleasePolicyLockAfterLateSetter", self.source)
        self.assertIn("CCNMN78PolicyHasOutstandingSetter", self.source)
        self.assertIn("&lockDescriptor, details, &failure", self.source)
        self.assertNotIn("CCNMArmSetterWatchdog", self.source)

    def test_baseline_survives_verified_enable_and_is_required_for_disable(self):
        self.assertIn("CCNMN78PolicyBaselinePath", self.source)
        self.assertIn("CCNMEnableN78Preference", self.source)
        self.assertIn("CCNMDisableN78Preference", self.source)
        disable = self.source[self.source.index("CCNMDisableN78Preference"):]
        self.assertIn("CCNMN78PolicyBaselinePath", disable)
        self.assertIn("CCNMRecoveryStateEnabledWithBaseline", self.source)

    def test_readback_has_attempt_and_monotonic_wall_clock_bounds(self):
        self.assertIn("CCNMReadBackMaximumAttempts = 31", self.source)
        self.assertIn("CCNMReadBackDeadlineSeconds = 30.0", self.source)
        self.assertIn('result[@"deadlineExceeded"] = @YES', self.source)
        self.assertEqual(self.source.count('[readBack[@"deadlineExceeded"] boolValue]'), 2)

    def test_read_only_preflight_failure_does_not_create_recovery_state(self):
        start = self.source.index("NSDictionary *initial = CCNMReadFreshBandInfo")
        end = self.source.index("NSDictionary *payload = CCNMBuildN78Payload", start)
        preflight_failure = self.source[start:end]
        self.assertNotIn("CCNMMarkRecovery", preflight_failure)
        self.assertIn("No baseline, intent, in-flight marker, or setter call", preflight_failure)

    def test_control_center_uses_public_state_and_glyph_refresh_apis(self):
        self.assertIn("refreshState", self.cc_source)
        self.assertIn("refreshModulePresentation", self.cc_source)
        self.assertIn("respondsToSelector:@selector(reconfigureView)", self.cc_source)

    def test_control_center_glyph_reflects_requested_policy(self):
        self.assertIn("CCNMPolicyIsRequested(state)", self.cc_source)
        self.assertIn('requested ? @"n78\\n..." : @"Auto\\n..."', self.cc_source)
        self.assertIn('requested ? @"n78\\n!" : @"Auto\\n!"', self.cc_source)
        self.assertIn(
            "CCNMServingGlyphText(self.servingSummary, self.servingRefreshInProgress)",
            self.cc_source,
        )

    def test_control_center_does_not_persist_local_network_label_as_truth(self):
        self.assertNotIn("selectedNetwork", self.cc_source)
        self.assertIn("CCNMN78Policy", self.cc_source)
        self.assertIn("policyOperationPending", self.cc_source)
        self.assertIn("self.policyOperationPending = YES", self.cc_source)
        self.assertIn("weakSelf.policyOperationPending = NO", self.cc_source)
        self.assertIn("CCNMN78PolicyDidChangeDarwinNotification", self.cc_source)
        self.assertIn("CFNotificationCenterAddObserver", self.cc_source)
        self.assertIn("CFNotificationCenterRemoveObserver", self.cc_source)
        self.assertIn("CCNMPostPolicyDidChange", self.source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
