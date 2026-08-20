#!/usr/bin/env python3
"""P0 contracts for removal/downgrade restoration and cleanup recovery."""

from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACTIONS_MAKEFILE = ROOT / "package-actions/Makefile"
PRERM_SOURCE = ROOT / "package-actions/prerm.m"
POSTINST_SOURCE = ROOT / "package-actions/postinst.m"
POSTINST_TEMPLATE = ROOT / "package-actions/postinst.sh.in"
PRERM_TEMPLATE = ROOT / "package-actions/prerm.sh.in"
MAINTAINER_SOURCE = ROOT / "package-actions/CCNMMaintainerEnvironment.m"
ROOT_MAKEFILE = ROOT / "Makefile"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import verify_release_package  # noqa: E402


class UninstallGuardTests(unittest.TestCase):
    def test_the_policy_guards_ship_as_payload_helpers_not_maintainer_scripts(self):
        # dpkg's maintainer scripts are shell; the compiled code became a helper
        # the shell calls. On roothide a compiled maintainer script runs without
        # the bootstrap injection and gets EPERM on every write and child exec
        # inside the jailbreak root, so it cannot do the privileged half.
        self.assertTrue(ACTIONS_MAKEFILE.exists())
        self.assertTrue(PRERM_SOURCE.exists())
        self.assertTrue(POSTINST_SOURCE.exists())
        self.assertTrue(POSTINST_TEMPLATE.exists())
        self.assertTrue(PRERM_TEMPLATE.exists())
        makefile = ACTIONS_MAKEFILE.read_text()
        root_makefile = ROOT_MAKEFILE.read_text()
        self.assertIn(
            "TOOL_NAME = networkmanager-install-guard networkmanager-removal-guard",
            makefile,
        )
        self.assertIn("networkmanager-install-guard_INSTALL_PATH = /usr/libexec", makefile)
        self.assertIn("networkmanager-removal-guard_INSTALL_PATH = /usr/libexec", makefile)
        # Nothing compiled may be installed into the control archive again.
        self.assertNotIn("/DEBIAN", makefile)
        self.assertIn("networkmanager-install-guard_FILES = postinst.m", makefile)
        self.assertIn("networkmanager-removal-guard_FILES = prerm.m", makefile)
        self.assertIn("../networkmanagerprefs/CCNMN78PolicySupport.m", makefile)
        self.assertIn("../networkmanagerprefs/CCNMN78PolicyController.m", makefile)
        self.assertIn("CCNMMaintainerEnvironment.m", makefile)
        for tool in ("networkmanager-install-guard", "networkmanager-removal-guard"):
            self.assertIn(
                "%s_OBJCFLAGS += -fno-modules -fno-implicit-modules" % tool, makefile)
        self.assertIn("-DCCNM_MAINTAINER_SCRIPT", makefile)
        self.assertNotIn("-lroothide", makefile)
        self.assertIn("SUBPROJECTS += package-actions", root_makefile)

    def test_the_shell_postinst_no_longer_rewrites_the_launchd_plist(self):
        # The retired mechanism. postinst used to convert the plist with plutil and
        # sed @JBROOT@ into the live jailbreak root, which was the cause of the
        # doubled program path the reporting device showed: roothide's launchctl is
        # itself redirected and prepends jbroot to every absolute path in the file
        # on load, so a plist that already carried one got a second.
        #
        # Asserted on the executable body only. The header comments deliberately
        # explain why those three tools are gone, and that prose is worth keeping.
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            text = template.read_text()
            with self.subTest(template=template.name):
                self.assertTrue(text.startswith("#!/bin/sh\n"))
                self.assertIn("jbroot", text)
                body = text[text.index("SCHEME_PREFIX="):]
                self.assertNotIn("@JBROOT@", body)
                for line in body.splitlines():
                    code = line.split("#", 1)[0]
                    # Word boundaries: a substring test for "sed " also matches
                    # the middle of "used ".
                    found = re.search(r"\b(plutil|sed|grep)\b", code)
                    self.assertIsNone(found, f"{template.name}: {line}")
        self.assertIn("networkmanager-install-guard", POSTINST_TEMPLATE.read_text())
        prerm = PRERM_TEMPLATE.read_text()
        self.assertIn("networkmanager-removal-guard", prerm)
        # Fail-closed: an unusable guard blocks removal rather than allowing it.
        self.assertIn("exit 73", prerm)

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

    def test_the_guards_use_the_prefix_the_shell_resolved(self):
        # The shell maintainer script already resolved which prefix exists and
        # exports it. Re-deriving it inside the guard is not just redundant, it
        # is wrong on roothide: the guard is invoked through a bare path, so its
        # executable path carries no .jbroot- component, and scanning
        # /var/containers/Bundle/Application from a redirected process looks
        # inside the jailbreak root rather than at it.
        source = POLICY_SOURCE.read_text()
        self.assertIn("CCNM_MAINTAINER_SCRIPT", source)
        maintainer = source[source.index("#if defined(CCNM_MAINTAINER_SCRIPT)"):
                            source.index("#elif __has_include(<roothide.h>)")]
        self.assertIn("CCNMMaintainerInstallPrefix()", maintainer)
        # The former self-derivation strategies must not come back.
        for token in ("CCNMJBResourceRoot", "_NSGetExecutablePath",
                      '@"/var/containers/Bundle/Application/"', '".jbroot-"',
                      "THEOS_PACKAGE_INSTALL_PREFIX"):
            self.assertNotIn(token, maintainer)
        # An unresolved prefix must not silently degrade to a bare path: a policy
        # read against the wrong root would look clean and could authorize
        # removal while a forced band configuration is still applied.
        self.assertIn('@"/.networkmanager-unresolved-install-prefix"', maintainer)
        # Concatenation, not stringByAppendingPathComponent:, because the empty
        # prefix must yield the original absolute path.
        self.assertIn("stringByAppendingString:path", maintainer)
        self.assertNotIn("stringByAppendingPathComponent:path", maintainer)
        self.assertNotIn("#import <roothide.h>", maintainer)

    def test_the_shell_exports_the_prefixes_it_resolved_to_both_guards(self):
        for template in ("postinst.sh.in", "prerm.sh.in"):
            text = (ROOT / "package-actions" / template).read_text()
            with self.subTest(template=template):
                # The install prefix is a filesystem root for a process nothing
                # redirects, so it must be the real jailbreak root and is
                # exported only when that is known. Leaving it unset makes the
                # guard fail closed instead of reading the wrong root and
                # reporting every policy record absent, which is
                # indistinguishable from a clean band configuration.
                self.assertIn(
                    'NETWORKMANAGER_INSTALL_PREFIX="$JBROOT_PREFIX"', text)
                self.assertIn('if [ -n "$JBROOT_PREFIX" ]; then', text)
                self.assertIn("export NETWORKMANAGER_INSTALL_PREFIX", text)
                # Never the prefix the shell resolved for itself: this shell is
                # redirected, so that value is legitimately empty and says
                # nothing about the filesystem the guard sees.
                self.assertNotIn(
                    'NETWORKMANAGER_INSTALL_PREFIX="$RESOLVED_PREFIX"', text)
                # The launchd prefix is a package-time constant describing what
                # must literally appear inside the plist, and empty is the
                # correct roothide answer, so it is always exported. Empty and
                # unset are different answers to the guard.
                self.assertIn(
                    'NETWORKMANAGER_LAUNCHD_PREFIX="$LAUNCHD_PREFIX"', text)
                self.assertIn("export NETWORKMANAGER_LAUNCHD_PREFIX", text)
                self.assertNotIn('if [ -n "$LAUNCHD_PREFIX" ]; then', text)
                # Exported before the guard runs, not after.
                self.assertLess(text.index("export NETWORKMANAGER_INSTALL_PREFIX"),
                                text.rindex('"$@"'))
                self.assertLess(text.index("export NETWORKMANAGER_LAUNCHD_PREFIX"),
                                text.rindex('"$@"'))

    def test_the_install_and_launchd_prefixes_are_kept_distinct(self):
        # Conflating these was the original mistake, and they disagree on exactly
        # one point: whether empty is a valid answer.
        #
        # The install prefix is what the guard prepends to open a file. The guard
        # is not redirected -- it links no libroothide and is exec'd through a
        # bare path -- so an empty prefix lands every read on the real root. It is
        # therefore rejected here and the value is probed against this package's
        # own anchor file rather than trusted.
        #
        # The launchd prefix is what must literally appear inside the plist, and
        # empty is the correct roothide answer: launchctl prepends the jailbreak
        # root itself, so a prefix written into the plist would be doubled.
        source = MAINTAINER_SOURCE.read_text()
        supplied = source[source.index("static NSString *CCNMPrefixFromEnvironment"):
                          source.index("NSString *CCNMMaintainerInstallPrefix")]
        self.assertIn("if (!value) {", supplied)
        self.assertIn("emptyIsValid ? @\"\" : nil", supplied)
        # A relative value or a trailing slash is never a usable prefix.
        self.assertIn('hasPrefix:@"/"', supplied)
        self.assertIn('hasSuffix:@"/"', supplied)
        install = source[source.index("NSString *CCNMMaintainerInstallPrefix"):
                         source.index("static NSString *CCNMMaintainerLaunchdPrefix")]
        self.assertIn("CCNMInstallPrefixVariable, NO", install)
        # And it is measured, not taken on faith.
        self.assertIn("CCNMVerdictForPrefix", install)
        launchd = source[source.index("static NSString *CCNMMaintainerLaunchdPrefix"):
                         source.index("NSString *CCNMMaintainerJailbreakRoot")]
        self.assertIn("CCNMLaunchdPrefixVariable, YES", launchd)
        # Set-ness is carried separately from the value, so an empty prefix is
        # distinguishable from a variable the maintainer script never set.
        self.assertIn("BOOL *resolved", launchd)
        self.assertIn("didResolve", launchd)
        # The jailbreak root is a third question: an empty install prefix is a
        # valid answer there but is not a root that can be prepended.
        root_body = source[source.index("NSString *CCNMMaintainerJailbreakRoot"):
                           source.index("NSString *CCNMMaintainerRootedPath")]
        self.assertIn("prefix.length > 0 ? prefix : nil", root_body)
        rooted = source[source.index("NSString *CCNMMaintainerRootedPath"):
                        source.index("// launchctl lookup.")]
        self.assertIn("stringByAppendingString:path", rooted)
        self.assertNotIn("stringByAppendingPathComponent:path", rooted)
        # launchctl must be handed the launchd path, not ours.
        register = source[
            source.index("CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd"):]
        bootstrap = register.index('@"bootstrap"')
        self.assertIn("CCNMMaintainerLaunchdPath(", register[:bootstrap])

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
            "CCNMMaintainerInstallPrefix",
            "CCNMMaintainerLaunchdPrefix",
            "THEOS_PACKAGE_INSTALL_PREFIX",
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
        # No runtime self-derivation of the root. A guard that guesses can read a
        # policy state that is not the live one, call it clean, and authorize
        # removal while a forced band configuration is still applied.
        for token in ("_NSGetExecutablePath", "/var/containers/Bundle/Application",
                      '".jbroot-"'):
            self.assertNotIn(token, source)

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
        self.assertIn("could not be resolved against the install prefix", body)
        self.assertIn("is not readable at %@", body)
        self.assertIn("is not executable at %@", body)
        self.assertIn("is missing at %@", body)
        # An unset or malformed prefix is its own failure, named per variable, so
        # the dpkg log distinguishes "the shell did not tell me" from "the file
        # is not there".
        self.assertIn("The install prefix could not be determined", body)
        self.assertIn("The launchd path prefix could not be determined", body)
        self.assertIn("not set by the maintainer script", body)
        # Diagnostics must name the path and the reason so a device report is
        # enough. access(2) is deliberately absent: on this platform
        # access(X_OK) returned EPERM for the freshly unpacked helper, so mode
        # bits and the actual read are the only trustworthy evidence. The
        # file-wide ban is enforced in tests/test_launchctl_probe_order.py.
        code = "\n".join(
            line for line in body.splitlines()
            if not line.lstrip().startswith("//")
        )
        self.assertNotIn("access(", code)
        self.assertIn("stat errno %d", body)
        self.assertIn("mode %o", body)
        self.assertIn("readError.localizedDescription", body)
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
        self.assertEqual(
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
            ("networkmanager-install-guard", "networkmanager-removal-guard"),
        )
        self.assertIn(
            "usr/libexec/networkmanager-removal-guard",
            verify_release_package.REQUIRED_PAYLOAD_FILES,
        )
        verifier = (ROOT / "scripts/verify_release_package.py").read_text()
        self.assertIn("binary.name not in UNLINKED_ROOTHIDE_TOOLS", verifier)
        self.assertIn("must be a shell script, not a Mach-O binary", verifier)


if __name__ == "__main__":
    unittest.main(verbosity=2)
