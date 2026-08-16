#!/usr/bin/env python3
"""Executable model for delayed CoreTelephony Band read-back.

The target-device trace showed that both setters returned normally while
getBandInfo: lagged behind: the removal became visible only during the restore
phase, and the restored snapshot was visible roughly 100 seconds later. These
tests pin the bounded polling semantics used by the Objective-C probe.
"""
import unittest

POLL_INTERVAL_SECONDS = 1
MAXIMUM_ATTEMPTS = 121


def wait_for_expected(observations, expected):
    """Mirror CCNMWaitForExpectedBandReadBack over deterministic samples."""
    last_valid = None
    attempts = 0
    matched = False
    for attempt in range(1, MAXIMUM_ATTEMPTS + 1):
        attempts = attempt
        sample = observations[min(attempt - 1, len(observations) - 1)]
        if isinstance(sample, dict):
            last_valid = sample
            if sample == expected:
                matched = True
                break
    return {
        "attempts": attempts,
        "matched": matched,
        "last_valid": last_valid,
    }


class BandReadBackPollModelTests(unittest.TestCase):
    def test_device_observed_100_second_delay_is_accepted(self):
        old = {"LTE": [46, 48]}
        expected = {"LTE": [46]}
        observations = [old] * 100 + [expected]
        result = wait_for_expected(observations, expected)
        self.assertTrue(result["matched"])
        self.assertEqual(result["attempts"], 101)
        self.assertEqual(result["last_valid"], expected)

    def test_restore_waits_through_stale_removed_value(self):
        removed = {"LTE": [46]}
        snapshot = {"LTE": [46, 48]}
        result = wait_for_expected([removed] * 100 + [snapshot], snapshot)
        self.assertTrue(result["matched"])
        self.assertEqual(result["last_valid"], snapshot)

    def test_timeout_preserves_last_valid_read_for_diagnosis(self):
        original = {"LTE": [46, 48]}
        requested = {"LTE": [46]}
        result = wait_for_expected([original], requested)
        self.assertFalse(result["matched"])
        self.assertEqual(result["attempts"], MAXIMUM_ATTEMPTS)
        self.assertEqual(result["last_valid"], original)

    def test_invalid_reads_do_not_count_as_success(self):
        expected = {"LTE": [46]}
        result = wait_for_expected([None, None, expected], expected)
        self.assertTrue(result["matched"])
        self.assertEqual(result["attempts"], 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
