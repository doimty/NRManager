#!/usr/bin/env python3
"""Contracts for the CommCenter-based carrier-default reset path."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "networkmanagerprefs"
CONTROLLER = (PREFS / "CCNMN78PolicyController.m").read_text()
RESET = (PREFS / "CCNMCarrierReset.m").read_text()
RESET_HEADER = (PREFS / "CCNMCarrierReset.h").read_text()
ROOT_CONTROLLER = (PREFS / "CCNMRootListController.m").read_text()
ROOT_HEADER = (PREFS / "CCNMRootListController.h").read_text()
ROOT_PLIST = (PREFS / "Resources/Root.plist").read_text()
PRERM = (ROOT / "package-actions/prerm.sh.in").read_text()
CARRIER_SHELL = (ROOT / "package-actions/carrier-reset.sh.inc").read_text()
PATCHER = (ROOT / "scripts/patch-maintenance-launchd.py").read_text()
MAKEFILE = (PREFS / "Makefile").read_text()
ACTIONS_MAKEFILE = (ROOT / "package-actions/Makefile").read_text()


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


def carrier_shell_calls(name: str) -> list:
    """Lines of the shell adapter that actually invoke `name`.

    Comment lines are excluded. The adapter explains at length why it uses
    bounded_run rather than launchctl_run, and a plain substring search over the
    file finds those explanations -- so an assertion written that way fails on the
    prose that documents the behaviour it is checking for.
    """
    return [line.strip() for line in CARRIER_SHELL.splitlines()
            if not line.lstrip().startswith("#")
            and re.search(rf"(^|[;&|(]|\bthen\b|\bdo\b)\s*{re.escape(name)}\s", line)]


class ResetModuleTests(unittest.TestCase):
    def test_interface_is_one_deep_operation(self):
        self.assertIn("CCNMResetCarrierConfiguration", RESET_HEADER)
        self.assertEqual(RESET_HEADER.count("CCNMResetCarrierConfiguration"), 1)
        self.assertNotIn("setActiveBandInfo", RESET_HEADER + RESET)
        self.assertNotIn("CCNMCallSetter", RESET_HEADER + RESET)

    def test_command_is_fixed_and_two_invocations_are_not_collapsed(self):
        body = function_body(RESET, "CCNMResetCarrierConfiguration(")
        self.assertEqual(body.count('"killall -9 CommCenter"'), 1)
        run_calls = re.findall(r"CCNMCarrierResetRunOne\(", body)
        self.assertEqual(len(run_calls), 2)
        self.assertIn("firstStatus != 0", body)
        self.assertIn("secondStatus != 0", body)
        self.assertIn("CCNMCarrierResetInterInvocationMicroseconds", body)

    def test_reset_module_has_no_policy_or_band_write_dependency(self):
        self.assertNotIn("CCNMN78Policy", RESET)
        self.assertNotIn("CoreTelephony", RESET)
        self.assertNotIn("setActiveBandInfo", RESET)
        self.assertIn("posix_spawn", RESET)
        self.assertIn("waitpid", RESET)
        self.assertIn("SIGKILL", RESET)

    def test_reset_result_distinguishes_both_attempts(self):
        for key in (
            "CCNMCarrierResetFirstAttemptedKey",
            "CCNMCarrierResetSecondAttemptedKey",
            "CCNMCarrierResetFirstExitStatusKey",
            "CCNMCarrierResetSecondExitStatusKey",
        ):
            self.assertIn(key, RESET_HEADER)
            self.assertIn(key, RESET)


class ControllerResetTests(unittest.TestCase):
    def test_disable_and_recover_share_the_reset_owner(self):
        disable = function_body(CONTROLLER, "- (NSDictionary *)performDisable")
        recover = function_body(CONTROLLER, "- (NSDictionary *)performRecovery")
        self.assertIn("performCarrierReset", disable)
        self.assertIn("performCarrierReset", recover)
        self.assertEqual(disable.count("CCNMCallSetter"), 0)
        self.assertEqual(recover.count("CCNMCallSetter"), 0)
        self.assertEqual(disable.count("CCNMBuildRestorePayload"), 0)
        self.assertEqual(recover.count("CCNMBuildRestorePayload"), 0)

    def test_reset_operation_never_constructs_a_reverse_payload(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performCarrierReset")
        for forbidden in (
            "CCNMCallSetter",
            "CCNMBuildRestorePayload",
            "CCNMCreateBandPayload",
            "setActiveBandInfo",
        ):
            self.assertNotIn(forbidden, body)
        self.assertIn("CCNMResetCarrierConfiguration", body)
        self.assertIn("CCNMFinishCarrierResetState", body)
        self.assertIn("CCNMRecoveryStateCarrierResetPending", body)
        self.assertIn("CCNMRecoveryStateCarrierResetFailed", body)

    def test_reset_failure_keeps_evidence_and_success_retires_it(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performCarrierReset")
        failure = body.index("CCNMResetCarrierConfiguration")
        self.assertIn("CCNMMarkRecovery", body[failure:])
        self.assertIn("CCNMErrorSummary(operation, CCNMN78PolicyErrorCarrierResetFailed", body)
        self.assertIn("CCNMFinishCarrierResetState", body)
        finish = function_body(CONTROLLER, "static BOOL CCNMFinishCarrierResetState")
        self.assertIn("CCNMRemoveOptionalRecord", finish)
        self.assertIn("CCNMN78PolicyBaselinePath()", finish)

    def test_legacy_removal_guard_is_not_a_new_write_gate(self):
        summary = function_body(CONTROLLER, "static NSDictionary *CCNMSummaryFromState")
        self.assertIn("CCNMN78PolicySummaryMayWriteKey", summary)
        may_write_line = next(line for line in summary.splitlines() if "MayWriteKey" in line)
        self.assertNotIn("removalGuardPresent", may_write_line)
        enable = function_body(CONTROLLER, "- (NSDictionary *)performEnable")
        self.assertNotIn("CCNMN78PolicyErrorBusy", enable[enable.index("removalGuard"):]
                         if "removalGuard" in enable else "")


class SettingsResetTests(unittest.TestCase):
    def test_old_one_time_recovery_is_gone(self):
        for source in (ROOT_CONTROLLER, ROOT_HEADER, ROOT_PLIST):
            self.assertNotIn("KnownOrphan", source)
            self.assertNotIn("knownOrphan", source)
        self.assertNotIn("recoverKnownOrphanedN78", ROOT_CONTROLLER + ROOT_HEADER + ROOT_PLIST)

    def test_settings_exposes_one_reload_action(self):
        self.assertIn("resetCarrierConfigurationHandler", ROOT_HEADER)
        self.assertIn("reloadCarrierDefaults:", ROOT_CONTROLLER)
        self.assertIn("reloadCarrierDefaults:", ROOT_PLIST)
        self.assertIn("RESET_CARRIER_DEFAULTS", ROOT_PLIST)
        self.assertNotIn("restoreOriginalBandConfigurationHandler", ROOT_HEADER)
        self.assertNotIn("restoreOriginalBandConfiguration:", ROOT_CONTROLLER)

    def test_settings_reset_action_does_not_write_the_modem_directly(self):
        body = function_body(ROOT_CONTROLLER, "- (void)reloadCarrierDefaults:(PSSpecifier *)specifier {")
        self.assertIn("resetCarrierConfigurationHandler", body)
        self.assertNotIn("CCNMEnableN78Preference", body)
        self.assertNotIn("CCNMDisableN78Preference", body)
        self.assertNotIn("setActiveBandInfo", body)


class MaintainerResetTests(unittest.TestCase):
    def test_prerm_carries_the_observed_double_kill(self):
        self.assertIn("@CARRIER_RESET_SUPPORT@", PRERM)
        # bounded_run, deliberately not launchctl_run. The latching wrapper is
        # correct for launchd and wrong here: it short-circuits every call after
        # the first deadline, so a slow first kill would skip the second -- and the
        # second invocation is the device-observed primitive, not a retry.
        self.assertEqual(
            CARRIER_SHELL.count('bounded_run "$CARRIER_KILLALL" -9 CommCenter'), 2)
        self.assertEqual(carrier_shell_calls("launchctl_run"), [])
        self.assertIn("killall -9 CommCenter", PRERM + CARRIER_SHELL)
        self.assertIn("carrier_reset_defaults", PRERM)

    def test_prerm_never_imports_policy_or_blocks_dpkg_on_reset_failure(self):
        self.assertNotIn("CCNMN78PolicyController", PRERM)
        self.assertNotIn("CoreTelephony", PRERM)
        self.assertNotIn("networkmanager-removal-guard", PRERM)
        self.assertIn("removal continues", PRERM)
        self.assertIn("exit 0", PRERM)

    def test_prerm_only_retires_records_after_reset_success(self):
        reset = PRERM.index("reset_succeeded=0")
        cleanup = PRERM.index("discard_policy_records")
        self.assertLess(reset, cleanup)
        self.assertIn('if [ "$reset_succeeded" -eq 1 ]', PRERM)

    def test_patcher_renders_the_reset_adapter_only_into_prerm(self):
        self.assertIn('CARRIER_RESET_INCLUDE = "carrier-reset.sh.inc"', PATCHER)
        self.assertIn('"@CARRIER_RESET_SUPPORT@"', PATCHER)
        self.assertIn("carrier_reset_support", PATCHER)
        self.assertIn("CCNMCarrierReset.m", MAKEFILE)
        self.assertIn("TOOL_NAME = networkmanager-install-guard", ACTIONS_MAKEFILE)
        self.assertNotIn("networkmanager-removal-guard", ACTIONS_MAKEFILE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
