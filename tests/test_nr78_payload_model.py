#!/usr/bin/env python3
"""Executable contract for the Stage 3 NR n78-only diagnostic payload."""
import copy
import unittest

NR_KEY = "kCTRegistrationRadioAccessTechnologyNR"
LTE_KEY = "kCTRegistrationRadioAccessTechnologyLTE"
TARGET_NR_BAND = 78

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


def build_nr78_only_bands(original, supported):
    if not isinstance(original, dict) or not isinstance(supported, dict):
        return None
    active_nr = original.get(NR_KEY)
    supported_nr = supported.get(NR_KEY)
    if not isinstance(active_nr, list) or not isinstance(supported_nr, list):
        return None
    if TARGET_NR_BAND not in active_nr or TARGET_NR_BAND not in supported_nr:
        return None
    if active_nr == [TARGET_NR_BAND]:
        return None
    modified = copy.deepcopy(original)
    modified[NR_KEY] = [TARGET_NR_BAND]
    return modified


def validate_nr78_only(original, modified):
    if not isinstance(original, dict) or not isinstance(modified, dict):
        return False
    if set(original) != set(modified) or modified.get(NR_KEY) != [TARGET_NR_BAND]:
        return False
    return all(modified[key] == values for key, values in original.items() if key != NR_KEY)


class NR78PayloadModelTests(unittest.TestCase):
    def test_target_device_payload_sets_only_nr_to_n78(self):
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        self.assertTrue(validate_nr78_only(DEVICE_BANDS, modified))
        self.assertEqual(modified[NR_KEY], [78])

    def test_full_lte_list_is_byte_identical_for_nsa_anchor_and_fallback(self):
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        self.assertEqual(modified[LTE_KEY], DEVICE_BANDS[LTE_KEY])

    def test_all_non_nr_rat_arrays_are_unchanged(self):
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        for key, values in DEVICE_BANDS.items():
            if key != NR_KEY:
                self.assertEqual(modified[key], values)

    def test_refuses_when_n78_is_not_live_active(self):
        original = copy.deepcopy(DEVICE_BANDS)
        original[NR_KEY].remove(78)
        self.assertIsNone(build_nr78_only_bands(original, DEVICE_SUPPORTED))

    def test_refuses_when_n78_is_not_live_supported(self):
        supported = copy.deepcopy(DEVICE_SUPPORTED)
        supported[NR_KEY].remove(78)
        self.assertIsNone(build_nr78_only_bands(DEVICE_BANDS, supported))

    def test_refuses_identity_request_when_live_nr_is_already_only_n78(self):
        original = copy.deepcopy(DEVICE_BANDS)
        original[NR_KEY] = [78]
        self.assertIsNone(build_nr78_only_bands(original, DEVICE_SUPPORTED))

    def test_rejects_any_lte_change(self):
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        modified[LTE_KEY] = [3]
        self.assertFalse(validate_nr78_only(DEVICE_BANDS, modified))

    def test_rejects_additional_nr_band_or_rat_key_change(self):
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        modified[NR_KEY] = [78, 79]
        self.assertFalse(validate_nr78_only(DEVICE_BANDS, modified))
        modified = build_nr78_only_bands(DEVICE_BANDS, DEVICE_SUPPORTED)
        modified["extra"] = [1]
        self.assertFalse(validate_nr78_only(DEVICE_BANDS, modified))


if __name__ == "__main__":
    unittest.main(verbosity=2)
