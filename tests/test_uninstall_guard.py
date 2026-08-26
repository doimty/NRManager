#!/usr/bin/env python3
"""Contracts for the non-blocking shell removal and downgrade paths.

The old name is retained because this file is the historical home of the
uninstall checks. Neither old implementation is: removal no longer asks a
compiled guard whether a saved BandInfo can be replayed, and it no longer
reloads carrier defaults through two bounded CommCenter kills either.

The second of those is the 1.6.0 regression. The reload's exit status was read as
proof that the modem had gone back to the carrier's band configuration, the target
device disproved the premise -- the bands stayed narrowed -- and that false
success then authorised deleting the policy records, baseline included. The
baseline holds the only copy of the pre-enable configuration, so the one path that
could not restore was also the one path that destroyed the means of restoring.

What prerm does now is keep the records that make the Settings route work after
the package is gone, discard them only when no baseline proves there is still
something to undo, and always let dpkg finish. The reverse-write restore itself
lives in the Settings bundle and is pinned in tests/test_reverse_restore.py.
"""

from pathlib import Path
import re
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACTIONS_MAKEFILE = ROOT / "package-actions/Makefile"
POSTINST_SOURCE = ROOT / "package-actions/postinst.m"
POSTINST_TEMPLATE = ROOT / "package-actions/postinst.sh.in"
PRERM_TEMPLATE = ROOT / "package-actions/prerm.sh.in"
POLICY_SUPPORT = ROOT / "package-actions/policy-records.sh.inc"
RETIRED_CARRIER_SUPPORT = ROOT / "package-actions/carrier-reset.sh.inc"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
MAINTAINER_SOURCE = ROOT / "package-actions/CCNMMaintainerEnvironment.m"
PATCHER_PATH = ROOT / "scripts/patch-maintenance-launchd.py"
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
import verify_release_package  # noqa: E402



def shell_code(text: str) -> str:
    """Drop shell comment lines so prose cannot satisfy a source contract."""
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))


def objc_code(text: str) -> str:
    """Remove the two Objective-C comment forms for token-level assertions."""
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def function_body(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(marker)


class UninstallGuardTests(unittest.TestCase):
    def test_only_the_install_guard_is_a_compiled_payload_helper(self):
        """The shell owns removal; the binary owns only plist inspection."""
        makefile = ACTIONS_MAKEFILE.read_text()
        self.assertTrue(POSTINST_SOURCE.exists())
        self.assertFalse((ROOT / "package-actions/prerm.m").exists())
        self.assertNotIn("CCNMDpkgVersion", makefile)
        self.assertNotIn("prerm.m", makefile)
        self.assertIn("TOOL_NAME = networkmanager-install-guard", makefile)
        self.assertNotIn("networkmanager-removal-guard", makefile)
        self.assertIn("networkmanager-install-guard_FILES = postinst.m", makefile)
        self.assertIn("networkmanager-install-guard_INSTALL_PATH = /usr/libexec", makefile)
        self.assertNotIn("/DEBIAN", makefile)
        self.assertIn("-DCCNM_MAINTAINER_SCRIPT", makefile)

        self.assertIn("usr/libexec/networkmanager-install-guard",
                      verify_release_package.REQUIRED_PAYLOAD_FILES)
        self.assertNotIn("usr/libexec/networkmanager-removal-guard",
                         verify_release_package.REQUIRED_PAYLOAD_FILES)
        self.assertEqual(
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
            ("networkmanager-install-guard", "networkmanager-maintenance"),
        )
        self.assertIn(
            "networkmanager-removal-guard",
            verify_release_package.FORBIDDEN_LEGACY_PAYLOAD_BASENAMES,
        )

    def test_maintainer_sources_are_shell_and_the_templates_are_distinct(self):
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            text = template.read_text()
            with self.subTest(template=template.name):
                self.assertTrue(text.startswith("#!/bin/sh\n"))
                self.assertNotIn("@JBROOT@", shell_code(text))
                # The old plist substitution needed these tools. Their names may
                # occur in the explanatory header, but not in executable lines.
                for line in shell_code(text).splitlines():
                    self.assertIsNone(
                        re.search(r"\b(plutil|sed|grep)\b", line),
                        f"{template.name}: {line}",
                    )
        postinst = shell_code(POSTINST_TEMPLATE.read_text())
        prerm = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("networkmanager-install-guard", postinst)
        self.assertNotIn("networkmanager-removal-guard", prerm)
        self.assertIn("@POLICY_RECORD_SUPPORT@", prerm)
        # postinst has no reason to know these paths: it neither inspects nor
        # deletes policy records, and the include's only job is removal cleanup.
        self.assertNotIn("@POLICY_RECORD_SUPPORT@", postinst)
        # The retired include, gone rather than merely unreferenced.
        self.assertFalse(RETIRED_CARRIER_SUPPORT.exists())
        for text in (postinst, prerm):
            self.assertNotIn("@CARRIER_RESET_SUPPORT@", text)
            self.assertNotIn("@CARRIER_RESET_FLOOR@", text)

    def test_postinst_checks_only_the_maintenance_contract_and_is_non_fatal(self):
        source = objc_code(POSTINST_SOURCE.read_text())
        self.assertIn("CCNMActionExpectsAWorkingInstall", source)
        self.assertIn("CCNMVerifyMaintenanceLaunchdContract", source)
        self.assertIn("CCNMMaintenanceLaunchdVerifiedSentinel", source)
        self.assertIn("return CCNMInstallAllowed", source)
        self.assertNotIn("CCNMClearN78PolicyRemovalGuardIfSafe", source)
        self.assertNotIn("CCNMArmN78PolicyRemovalGuard", source)
        self.assertNotIn("CCNMN78PolicyController.h", source)
        self.assertNotIn("CCNMRecoverN78Preference", source)
        # A contract mismatch disables automatic monitoring, not package setup.
        verify = source.index("CCNMVerifyMaintenanceLaunchdContract")
        self.assertNotIn("return CCNMPostinstBlocked", source[verify:])
        self.assertIn("warning", source[verify:].lower())

    def test_prerm_reports_what_it_cannot_undo_and_always_returns_zero(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("@POLICY_RECORD_SUPPORT@", source)
        self.assertIn("policy_baseline_present", source)
        self.assertIn("CANNOT undo it", source)
        self.assertIn("only turning the preference off in Settings", source)
        self.assertIn("removal continues", source)
        self.assertTrue(re.search(r"\nexit 0\s*$", source))
        for forbidden in (
            "CoreTelephony", "CCNMN78PolicyController", "networkmanager-removal-guard",
            "CCNMRecoverN78Preference", "CCNMArmN78PolicyRemovalGuard",
            "CCNMPrermBlocked", "exit 73",
            # The retired reload, and the success signal that made it dangerous.
            "CommCenter", "killall", "carrier_reset_defaults", "reset_succeeded",
        ):
            self.assertNotIn(forbidden, source)

    def test_no_process_signal_is_treated_as_a_restored_modem(self):
        # The 1.6.0 defect in one assertion: a process exit status was read as
        # proof about the modem's band configuration. Nothing in either shell file
        # may signal a process at all, so no such inference is available.
        for path in (PRERM_TEMPLATE, POLICY_SUPPORT):
            with self.subTest(file=path.name):
                code = shell_code(path.read_text())
                for forbidden in ("killall", "CommCenter", "kill -", "pkill"):
                    self.assertNotIn(forbidden, code)

    def test_the_bootout_is_the_only_child_process_left(self):
        # Every child a maintainer script runs is a chance to wedge dpkg, and this
        # project has done it. 1.6.0 ran three kinds here -- two killalls, a dpkg
        # version comparison, and the bootout -- and resolving the delay command
        # too late made the comparison report "below the floor" on every ordinary
        # upgrade. Removing the reload and the floor removed two of the three.
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("resolve_delay_command", source)
        self.assertLess(source.index("resolve_delay_command"),
                        source.index("launchd_bootout"))
        self.assertNotIn("bounded_run", source)
        self.assertNotIn("resolve_dpkg_command", source)
        self.assertNotIn("resolve_carrier_killall", source)
        # The include is pure filesystem work: paths, `[ -e ]`, and `rm -f`.
        include = shell_code(POLICY_SUPPORT.read_text())
        for forbidden in ("launchctl_run", "bounded_run", "LAUNCHCTL_DELAY"):
            self.assertNotIn(forbidden, include)
        self.assertIn("rm -f", include)

    def test_policy_records_are_retired_only_when_no_baseline_remains(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        present = source.index("policy_baseline_present")
        cleanup = source.index("discard_policy_records")
        self.assertLess(present, cleanup)
        # Both conditions, on the one line that deletes. A baseline on disk is the
        # only copy of the pre-enable configuration and the only evidence that an
        # enable is still in effect, so it gates the deletion of the whole set.
        line = next(l for l in source.splitlines() if "discard_policy_records" in l)
        self.assertIn('[ "$ACTION" = remove ]', line)
        self.assertIn('[ -z "$BASELINE_PRESENT" ]', line)
        records = function_body(POLICY_SUPPORT.read_text(), "policy_records()")
        for suffix in ("state.plist", "intent.plist", "inflight.plist"):
            self.assertIn(suffix, records)
        # The baseline is in the set through the shared basename variable rather
        # than a second literal, which is what keeps the presence check and the
        # deletion from disagreeing about which file they mean.
        self.assertIn("${POLICY_BASELINE_BASENAME}", records)
        discard = function_body(POLICY_SUPPORT.read_text(), "discard_policy_records()")
        self.assertIn("remove_listed_files", discard)
        # The user selection is intentionally a separate preference, not policy
        # evidence. It has its own removal-only cleanup below.
        self.assertNotIn("n78-selection.plist", records)

    def test_the_user_selection_is_discarded_only_on_remove(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        line = next(l for l in source.splitlines() if "discard_band_selection" in l)
        self.assertIn('[ "$ACTION" = remove ]', line)
        # Independent of the baseline on purpose: preference data cannot leave the
        # modem in a worse state, so its cleanup has no reason to wait on a
        # narrowed modem being undone first.
        self.assertNotIn("BASELINE_PRESENT", line)
        selection = function_body(POLICY_SUPPORT.read_text(), "policy_band_selection()")
        self.assertIn("n78-selection.plist", selection)

    def test_the_action_is_read_without_a_version_comparison(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn('ACTION="${1:-}"', source)
        self.assertIn('[ "$ACTION" != remove ]', source)
        # dpkg's second positional argument is the incoming version, and nothing
        # here reads it any more. 1.6.0 compared it against a floor to decide
        # whether the successor could undo a narrowed modem; both halves were
        # wrong, because the reload undid nothing and no version needs protecting
        # from records it can simply ignore.
        self.assertNotIn('"${2:-}"', source)
        self.assertNotIn("INCOMING_VERSION", source)
        self.assertNotIn("CARRIER_RESET_FLOOR", source)
        self.assertNotIn("version_is_at_least", source)
        self.assertNotIn("compare-versions", source)
        patcher = PATCHER_PATH.read_text()
        self.assertIn('POLICY_RECORD_INCLUDE = "policy-records.sh.inc"', patcher)
        self.assertIn('"@POLICY_RECORD_SUPPORT@"', patcher)
        self.assertNotIn("CARRIER_RESET_FLOOR =", patcher)
        # Retired placeholders are named in the patcher so a template that still
        # carries one fails loudly rather than shipping it unsubstituted.
        for retired in ("@CARRIER_RESET_SUPPORT@", "@CARRIER_RESET_FLOOR@"):
            self.assertIn(retired, patcher[patcher.index("RETIRED_PLACEHOLDERS"):])
        # And the include goes only where it is used.
        self.assertNotIn('"@POLICY_RECORD_SUPPORT@"',
                         patcher[patcher.index('"postinst":'):patcher.index('"prerm":')])

    def test_prerm_stops_the_daemon_but_never_blocks_removal_on_launchd(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("resolve_launchctl", source)
        self.assertIn("launchd_bootout", source)
        self.assertIn("removal continues", source)
        # Helper functions return statuses internally, but the top-level prerm
        # deliberately ends with an unconditional zero so dpkg cannot be blocked
        # by a reset, cleanup, or launchd warning.
        self.assertNotIn("exit 73", source)
        self.assertTrue(re.search(r"\nexit 0\s*$", source))

    def test_the_legacy_removal_guard_path_is_migration_cleanup_only(self):
        policy = objc_code(POLICY_SOURCE.read_text())
        self.assertIn("CCNMN78PolicyRemovalGuardPath", policy)
        # It is deleted where the modem provably reached system default, which is
        # now the read-back-verified restore rather than a killed process.
        finish = function_body(policy, "static BOOL CCNMFinishSystemDefaultState")
        self.assertIn("CCNMN78PolicyRemovalGuardPath()", finish)
        self.assertIn("CCNMFileExists", finish)
        self.assertIn("unlink", finish)
        # Cleanup only: failing to delete it may not fail the restore, and its
        # presence may not become a verdict.
        self.assertNotIn("return NO", finish[finish.index("CCNMFileExists"):])
        summary = function_body(policy, "static NSDictionary *CCNMSummaryFromState")
        self.assertNotIn("removalGuardPresent",
                         summary.replace("legacyRemovalGuardPresent", ""))

    def test_the_controller_owns_the_reverse_restore_again(self):
        # 1.6.0 deleted this path in favour of the reload. It is back, because
        # undoing the narrowing needs the mirror of the write that caused it.
        policy = objc_code(POLICY_SOURCE.read_text())
        self.assertIn("performRestoreOperation:", policy)
        self.assertIn("CCNMBuildRestorePayload", policy)
        self.assertIn("CCNMValidateRestorePayload", policy)
        self.assertIn("CCNMValidateBaselineCompatibility", policy)
        # And the reload is gone from the bundle: adapter, states and source file.
        self.assertNotIn("performCarrierReset", policy)
        self.assertNotIn("CCNMResetCarrierConfiguration", policy)
        self.assertFalse((ROOT / "networkmanagerprefs/CCNMCarrierReset.m").exists())
        self.assertFalse((ROOT / "networkmanagerprefs/CCNMCarrierReset.h").exists())
        self.assertNotIn("CCNMCarrierReset.m",
                         (ROOT / "networkmanagerprefs/Makefile").read_text())

    def test_prefix_resolution_stays_process_specific(self):
        maintainer = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMMaintainerInstallPrefix", maintainer)
        self.assertIn("CCNMMaintainerLaunchdPrefix", maintainer)
        self.assertIn("emptyIsValid ? @\"\" : nil", maintainer)
        self.assertIn("CCNMInstallPrefixVariable, NO", maintainer)
        self.assertIn("CCNMLaunchdPrefixVariable, YES", maintainer)
        postinst = shell_code(POSTINST_TEMPLATE.read_text())
        self.assertIn('NETWORKMANAGER_INSTALL_PREFIX="$JBROOT_PREFIX"', postinst)
        self.assertIn('NETWORKMANAGER_LAUNCHD_PREFIX="$LAUNCHD_PREFIX"', postinst)
        # prerm runs no compiled guard, so it has no reason to export a guard
        # prefix. It resolves its own command paths directly.
        self.assertNotIn("NETWORKMANAGER_INSTALL_PREFIX", shell_code(PRERM_TEMPLATE.read_text()))

    def test_package_verifier_requires_shell_scripts_and_rejects_the_retired_binary(self):
        self.assertEqual(verify_release_package.REQUIRED_MAINTAINER_FILES, {"postinst", "prerm"})
        verifier = (ROOT / "scripts/verify_release_package.py").read_text()
        self.assertIn("must be a shell script, not a Mach-O binary", verifier)
        self.assertIn("FORBIDDEN_LEGACY_PAYLOAD_BASENAMES", verifier)
        self.assertIn("RETIRED_REMOVAL_GUARD_RELATIVE", verifier)

        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory)
            (control / "postinst").write_text(
                "#!/bin/sh\n"
                "/usr/libexec/networkmanager-install-guard \"$@\"\n"
                "exit 0\n"
            )
            (control / "prerm").write_text("#!/bin/sh\nexit 0\n")
            for path in control.iterdir():
                path.chmod(0o755)
            failures = []
            evidence = verify_release_package.verify_maintainer_scripts(control, failures)
            self.assertEqual(evidence["status"], "passed", failures)
            self.assertEqual(failures, [])

    def test_no_removed_recovery_ui_or_method_survives_in_the_policy_bundle_sources(self):
        combined = "\n".join(
            (ROOT / path).read_text()
            for path in (
                "networkmanagerprefs/CCNMRootListController.m",
                "networkmanagerprefs/CCNMRootListController.h",
                "networkmanagerprefs/Resources/Root.plist",
            )
        )
        for token in (
            "KnownOrphan", "knownOrphan", "recoverKnownOrphanedN78",
            "restoreOriginalBands", "restoreOriginalBandConfiguration",
        ):
            self.assertNotIn(token, combined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
