#!/usr/bin/env python3
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "maintenance-daemon"
SOURCE = DAEMON / "main.m"
MAKEFILE = DAEMON / "Makefile"
ROOT_MAKEFILE = ROOT / "Makefile"
LAUNCHD = ROOT / "layout" / "Library" / "LaunchDaemons" / "me.nixuge.networkmanager.maintenance.plist"
PATCHER = ROOT / "scripts" / "patch-maintenance-launchd.py"
READER = ROOT / "networkmanagerprefs" / "CCNMN78PolicyReader.m"
READER_H = ROOT / "networkmanagerprefs" / "CCNMN78PolicyReader.h"
PROGRAM = "/usr/libexec/networkmanager-maintenance"
BASELINE = (
    "/var/mobile/Library/Preferences/"
    "me.nixuge.networkmanager.n78-policy.baseline.plist"
)
# What the repo template carries where a lane prefix belongs. Invalid on both
# lanes by design, so a before-package patcher that never ran fails both.
SENTINEL = "@PLIST_PREFIX@"


class MaintenanceDaemonSkeletonTests(unittest.TestCase):
    def test_read_only_daemon_sources_exist_and_are_built(self):
        self.assertTrue(SOURCE.exists(), SOURCE)
        self.assertTrue(MAKEFILE.exists(), MAKEFILE)
        root_makefile = ROOT_MAKEFILE.read_text()
        makefile = MAKEFILE.read_text()
        self.assertIn("SUBPROJECTS += maintenance-daemon", root_makefile)
        self.assertIn("TOOL_NAME = networkmanager-maintenance", makefile)
        self.assertIn("CCNMServingStatusProvider.m", makefile)
        self.assertIn("CCNMN78PolicySupport.m", makefile)
        self.assertIn("CCNMN78PolicyReader.m", makefile)
        self.assertIn("CCNMAutomaticMaintenanceDecision.c", makefile)
        self.assertIn("CCNMAutomaticMaintenanceRecord.m", makefile)
        self.assertIn("networkmanager-maintenance_INSTALL_PATH = /usr/libexec", makefile)
        prefs_makefile = (ROOT / "networkmanagerprefs" / "Makefile").read_text()
        self.assertIn("CCNMN78PolicySupport.m", prefs_makefile)

    def test_daemon_imports_reader_not_controller(self):
        source = SOURCE.read_text()
        self.assertIn("CCNMN78PolicyReader.h", source)
        self.assertNotIn("CCNMN78PolicyController.h", source)

    def test_daemon_entry_is_read_only_and_requires_exact_enabled_state(self):
        source = SOURCE.read_text()
        for token in (
            "CCNMReadN78PolicyState",
            "CCNMServingStatusProvider",
            "CCNMEvaluateAutomaticMaintenance",
            "CCNMPolicySummaryIsStableEnabled",
            "CCNMRecoveryStateEnabledWithBaseline",
            "CCNMAppliedPolicyVerifiedN78Only",
            "CCNMRequestedModeN78Preferred",
            "CCNMServingSummaryCapabilityReadSuccessKey",
            "CCNMMaintenanceCapabilityCompatible",
            "CCNMServingSummarySubscriptionUUIDKey",
            'summary[@"transitionPresent"]',
            "previousSample",
            "currentSample",
        ):
            self.assertIn(token, source)
        # The stable-enabled test used to also require the removal guard to be
        # absent, because a present guard meant a removal was mid-flight and the
        # daemon would have been maintaining a policy on its way out. The guard is
        # gone: prerm reloads carrier defaults instead of recording a verdict for
        # a later step to consult, so there is no window for the daemon to observe
        # and nothing left for it to read.
        self.assertNotIn("removalGuard", source)
        self.assertIn('CCNMSysctlString("hw.machine")', source)
        self.assertIn('CCNMSysctlString("kern.osproductversion")', source)
        self.assertIn('CCNMSysctlString("kern.osversion")', source)
        self.assertIn("CCNMServingSummaryCapabilitySampledAtMillisecondsKey", source)
        self.assertIn("CCNMUnixMilliseconds()", source)
        # The gate is the recorded NR target, not band 78. Live NR must equal it and
        # the modem must still declare support for every band in it.
        self.assertIn("CCNMN78PolicySummaryTargetNRBandsKey", source)
        self.assertIn("CCNMActiveNRBandsMatchTarget", source)
        self.assertIn("CCNMMaintenanceTargetIsCurrentlySupported", source)
        self.assertIn('CCNMServingSummaryCapabilitySupportedNRBandsKey', source)
        self.assertNotIn('input.capabilityCompatible = [latestPolicy["baselineValid"] boolValue]', source)
        for forbidden in (
            "setActiveBandInfo",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "CCNMRecoverKnownOrphanedN78WithCompletion",
            "CCNMCreateDurableRecord",
            "CCNMReplaceDurableRecord",
        ):
            self.assertNotIn(forbidden, source)

    def test_daemon_exits_only_after_baseline_retirement(self):
        source = SOURCE.read_text()
        self.assertIn("exitAfterBaselineRetirement", source)
        self.assertIn("CFRunLoopStop(CFRunLoopGetMain())", source)
        self.assertGreaterEqual(
            source.count('if (![summary[@"baselinePresent"] boolValue])') +
            source.count('if (![policy[@"baselinePresent"] boolValue])') +
            source.count('if (![latestPolicy[@"baselinePresent"] boolValue])'),
            3,
        )
        method = source[
            source.index("- (void)exitAfterBaselineRetirement"):
            source.index("- (void)policyMayHaveChanged")
        ]
        self.assertNotIn("CCNMPolicySummaryIsStableEnabled", method)

    def test_reader_contains_no_writer_code(self):
        reader = READER.read_text()
        for forbidden in (
            "setActiveBandInfo",
            "CCNMEnableN78Preference",
            "CCNMDisableN78Preference",
            "CCNMRecoverN78Preference",
            "CCNMRecoverKnownOrphanedN78WithCompletion",
            "CCNMArmN78PolicyRemovalGuard",
            "CCNMClearN78PolicyRemovalGuardIfSafe",
            "CCNMPersistState",
            "CCNMMarkRecovery",
            "CCNMAcquirePolicyLock",
            "CCNMReleasePolicyLock",
            "CCNMCreateDurableRecord",
            "CCNMReplaceDurableRecord",
            "CCNMReplaceExpectedRecord",
            "CCNMRemoveExpectedRecord",
            "CCNMBeginSetter",
            "CCNMFinishSetter",
            "CCNMCallSetter",
            "CCNMSetterUncertainLatch",
            "CCNMSetterCallActive",
        ):
            self.assertNotIn(forbidden, reader,
                f"Reader contains forbidden writer token: {forbidden}")

    def test_reader_exports_read_entry_point(self):
        reader = READER.read_text()
        self.assertIn("CCNMReadN78PolicyState", reader)
        self.assertIn("CCNMReadPolicyStateInternal", reader)

    def test_reader_header_exists(self):
        self.assertTrue(READER_H.exists(), READER_H)
        header = READER_H.read_text()
        self.assertIn("CCNMReadN78PolicyState", header)
        self.assertIn("CCNMValidateBaselineRecord", header)
        self.assertIn("CCNMValidateStateRecord", header)
        self.assertNotIn("CCNMEnableN78Preference", header)

    def test_launchd_contract_is_policy_scoped_and_read_only(self):
        self.assertTrue(LAUNCHD.exists(), LAUNCHD)
        with LAUNCHD.open("rb") as handle:
            payload = plistlib.load(handle)
        self.assertEqual(payload["Label"], "me.nixuge.networkmanager.maintenance")
        self.assertEqual(payload["UserName"], "root")
        self.assertEqual(payload["EnvironmentVariables"]["DISABLE_TWEAKS"], "1")
        # The repo template carries a sentinel where the prefix belongs, not a
        # lane prefix. @PLIST_PREFIX@ is invalid on both lanes on purpose: it used
        # to be @JBROOT@, which made a skipped before-package patch look correct
        # on roothide and only broke rootless.
        self.assertEqual(payload["ProgramArguments"], [SENTINEL + PROGRAM, "--daemon"])
        self.assertEqual(payload["KeepAlive"], {
            "PathState": {SENTINEL + BASELINE: True},
        })
        self.assertNotIn("RunAtLoad", payload)
        self.assertNotIn("SuccessfulExit", payload["KeepAlive"])

    def test_staging_patcher_emits_exact_paths_for_both_schemes(self):
        root_makefile = ROOT_MAKEFILE.read_text()
        self.assertIn("scripts/patch-maintenance-launchd.py", root_makefile)
        # roothide gets bare paths: its launchctl rewrites every absolute path in
        # the plist as jbroot(path) before launchd sees it, so a prefix written
        # here would be doubled. rootless gets /var/jb because nothing there
        # rewrites anything.
        for scheme, prefix in (("rootless", "/var/jb"), ("roothide", "")):
            with self.subTest(scheme=scheme), tempfile.TemporaryDirectory() as temporary:
                staged = Path(temporary)
                target = staged / "Library" / "LaunchDaemons" / LAUNCHD.name
                target.parent.mkdir(parents=True)
                shutil.copy2(LAUNCHD, target)
                result = subprocess.run(
                    [
                        "python3", str(PATCHER),
                        "--scheme", scheme,
                        "--staging-dir", str(staged),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                raw = target.read_bytes()
                # Nothing on the device rewrites this file any more, so a
                # surviving sentinel would be permanent.
                self.assertNotIn(SENTINEL.encode(), raw)
                self.assertNotIn(b"@JBROOT@", raw)
                payload = plistlib.loads(raw)
                self.assertEqual(payload["ProgramArguments"][0], prefix + PROGRAM)
                self.assertEqual(payload["KeepAlive"]["PathState"], {
                    prefix + BASELINE: True,
                })


if __name__ == "__main__":
    unittest.main(verbosity=2)
