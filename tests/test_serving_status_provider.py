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
POLICY = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
MAKEFILE = ROOT / "networkmanagerprefs/Makefile"


def code_only(text):
    """The source with comments removed, so prose cannot satisfy or break a check.

    Assertions about what the code does must read the code. A comment explaining
    why the write path keeps its device allowlist should not make an assertion
    about the read path fail, and equally a commented-out gate must never be able
    to satisfy one. String literals are preserved because several checks are about
    message text.
    """
    out = []
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if character == '"':
            out.append(character)
            index += 1
            while index < length:
                out.append(text[index])
                if text[index] == "\\":
                    if index + 1 < length:
                        out.append(text[index + 1])
                        index += 2
                        continue
                elif text[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = length if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = length if end < 0 else end + 2
            continue
        out.append(character)
        index += 1
    return "".join(out)


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

    def test_provider_uses_reviewed_responsive_sampler_and_build_includes_it(self):
        source = SOURCE.read_text()
        sampler = SAMPLER.read_text()
        makefile = MAKEFILE.read_text()
        self.assertTrue(HEADER.exists())
        self.assertTrue(SAMPLER.exists())
        self.assertIn('#import "CCNMServingCellSampler.h"', source)
        self.assertIn("CCNMRunResponsiveServingCellSampler", source)
        self.assertNotIn("CCNMRunAdaptiveServingCellSampler(client", source)
        self.assertNotIn("CCNMRunFullWindowServingCellSampler(client", source)
        self.assertIn("CCNMRunAdaptiveServingCellSampler", sampler)
        self.assertIn("CCNMRunFullWindowServingCellSampler", sampler)
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

    def test_reading_is_not_gated_on_a_device_allowlist(self):
        """The read path runs on any model; only the write path is pinned.

        A RAT-selection write is a modem configuration change whose restore has
        been verified on exactly one device, which is why that path keeps its
        allowlist. Reading the serving cell and the band capability changes
        nothing, so there is no restore to have verified and refusing an unknown
        model buys no safety. What makes the read safe on an unverified device is
        the ABI validation and the bounded waits, which apply regardless of model.
        """
        source = code_only(SOURCE.read_text())
        sampler = code_only(SAMPLER.read_text())
        for gate in ("iPhone14,3", "19B81", "CCNMServingValidateTarget"):
            self.assertNotIn(gate, source)
            self.assertNotIn(gate, sampler)
        self.assertNotIn("majorVersion == 15", source)
        # The write path must still be pinned. If this ever fails, an allowlist
        # was removed from the wrong side.
        policy = code_only(POLICY.read_text())
        self.assertIn('[model isEqualToString:@"iPhone14,3"]', policy)
        self.assertIn('[build isEqualToString:@"19B81"]', policy)
        self.assertIn("CCNMValidateTarget", policy)
        # What remains in the read path is the ABI and shape validation that does
        # the actual protecting.
        for guard in (
            "CCNMServingValidateSubscriptionABI",
            "CCNMServingValidateBandInfoABI",
            "respondsToSelector:",
            "@try {",
        ):
            self.assertIn(guard, source)

    def test_device_identity_is_reported_not_used_as_truth(self):
        source = SOURCE.read_text()
        header = HEADER.read_text()
        self.assertIn("CCNMServingDeviceIdentity", source)
        for key in (
            "CCNMServingSummaryDeviceModelKey",
            "CCNMServingSummarySystemBuildKey",
            "CCNMServingSummarySystemVersionKey",
        ):
            self.assertIn(key, header)
            self.assertIn(key, source)
        # Identity is attached to every published summary, so a refusal elsewhere
        # can say which device it measured instead of only which one it accepts.
        self.assertIn(
            "[summary addEntriesFromDictionary:CCNMServingDeviceIdentity()];", source
        )
        self.assertIn('evidence[@"deviceIdentity"] = CCNMServingDeviceIdentity();', source)
        # Reported only. No comparison against it may decide anything.
        identity_start = source.index("static NSDictionary<NSString *, id> *CCNMServingDeviceIdentity")
        identity_end = source.index("}", source.index("return @{", identity_start))
        identity = source[identity_start:identity_end]
        for decision in ("isEqual", "if (", "return NO", "return YES"):
            self.assertNotIn(decision, identity)

    def test_data_line_is_chosen_and_reported_never_assumed(self):
        """Dual SIM must not make the read fail, and the row must not claim SIM 1.

        Requiring exactly one present SIM in slot 1 was the write path's
        constraint, borrowed here for no reason: a write has to bind to an
        unambiguous subscription, a read does not. The system's own data-line
        selection is used, with the single usable subscription as fallback, and
        only a genuinely ambiguous choice fails.
        """
        source = SOURCE.read_text()
        self.assertNotIn("Exactly one present and good SIM in slot 1 is required.", source)
        self.assertNotIn("context.slotID == 1", source)
        self.assertIn("userDataPreferred", source)
        self.assertIn("@selector(userDataPreferred)", source)
        self.assertIn("flagged.count == 1", source)
        self.assertIn("usable.count == 1", source)
        # CoreTelephony's own data-line answer is preferred, but only when it names
        # a subscription that is actually present and usable, so a stale or foreign
        # answer cannot select an absent SIM.
        self.assertIn("CCNMServingPreferredDataLineUUID", source)
        self.assertIn("getCurrentDataSubscriptionContextSync:", source)
        self.assertIn("[usable addObject:context];", source)
        reported = source.index("if (reportedDataLineUUID.length &&")
        self.assertLess(source.index("[usable addObject:context];"), reported)
        # That selector is not in the reviewed device baseline, so it must be
        # optional and ABI checked like every other private call here.
        self.assertIn("@optional", source)
        probe_start = source.index("static NSString *CCNMServingPreferredDataLineUUID")
        probe_end = source.index("\n}", probe_start)
        probe = source[probe_start:probe_end]
        self.assertIn("CCNMServingValidateObjectErrorABI", probe)
        self.assertIn("@try {", probe)
        self.assertIn("return nil;", probe)
        # The chosen slot is reported rather than hardcoded, in the summary and in
        # the settings row.
        self.assertNotIn('CCNMServingSummaryDataLineKey: @"slot1"', source)
        self.assertNotIn('summary[CCNMServingSummaryDataLineKey] = @"slot1";', source)
        self.assertIn('[NSString stringWithFormat:@"slot%lld", slotID.longLongValue]', source)
        controller = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
        self.assertIn("dataLineDisplayValue:", controller)
        self.assertNotIn(
            'dataLineValue:CCNMPreferencesLocalizedString(@"DATA_LINE_SLOT_1")', controller
        )
        for language in ("en", "zh-Hans"):
            strings = (ROOT / f"networkmanagerprefs/Resources/{language}.lproj"
                       / "NetworkManagerPrefs.strings").read_text()
            self.assertIn('"DATA_LINE_SLOT_2"', strings)
            self.assertIn('"DATA_LINE_FORMAT"', strings)

    def test_unsupported_target_alert_reports_what_it_measured(self):
        controller = (ROOT / "networkmanagerprefs/CCNMRootListController.m").read_text()
        self.assertIn("measuredDeviceDescription:", controller)
        self.assertIn('POLICY_ERROR_MEASURED_DEVICE_FORMAT', controller)
        # A summary that never reached the target check has no identity to show,
        # and must not have one invented for it.
        start = controller.index("- (NSString *)measuredDeviceDescription:")
        end = controller.index("- (NSString *)policyFailureLocalizationKey:", start)
        measured = controller[start:end]
        self.assertIn("return @\"\";", measured)
        for language in ("en", "zh-Hans"):
            strings = (ROOT / f"networkmanagerprefs/Resources/{language}.lproj"
                       / "NetworkManagerPrefs.strings").read_text()
            self.assertIn('"POLICY_ERROR_MEASURED_DEVICE_FORMAT"', strings)

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
            "publishedAtMilliseconds",
            "stale",
            "frequencyMHz",
            "dataLine",
        ):
            self.assertIn(token, header + source)
        self.assertIn("CCNMServingFreshnessLifetimeMilliseconds", source)
        self.assertIn("me.nixuge.networkmanager.serving-status.plist", source)
        self.assertIn("me.nixuge.networkmanager.livecc.serving-status.plist", source)
        self.assertIn("me.nixuge.networkmanager.livecc.serving-status-changed", source)
        self.assertIn("CCNM_SERVING_USE_LIVECC_NAMESPACE", source)
        self.assertIn("CCNMServingCacheLockPath", source)
        self.assertIn("CCNMServingAcquireCacheLock", source)
        self.assertIn("flock(descriptor, LOCK_EX)", source)
        self.assertIn("CCNMServingReadCachedSummary", source)
        self.assertIn("CCNMServingPersistCachedSummary", source)
        self.assertIn("getBandInfo:error:", source)
        self.assertIn("CCNMServingValidateBandInfoABI", source)
        self.assertIn("CCNMServingReadCapability", source)
        self.assertIn("CCNMServingSummaryCapabilityN78SupportedKey", header + source)
        self.assertIn("CCNMServingSummaryCapabilityN78ActiveKey", header + source)
        self.assertIn("CCNMServingSummarySubscriptionUUIDKey", header + source)
        self.assertIn("writeToFile:CCNMServingCachePath() atomically:YES", source)
        self.assertIn("CCNMServingStatusDidChangeDarwinNotification", header + source)
        self.assertIn("CFNotificationCenterPostNotification", source)
        self.assertIn("CCNMServingReadCachedSummary", source)
        self.assertIn("CCNMServingSummaryPublishedAtMillisecondsKey", header + source)
        self.assertIn("previousPublishedAt + 1", source)
        self.assertIn("cacheLockDescriptor >= 0 && CCNMServingPersistCachedSummary", source)
        self.assertIn("CCNMServingReleaseCacheLock(cacheLockDescriptor)", source)
        self.assertIn("CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue", source)
        release_start = source.index("- (void)releaseRetainedSamplerLockWhenSafe")
        release_end = source.index("- (void)refreshWithCompletion:", release_start)
        release = source[release_start:release_end]
        self.assertLess(release.index("[self publishSummary:resolved"),
                        release.index("CCNMReleaseServingSamplerLock"))
        self.assertIn("CCNMServingSummarySampledAtMillisecondsKey] = @0", release)
        lock_failure_start = source.index("if (lockDescriptor < 0)")
        lock_failure_end = source.index("NSDictionary *report = nil", lock_failure_start)
        lock_failure = source[lock_failure_start:lock_failure_end]
        self.assertNotIn("publishSummary", lock_failure)
        self.assertIn("deliverCompletion", lock_failure)
        self.assertIn("nrObservationStatus", SAMPLER.read_text())
        self.assertIn("cellMonitorSamplingStatus", source + SAMPLER.read_text())

    def test_provider_accepts_only_a_valid_current_confirmation(self):
        source = SOURCE.read_text()
        sampler = SAMPLER.read_text()
        self.assertIn("CCNMCellMonitorRATKind", source)
        self.assertIn('report[@"cellMonitorSamplingMode"]', source)
        self.assertIn('report[@"cellMonitorSamplingStatus"]', source)
        self.assertIn('report[@"servingObservationConfirmed"]', source)
        self.assertIn('report[@"confirmedServingCell"]', source)
        self.assertIn("confirmedServingCellValid", source)
        self.assertIn('report[@"confirmedServingSampledAt"]', source)
        self.assertNotIn("latestNR", source)
        self.assertNotIn("latestLTE", source)
        self.assertNotIn("latestOther", source)
        self.assertIn("CCNMServingCellRATTier", sampler)
        self.assertIn("invalidWinningTier", sampler)

    def test_capability_gate_is_read_only_and_requires_both_domains(self):
        source = SOURCE.read_text()
        self.assertIn("CCNMServingSummaryCapabilityReadSuccessKey", source)
        self.assertIn("[supportedNR containsObject:@78]", source)
        self.assertIn("[activeNR containsObject:@78]", source)
        self.assertIn("CCNMServingCapabilityFailure", source)
        self.assertNotIn("setActiveBandInfo", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
