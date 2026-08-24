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

    def test_remove_upgrade_and_downgrade_path_restores_before_allowing_removal(self):
        source = PRERM_SOURCE.read_text()
        for action in ('@"remove"', '@"upgrade"', '@"deconfigure"', '@"failed-upgrade"'):
            self.assertIn(action, source)
        read = source.index("CCNMReadN78PolicyState()")
        recover = source.index("CCNMRecoverN78Preference")
        self.assertLess(read, recover)
        self.assertIn("CCNMReadN78PolicyState()", source)
        self.assertIn("CCNMRecoverN78Preference", source)
        self.assertIn("CCNMN78PolicySummaryMayUninstallKey", source)
        self.assertIn("CCNMArmN78PolicyRemovalGuard()", source)
        self.assertIn('summary[@"baselinePresent"]', source)
        self.assertIn('summary[@"transitionPresent"]', source)
        self.assertIn("CCNMExitWhenSetterSettled(", source)
        self.assertIn("CCNMN78PolicyHasOutstandingSetter()", source)
        self.assertIn("dispatch_after", source)
        # Stopping the daemon is the shell's, after this guard returns a clean
        # verdict; see tests/test_launchctl_ownership.py for why it cannot be
        # here. The ordering is covered in tests/test_maintainer_shell_scripts.py.
        self.assertNotIn("Launchd", "\n".join(
            line for line in source.splitlines()
            if not line.lstrip().startswith("//")))

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

    def test_the_guard_never_destroys_the_evidence_a_reinstall_needs(self):
        """Removal is no longer fail-closed over radio state; this is what replaced it.

        Since removal proceeds with a modified modem, a reinstall is the primary
        recovery route, and it only works because the durable policy records
        outlive the package. Destroying them here would convert a recoverable
        state into an unrecoverable one -- the exact harm the old block existed to
        prevent, now reachable by cleanup rather than by refusal.
        """
        source = PRERM_SOURCE.read_text()
        self.assertIn("geteuid() != 0", source)
        self.assertIn("return CCNMPrermBlocked", source)
        self.assertNotIn("|| true", source)
        self.assertNotIn("unlink(CCNMN78PolicyBaselinePath", source)
        self.assertNotIn("removeItemAtPath:CCNMN78PolicyBaselinePath", source)
        # The band selection is the one durable file this script may retire, and
        # only on a real removal; see
        # test_the_band_selection_is_discarded_when_the_install_is_retired.
        for path in (
            "CCNMN78PolicyStatePath",
            "CCNMN78PolicyIntentPath",
            "CCNMN78PolicyInFlightPath",
        ):
            self.assertNotIn(f"unlink({path}", source)
            self.assertNotIn(f"removeItemAtPath:{path}", source)

    def test_the_band_selection_is_discarded_when_the_install_is_retired(self):
        """A preference that outlives the package makes reinstalling a dead remedy.

        The selection deliberately survives the off state, so it cannot join
        CCNMN78PolicyPaths() and be retired with the policy records. That leaves
        removal as the only moment it has no owner left. Skipping it is worse than
        untidy: a stored band the current SIM no longer offers makes the toggle
        refuse, and nothing in Settings names the stored value, so the one remedy
        every user reaches for -- reinstall -- would silently inherit the same
        selection and fail again.
        """
        prerm = PRERM_SOURCE.read_text()

        # A single funnel authorizes removal, so a later early return added to this
        # guard cannot quietly skip the cleanup.
        self.assertTrue("static CCNMPrermExitCode CCNMAllowRemoval(" in prerm,
                        "prerm has no single removal-authorizing funnel")
        funnel = prerm[prerm.index("static CCNMPrermExitCode CCNMAllowRemoval("):]
        funnel = funnel[:funnel.index("\n}")]
        self.assertIn("CCNMDiscardRetiredBandSelection", funnel)
        # Only a real retirement discards it. upgrade and failed-upgrade hand the
        # same records to a successor, and deconfigure leaves the package unpacked,
        # so none of them may throw away a preference the user still owns.
        self.assertIn('@"remove"', funnel)
        self.assertTrue(funnel.count("CCNMDiscardRetiredBandSelection") == 1, funnel)

        self.assertTrue("static void CCNMDiscardRetiredBandSelection(" in prerm,
                        "prerm does not define the selection cleanup")
        discard = prerm[prerm.index("static void CCNMDiscardRetiredBandSelection("):]
        discard = discard[:discard.index("\n}")]
        self.assertIn("CCNMN78SelectedBandsPath()", discard)
        # Preference data is not policy evidence. Failing to unlink it leaves the
        # modem untouched, so it must be reported and never become a block: that
        # would make an unremovable package out of a stale preference file.
        self.assertTrue("CCNMPrermBlocked" not in discard, discard)
        self.assertIn("fprintf(stderr", discard)
        self.assertIn("ENOENT", discard)

    def test_every_durable_file_is_either_policy_evidence_or_retired_on_removal(self):
        """Locks the rule, not the one file that currently breaks it.

        1.6.0 introduced the first file the policy owns but the policy records do
        not retire. The next preference added will land in the same gap, and the
        symptom is invisible until a user reinstalls, so the check has to be about
        the set of durable paths rather than about n78-selection.plist.
        """
        policy = POLICY_SOURCE.read_text()
        prerm = PRERM_SOURCE.read_text()

        declared = re.findall(r'CCNMPolicyRoot\(@"([^"]+)"\)', policy)
        self.assertGreater(len(declared), 1)
        accessors = dict(re.findall(
            r"NSString \*(CCNMN78\w+)\(void\) \{\s*"
            r'return CCNMPolicyRoot\(@"([^"]+)"\);',
            policy))
        # Every durable path is reachable through exactly one named accessor, so
        # the audit below cannot be defeated by an inline path literal.
        self.assertEqual(sorted(accessors.values()), sorted(declared))

        retired = policy[policy.index("NSArray<NSString *> *CCNMN78PolicyPaths(void)"):]
        retired = retired[:retired.index("\n}")]
        for accessor in accessors:
            call = accessor + "()"
            self.assertTrue(
                call in retired or call in prerm,
                f"{accessor} names a durable file that is neither retired with the "
                f"policy records nor discarded on removal")

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
                        source.index("static NSString *CCNMMaintainerLaunchdPath")]
        self.assertIn("stringByAppendingString:path", rooted)
        self.assertNotIn("stringByAppendingPathComponent:path", rooted)
        # The contract check compares against the launchd path, not ours: they are
        # different values on roothide and comparing the wrong one would reject a
        # correct plist.
        verify = source[source.index("BOOL CCNMVerifyMaintenanceLaunchdContract"):]
        self.assertIn("CCNMMaintainerLaunchdPath(", verify)
        self.assertLess(verify.index("CCNMMaintainerLaunchdPath("),
                        verify.index("isEqualToString:expectedProgram"))

    def test_postinst_attempts_guard_cleanup_before_the_launchd_check(self):
        source = POSTINST_SOURCE.read_text()
        clear = source.index("CCNMClearN78PolicyRemovalGuardIfSafe()")
        guard_check = source.index('[summary[@"removalGuardPresent"] boolValue]')
        verify = source.index("CCNMVerifyMaintenanceLaunchdContract(&launchdError)")
        self.assertLess(clear, guard_check)
        self.assertLess(guard_check, verify)

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

    def test_postinst_launchd_verification_is_non_fatal(self):
        # The maintenance daemon only provides automatic serving-state
        # monitoring. It owns no policy or modem state, so a host whose plist or
        # helper is unusable must still get a fully configured package instead of
        # a permanently half-installed one.
        source = POSTINST_SOURCE.read_text()
        verify = source.index("CCNMVerifyMaintenanceLaunchdContract(&launchdError)")
        tail = source[verify:]
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
        self.assertIn("return CCNMAllowRemoval(action)", guard_body)
        # The funnel every allowed verdict goes through must not read or write
        # policy state either, or the exemption above would be undone by it.
        funnel = source[source.index("static CCNMPrermExitCode CCNMAllowRemoval("):]
        funnel = funnel[:funnel.index("\n}")]
        for policy_call in (
            "CCNMReadN78PolicyState",
            "CCNMRecoverN78Preference",
            "CCNMArmN78PolicyRemovalGuard",
            "CCNMN78PolicyStatePath",
            "CCNMN78PolicyBaselinePath",
            "CCNMN78PolicyRemovalGuardPath",
        ):
            self.assertTrue(policy_call not in funnel, funnel)
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

    def test_launchd_owner_is_fail_closed_and_scheme_aware(self):
        source = MAINTAINER_SOURCE.read_text()
        for token in (
            "CCNMMaintainerInstallPrefix",
            "CCNMMaintainerLaunchdPrefix",
            "THEOS_PACKAGE_INSTALL_PREFIX",
            "CCNMVerifyMaintenanceLaunchdContract",
            # Contract keys that must be checked, since a plist missing either one
            # would load a daemon that is not the reviewed one: without
            # DISABLE_TWEAKS the daemon gets the tweak injected into itself, and a
            # SuccessfulExit KeepAlive would restart it forever instead of
            # letting it exit when the policy is disabled.
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
        # Running launchctl belongs to the shell and the retired probe must not
        # come back; both are pinned in tests/test_launchctl_ownership.py.

    def test_the_contract_accepts_the_plist_launchctl_rewrote_on_load(self):
        """One file, two correct spellings, at two different moments.

        roothide's launchctl rewrites absolute paths to jbroot(path) and writes the
        result back to disk with its own __Patched marker, so after the first
        successful load the file no longer holds the bare paths that shipped. Any
        later postinst run that does not unpack sees the rewritten file: plain
        `dpkg --configure`, and the abort-remove rerun after a blocked prerm. The
        reporting device hit the second one and the guard reported a contract
        violation against a plist that was correct and already loaded.

        The widening is evidence-bound rather than lenient. __Patched is
        launchctl's own marker and this package never writes it, the comparison
        stays exact so the doubled path this project shipped once is still a
        mismatch, and a prefix from a previous jailbreak root still fails -- which
        is right, because a re-jailbreak needs a reinstall rather than a load.
        """
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("BOOL CCNMVerifyMaintenanceLaunchdContract"):]
        code = "\n".join(
            line for line in body.splitlines()
            if not line.lstrip().startswith("//")
        )
        # Gated on launchctl's own marker, read as a boolean number rather than
        # accepted for mere presence.
        self.assertIn('installed[@"__Patched"] isKindOfClass:NSNumber.class', code)
        self.assertIn('[installed[@"__Patched"] boolValue]', code)
        self.assertIn("launchctlRewrote", code)
        # The alternative is the install-prefix form, which is what launchctl
        # produces. Reusing the already-resolved executablePath keeps it identical
        # to the file the stat above proved is present and executable.
        self.assertIn("NSString *rewrittenProgram = executablePath;", code)
        self.assertIn("NSString *rewrittenBaseline = CCNMMaintainerRootedPath(", code)
        # Both keys must widen, or a rewritten plist still fails on the watched
        # path alone.
        for name in ("programMatches", "baselineMatches"):
            clause = code[code.index("BOOL %s =" % name):]
            clause = clause[:clause.index(";")]
            self.assertIn("isEqualToString:expected", clause)
            self.assertIn("launchctlRewrote", clause)
        self.assertIn("if (!programMatches || !baselineMatches)", code)
        # Still exact: a doubled prefix and a stale jailbreak root must keep
        # failing, so no suffix or containment test may appear.
        for forbidden in ("hasSuffix:", "hasPrefix:", "containsString:", "rangeOfString:"):
            self.assertNotIn(forbidden, code)
        # The refusal names the accepted alternative too, or the mismatch is not
        # diagnosable from the dpkg log.
        self.assertIn("once launchctl has rewritten them", code)

    def test_missing_baseline_only_cleans_a_verified_restore_checkpoint(self):
        source = POLICY_SOURCE.read_text()
        self.assertIn("CCNMIsVerifiedRestoreCleanupCheckpoint", source)
        self.assertIn('state[@"readBackVerified"]', source)
        self.assertIn('state[@"verifiedActiveBands"]', source)
        self.assertIn("CCNMDictionariesEqual(fresh[@\"activeBands\"], state[@\"verifiedActiveBands\"])", source)
        self.assertIn("A required policy baseline is missing; no modem write was issued.", source)

    def test_an_unreadable_modem_does_not_make_the_package_unremovable(self):
        """The live probe cannot succeed from a maintainer script, so it cannot be a gate.

        CoreTelephony answers EACCES to the guard even at euid 0: it links no
        libroothide and is exec'd through a bare path, so it gets neither the
        jailbreak's path redirection nor its exemptions. A check that can only
        return "inconclusive" is an unconditional deny, and it made the package
        impossible to remove on every device.

        The probe is kept for diagnosis and for the reviewed-orphan detection, but
        an unanswered probe must fall through to the durable records.
        """
        source = self._prerm_code()
        probe = source.index('BOOL liveProbeUnavailable = ![orphanEligibility[@"conclusive"]')
        durable = source.index("CCNMSummaryAllowsRemoval(current)")
        self.assertLess(probe, durable)
        # Nothing between them may refuse. This is the whole fix: an inconclusive
        # probe warns and the durable records decide.
        self.assertNotIn("return CCNMPrermBlocked", source[probe:durable])
        # The call itself stays, so an entitled or rootless guard starts working
        # again with no further change.
        self.assertIn("CCNMReadKnownOrphanedN78RemovalSafety()", source)
        # The warning names the observed error, so a failure mode other than EACCES
        # is diagnosable from the dpkg log alone.
        self.assertEqual(source.count("liveProbeError"), 2)

    def test_a_modified_modem_warns_instead_of_making_the_package_unremovable(self):
        """Removal never blocks over radio state, because that state is recoverable.

        The fail-closed design assumed a narrowed NR set could not be undone once
        the restore implementation departed. Restoring the device's carrier
        configuration clears it, established by operator report, so blocking buys
        nothing and costs an unremovable package -- delivered as exit 73 plus
        stderr, which a graphical package manager may discard entirely.

        The three paths that can find a modified modem must all warn and continue,
        and the durable records must survive so a reinstall can still recover.
        """
        source = self._prerm_code()
        # Exactly one refusal remains, and it is the non-root invocation: dpkg
        # always runs maintainer scripts as root, so that is an out-of-band call,
        # not a device condition, and refusing it cannot strand a real removal.
        self.assertEqual(source.count("return CCNMPrermBlocked"), 1)
        root_check = source.index("geteuid() != 0")
        refusal = source.index("return CCNMPrermBlocked")
        self.assertLess(root_check, refusal)
        self.assertLess(refusal, source.index("CCNMReadN78PolicyState()"))
        # All three modified-modem outcomes funnel through one reporting helper:
        # the reviewed-orphan detection, the unreachable modem, and a restore that
        # did not verify.
        self.assertEqual(source.count("CCNMAllowRemovalWithModifiedModem(action"), 3)
        helper = source.index("static CCNMPrermExitCode CCNMAllowRemovalWithModifiedModem")
        body = source[helper:source.index("int main(", helper)]
        # It must go through the funnel, or the band selection is left behind.
        self.assertIn("return CCNMAllowRemoval(action);", body)
        self.assertNotIn("CCNMPrermBlocked", body)
        self.assertIn("fprintf(stderr", body)
        # The warning has to name both remedies and the reason it is safe, since
        # this is the only thing the user will see.
        self.assertIn("reinstall this package", body)
        self.assertIn("carrier configuration", body)
        self.assertIn("LTE was never modified", body)
        # Records are what make a reinstall able to recover, so nothing here may
        # retire them. The per-path assertions live in
        # test_the_guard_never_destroys_the_evidence_a_reinstall_needs.
        self.assertNotIn("CCNMN78PolicyBaselinePath", body)

    def test_the_restore_is_still_attempted_when_the_modem_is_reachable(self):
        """Warning instead of blocking must not become skipping the restore.

        Restoring here is still the best available outcome; it is just no longer a
        precondition for removal. It is skipped only when the probe proved the
        access is unavailable, because every failure path inside the recovery
        routine durably marks recoveryRequired/rebootRequired, and that marker
        keeps the removal guard armed -- turning every later install into a
        half-configured package whose Settings UI can no longer recover.
        """
        source = self._prerm_code()
        guard = source.rindex("if (liveProbeUnavailable)")
        restore = source.index("CCNMRecoverN78Preference")
        self.assertLess(guard, restore)
        # The skip is conditional on the probe, not unconditional.
        self.assertIn("CCNMAllowRemovalWithModifiedModem(action", source[guard:restore])
        # A verified restore takes the plain funnel, so a clean device still gets a
        # silent removal with no scary warning.
        self.assertIn("CCNMExitWhenSetterSettled(CCNMAllowRemoval(action));", source)

    @staticmethod
    def _prerm_code():
        """prerm.m with // comments removed.

        Every assertion here is about control flow, and this file explains its
        reasoning at length in comments that quote the very tokens being
        searched for. Matching one of those would make the test pass on prose.
        """
        return "\n".join(
            line for line in PRERM_SOURCE.read_text().splitlines()
            if not line.lstrip().startswith("//")
        )

    def test_package_verifier_requires_and_inspects_prerm(self):
        self.assertEqual(verify_release_package.REQUIRED_MAINTAINER_FILES, {"postinst", "prerm"})
        self.assertIn(
            "networkmanager-removal-guard",
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
        )
        self.assertIn(
            "usr/libexec/networkmanager-removal-guard",
            verify_release_package.REQUIRED_PAYLOAD_FILES,
        )
        verifier = (ROOT / "scripts/verify_release_package.py").read_text()
        self.assertIn("binary.name in UNLINKED_ROOTHIDE_TOOLS", verifier)
        self.assertIn("must be a shell script, not a Mach-O binary", verifier)


if __name__ == "__main__":
    unittest.main(verbosity=2)
