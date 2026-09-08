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
LAUNCHD = ROOT / "layout" / "Library" / "LaunchDaemons" / "com.doimty.nrmanager.maintenance.plist"
PATCHER = ROOT / "scripts" / "patch-maintenance-launchd.py"
READER = ROOT / "nrmanagerprefs" / "CCNMN78PolicyReader.m"
READER_H = ROOT / "nrmanagerprefs" / "CCNMN78PolicyReader.h"
PROGRAM = "/usr/libexec/nrmanager-maintenance"
PREFERENCES = "/var/mobile/Library/Preferences"
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
        self.assertIn("TOOL_NAME = nrmanager-maintenance", makefile)
        self.assertIn("CCNMServingStatusProvider.m", makefile)
        self.assertIn("CCNMN78PolicySupport.m", makefile)
        self.assertIn("CCNMN78PolicyReader.m", makefile)
        self.assertIn("CCNMAutomaticMaintenanceDecision.c", makefile)
        self.assertIn("CCNMAutomaticMaintenanceRecord.m", makefile)
        self.assertIn("nrmanager-maintenance_INSTALL_PATH = /usr/libexec", makefile)
        prefs_makefile = (ROOT / "nrmanagerprefs" / "Makefile").read_text()
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

    def test_reader_paths_follow_current_data_line_uuid(self):
        reader = READER.read_text()
        # Dual-SIM: Settings writes per-subscription policy files named with the
        # normalized UUID of the SIM that owns the configuration. The daemon is
        # compiled without the controller, so the reader has to probe the
        # current data-line UUID itself and offer the same ForUUID path
        # contract as the controller's write path.
        for token in (
            "CCNMCurrentDataLineUUID",
            "CCNMNormalizeUUID",
            "CCNMN78PolicyStatePathForUUID",
            "CCNMN78PolicyBaselinePathForUUID",
            "CCNMN78PolicyIntentPathForUUID",
            "CCNMN78PolicyInFlightPathForUUID",
            "CCNMN78PolicyLockPathForUUID",
        ):
            self.assertIn(token, reader,
                f"Reader missing per-UUID contract: {token}")
        # The read path must consult the per-UUID files, not merely define the
        # helpers. Both the internal read entry and the summary builder decide
        # what exists on disk and what the recorded target is, so both must
        # resolve their paths through ForUUID.
        internal = reader[
            reader.index("static NSDictionary *CCNMReadPolicyStateInternal(void) {"):
            reader.index("NSDictionary *CCNMReadN78PolicyState(void) {")
        ]
        self.assertIn("ForUUID", internal)
        summary = reader[
            reader.index("static NSDictionary *CCNMSummaryFromState("):
            reader.index("static NSDictionary *CCNMReadPolicyStateInternal(void) {")
        ]
        self.assertIn("ForUUID", summary)

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
        self.assertEqual(payload["Label"], "com.doimty.nrmanager.maintenance")
        self.assertEqual(payload["UserName"], "root")
        self.assertEqual(payload["EnvironmentVariables"]["DISABLE_TWEAKS"], "1")
        # The repo template carries a sentinel where the prefix belongs, not a
        # lane prefix. @PLIST_PREFIX@ is invalid on both lanes on purpose: it used
        # to be @JBROOT@, which made a skipped before-package patch look correct
        # on roothide and only broke rootless.
        self.assertEqual(payload["ProgramArguments"], [SENTINEL + PROGRAM, "--daemon"])
        # The daemon is started at load and whenever the preferences directory
        # changes, and is restarted only when it did not exit cleanly. It must
        # not be pinned to a record file: the write path names records by
        # subscription UUID and migrates the legacy file on first read, and
        # launchd cannot predict the next UUID. A PathState pinned to the legacy
        # baseline either stops the job after the migration or, after a SIM
        # switch, keeps it running against the wrong subscription's records.
        self.assertEqual(payload["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(payload["RunAtLoad"], True)
        self.assertEqual(payload["WatchPaths"], [SENTINEL + PREFERENCES])
        self.assertEqual(payload["ThrottleInterval"], 30)
        self.assertNotIn("PathState", payload["KeepAlive"])
        # No record path may be pinned anywhere in the plist.
        self.assertNotIn("n78-policy", LAUNCHD.read_text())

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
                # Same contract as the template: not pinned to any record path,
                # started at load and on preferences-directory changes, restarted
                # only on unclean exit.
                self.assertEqual(payload["KeepAlive"], {"SuccessfulExit": False})
                self.assertEqual(payload["RunAtLoad"], True)
                self.assertEqual(payload["WatchPaths"], [prefix + PREFERENCES])
                self.assertNotIn(b"n78-policy", raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
