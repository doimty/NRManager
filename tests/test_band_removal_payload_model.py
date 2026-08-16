#!/usr/bin/env python3
"""Executable model of the cold-band removal payload rules.

The Objective-C helpers cannot run on this host, so this mirrors their exact
contract and pins the behaviour that matters for safety: the request must be the
original slot-1 dictionary minus one allowed cold LTE band, every other radio
technology must stay byte-identical, and anything else must be rejected.

The LTE/NR values below are the real slot-1 sets read from the target device
(iPhone14,3 / iOS 15.1.1 / 19B81).
"""
import unittest

REMOVAL_RAT_KEY = "kCTRegistrationRadioAccessTechnologyLTE"
COLD_REMOVAL_CANDIDATES = (48, 46)

DEVICE_SUPPORTED_BANDS = {
    REMOVAL_RAT_KEY: [
        1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 30, 34,
        38, 39, 40, 41, 42, 46, 48, 66,
    ],
}

DEVICE_BANDS = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": list(range(1, 21)),
    "kCTRegistrationRadioAccessTechnologyGSM": list(range(1, 10)),
    REMOVAL_RAT_KEY: [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19, 20, 21, 24,
        25, 26, 27, 28, 29, 30, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
        48, 66, 71,
    ],
    "kCTRegistrationRadioAccessTechnologyNR": [
        1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 30, 34, 38, 39, 40,
        41, 48, 50, 51, 53, 65, 66, 70, 71, 74, 75, 76, 77, 78, 79, 80, 81, 82,
        83, 84, 85, 86, 257, 258, 259, 260, 261,
    ],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": list(range(1, 7)),
    "kCTRegistrationRadioAccessTechnologyUTRAN": list(range(1, 12)),
}


def array_removing_single_occurrence(values, target):
    reduced = []
    removals = 0
    for value in values:
        if removals == 0 and value == target:
            removals += 1
            continue
        reduced.append(value)
    return reduced, removals == 1


def build_single_removal_bands(original, supported=DEVICE_SUPPORTED_BANDS):
    lte = original.get(REMOVAL_RAT_KEY)
    supported_lte = supported.get(REMOVAL_RAT_KEY) if isinstance(supported, dict) else None
    if not isinstance(lte, list) or len(lte) < 2 or not isinstance(supported_lte, list):
        return None, None
    target = next((b for b in COLD_REMOVAL_CANDIDATES if b in lte and b in supported_lte), None)
    if target is None:
        return None, None
    reduced, removed_one = array_removing_single_occurrence(lte, target)
    if not removed_one:
        return None, None
    modified = dict(original)
    modified[REMOVAL_RAT_KEY] = reduced
    return modified, target


def validate_single_band_removal(original, modified, removed_band):
    if not isinstance(original, dict) or not isinstance(modified, dict):
        return False
    if set(original) != set(modified):
        return False
    if removed_band not in COLD_REMOVAL_CANDIDATES:
        return False
    for key, original_values in original.items():
        modified_values = modified[key]
        if not isinstance(original_values, list) or not isinstance(modified_values, list):
            return False
        if key != REMOVAL_RAT_KEY:
            if modified_values != original_values:
                return False
            continue
        expected, removed_one = array_removing_single_occurrence(original_values, removed_band)
        if not removed_one or modified_values != expected:
            return False
    return True


class ColdBandRemovalModelTests(unittest.TestCase):
    def test_device_payload_removes_only_band_48(self):
        modified, removed = build_single_removal_bands(DEVICE_BANDS)
        self.assertEqual(removed, 48)
        self.assertTrue(validate_single_band_removal(DEVICE_BANDS, modified, removed))
        self.assertEqual(
            set(DEVICE_BANDS[REMOVAL_RAT_KEY]) - set(modified[REMOVAL_RAT_KEY]),
            {48},
        )
        self.assertEqual(
            len(modified[REMOVAL_RAT_KEY]),
            len(DEVICE_BANDS[REMOVAL_RAT_KEY]) - 1,
        )

    def test_nr_band_48_is_untouched(self):
        modified, _ = build_single_removal_bands(DEVICE_BANDS)
        for key, values in DEVICE_BANDS.items():
            if key == REMOVAL_RAT_KEY:
                continue
            self.assertEqual(modified[key], values)
        self.assertIn(48, modified["kCTRegistrationRadioAccessTechnologyNR"])

    def test_falls_back_to_band_46_when_48_absent(self):
        original = dict(DEVICE_BANDS)
        original[REMOVAL_RAT_KEY] = [b for b in DEVICE_BANDS[REMOVAL_RAT_KEY] if b != 48]
        modified, removed = build_single_removal_bands(original)
        self.assertEqual(removed, 46)
        self.assertTrue(validate_single_band_removal(original, modified, removed))

    def test_falls_back_to_supported_band_46_when_active_48_is_unsupported(self):
        supported = {REMOVAL_RAT_KEY: [46]}
        modified, removed = build_single_removal_bands(DEVICE_BANDS, supported)
        self.assertEqual(removed, 46)
        self.assertTrue(validate_single_band_removal(DEVICE_BANDS, modified, removed))

    def test_refuses_candidate_not_in_live_supported_set(self):
        supported = {REMOVAL_RAT_KEY: [1, 3, 8, 41]}
        modified, removed = build_single_removal_bands(DEVICE_BANDS, supported)
        self.assertIsNone(modified)
        self.assertIsNone(removed)

    def test_refuses_when_no_cold_candidate_is_active(self):
        original = dict(DEVICE_BANDS)
        original[REMOVAL_RAT_KEY] = [b for b in DEVICE_BANDS[REMOVAL_RAT_KEY] if b not in (46, 48)]
        modified, removed = build_single_removal_bands(original)
        self.assertIsNone(modified)
        self.assertIsNone(removed)

    def test_rejects_removing_a_primary_band(self):
        modified = dict(DEVICE_BANDS)
        modified[REMOVAL_RAT_KEY] = [b for b in DEVICE_BANDS[REMOVAL_RAT_KEY] if b != 3]
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, modified, 3))
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, modified, 48))

    def test_rejects_extra_change_in_another_technology(self):
        modified, removed = build_single_removal_bands(DEVICE_BANDS)
        tampered = dict(modified)
        tampered["kCTRegistrationRadioAccessTechnologyNR"] = [
            b for b in DEVICE_BANDS["kCTRegistrationRadioAccessTechnologyNR"] if b != 78
        ]
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, tampered, removed))

    def test_rejects_dropped_or_added_technology_key(self):
        modified, removed = build_single_removal_bands(DEVICE_BANDS)
        without_key = {k: v for k, v in modified.items() if k != "kCTRegistrationRadioAccessTechnologyGSM"}
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, without_key, removed))
        with_extra = dict(modified)
        with_extra["kCTRegistrationRadioAccessTechnologyExtra"] = [1]
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, with_extra, removed))

    def test_rejects_reordered_or_truncated_list(self):
        modified, removed = build_single_removal_bands(DEVICE_BANDS)
        reordered = dict(modified)
        reordered[REMOVAL_RAT_KEY] = list(reversed(modified[REMOVAL_RAT_KEY]))
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, reordered, removed))
        truncated = dict(modified)
        truncated[REMOVAL_RAT_KEY] = modified[REMOVAL_RAT_KEY][:-1]
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, truncated, removed))

    def test_removal_is_exactly_one_occurrence(self):
        original = dict(DEVICE_BANDS)
        original[REMOVAL_RAT_KEY] = [48, 1, 2, 48]
        reduced, removed_one = array_removing_single_occurrence(original[REMOVAL_RAT_KEY], 48)
        self.assertTrue(removed_one)
        self.assertEqual(reduced, [1, 2, 48])

    def test_identity_payload_is_not_a_valid_removal(self):
        self.assertFalse(validate_single_band_removal(DEVICE_BANDS, dict(DEVICE_BANDS), 48))


if __name__ == "__main__":
    unittest.main(verbosity=2)
