#!/usr/bin/env python3
"""Executable contract for the LTE B1-only diagnostic payload and evidence."""
import copy
import unittest

LTE_KEY = "kCTRegistrationRadioAccessTechnologyLTE"
NR_KEY = "kCTRegistrationRadioAccessTechnologyNR"
LTE_SERVING_RAT = "kCTCellMonitorRadioAccessTechnologyLTE"
NR_SERVING_RAT = "kCTCellMonitorRadioAccessTechnologyNR"
TARGET_LTE_BAND = 1
PRECONDITION_LTE_BAND = 3
REQUIRED_TRAILING_SAMPLES = 2

DEVICE_BANDS = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": list(range(1, 21)),
    "kCTRegistrationRadioAccessTechnologyGSM": list(range(1, 10)),
    LTE_KEY: [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19, 20, 21,
        24, 25, 26, 27, 28, 29, 30, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
        43, 46, 48, 66, 71,
    ],
    NR_KEY: [
        1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 30, 34, 38, 39,
        40, 41, 48, 50, 51, 53, 65, 66, 70, 71, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 257, 258, 259, 260, 261,
    ],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": list(range(1, 7)),
    "kCTRegistrationRadioAccessTechnologyUTRAN": list(range(1, 12)),
}

DEVICE_SUPPORTED = copy.deepcopy(DEVICE_BANDS)
DEVICE_SUPPORTED[NR_KEY] = [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 30, 38, 40, 41, 48, 66, 77, 78, 79]


def is_band_dictionary(value):
    if not isinstance(value, dict) or not value:
        return False
    for rat, bands in value.items():
        if not isinstance(rat, str) or not isinstance(bands, list):
            return False
        if any(type(band) is not int for band in bands):
            return False
    return True


def build_lte_b1_only_bands(original, supported):
    if not is_band_dictionary(original) or not is_band_dictionary(supported):
        return None
    active_lte = original.get(LTE_KEY)
    supported_lte = supported.get(LTE_KEY)
    if not isinstance(active_lte, list) or not isinstance(supported_lte, list):
        return None
    if TARGET_LTE_BAND not in active_lte or TARGET_LTE_BAND not in supported_lte:
        return None
    if active_lte == [TARGET_LTE_BAND]:
        return None
    modified = copy.deepcopy(original)
    modified[LTE_KEY] = [TARGET_LTE_BAND]
    return modified


def validate_lte_b1_only(original, modified):
    if not is_band_dictionary(original) or not is_band_dictionary(modified):
        return False
    if set(original) != set(modified):
        return False
    if modified.get(LTE_KEY) != [TARGET_LTE_BAND]:
        return False
    return all(modified[key] == values for key, values in original.items() if key != LTE_KEY)


def sample_has_exact_serving_band(sample, target_band):
    if type(target_band) is not int or not isinstance(sample, dict):
        return False
    if sample.get("cellMonitorCopyStatus") != "parsed":
        return False
    serving_cells = sample.get("servingCells")
    if not isinstance(serving_cells, list) or not serving_cells:
        return False
    if any(not isinstance(serving_cell, dict) for serving_cell in serving_cells):
        return False
    if any(not isinstance(serving_cell.get("rat"), str) for serving_cell in serving_cells):
        return False
    lte_cells = [cell for cell in serving_cells if cell["rat"] == LTE_SERVING_RAT]
    return bool(lte_cells) and all(
        type(cell.get("band")) is int and cell["band"] == target_band
        for cell in lte_cells
    )


def trailing_exact_serving_band_count(report, target_band):
    if (
        not isinstance(report, dict)
        or type(target_band) is not int
        or report.get("cellMonitorSucceeded") is not True
        or report.get("cellMonitorSamplingStatus") != "complete"
    ):
        return 0
    samples = report.get("cellMonitorSamples")
    if not isinstance(samples, list):
        return 0
    trailing = 0
    for sample in samples:
        if sample_has_exact_serving_band(sample, target_band):
            trailing += 1
        else:
            trailing = 0
    return trailing


def confirms_exact_serving_band(report, target_band, required=REQUIRED_TRAILING_SAMPLES):
    if type(required) is not int or required <= 0:
        return False
    return trailing_exact_serving_band_count(report, target_band) >= required


def parsed_sample(rat=LTE_SERVING_RAT, band=TARGET_LTE_BAND):
    return {
        "cellMonitorCopyStatus": "parsed",
        "servingCells": [{"rat": rat, "band": band}],
    }


def report_with_samples(*samples):
    return {
        "cellMonitorSucceeded": True,
        "cellMonitorSamplingStatus": "complete",
        "cellMonitorSamples": list(samples),
    }


class LTEB1PayloadModelTests(unittest.TestCase):
    def test_target_device_payload_sets_only_lte_to_b1(self):
        modified = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        self.assertTrue(validate_lte_b1_only(DEVICE_BANDS, modified))
        self.assertEqual(set(modified), set(DEVICE_BANDS))
        self.assertEqual(modified[LTE_KEY], [1])

    def test_all_non_lte_rat_arrays_remain_equal(self):
        modified = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        for key, values in DEVICE_BANDS.items():
            if key != LTE_KEY:
                self.assertEqual(modified[key], values)

    def test_refuses_when_b1_is_not_live_active_or_supported(self):
        active = copy.deepcopy(DEVICE_BANDS)
        active[LTE_KEY].remove(1)
        supported = copy.deepcopy(DEVICE_SUPPORTED)
        supported[LTE_KEY].remove(1)
        self.assertIsNone(build_lte_b1_only_bands(active, DEVICE_SUPPORTED))
        self.assertIsNone(build_lte_b1_only_bands(DEVICE_BANDS, supported))

    def test_refuses_identity_request_when_lte_is_already_only_b1(self):
        original = copy.deepcopy(DEVICE_BANDS)
        original[LTE_KEY] = [1]
        self.assertIsNone(build_lte_b1_only_bands(original, DEVICE_SUPPORTED))

    def test_rejects_extra_lte_band(self):
        modified = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        modified[LTE_KEY] = [1, 3]
        self.assertFalse(validate_lte_b1_only(DEVICE_BANDS, modified))

    def test_rejects_any_non_lte_change(self):
        modified = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        modified[NR_KEY] = [78]
        self.assertFalse(validate_lte_b1_only(DEVICE_BANDS, modified))

    def test_rejects_rat_key_set_changes(self):
        added = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        added["extra"] = [1]
        removed = build_lte_b1_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        del removed[NR_KEY]
        self.assertFalse(validate_lte_b1_only(DEVICE_BANDS, added))
        self.assertFalse(validate_lte_b1_only(DEVICE_BANDS, removed))

    def test_rejects_malformed_band_dictionaries(self):
        malformed_values = [
            None,
            [],
            {},
            {LTE_KEY: (1, 3)},
            {LTE_KEY: [1, True]},
            {LTE_KEY: [1], NR_KEY: "78"},
            {1: [1]},
        ]
        for malformed in malformed_values:
            with self.subTest(malformed=malformed):
                self.assertIsNone(build_lte_b1_only_bands(malformed, DEVICE_SUPPORTED))
                self.assertIsNone(build_lte_b1_only_bands(DEVICE_BANDS, malformed))
                self.assertFalse(validate_lte_b1_only(DEVICE_BANDS, malformed))
                self.assertFalse(validate_lte_b1_only(malformed, DEVICE_BANDS))


class LTEB1ServingEvidenceModelTests(unittest.TestCase):
    def test_stable_b3_precondition_requires_two_trailing_samples(self):
        report = report_with_samples(
            parsed_sample(band=1),
            parsed_sample(band=3),
            parsed_sample(band=3),
        )
        self.assertEqual(trailing_exact_serving_band_count(report, PRECONDITION_LTE_BAND), 2)
        self.assertTrue(confirms_exact_serving_band(report, PRECONDITION_LTE_BAND))

    def test_b1_post_write_confirmation_uses_trailing_samples(self):
        report = report_with_samples(
            parsed_sample(band=3),
            parsed_sample(band=1),
            parsed_sample(band=1),
        )
        self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 2)
        self.assertTrue(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_transient_b1_followed_by_b3_fails_trailing_criterion(self):
        report = report_with_samples(
            parsed_sample(band=1),
            parsed_sample(band=1),
            parsed_sample(band=3),
        )
        self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 0)
        self.assertFalse(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_competing_lte_band_invalidates_an_exact_b1_sample(self):
        mixed_lte = {
            "cellMonitorCopyStatus": "parsed",
            "servingCells": [
                {"rat": LTE_SERVING_RAT, "band": 1},
                {"rat": LTE_SERVING_RAT, "band": 3},
            ],
        }
        report = report_with_samples(parsed_sample(band=1), mixed_lte)
        self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 0)
        self.assertFalse(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_nr_can_coexist_with_an_exact_lte_b1_sample(self):
        lte_with_nr = {
            "cellMonitorCopyStatus": "parsed",
            "servingCells": [
                {"rat": LTE_SERVING_RAT, "band": 1},
                {"rat": NR_SERVING_RAT, "band": 78},
            ],
        }
        report = report_with_samples(lte_with_nr, lte_with_nr)
        self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 2)
        self.assertTrue(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_nr_missing_no_service_and_malformed_samples_reset_count(self):
        reset_samples = {
            "nr": parsed_sample(rat=NR_SERVING_RAT, band=78),
            "missing_band": parsed_sample(band=None),
            "no_service": {
                "cellMonitorCopyStatus": "parsed",
                "servingCells": [],
            },
            "unparsed": {
                "cellMonitorCopyStatus": "parseError",
                "servingCells": [{"rat": LTE_SERVING_RAT, "band": 1}],
            },
            "malformed_sample": "not-a-sample",
            "malformed_serving_cell": {
                "cellMonitorCopyStatus": "parsed",
                "servingCells": ["not-a-cell"],
            },
            "mixed_exact_and_malformed_cells": {
                "cellMonitorCopyStatus": "parsed",
                "servingCells": [
                    {"rat": LTE_SERVING_RAT, "band": 1},
                    "not-a-cell",
                ],
            },
        }
        for name, reset_sample in reset_samples.items():
            with self.subTest(name=name):
                report = report_with_samples(
                    parsed_sample(band=1),
                    parsed_sample(band=1),
                    reset_sample,
                )
                self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 0)
                self.assertFalse(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_band_requires_exact_integer_semantics(self):
        for band in (True, 1.0, "1", None):
            with self.subTest(band=band):
                report = report_with_samples(parsed_sample(band=band), parsed_sample(band=band))
                self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 0)
                self.assertFalse(confirms_exact_serving_band(report, TARGET_LTE_BAND))

    def test_two_required_threshold_rejects_one_and_accepts_two(self):
        one_sample = report_with_samples(parsed_sample(band=1))
        two_samples = report_with_samples(parsed_sample(band=1), parsed_sample(band=1))
        self.assertFalse(confirms_exact_serving_band(one_sample, TARGET_LTE_BAND))
        self.assertTrue(confirms_exact_serving_band(two_samples, TARGET_LTE_BAND))

    def test_malformed_reports_have_no_serving_evidence(self):
        for report in (
            None,
            [],
            {},
            {"cellMonitorSamples": None},
            {"cellMonitorSucceeded": True, "cellMonitorSamplingStatus": "partial", "cellMonitorSamples": []},
        ):
            with self.subTest(report=report):
                self.assertEqual(trailing_exact_serving_band_count(report, TARGET_LTE_BAND), 0)


def finalize_transaction_flags(*, setter_attempted, setter_returned_without_error,
                               determinate, effect_applied, observation_completed,
                               restore_attempted, restore_read_back_equal,
                               recovery_records_created, recovery_records_removed,
                               post_write_b1_observed):
    recovered = restore_attempted and restore_read_back_equal
    restore_pending = setter_attempted and not recovered
    cleanup_pending = recovery_records_created and not recovery_records_removed
    recovery_pending = restore_pending or cleanup_pending
    transaction_completed_safely = (
        determinate
        and setter_returned_without_error
        and observation_completed
        and recovered
        and recovery_records_removed
        and not recovery_pending
    )
    b1_serving_confirmed = transaction_completed_safely and effect_applied and post_write_b1_observed
    return transaction_completed_safely, recovery_pending, b1_serving_confirmed


class LTEB1OutcomeModelTests(unittest.TestCase):
    def test_setter_error_blocks_safe_completion_even_when_restore_matches(self):
        safe, pending, confirmed = finalize_transaction_flags(
            setter_attempted=True,
            setter_returned_without_error=False,
            determinate=True,
            effect_applied=True,
            observation_completed=True,
            restore_attempted=True,
            restore_read_back_equal=True,
            recovery_records_created=True,
            recovery_records_removed=True,
            post_write_b1_observed=True,
        )
        self.assertFalse(safe)
        self.assertFalse(pending)
        self.assertFalse(confirmed)

    def test_cleanup_failure_keeps_recovery_pending_and_b1_unconfirmed(self):
        safe, pending, confirmed = finalize_transaction_flags(
            setter_attempted=True,
            setter_returned_without_error=True,
            determinate=True,
            effect_applied=True,
            observation_completed=True,
            restore_attempted=True,
            restore_read_back_equal=True,
            recovery_records_created=True,
            recovery_records_removed=False,
            post_write_b1_observed=True,
        )
        self.assertFalse(safe)
        self.assertTrue(pending)
        self.assertFalse(confirmed)

    def test_serving_evidence_is_only_confirmed_after_verified_transaction(self):
        safe, pending, confirmed = finalize_transaction_flags(
            setter_attempted=True,
            setter_returned_without_error=True,
            determinate=True,
            effect_applied=True,
            observation_completed=True,
            restore_attempted=True,
            restore_read_back_equal=False,
            recovery_records_created=True,
            recovery_records_removed=False,
            post_write_b1_observed=True,
        )
        self.assertFalse(safe)
        self.assertTrue(pending)
        self.assertFalse(confirmed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
