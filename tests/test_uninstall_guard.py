#!/usr/bin/env python3
"""Contracts for the non-blocking shell removal and downgrade paths.

The old name is retained because this file is the historical home of the
uninstall checks. The old implementation is not: removal no longer asks a
compiled guard whether a saved BandInfo can be replayed. It reloads carrier
defaults through two bounded CommCenter kills, warns on every inconclusive
outcome, and always lets dpkg finish.
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
CARRIER_SUPPORT = ROOT / "package-actions/carrier-reset.sh.inc"
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
        self.assertIn("@CARRIER_RESET_SUPPORT@", prerm)
        self.assertNotIn("@CARRIER_RESET_SUPPORT@", postinst)

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

    def test_prerm_uses_the_carrier_reset_and_always_returns_zero(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("@CARRIER_RESET_SUPPORT@", source)
        self.assertIn("carrier_reset_defaults", source)
        self.assertIn("reset_succeeded=0", source)
        self.assertIn('if [ "$reset_succeeded" -eq 1 ]', source)
        self.assertIn("removal continues", source)
        self.assertTrue(re.search(r"\nexit 0\s*$", source))
        for forbidden in (
            "CoreTelephony", "CCNMN78PolicyController", "networkmanager-removal-guard",
            "CCNMRecoverN78Preference", "CCNMArmN78PolicyRemovalGuard",
            "CCNMPrermBlocked", "exit 73",
        ):
            self.assertNotIn(forbidden, source)

    def test_the_two_kills_are_independent_and_bounded(self):
        source = CARRIER_SUPPORT.read_text()
        body = function_body(source, "carrier_reset_defaults()")
        self.assertEqual(body.count('bounded_run "$CARRIER_KILLALL" -9 CommCenter'), 2)
        self.assertIn('"$LAUNCHCTL_DELAY" 0.25', body)
        self.assertNotIn("launchctl_run", body)
        self.assertIn("_carrier_first_status", body)
        self.assertIn("_carrier_second_status", body)

    def test_policy_records_are_retired_only_after_a_confirmed_reset(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        reset = source.index("reset_succeeded=0")
        cleanup = source.index("discard_policy_records")
        self.assertLess(reset, cleanup)
        self.assertIn('if [ "$reset_succeeded" -eq 1 ] && ! discard_policy_records', source)
        records = function_body(CARRIER_SUPPORT.read_text(), "carrier_policy_records()")
        for suffix in ("state.plist", "baseline.plist", "intent.plist", "inflight.plist"):
            self.assertIn(suffix, records)
        discard = function_body(CARRIER_SUPPORT.read_text(), "discard_policy_records()")
        self.assertIn("remove_listed_files", discard)
        # The user selection is intentionally a separate preference, not policy
        # evidence. It has its own removal-only cleanup below.
        self.assertNotIn("n78-selection.plist", records)

    def test_the_user_selection_is_discarded_only_on_remove(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn('[ "$ACTION" = remove ] && ! discard_band_selection', source)
        selection = function_body(CARRIER_SUPPORT.read_text(), "carrier_band_selection()")
        self.assertIn("n78-selection.plist", selection)
        action = source[source.index("case \"$ACTION\" in"):source.index("if [ -n \"$RETIRING\" ]")]
        # No downgrade/upgrade branch may call the preference cleanup.
        self.assertNotIn("discard_band_selection", action)

    def test_upgrade_floor_is_shell_rendered_and_downgrade_is_retirement(self):
        source = shell_code(PRERM_TEMPLATE.read_text())
        self.assertIn("CARRIER_RESET_FLOOR='@CARRIER_RESET_FLOOR@'", source)
        self.assertIn('elif version_is_at_least "$INCOMING_VERSION" "$CARRIER_RESET_FLOOR"', source)
        self.assertIn('case "$ACTION" in', source)
        self.assertIn("upgrade)", source)
        self.assertIn("remove)", source)
        patcher = PATCHER_PATH.read_text()
        self.assertIn('CARRIER_RESET_FLOOR = "1.6.0"', patcher)
        self.assertIn('"@CARRIER_RESET_FLOOR@"', patcher)
        self.assertIn('"prerm": COMMON_PLACEHOLDERS + ("@CARRIER_RESET_SUPPORT@",', patcher)
        self.assertNotIn('"@CARRIER_RESET_FLOOR@"',
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
        finish = function_body(policy, "static BOOL CCNMFinishCarrierResetState")
        self.assertIn("CCNMN78PolicyRemovalGuardPath()", finish)
        self.assertIn("CCNMFileExists", finish)
        # It must not be used as a new write/removal verdict.
        summary = function_body(policy, "static NSDictionary *CCNMSummaryFromState")
        self.assertNotIn("removalGuardPresent", summary)

    def test_the_controller_no_longer_has_a_reverse_restore_operation(self):
        policy = objc_code(POLICY_SOURCE.read_text())
        self.assertNotIn("performRestoreOperation", policy)
        self.assertNotIn("CCNMBuildRestorePayload", policy)
        self.assertNotIn("CCNMValidateBaselineCompatibility", policy)
        self.assertIn("performCarrierReset", policy)
        self.assertIn("CCNMResetCarrierConfiguration", policy)

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
