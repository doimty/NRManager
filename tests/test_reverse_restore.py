#!/usr/bin/env python3
"""Contracts for the reverse-write restore path.

1.6.0 replaced this path with a `killall -9 CommCenter` "carrier defaults reload"
on the belief that the modem would reload the carrier's own band configuration.
The target device disproved it: the bands stayed narrowed. Worse, the reload's
exit status was read as proof of success, and that success authorised deleting the
baseline -- the only copy of the pre-enable configuration -- so the one path that
could not restore was also the one that destroyed the means of restoring.

Undoing the narrowing needs the mirror of the write that caused it: a reverse
`setActiveBandInfo:` carrying the saved NR array. These tests pin the properties
that made the 1.6.0 regression possible, so it cannot come back:

  * only one RAT key is ever written, because enable narrowed exactly one;
  * success is a modem read-back, never a process exit status;
  * the baseline is retired only after the read-back matched;
  * no maintainer script signals CommCenter or claims a restore.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / "networkmanagerprefs"
CONTROLLER = (PREFS / "CCNMN78PolicyController.m").read_text()
READER = (PREFS / "CCNMN78PolicyReader.m").read_text()
ROOT_CONTROLLER = (PREFS / "CCNMRootListController.m").read_text()
ROOT_HEADER = (PREFS / "CCNMRootListController.h").read_text()
ROOT_PLIST = (PREFS / "Resources/Root.plist").read_text()
PRERM = (ROOT / "package-actions/prerm.sh.in").read_text()
POSTINST = (ROOT / "package-actions/postinst.sh.in").read_text()
POLICY_SHELL = (ROOT / "package-actions/policy-records.sh.inc").read_text()
PATCHER = (ROOT / "scripts/patch-maintenance-launchd.py").read_text()
MAKEFILE = (PREFS / "Makefile").read_text()
ACTIONS_MAKEFILE = (ROOT / "package-actions/Makefile").read_text()

# Every source file that could plausibly host a revived reload adapter.
ALL_SOURCES = {
    "CCNMN78PolicyController.m": CONTROLLER,
    "CCNMN78PolicyReader.m": READER,
    "CCNMRootListController.m": ROOT_CONTROLLER,
    "CCNMRootListController.h": ROOT_HEADER,
    "Root.plist": ROOT_PLIST,
    "prerm.sh.in": PRERM,
    "postinst.sh.in": POSTINST,
    "policy-records.sh.inc": POLICY_SHELL,
    "patch-maintenance-launchd.py": PATCHER,
}


def function_body(source: str, marker: str) -> str:
    """Body of the first definition whose marker is followed by a brace.

    A marker can also match a forward declaration -- performRestoreOperation: is
    declared in the private interface and defined 300 lines later -- and taking
    the first hit would return the class body instead of the method. A definition
    is the occurrence whose next `{` precedes its next `;`.
    """
    search = 0
    while True:
        start = source.index(marker, search)
        brace = source.find("{", start)
        semicolon = source.find(";", start)
        if brace >= 0 and (semicolon < 0 or brace < semicolon):
            break
        search = start + len(marker)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(marker)


def code_lines(source: str) -> str:
    """`source` with shell and C comment lines removed.

    Every one of these files explains the retired reload at length, and a plain
    substring search for `killall` or `CommCenter` finds the prose that documents
    why they are gone. An assertion written that way fails on its own rationale.
    """
    kept = []
    for line in source.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith("//"):
            continue
        kept.append(line)
    return "\n".join(kept)


def interface_block(source: str, marker: str) -> str:
    """Text of an Objective-C @interface/@implementation block.

    Not function_body: these blocks are delimited by @end, and their first `{`
    belongs to whichever method body comes first.
    """
    start = source.index(marker)
    return source[start:source.index("\n@end", start)]


class RestorePayloadWidthTests(unittest.TestCase):
    """The restore writes exactly the mirror of what enable narrowed."""

    def test_only_the_nr_key_is_replaced(self):
        body = function_body(CONTROLLER, "static NSDictionary *CCNMBuildRestorePayload(")
        assignments = re.findall(r"draft\[(.+?)\]\s*=", body)
        self.assertEqual(assignments, ["CCNMNRKey"])
        self.assertIn("baseline[CCNMNRKey]", body)

    def test_the_payload_is_validated_against_live_and_saved_evidence(self):
        body = function_body(CONTROLLER, "static NSDictionary *CCNMBuildRestorePayload(")
        self.assertIn("CCNMValidateRestorePayload(live, baseline, payload", body)
        # The builder returns nil rather than an unvalidated dictionary, so a
        # future shape change cannot reach the setter unchecked.
        self.assertIn("? payload : nil", body)

    def test_the_validator_rejects_any_change_outside_nr(self):
        body = function_body(CONTROLLER, "static BOOL CCNMValidateRestorePayload(")
        self.assertIn("identical complete RAT key sets", body)
        self.assertIn("exact saved NR array", body)
        self.assertIn("changed current non-NR RAT", body)


class RestoreOperationTests(unittest.TestCase):
    """One owner serves both disable and recover."""

    def test_disable_and_recover_share_the_restore_owner(self):
        disable = function_body(CONTROLLER, "- (NSDictionary *)performDisable")
        recover = function_body(CONTROLLER, "- (NSDictionary *)performRecovery")
        self.assertIn('performRestoreOperation:@"disable" allowIncompleteEvidence:NO', disable)
        self.assertIn('performRestoreOperation:@"recover" allowIncompleteEvidence:YES', recover)

    def test_the_restore_owner_is_declared_before_its_callers(self):
        # performDisable/performRecovery call it earlier in the file. Clang
        # resolves that inside one @implementation, but the private interface is
        # where the contract is stated, and losing it is a silent -Wundeclared
        # risk for any future caller outside the class body.
        private = interface_block(CONTROLLER, "@interface CCNMN78PolicyController ()")
        self.assertIn("performRestoreOperation:(NSString *)operation", private)
        self.assertIn("allowIncompleteEvidence:(BOOL)allowIncomplete", private)

    def test_the_restore_writes_the_modem_and_verifies_by_reading_back(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        self.assertIn("CCNMCreateBandPayload(payload", body)
        self.assertIn("CCNMCallSetter(client, context, payloadInfo", body)
        self.assertIn("CCNMWaitForReadBack(client, subscriptionUUID", body)
        # Read-back is the success criterion. A mismatch must not be reported as a
        # restored modem, which is exactly what the exit-status check did.
        self.assertIn('if (![readBack[@"matched"] boolValue])', body)

    def test_an_uncertain_setter_demands_a_reboot_rather_than_a_retry(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        uncertain = body.index("outcome == CCNMSetterOutcomeUncertain")
        window = body[uncertain:uncertain + 600]
        self.assertIn("CCNMRecoveryStateRebootRequired", window)
        self.assertIn("CCNMN78PolicyErrorSetterUncertain", window)

    def test_a_process_level_uncertain_latch_blocks_before_any_read(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        latch = body.index("CCNMSetterUncertainLatch")
        first_load = body.index("CCNMLoadRecord(")
        self.assertLess(latch, first_load)

    def test_disable_requires_a_settled_enabled_state(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        self.assertIn("BOOL stableEnabled", body)
        self.assertIn("if (!allowIncomplete && !stableEnabled)", body)
        self.assertIn("CCNMAppliedPolicyVerifiedN78Only", body)
        self.assertIn("CCNMRecoveryStateEnabledWithBaseline", body)

    def test_transition_evidence_from_this_boot_refuses_a_second_write(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        self.assertIn("inFlightMayBeCurrent", body)
        self.assertIn("intentMayBeCurrent", body)
        self.assertIn("pendingStateMayBeCurrent", body)
        self.assertIn("baselineOnlyMayBeCurrent", body)
        guard = body.index("if (inFlightMayBeCurrent")
        window = body[guard:guard + 900]
        self.assertIn("CCNMRecoveryStateRebootRequired", window)
        self.assertIn("reboot before recovery", window)
        # The refusal happens before the payload is built, so a boot-local
        # transition cannot reach CoreTelephony at all.
        self.assertLess(guard, body.index("CCNMBuildRestorePayload("))

    def test_the_retired_reset_states_are_exempt_from_that_refusal(self):
        # 1.6.0's reload issued no modem write, so a state naming it cannot hide an
        # outstanding setter. Treating it as a boot-local transition would strand
        # exactly the devices that build left narrowed: they would have to reboot
        # before the restore they need became available.
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        self.assertIn("BOOL resetStateOwnsNoModemWrite", body)
        self.assertIn("CCNMRecoveryStateCarrierResetPending", body)
        self.assertIn("CCNMRecoveryStateCarrierResetFailed", body)
        pending = next(line for line in body.splitlines()
                       if "BOOL pendingStateMayBeCurrent" in line)
        self.assertIn("!resetStateOwnsNoModemWrite", pending)
        # The exemption is scoped to the pending-state term. Applying it to the
        # in-flight or intent terms would excuse evidence that does have a write
        # behind it.
        for name in ("inFlightMayBeCurrent", "intentMayBeCurrent", "baselineOnlyMayBeCurrent"):
            line = next(l for l in body.splitlines() if f"BOOL {name}" in l)
            self.assertNotIn("resetStateOwnsNoModemWrite", line)

    def test_a_missing_baseline_is_never_replaced_by_a_guess(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        no_baseline = function_body(body, "if (!baselineExists)")
        self.assertIn("no modem write was issued", no_baseline)
        self.assertNotIn("CCNMCallSetter", no_baseline)
        self.assertNotIn("CCNMCreateBandPayload", no_baseline)

    def test_an_already_restored_modem_is_not_written_again(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        equal = body.index('CCNMDictionariesEqual(payload, fresh[@"activeBands"])')
        window = body[equal:equal + 1200]
        self.assertIn('details[@"writeNotNeeded"] = @YES', window)
        self.assertIn("CCNMFinishSystemDefaultState", window)
        self.assertNotIn("CCNMCallSetter", window)


class ResumableCheckpointTests(unittest.TestCase):
    """A crash between "baseline retired" and "state says clean" is recoverable."""

    def test_the_checkpoint_is_written_before_the_baseline_is_retired(self):
        body = function_body(CONTROLLER, "static BOOL CCNMFinishSystemDefaultState(")
        checkpoint = body.index("CCNMRecoveryStateRestorePending")
        retire = body.index("CCNMRetireTransitionRecords")
        remove_baseline = body.index("CCNMN78PolicyBaselinePath()")
        self.assertLess(checkpoint, retire)
        self.assertLess(retire, remove_baseline)
        self.assertIn('@"readBackVerified": @YES', body)
        self.assertIn('@"verifiedActiveBands": verifiedBands', body)

    def test_resuming_the_checkpoint_issues_no_second_write(self):
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        resume = body.index("CCNMIsVerifiedRestoreCleanupCheckpoint(state)")
        window = body[resume:resume + 3600]
        self.assertIn('details[@"writeNotNeeded"] = @YES', window)
        self.assertNotIn("CCNMCallSetter", window)
        self.assertNotIn("CCNMCreateBandPayload", window)
        # Gated on the evidence being older than this boot and on the live bands
        # still equalling the ones the read-back verified.
        self.assertIn("CCNMBootRelationEarlier", body[:resume])
        self.assertIn('CCNMDictionariesEqual(fresh[@"activeBands"], state[@"verifiedActiveBands"])', window)

    def test_the_checkpoint_predicate_requires_verified_evidence(self):
        body = function_body(CONTROLLER, "static BOOL CCNMIsVerifiedRestoreCleanupCheckpoint(")
        self.assertIn("CCNMValidateStateRecord(state, NULL)", body)
        self.assertIn("CCNMAppliedPolicyApplying", body)
        self.assertIn("CCNMRecoveryStateRestorePending", body)
        self.assertIn('[state[@"readBackVerified"] isEqual:@YES]', body)
        self.assertIn('![state[@"uncertain"] boolValue]', body)
        self.assertIn("CCNMValidateBandDictionary(verifiedBands, NULL)", body)

    def test_the_resumed_slot_comes_from_the_revalidated_subscription(self):
        # A state written before the slot field existed has no slot at all, and
        # defaulting that to 1 would record a slot this device was never observed
        # on. A nil in a dictionary literal would also raise inside Preferences.
        body = function_body(CONTROLLER, "- (NSDictionary *)performRestoreOperation:")
        resume = body.index("CCNMIsVerifiedRestoreCleanupCheckpoint(state)")
        window = body[resume:resume + 3600]
        self.assertIn('details[@"targetSlotID"]', window)
        self.assertIn("CCNMValidSlotID(cleanupSlotID)", window)
        self.assertIn('details[@"targetSubscriptionUUID"]', window)


class BaselineCompatibilityTests(unittest.TestCase):
    def test_an_old_baseline_without_capability_evidence_is_accepted(self):
        # A baseline is the only way back from an enable. Refusing one for lacking
        # a field that did not exist when it was written would strand the device it
        # was written to protect.
        body = function_body(CONTROLLER, "static BOOL CCNMValidateBaselineCompatibility(")
        self.assertIn("hasCapabilitySnapshot", body)
        self.assertIn("if (!hasCapabilitySnapshot)", body)
        after = body.index("if (!hasCapabilitySnapshot)")
        self.assertIn("return YES;", body[after:after + 400])

    def test_the_gate_is_hardware_and_shape_not_the_ios_build(self):
        body = function_body(CONTROLLER, "static BOOL CCNMValidateBaselineCompatibility(")
        self.assertIn("BOOL sameDevice", body)
        self.assertIn("BOOL sameCapabilityShape", body)
        self.assertIn("BOOL ownedFieldsValid", body)
        refusal = next(line for line in body.splitlines()
                       if "if (!sameDevice" in line)
        self.assertNotIn("systemBuild", refusal)
        self.assertNotIn("systemVersion", refusal)

    def test_active_nr_is_not_required_to_be_a_subset_of_supported_nr(self):
        # The modem's BandInfo contract permits it, and the target device's own
        # verified restore read-back had exactly that shape.
        body = function_body(CONTROLLER, "static BOOL CCNMValidateBaselineCompatibility(")
        fit_call = next(line for line in body.splitlines()
                        if "CCNMBaselineNRBandsFitCurrentCapability" in line)
        self.assertIn("savedSupported[CCNMNRKey]", fit_call)
        self.assertNotIn("savedActive", fit_call)

    def test_non_dictionary_evidence_cannot_reach_keyed_subscripting(self):
        # This bundle loads into SpringBoard and Preferences, where subscripting a
        # non-dictionary raises.
        body = function_body(CONTROLLER, "static BOOL CCNMValidateBaselineCompatibility(")
        self.assertIn('[baseline[@"activeBands"] isKindOfClass:NSDictionary.class]', body)
        self.assertIn("[currentSupportedBands isKindOfClass:NSDictionary.class]", body)
        self.assertIn('[baseline[@"supportedBands"] isKindOfClass:NSDictionary.class]', body)


class RetiredResetStateTests(unittest.TestCase):
    """The 1.6.0 states stay readable; only their producers are gone."""

    def test_no_source_file_signals_commcenter_any_more(self):
        for name, source in ALL_SOURCES.items():
            code = code_lines(source)
            with self.subTest(file=name):
                self.assertNotIn("killall", code)
                self.assertNotIn("CommCenter", code)
                self.assertNotIn("CCNMResetCarrierConfiguration", code)
                self.assertNotIn("performCarrierReset", code)

    def test_the_reset_module_is_deleted(self):
        for stem in ("CCNMCarrierReset.h", "CCNMCarrierReset.m"):
            self.assertFalse((PREFS / stem).exists(), stem)
        self.assertNotIn("CCNMCarrierReset", MAKEFILE)
        self.assertFalse((ROOT / "package-actions/carrier-reset.sh.inc").exists())

    def test_the_state_values_stay_readable_for_installed_devices(self):
        # 1.6.0 shipped. A device can hold a state record naming these values, and
        # judging our own record foreign would lock the only way out.
        for value in ("CCNMRecoveryStateCarrierResetPending",
                      "CCNMRecoveryStateCarrierResetFailed"):
            self.assertIn(value, function_body(CONTROLLER, "static BOOL CCNMValidateStateRecord("))
            self.assertIn(value, READER)
        self.assertIn("CCNMN78PolicyErrorCarrierResetFailed", READER)

    def test_the_states_have_no_producer_left(self):
        # Read-side compatibility, not a live path: nothing may write them.
        for value in ("CCNMRecoveryStateCarrierResetPending",
                      "CCNMRecoveryStateCarrierResetFailed"):
            for marker in ("CCNMMarkRecovery(", "CCNMBuildStateRecord("):
                offsets = [m.start() for m in re.finditer(re.escape(marker), CONTROLLER)]
                for offset in offsets:
                    call = CONTROLLER[offset:CONTROLLER.index(";", offset)]
                    self.assertNotIn(value, call)


class SettingsRestoreActionTests(unittest.TestCase):
    def test_settings_exposes_one_restore_action(self):
        self.assertIn("restoreSavedConfigurationHandler", ROOT_HEADER)
        self.assertIn("restoreSavedConfiguration:", ROOT_CONTROLLER)
        self.assertIn("restoreSavedConfiguration:", ROOT_PLIST)
        self.assertIn("RESTORE_SAVED_CONFIGURATION", ROOT_PLIST)
        for retired in ("resetCarrierConfigurationHandler", "reloadCarrierDefaults",
                        "RESET_CARRIER_DEFAULTS", "restoreOriginalBands"):
            self.assertNotIn(retired, ROOT_CONTROLLER + ROOT_HEADER + ROOT_PLIST)

    def test_the_action_routes_through_the_policy_owner_and_never_writes_directly(self):
        body = function_body(ROOT_CONTROLLER,
                             "- (void)restoreSavedConfiguration:(PSSpecifier *)specifier {")
        self.assertIn("restoreSavedConfigurationHandler", body)
        self.assertNotIn("setActiveBandInfo", body)
        self.assertNotIn("CCNMEnableN78Preference", body)
        self.assertNotIn("CCNMDisableN78Preference", body)
        # The production handler is the recovery entry point.
        handlers = function_body(ROOT_CONTROLLER, "- (void)configureProductionHandlers {")
        self.assertIn("restoreSavedConfigurationHandler", handlers)
        self.assertIn("beginPolicyRecovery", handlers)
        self.assertIn("CCNMRecoverN78Preference", function_body(
            ROOT_CONTROLLER, "- (void)beginPolicyRecovery {"))

    def test_the_action_is_gated_on_a_recoverable_baseline(self):
        body = function_body(ROOT_CONTROLLER,
                             "- (void)restoreSavedConfiguration:(PSSpecifier *)specifier {")
        self.assertIn("!self.hasRecoverableBaseline", body)
        self.assertIn("self.requiresReboot", body)
        self.assertIn("self.policyOperationInProgress", body)


class MaintainerScriptTests(unittest.TestCase):
    def test_prerm_never_claims_to_restore_anything(self):
        code = code_lines(PRERM)
        self.assertIn("CANNOT undo it", PRERM)
        self.assertIn("only turning the preference off in Settings", PRERM)
        self.assertNotIn("CCNMN78PolicyController", code)
        self.assertNotIn("CoreTelephony", code)
        self.assertNotIn("networkmanager-removal-guard", code)
        self.assertIn("exit 0", code)

    def test_the_baseline_is_never_discarded_while_it_describes_something(self):
        # The 1.6.0 regression in one line: a false success deleted the only copy
        # of the user's pre-enable configuration.
        line = next(l for l in PRERM.splitlines() if "discard_policy_records" in l
                    and not l.lstrip().startswith("#"))
        self.assertIn('[ "$ACTION" = remove ]', line)
        self.assertIn('[ -z "$BASELINE_PRESENT" ]', line)

    def test_the_presence_check_and_the_deletion_share_one_path_generator(self):
        # Two hand-written copies of a record path is how a presence check and a
        # deletion come to disagree about which file they mean. The shared thing is
        # the basename, not the generator: the baseline-only list cannot be a slice
        # of the full one without an external tool selecting a line by number,
        # which then silently follows whatever becomes line two next.
        self.assertEqual(
            POLICY_SHELL.count("me.nixuge.networkmanager.n78-policy.baseline.plist"), 1)
        self.assertIn("POLICY_BASELINE_BASENAME='me.nixuge.networkmanager.n78-policy.baseline.plist'",
                      POLICY_SHELL)
        for generator in ("policy_records()", "policy_baseline_record()"):
            with self.subTest(generator=generator):
                body = function_body(POLICY_SHELL, generator)
                self.assertIn("${POLICY_BASELINE_BASENAME}", body)
                self.assertNotIn("me.nixuge.networkmanager.n78-policy.baseline.plist", body)
        # And the directory is shared too, so the two cannot disagree about where.
        for generator in ("policy_records()", "policy_baseline_record()",
                          "policy_band_selection()"):
            with self.subTest(directory_in=generator):
                self.assertIn("${POLICY_RECORD_DIR}", function_body(POLICY_SHELL, generator))
        present = function_body(POLICY_SHELL, "policy_baseline_present()")
        self.assertIn("policy_baseline_record", present)
        self.assertNotIn("me.nixuge.networkmanager", present)

    def test_the_band_selection_is_a_separate_list_discarded_on_removal_only(self):
        records = function_body(POLICY_SHELL, "policy_records()")
        self.assertNotIn("n78-selection.plist", records)
        selection = function_body(POLICY_SHELL, "policy_band_selection()")
        self.assertIn("n78-selection.plist", selection)
        line = next(l for l in PRERM.splitlines() if "discard_band_selection" in l
                    and not l.lstrip().startswith("#"))
        self.assertIn('[ "$ACTION" = remove ]', line)
        self.assertNotIn("BASELINE_PRESENT", line)

    def test_the_include_carries_no_signalling_or_version_machinery(self):
        code = code_lines(POLICY_SHELL)
        for retired in ("carrier_reset_defaults", "resolve_carrier_killall",
                        "version_is_at_least", "resolve_dpkg_command",
                        "compare-versions"):
            self.assertNotIn(retired, code)

    def test_prerm_still_bounds_its_one_remaining_child_process(self):
        # The bootout is the only child process left, and launchctl_run refuses to
        # run one unbounded. Losing resolve_delay_command would silently skip it.
        delay = PRERM.index("resolve_delay_command")
        check = PRERM.index('if [ -z "$LAUNCHCTL_DELAY" ]')
        self.assertLess(delay, check)
        self.assertLess(check, PRERM.index("launchd_bootout"))

    def test_the_patcher_renders_the_policy_include_into_prerm_only(self):
        self.assertIn('POLICY_RECORD_INCLUDE = "policy-records.sh.inc"', PATCHER)
        self.assertIn('"@POLICY_RECORD_SUPPORT@"', PATCHER)
        self.assertIn("policy_record_support", PATCHER)
        self.assertIn("@POLICY_RECORD_SUPPORT@", PRERM)
        self.assertNotIn("@POLICY_RECORD_SUPPORT@", POSTINST)
        self.assertNotIn("carrier-reset.sh.inc", code_lines(PATCHER))

    def test_the_retired_placeholders_still_fail_packaging(self):
        # A template that still carries one must fail rather than ship the token as
        # literal shell.
        retired = function_body(PATCHER, "RETIRED_PLACEHOLDERS = (") \
            if "RETIRED_PLACEHOLDERS = (" in PATCHER else ""
        line = next(l for l in PATCHER.splitlines() if l.startswith("RETIRED_PLACEHOLDERS"))
        self.assertIn("@CARRIER_RESET_SUPPORT@", line)
        self.assertIn("@CARRIER_RESET_FLOOR@", line)
        self.assertNotIn("CARRIER_RESET_FLOOR =", code_lines(PATCHER))

    def test_the_guards_do_not_link_the_policy_controller(self):
        self.assertIn("TOOL_NAME = networkmanager-install-guard", ACTIONS_MAKEFILE)
        self.assertNotIn("networkmanager-removal-guard", ACTIONS_MAKEFILE)
        self.assertNotIn("CCNMN78PolicyController.m", ACTIONS_MAKEFILE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
