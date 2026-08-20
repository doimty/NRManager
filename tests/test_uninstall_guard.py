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

    def test_postinst_registers_only_after_guard_cleanup(self):
        source = POSTINST_SOURCE.read_text()
        clear = source.index("CCNMClearN78PolicyRemovalGuardIfSafe()")
        cleared_check = source.index("if (!cleared)")
        register = source.index("CCNMRegisterMaintenanceLaunchd(&launchdError)")
        self.assertLess(clear, cleared_check)
        self.assertLess(cleared_check, register)
        # Policy-state safety stays fail-closed: an uncleared removal guard must
        # still block configure, because leaving it armed would let the modem
        # policy be enabled while the package believes removal was approved.
        self.assertIn("return CCNMPostinstBlocked", source[cleared_check:register])

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
