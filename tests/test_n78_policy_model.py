#!/usr/bin/env python3
"""Executable state model for the formal n78-preferred policy."""

from dataclasses import dataclass
from enum import Enum
import copy
import unittest


NR_KEY = "kCTRegistrationRadioAccessTechnologyNR"
LTE_KEY = "kCTRegistrationRadioAccessTechnologyLTE"
TARGET_NR = [78]

ORIGINAL_BANDS = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": [1, 2, 3],
    "kCTRegistrationRadioAccessTechnologyGSM": [1, 2],
    LTE_KEY: [1, 3, 8, 41],
    NR_KEY: [1, 28, 41, 77, 78, 79],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": [1, 2],
    "kCTRegistrationRadioAccessTechnologyUTRAN": [1, 8],
}


class RequestedMode(str, Enum):
    SYSTEM_DEFAULT = "systemDefault"
    N78_PREFERRED = "n78Preferred"


class AppliedPolicy(str, Enum):
    UNKNOWN = "unknown"
    APPLYING = "applying"
    VERIFIED_SYSTEM_DEFAULT = "verifiedSystemDefault"
    VERIFIED_N78_ONLY = "verifiedN78Only"
    DIVERGED = "diverged"
    RECOVERY_REQUIRED = "recoveryRequired"


class ServingState(str, Enum):
    NR_N78 = "nrN78"
    NR_OTHER = "nrOther"
    LTE = "lteBand"
    OTHER = "other"
    UNKNOWN = "unknown"


class RecoveryState(str, Enum):
    CLEAN = "clean"
    ENABLE_PENDING = "enablePending"
    ENABLED_WITH_BASELINE = "enabledWithBaseline"
    RESTORE_PENDING = "restorePending"
    REBOOT_REQUIRED = "rebootRequired"
    RECOVERY_FAILED = "recoveryFailed"


@dataclass
class DurablePolicy:
    requested: RequestedMode = RequestedMode.SYSTEM_DEFAULT
    applied: AppliedPolicy = AppliedPolicy.VERIFIED_SYSTEM_DEFAULT
    recovery: RecoveryState = RecoveryState.CLEAN
    baseline: dict | None = None
    intent: dict | None = None
    in_flight: bool = False
    uncertain: bool = False
    writes: int = 0
    removal_guard: bool = False


def build_n78_payload(original: dict, supported: dict) -> dict | None:
    if not isinstance(original, dict) or not isinstance(supported, dict):
        return None
    if set(original) != set(ORIGINAL_BANDS) or set(supported) != set(ORIGINAL_BANDS):
        return None
    active_nr = original.get(NR_KEY)
    supported_nr = supported.get(NR_KEY)
    if not isinstance(active_nr, list) or not isinstance(supported_nr, list):
        return None
    if 78 not in active_nr or 78 not in supported_nr or active_nr == TARGET_NR:
        return None
    payload = copy.deepcopy(original)
    payload[NR_KEY] = TARGET_NR.copy()
    return payload


def validate_n78_payload(original: dict, payload: dict) -> bool:
    if not isinstance(original, dict) or not isinstance(payload, dict):
        return False
    if set(original) != set(payload) or payload.get(NR_KEY) != TARGET_NR:
        return False
    return all(payload[key] == values for key, values in original.items() if key != NR_KEY)


def build_restore_payload(live: dict, baseline: dict) -> dict | None:
    if not isinstance(live, dict) or not isinstance(baseline, dict):
        return None
    if set(live) != set(baseline) or not isinstance(baseline.get(NR_KEY), list):
        return None
    restored = copy.deepcopy(live)
    restored[NR_KEY] = copy.deepcopy(baseline[NR_KEY])
    return restored


class PolicyControllerModel:
    def __init__(self):
        self.durable = DurablePolicy()
        self.live = copy.deepcopy(ORIGINAL_BANDS)
        self.serving = ServingState.UNKNOWN

    def enable(self, supported=ORIGINAL_BANDS, *, setter="success", readback="match") -> bool:
        d = self.durable
        if d.recovery != RecoveryState.CLEAN or d.uncertain or d.baseline is not None or d.removal_guard:
            return False
        payload = build_n78_payload(self.live, supported)
        if payload is None:
            return False

        d.baseline = copy.deepcopy(self.live)
        d.intent = copy.deepcopy(payload)
        d.in_flight = True
        d.recovery = RecoveryState.ENABLE_PENDING
        d.applied = AppliedPolicy.APPLYING
        d.writes += 1

        if setter in {"timeout", "exception", "overDeadline"}:
            d.uncertain = True
            d.applied = AppliedPolicy.RECOVERY_REQUIRED
            d.recovery = RecoveryState.REBOOT_REQUIRED
            return False
        if setter != "success":
            d.applied = AppliedPolicy.RECOVERY_REQUIRED
            d.recovery = RecoveryState.RECOVERY_FAILED
            return False

        if readback == "match":
            self.live = copy.deepcopy(payload)
            d.requested = RequestedMode.N78_PREFERRED
            d.applied = AppliedPolicy.VERIFIED_N78_ONLY
            d.recovery = RecoveryState.ENABLED_WITH_BASELINE
            d.intent = None
            d.in_flight = False
            return True
        if readback == "different":
            d.applied = AppliedPolicy.DIVERGED
            d.recovery = RecoveryState.RECOVERY_FAILED
            return False

        d.uncertain = True
        d.applied = AppliedPolicy.RECOVERY_REQUIRED
        d.recovery = RecoveryState.REBOOT_REQUIRED
        return False

    def disable(self, *, setter="success", readback="match") -> bool:
        d = self.durable
        if (
            d.recovery != RecoveryState.ENABLED_WITH_BASELINE
            or d.applied != AppliedPolicy.VERIFIED_N78_ONLY
            or d.baseline is None
            or d.uncertain
        ):
            return False
        payload = build_restore_payload(self.live, d.baseline)
        if payload is None:
            return False

        d.intent = copy.deepcopy(payload)
        d.in_flight = True
        d.recovery = RecoveryState.RESTORE_PENDING
        d.writes += 1

        if setter in {"timeout", "exception", "overDeadline"}:
            d.uncertain = True
            d.applied = AppliedPolicy.RECOVERY_REQUIRED
            d.recovery = RecoveryState.REBOOT_REQUIRED
            return False
        if setter != "success" or readback != "match":
            d.applied = AppliedPolicy.RECOVERY_REQUIRED
            d.recovery = RecoveryState.RECOVERY_FAILED
            return False

        self.live = payload
        d.requested = RequestedMode.SYSTEM_DEFAULT
        d.applied = AppliedPolicy.VERIFIED_SYSTEM_DEFAULT
        d.recovery = RecoveryState.CLEAN
        d.baseline = None
        d.intent = None
        d.in_flight = False
        return True

    def may_uninstall(self) -> bool:
        d = self.durable
        return (
            d.recovery == RecoveryState.CLEAN
            and d.applied == AppliedPolicy.VERIFIED_SYSTEM_DEFAULT
            and d.baseline is None
            and not d.in_flight
            and not d.uncertain
        )

    def arm_removal_guard(self) -> bool:
        if not self.may_uninstall():
            return False
        self.durable.removal_guard = True
        return True

    def prerm_allows_removal(self) -> bool:
        return self.may_uninstall() and self.durable.removal_guard

    def postinst_clear_removal_guard(self) -> bool:
        if not self.may_uninstall():
            return False
        self.durable.removal_guard = False
        return True


class N78PolicyPayloadTests(unittest.TestCase):
    def test_enable_changes_only_nr_to_exact_n78(self):
        payload = build_n78_payload(ORIGINAL_BANDS, ORIGINAL_BANDS)
        self.assertTrue(validate_n78_payload(ORIGINAL_BANDS, payload))
        self.assertEqual(payload[NR_KEY], [78])
        self.assertEqual(payload[LTE_KEY], ORIGINAL_BANDS[LTE_KEY])

    def test_enable_requires_n78_active_and_supported(self):
        active = copy.deepcopy(ORIGINAL_BANDS)
        active[NR_KEY].remove(78)
        supported = copy.deepcopy(ORIGINAL_BANDS)
        supported[NR_KEY].remove(78)
        self.assertIsNone(build_n78_payload(active, ORIGINAL_BANDS))
        self.assertIsNone(build_n78_payload(ORIGINAL_BANDS, supported))

    def test_restore_replaces_only_nr_with_exact_saved_original(self):
        current = build_n78_payload(ORIGINAL_BANDS, ORIGINAL_BANDS)
        current[LTE_KEY] = [3, 41]
        restored = build_restore_payload(current, ORIGINAL_BANDS)
        self.assertEqual(restored[NR_KEY], ORIGINAL_BANDS[NR_KEY])
        self.assertEqual(restored[LTE_KEY], [3, 41])


class N78PolicyLifecycleTests(unittest.TestCase):
    def test_verified_enable_retains_baseline_until_disable(self):
        controller = PolicyControllerModel()
        self.assertTrue(controller.enable())
        self.assertEqual(controller.durable.requested, RequestedMode.N78_PREFERRED)
        self.assertEqual(controller.durable.applied, AppliedPolicy.VERIFIED_N78_ONLY)
        self.assertEqual(controller.durable.recovery, RecoveryState.ENABLED_WITH_BASELINE)
        self.assertEqual(controller.durable.baseline, ORIGINAL_BANDS)
        self.assertFalse(controller.may_uninstall())

        self.assertTrue(controller.disable())
        self.assertEqual(controller.live, ORIGINAL_BANDS)
        self.assertTrue(controller.may_uninstall())

    def test_lte_fallback_does_not_invalidate_verified_n78_policy(self):
        controller = PolicyControllerModel()
        self.assertTrue(controller.enable())
        controller.serving = ServingState.LTE
        self.assertEqual(controller.durable.applied, AppliedPolicy.VERIFIED_N78_ONLY)
        self.assertEqual(controller.serving, ServingState.LTE)

    def test_uncertain_enable_forbids_a_second_same_boot_write(self):
        controller = PolicyControllerModel()
        self.assertFalse(controller.enable(setter="timeout"))
        self.assertEqual(controller.durable.writes, 1)
        self.assertEqual(controller.durable.recovery, RecoveryState.REBOOT_REQUIRED)
        self.assertFalse(controller.enable())
        self.assertFalse(controller.disable())
        self.assertEqual(controller.durable.writes, 1)

    def test_diverged_readback_preserves_baseline_and_blocks_uninstall(self):
        controller = PolicyControllerModel()
        self.assertFalse(controller.enable(readback="different"))
        self.assertIsNotNone(controller.durable.baseline)
        self.assertEqual(controller.durable.applied, AppliedPolicy.DIVERGED)
        self.assertFalse(controller.may_uninstall())

    def test_disable_timeout_preserves_baseline_and_requires_reboot(self):
        controller = PolicyControllerModel()
        self.assertTrue(controller.enable())
        baseline = copy.deepcopy(controller.durable.baseline)
        self.assertFalse(controller.disable(setter="overDeadline"))
        self.assertEqual(controller.durable.baseline, baseline)
        self.assertEqual(controller.durable.recovery, RecoveryState.REBOOT_REQUIRED)
        self.assertFalse(controller.may_uninstall())

    def test_removal_guard_closes_the_post_prerm_enable_race(self):
        controller = PolicyControllerModel()
        self.assertTrue(controller.arm_removal_guard())
        self.assertTrue(controller.prerm_allows_removal())
        self.assertFalse(controller.enable())
        self.assertTrue(controller.postinst_clear_removal_guard())
        self.assertFalse(controller.prerm_allows_removal())
        self.assertTrue(controller.enable())

    def test_active_policy_cannot_arm_removal_guard(self):
        controller = PolicyControllerModel()
        self.assertTrue(controller.enable())
        self.assertFalse(controller.arm_removal_guard())
        self.assertFalse(controller.prerm_allows_removal())

    def test_requested_applied_and_serving_are_never_inferred(self):
        controller = PolicyControllerModel()
        controller.durable.requested = RequestedMode.N78_PREFERRED
        controller.durable.applied = AppliedPolicy.UNKNOWN
        controller.serving = ServingState.NR_N78
        self.assertEqual(controller.durable.requested, RequestedMode.N78_PREFERRED)
        self.assertEqual(controller.durable.applied, AppliedPolicy.UNKNOWN)
        self.assertEqual(controller.serving, ServingState.NR_N78)


if __name__ == "__main__":
    unittest.main(verbosity=2)
