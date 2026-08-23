#!/usr/bin/env python3
"""Executable model and static contracts for user-chosen NR band selection (1.6.0).

The shipped 1.5.0 feature pins NR to the literal ``[78]``. This suite specifies the
generalisation to a user-chosen subset: what a legal selection is, where the legal
domain comes from, and why the written array must be ascending.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
READER = ROOT / "networkmanagerprefs/CCNMN78PolicyReader.m"
DAEMON = ROOT / "maintenance-daemon/main.m"

NR_KEY = "kCTRegistrationRadioAccessTechnologyNR"
LTE_KEY = "kCTRegistrationRadioAccessTechnologyLTE"

ORIGINAL_BANDS = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": [1, 2, 3],
    "kCTRegistrationRadioAccessTechnologyGSM": [1, 2],
    LTE_KEY: [1, 3, 8, 41],
    NR_KEY: [1, 28, 41, 77, 78, 79],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": [1, 2],
    "kCTRegistrationRadioAccessTechnologyUTRAN": [1, 8],
}

SUPPORTED_BANDS = dict(ORIGINAL_BANDS, **{NR_KEY: [1, 41, 78, 79]})


# --- the model under specification -------------------------------------------------


def canonical_selection(selection):
    """Ascending, unique, positive integers. None when the input cannot be one."""
    if not isinstance(selection, list) or not selection:
        return None
    for band in selection:
        if isinstance(band, bool) or not isinstance(band, int) or band <= 0:
            return None
    if len(set(selection)) != len(selection):
        return None
    return sorted(selection)


def selectable_domain(active, supported):
    """A selection may only narrow: fresh active NR intersected with fresh supported NR."""
    if not isinstance(active, dict) or not isinstance(supported, dict):
        return None
    active_nr, supported_nr = active.get(NR_KEY), supported.get(NR_KEY)
    if not isinstance(active_nr, list) or not isinstance(supported_nr, list):
        return None
    domain = sorted(set(active_nr) & set(supported_nr))
    return domain or None


def build_selected_payload(active, supported, selection):
    canonical = canonical_selection(selection)
    domain = selectable_domain(active, supported)
    if canonical is None or domain is None:
        return None
    if not set(canonical).issubset(domain):
        return None
    if canonical == domain:
        # Pinning everything iOS already allowed is what "off" means.
        return None
    if canonical == active.get(NR_KEY):
        return None
    payload = {key: list(values) for key, values in active.items()}
    payload[NR_KEY] = canonical
    return payload


def validate_selected_payload(original, payload, selection):
    canonical = canonical_selection(selection)
    if canonical is None or not isinstance(original, dict) or not isinstance(payload, dict):
        return False
    if set(original) != set(payload):
        return False
    for key, values in original.items():
        expected = canonical if key == NR_KEY else values
        if payload[key] != expected:
            return False
    return True


def maintenance_gate_allows(target, active_nr, supported_nr):
    """Whether the maintenance daemon may act on a sample.

    The daemon owns an automatic action whose safety argument is that the modem
    still holds exactly what the policy put there. Under a fixed [78] that reduced
    to two band-78 booleans. Under a chosen subset the sound questions are whether
    live NR equals the recorded target, and whether the modem still declares
    support for every band in that target.
    """
    canonical = canonical_selection(target)
    if canonical is None:
        return False
    if not isinstance(active_nr, list) or not isinstance(supported_nr, list):
        return False
    if active_nr != canonical:
        return False
    return set(canonical).issubset(supported_nr)


# --- reference-device evidence parsed from the shipped constants --------------------


def _historical_nr(function_name):
    source = CONTROLLER.read_text()
    start = source.index(function_name)
    key = source.index(f'@"{NR_KEY}"', start)
    open_bracket = source.index("@[", key)
    depth = 0
    for index in range(open_bracket, len(source)):
        if source[index] == "[":
            depth += 1
        elif source[index] == "]":
            depth -= 1
            if depth == 0:
                blob = source[open_bracket:index + 1]
                return [int(value) for value in re.findall(r"@(\d+)", blob)]
    raise AssertionError(f"unterminated NR array in {function_name}")


class SelectionCanonicalisationTests(unittest.TestCase):
    def test_tap_order_cannot_reach_the_modem(self):
        """Read-back is whole-dictionary equality, so order is a correctness question."""
        self.assertEqual(canonical_selection([78, 41]), [41, 78])
        self.assertEqual(canonical_selection([41, 78]), [41, 78])
        self.assertEqual(canonical_selection([257, 41, 78]), [41, 78, 257])

    def test_two_applies_differing_only_in_tap_order_write_the_same_array(self):
        first = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [79, 41])
        second = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [41, 79])
        self.assertIsNotNone(first)
        self.assertEqual(first, second)
        self.assertEqual(first[NR_KEY], [41, 79])

    def test_malformed_selections_are_refused(self):
        for bad in ([], [78, 78], [0], [-1], [1.5], ["78"], [True], None, (41, 78)):
            self.assertIsNone(canonical_selection(bad), bad)

    def test_a_single_band_selection_is_byte_identical_to_the_shipped_behaviour(self):
        payload = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [78])
        self.assertEqual(payload[NR_KEY], [78])
        self.assertEqual(payload[LTE_KEY], ORIGINAL_BANDS[LTE_KEY])


class SelectableDomainTests(unittest.TestCase):
    def test_domain_is_the_intersection_and_is_ascending(self):
        self.assertEqual(selectable_domain(ORIGINAL_BANDS, SUPPORTED_BANDS), [1, 41, 78, 79])

    def test_reference_device_evidence_narrows_forty_six_active_bands_to_nineteen(self):
        active = _historical_nr("CCNMKnownOrphanHistoricalOriginalBands")
        supported = _historical_nr("CCNMKnownOrphanHistoricalSupportedBands")
        self.assertEqual(len(active), 46)
        self.assertEqual(len(supported), 19)
        domain = selectable_domain({NR_KEY: active}, {NR_KEY: supported})
        self.assertEqual(len(domain), 19)
        self.assertEqual(domain, sorted(domain))
        self.assertNotEqual(domain, active)

    def test_a_band_supported_but_never_active_is_outside_the_domain(self):
        supported = dict(SUPPORTED_BANDS, **{NR_KEY: [1, 41, 78, 79, 258]})
        self.assertNotIn(258, selectable_domain(ORIGINAL_BANDS, supported))
        self.assertIsNone(build_selected_payload(ORIGINAL_BANDS, supported, [78, 258]))

    def test_a_band_active_but_not_supported_is_outside_the_domain(self):
        self.assertIn(77, ORIGINAL_BANDS[NR_KEY])
        self.assertNotIn(77, SUPPORTED_BANDS[NR_KEY])
        self.assertNotIn(77, selectable_domain(ORIGINAL_BANDS, SUPPORTED_BANDS))
        self.assertIsNone(build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [77]))

    def test_selection_may_only_narrow(self):
        payload = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [41, 78])
        self.assertTrue(set(payload[NR_KEY]).issubset(ORIGINAL_BANDS[NR_KEY]))


class SelectionRefusalTests(unittest.TestCase):
    def test_whole_domain_selection_is_refused(self):
        domain = selectable_domain(ORIGINAL_BANDS, SUPPORTED_BANDS)
        self.assertIsNone(build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, domain))

    def test_a_selection_equal_to_the_live_array_is_refused_as_a_no_op(self):
        live = dict(ORIGINAL_BANDS, **{NR_KEY: [41, 78]})
        supported = dict(SUPPORTED_BANDS, **{NR_KEY: [1, 41, 78, 79]})
        self.assertIsNone(build_selected_payload(live, supported, [78, 41]))

    def test_empty_selection_is_refused_in_this_version(self):
        self.assertIsNone(build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, []))


class SelectedPayloadValidationTests(unittest.TestCase):
    def test_payload_must_carry_the_ascending_selection_exactly(self):
        payload = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [79, 41])
        self.assertTrue(validate_selected_payload(ORIGINAL_BANDS, payload, [41, 79]))
        self.assertTrue(validate_selected_payload(ORIGINAL_BANDS, payload, [79, 41]))

    def test_a_descending_written_array_is_rejected(self):
        payload = {key: list(values) for key, values in ORIGINAL_BANDS.items()}
        payload[NR_KEY] = [79, 41]
        self.assertFalse(validate_selected_payload(ORIGINAL_BANDS, payload, [41, 79]))

    def test_a_changed_non_nr_rat_is_rejected(self):
        payload = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [41, 78])
        payload[LTE_KEY] = [1, 3]
        self.assertFalse(validate_selected_payload(ORIGINAL_BANDS, payload, [41, 78]))

    def test_a_payload_carrying_a_different_set_is_rejected(self):
        payload = build_selected_payload(ORIGINAL_BANDS, SUPPORTED_BANDS, [41, 78])
        self.assertFalse(validate_selected_payload(ORIGINAL_BANDS, payload, [41, 79]))


class SelectionSourceContractTests(unittest.TestCase):
    """Both mirrored implementations must gain the same selection-aware primitives.

    Membership assertions use assertTrue/assertFalse rather than assertIn/assertNotIn:
    these sources are ~150 KB each and a failing assertIn would dump the whole file.
    """

    def setUp(self):
        self.controller = CONTROLLER.read_text()
        self.reader = READER.read_text()

    def assertPresent(self, needle, source, name):
        self.assertTrue(needle in source, f"{name}: expected to find {needle!r}")

    def assertAbsent(self, needle, source, name):
        self.assertFalse(needle in source, f"{name}: expected not to find {needle!r}")

    def test_both_mirrors_canonicalise_the_selection_ascending(self):
        for name, source, suffix in (("controller", self.controller, ""),
                                     ("reader", self.reader, "Local")):
            self.assertPresent(f"CCNMCanonicalNRSelection{suffix}", source, name)
            self.assertPresent("sortedArrayUsingSelector:@selector(compare:)", source, name)

    def test_both_mirrors_compute_the_selectable_domain(self):
        self.assertPresent("CCNMSelectableNRDomain", self.controller, "controller")
        self.assertPresent("CCNMSelectableNRDomainLocal", self.reader, "reader")

    def test_both_mirrors_validate_a_payload_against_a_selection(self):
        self.assertPresent("CCNMValidateSelectedNRPayload", self.controller, "controller")
        self.assertPresent("CCNMBuildSelectedNRPayload", self.controller, "controller")
        self.assertPresent("CCNMValidateSelectedNRPayloadLocal", self.reader, "reader")

    def test_no_shipped_comparison_pins_the_nr_array_to_a_literal_seventy_eight(self):
        for name, source in (("controller", self.controller), ("reader", self.reader)):
            for forbidden in ("containsObject:@78", "isEqualToArray:@[ @78 ]", "? @[ @78 ] :"):
                self.assertAbsent(forbidden, source, name)

    def test_the_enable_proof_records_the_applied_selection(self):
        self.assertEqual(self.controller.count('@"targetNRBands": @[ @78 ]'), 1,
                         "only the reviewed known-orphan replay may record a literal [78]")
        self.assertPresent('@"targetNRBands": selection', self.controller, "controller")

    def test_the_known_orphan_replay_stays_pinned_to_its_reviewed_evidence(self):
        self.assertPresent("active[CCNMNRKey] = @[ @78 ];", self.controller, "controller")
        self.assertPresent("CCNMKnownOrphanHistoricalActiveBands", self.controller, "controller")


class MaintenanceGateTests(unittest.TestCase):
    """The daemon must gate on the recorded target, not on band 78."""

    def test_a_non_78_selection_is_serviceable(self):
        self.assertTrue(maintenance_gate_allows([41], [41], [1, 41, 78, 79]))

    def test_live_bands_differing_from_the_target_stop_the_daemon(self):
        self.assertFalse(maintenance_gate_allows([41, 78], [41], [1, 41, 78, 79]))
        self.assertFalse(maintenance_gate_allows([41], [41, 78], [1, 41, 78, 79]))

    def test_a_target_the_modem_no_longer_supports_stops_the_daemon(self):
        self.assertFalse(maintenance_gate_allows([41, 78], [41, 78], [1, 78, 79]))

    def test_an_absent_or_malformed_target_stops_the_daemon(self):
        for bad in (None, [], [78, 78], [0], "78"):
            self.assertFalse(maintenance_gate_allows(bad, [78], [78]), bad)

    def test_a_single_band_78_policy_still_passes_the_gate(self):
        self.assertTrue(maintenance_gate_allows([78], [78], [1, 41, 78]))


class DaemonSourceContractTests(unittest.TestCase):
    def setUp(self):
        self.daemon = DAEMON.read_text()

    def test_the_daemon_gates_on_the_recorded_target(self):
        self.assertTrue("CCNMN78PolicySummaryTargetNRBandsKey" in self.daemon,
                        "daemon must read the policy's recorded NR target")

    def test_the_daemon_no_longer_gates_on_band_78_booleans(self):
        for forbidden in (
            "![servingSummary[CCNMServingSummaryCapabilityN78SupportedKey] boolValue]",
            "![servingSummary[CCNMServingSummaryCapabilityN78ActiveKey] boolValue]",
            "containsObject:@78",
            "isEqualToArray:@[ @78 ]",
        ):
            self.assertFalse(forbidden in self.daemon,
                             f"daemon: expected not to find {forbidden!r}")

    def test_the_daemon_still_reports_the_band_78_facts_in_its_record(self):
        # The two booleans stay in the durable record: they are factual telemetry
        # and part of a shipped record schema. Only their use as a gate is wrong.
        for required in ("CCNMARecordCapabilityN78SupportedKey",
                         "CCNMARecordCapabilityN78ActiveKey"):
            self.assertTrue(required in self.daemon,
                            f"daemon: expected to find {required!r}")

    def test_the_daemon_requires_the_target_to_be_currently_supported(self):
        self.assertTrue("CCNMMaintenanceTargetIsCurrentlySupported" in self.daemon,
                        "daemon must check the target against live supported NR")


if __name__ == "__main__":
    unittest.main()
