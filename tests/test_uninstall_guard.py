#!/usr/bin/env python3
"""P0 contracts for removal/downgrade restoration and cleanup recovery."""

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACTIONS_MAKEFILE = ROOT / "package-actions/Makefile"
PRERM_SOURCE = ROOT / "package-actions/prerm.m"
POSTINST_SOURCE = ROOT / "package-actions/postinst.m"
MAINTAINER_SOURCE = ROOT / "package-actions/CCNMMaintainerEnvironment.m"
ROOT_MAKEFILE = ROOT / "Makefile"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import verify_release_package  # noqa: E402


class UninstallGuardTests(unittest.TestCase):
    def test_compiled_prerm_is_built_as_a_package_control_script(self):
        self.assertTrue(ACTIONS_MAKEFILE.exists())
        self.assertTrue(PRERM_SOURCE.exists())
        self.assertTrue(POSTINST_SOURCE.exists())
        makefile = ACTIONS_MAKEFILE.read_text()
        root_makefile = ROOT_MAKEFILE.read_text()
        self.assertIn("TOOL_NAME = postinst prerm", makefile)
        self.assertIn("postinst_INSTALL_PATH = /DEBIAN", makefile)
        self.assertIn("prerm_INSTALL_PATH = /DEBIAN", makefile)
        self.assertIn("../networkmanagerprefs/CCNMN78PolicySupport.m", makefile)
        self.assertIn("../networkmanagerprefs/CCNMN78PolicyController.m", makefile)
        self.assertIn("CCNMMaintainerEnvironment.m", makefile)
        self.assertIn("postinst_OBJCFLAGS += -fno-modules -fno-implicit-modules", makefile)
        self.assertIn("prerm_OBJCFLAGS += -fno-modules -fno-implicit-modules", makefile)
        self.assertIn("-DCCNM_MAINTAINER_SCRIPT", makefile)
        self.assertNotIn("-lroothide", makefile)
        self.assertIn("SUBPROJECTS += package-actions", root_makefile)

    def test_remove_upgrade_and_downgrade_path_stops_daemon_then_restores(self):
        source = PRERM_SOURCE.read_text()
        for action in ('@"remove"', '@"upgrade"', '@"deconfigure"', '@"failed-upgrade"'):
            self.assertIn(action, source)
        stop = source.index("CCNMStopMaintenanceLaunchd(&launchdError)")
        read = source.index("CCNMReadN78PolicyState()")
        recover = source.index("CCNMRecoverN78Preference")
        self.assertLess(stop, read)
        self.assertLess(read, recover)
        self.assertIn("CCNMReadN78PolicyState()", source)
        self.assertIn("CCNMRecoverN78Preference", source)
        self.assertIn("CCNMN78PolicySummaryMayUninstallKey", source)
        self.assertIn("CCNMArmN78PolicyRemovalGuard()", source)
        self.assertIn('summary[@"baselinePresent"]', source)
        self.assertIn('summary[@"transitionPresent"]', source)
        self.assertIn("CCNMExitWhenSetterSettled(allowed ? CCNMRemovalAllowed", source)
        self.assertIn("CCNMN78PolicyHasOutstandingSetter()", source)
        self.assertIn("dispatch_after", source)

    def test_durable_guard_closes_prerm_to_dpkg_race_and_postinst_clears_it(self):
        policy = POLICY_SOURCE.read_text()
        prerm = PRERM_SOURCE.read_text()
        postinst = POSTINST_SOURCE.read_text()
        for token in (
            "CCNMN78PolicyRemovalGuardPath",
            "CCNMBuildRemovalGuardRecord",
            "CCNMValidateRemovalGuardRecord",
            "CCNMArmN78PolicyRemovalGuard",
            "CCNMClearN78PolicyRemovalGuardIfSafe",
            'summary[@"removalGuardPresent"]',
            'summary[@"removalGuardValid"]',
        ):
            self.assertIn(token, policy + prerm + postinst)
        self.assertIn('[@"removalGuardPresent"] boolValue', prerm)
        self.assertIn("CCNMClearN78PolicyRemovalGuardIfSafe()", postinst)
        self.assertIn('@"abort-remove"', postinst)

    def test_removal_is_fail_closed(self):
        source = PRERM_SOURCE.read_text()
        self.assertIn("geteuid() != 0", source)
        self.assertIn("return CCNMPrermBlocked", source)
        self.assertNotIn("|| true", source)
        self.assertNotIn("_exit(allowed ?", source)
        self.assertNotIn("unlink(CCNMN78PolicyBaselinePath", source)
        self.assertNotIn("removeItemAtPath:CCNMN78PolicyBaselinePath", source)

    def test_root_helper_preserves_mobile_access_to_policy_records_and_lock(self):
        source = POLICY_SOURCE.read_text()
        self.assertIn("CCNMNormalizePolicyDescriptorOwnership", source)
        self.assertIn('getpwnam("mobile")', source)
        self.assertIn("fchown", source)
        write_body = source[source.index("static BOOL CCNMWriteDataExclusively"):source.index("static BOOL CCNMCreateDurableRecord")]
        lock_body = source[source.index("static int CCNMAcquirePolicyLock"):source.index("static void CCNMReleasePolicyLock")]
        self.assertIn("CCNMNormalizePolicyDescriptorOwnership", write_body)
        self.assertIn("CCNMNormalizePolicyDescriptorOwnership", lock_body)

    def test_maintainer_scripts_are_self_contained(self):
        source = POLICY_SOURCE.read_text()
        self.assertIn("CCNM_MAINTAINER_SCRIPT", source)
        self.assertIn("CCNMJBResourceRoot", source)
        self.assertIn("CCNMJBResourceRootFromExecutable", source)
        self.assertIn("_NSGetExecutablePath", source)
        self.assertIn('@"/var/containers/Bundle/Application/"', source)
        self.assertIn("matches.count == 1", source)
        self.assertIn('@"/.networkmanager-invalid-jbroot"', source)
        self.assertIn('".jbroot-"', source)
        self.assertIn("THEOS_PACKAGE_INSTALL_PREFIX", source)
        self.assertNotIn("#import <roothide.h>", source.split("#elif __has_include(<roothide.h>)")[0])

    def test_postinst_attempts_guard_cleanup_before_registration(self):
        source = POSTINST_SOURCE.read_text()
        clear = source.index("CCNMClearN78PolicyRemovalGuardIfSafe()")
        guard_check = source.index('[summary[@"removalGuardPresent"] boolValue]')
        register = source.index("CCNMRegisterMaintenanceLaunchd(&launchdError)")
        self.assertLess(clear, guard_check)
        self.assertLess(guard_check, register)

    def test_postinst_never_blocks_configure_on_policy_state(self):
        # postinst owns nothing that can strand a modified modem: an armed guard
        # already forces mayWrite=NO and removal still requires a verified
        # restore. Failing configure only produces a half-installed package
        # whose Settings UI — the only way to run the recovery the error asks
        # for — is unavailable.
        source = POSTINST_SOURCE.read_text()
        clear = source.index("CCNMClearN78PolicyRemovalGuardIfSafe()")
        self.assertNotIn("return CCNMPostinstBlocked", source[clear:])
        # Root is still required, and that check precedes any policy work.
        self.assertIn("geteuid() != 0", source)
        self.assertLess(source.index("geteuid() != 0"), clear)
        self.assertLess(source.index("return CCNMPostinstBlocked"), clear)
        # A still-armed guard must be reported rather than silently ignored.
        self.assertIn("package-removal guard is still armed", source)

    def test_postinst_launchd_registration_is_non_fatal(self):
        # The maintenance daemon only provides automatic serving-state
        # monitoring. It owns no policy or modem state, so a host where
        # launchctl/plist/executable paths are unavailable must still get a
        # fully configured package instead of a permanently half-installed one.
        source = POSTINST_SOURCE.read_text()
        register = source.index("CCNMRegisterMaintenanceLaunchd(&launchdError)")
        tail = source[register:]
        self.assertNotIn("return CCNMPostinstBlocked", tail)
        self.assertIn("warning", tail)
        self.assertIn("return CCNMInstallAllowed", tail)
        # Do not promise a retry remedy for a deterministic lookup failure.
        self.assertNotIn("retried by reinstalling", tail)

    def test_upgrade_does_not_touch_policy_state(self):
        # Every failure path inside the recovery routine durably marks the state
        # recoveryRequired/rebootRequired. Attempting a restore during upgrade
        # therefore converts a transient read failure into a permanent install
        # blocker, while protecting nothing: the successor package ships the
        # same baseline path and the same restore implementation.
        source = PRERM_SOURCE.read_text()
        early = source.index("CCNMActionKeepsRestoreCapabilityInstalled(action",
                             source.index("int main("))
        self.assertLess(early, source.index("CCNMReadN78PolicyState()"))
        self.assertLess(early, source.index("CCNMReadKnownOrphanedN78RemovalSafety()"))
        self.assertLess(early, source.index("CCNMArmN78PolicyRemovalGuard()"))
        self.assertLess(early, source.index("CCNMRecoverN78Preference"))
        guard_body = source[early:source.index("CCNMReadN78PolicyState()")]
        self.assertIn("return CCNMRemovalAllowed", guard_body)
        # Only upgrade paths are exempt; remove and deconfigure stay gated.
        predicate = source[source.index("static BOOL CCNMActionKeepsRestoreCapabilityInstalled"):
                           source.index("static BOOL CCNMSummaryIsClean")]
        self.assertIn('@"upgrade"', predicate)
        self.assertIn('@"failed-upgrade"', predicate)
        self.assertNotIn('@"remove"', predicate)
        self.assertNotIn('@"deconfigure"', predicate)

    def test_upgrade_exemption_is_gated_on_the_peer_version(self):
        # dpkg uses `upgrade` for downgrades too, so exempting the action alone
        # would silently orphan the baseline when downgrading to a build that
        # predates the restore implementation.
        source = PRERM_SOURCE.read_text()
        self.assertIn("argv[2]", source)
        self.assertIn("versionArgument", source)
        self.assertIn("CCNMDpkgVersionIsAtLeast", source)
        predicate = source[source.index("static BOOL CCNMActionKeepsRestoreCapabilityInstalled"):
                           source.index("static BOOL CCNMSummaryIsClean")]
        # The version floor must gate `upgrade`, not `failed-upgrade`, which
        # runs from the incoming package.
        self.assertLess(predicate.index('@"failed-upgrade"'),
                        predicate.index("CCNMDpkgVersionIsAtLeast"))
        self.assertIn("CCNMDpkgVersion.c", ACTIONS_MAKEFILE.read_text())

    def test_prerm_launchd_stop_is_non_fatal(self):
        # Stopping the daemon is best-effort for the same reason. Removal must
        # remain gated on verified policy restore, not on launchctl success.
        source = PRERM_SOURCE.read_text()
        stop = source.index("CCNMStopMaintenanceLaunchd(&launchdError)")
        policy_read = source.index("CCNMReadN78PolicyState()")
        self.assertLess(stop, policy_read)
        self.assertNotIn("return CCNMPrermBlocked", source[stop:policy_read])
        self.assertIn("warning", source[stop:policy_read])
        # The policy restore gate itself is still fail-closed.
        self.assertIn("return CCNMPrermBlocked", source[policy_read:])

    def test_launchd_owner_is_fail_closed_and_scheme_aware(self):
        source = MAINTAINER_SOURCE.read_text()
        for token in (
            "CCNMCompiledInstallPrefix",
            "CCNMUniqueScannedJBRoot",
            "matches.count == 1",
            "CCNMPrepareMaintenanceLaunchd",
            "CCNMRunLaunchctl(@[@\"bootout\", target]",
            "CCNMRunLaunchctl(@[@\"bootstrap\", @\"system\", plistPath]",
            "CCNMRunLaunchctl(@[@\"kickstart\", @\"-k\", target]",
            "CCNMJobIsLoaded()",
            "DISABLE_TWEAKS",
            "SuccessfulExit",
        ):
            self.assertIn(token, source)
        self.assertNotIn("|| true", source)

    def test_launchctl_lookup_covers_every_filesystem_view(self):
        # A jailbreak bootstrap is not obligated to ship launchctl under its own
        # root, and on the reported device /bin/launchctl was a dangling symlink
        # while /usr/bin/launchctl was the real binary. The ordering itself is
        # covered behaviorally in tests/test_launchctl_probe_order.py; this only
        # pins that the maintainer delegates to it rather than reintroducing an
        # inline candidate list.
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMBuildLaunchctlProbeOrder", source)
        self.assertNotIn("relativeCandidates[index]", source)
        self.assertIn("CCNMLaunchctlProbe.h", source)

    def test_prepare_reports_each_missing_input_separately(self):
        # One combined "launchctl, plist, executable, or policy path" message is
        # not actionable; these inputs fail for unrelated reasons and each needs
        # a different fix on the device. launchctl is deliberately not among them
        # anymore: preparing the plist does not need it, and requiring it would
        # discard the durable work. See tests/test_launchctl_probe_order.py.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("BOOL CCNMPrepareMaintenanceLaunchd"):
                      source.index("BOOL CCNMStopMaintenanceLaunchd")]
        self.assertNotIn(
            "A required launchctl, plist, executable, or policy path is unavailable.",
            body)
        self.assertIn("could not be resolved against the jailbreak root", body)
        self.assertIn("is not readable at %@", body)
        self.assertIn("is not executable at %@", body)
        # Diagnostics must name the path and errno so a device report is enough.
        self.assertIn("plistPath, errno", body)
        self.assertIn("executablePath, errno", body)
        # The plist contract checks stay after the path checks.
        self.assertLess(body.index("is not executable at %@"),
                        body.index("CCNMMaintainerErrorPlist"))

    def test_missing_baseline_only_cleans_a_verified_restore_checkpoint(self):
        source = POLICY_SOURCE.read_text()
        self.assertIn("CCNMIsVerifiedRestoreCleanupCheckpoint", source)
        self.assertIn('state[@"readBackVerified"]', source)
        self.assertIn('state[@"verifiedActiveBands"]', source)
        self.assertIn("CCNMDictionariesEqual(fresh[@\"activeBands\"], state[@\"verifiedActiveBands\"])", source)
        self.assertIn("A required policy baseline is missing; no modem write was issued.", source)

    def test_package_verifier_requires_and_inspects_prerm(self):
        self.assertEqual(verify_release_package.REQUIRED_MAINTAINER_FILES, {"postinst", "prerm"})
        self.assertEqual(verify_release_package.MAINTAINER_BINARY_FILES, ("postinst", "prerm"))
        verifier = (ROOT / "scripts/verify_release_package.py").read_text()
        self.assertIn("binary.name not in MAINTAINER_BINARY_FILES", verifier)


if __name__ == "__main__":
    unittest.main(verbosity=2)
