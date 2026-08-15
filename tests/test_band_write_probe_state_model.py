#!/usr/bin/env python3
import unittest
from dataclasses import dataclass

WATCHDOG_SECONDS = 20.0


@dataclass
class RecoveryState:
    band_in_progress: bool = False
    automatic_restore_in_progress: bool = False
    manual_restore_in_progress: bool = False
    test_setter_in_progress: bool = False
    band_started_at: float = 0.0
    automatic_restore_started_at: float = 0.0
    test_setter_started_at: float = 0.0
    operation_generation: int = 0
    manual_recovery_generation: int = 0

    def begin_band(self, now: float):
        if self.band_in_progress or self.automatic_restore_in_progress or self.manual_restore_in_progress:
            return None
        self.band_in_progress = True
        self.band_started_at = now
        self.operation_generation += 1
        return self.operation_generation, self.manual_recovery_generation

    def begin_test_setter(self, now: float, operation_generation: int, manual_generation: int) -> bool:
        if (
            self.operation_generation != operation_generation
            or self.manual_recovery_generation != manual_generation
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.test_setter_in_progress
        ):
            return False
        self.test_setter_in_progress = True
        self.test_setter_started_at = now
        return True

    def end_test_setter(self):
        self.test_setter_in_progress = False
        self.test_setter_started_at = 0.0

    def begin_automatic_restore(self, now: float) -> bool:
        if self.automatic_restore_in_progress or self.manual_restore_in_progress:
            return False
        self.automatic_restore_in_progress = True
        self.automatic_restore_started_at = now
        return True

    def end_automatic_restore(self):
        self.automatic_restore_in_progress = False
        self.automatic_restore_started_at = 0.0

    def begin_manual_restore(self, now: float) -> bool:
        if self.manual_restore_in_progress:
            return False
        if self.automatic_restore_in_progress:
            if self.automatic_restore_started_at <= 0 or now - self.automatic_restore_started_at < WATCHDOG_SECONDS:
                return False
        if self.band_in_progress:
            protected_start = self.test_setter_started_at if self.test_setter_in_progress else self.band_started_at
            if protected_start <= 0 or now - protected_start < WATCHDOG_SECONDS:
                return False
            self.manual_recovery_generation += 1
        self.manual_restore_in_progress = True
        return True

    def end_manual_restore(self):
        self.manual_restore_in_progress = False


class BandWriteProbeStateModelTests(unittest.TestCase):
    def test_manual_restore_invalidates_a_delayed_prewrite_path(self):
        state = RecoveryState()
        operation, manual_generation = state.begin_band(now=1.0)

        self.assertTrue(state.begin_manual_restore(now=21.0))
        state.end_manual_restore()
        self.assertFalse(state.begin_test_setter(now=21.1, operation_generation=operation, manual_generation=manual_generation))

    def test_new_setter_blocks_manual_restore_for_its_own_full_window(self):
        state = RecoveryState()
        operation, manual_generation = state.begin_band(now=1.0)
        self.assertTrue(state.begin_test_setter(now=30.0, operation_generation=operation, manual_generation=manual_generation))

        self.assertFalse(state.begin_manual_restore(now=49.9))
        self.assertTrue(state.begin_manual_restore(now=50.0))

    def test_manual_restore_wins_atomic_race_before_setter(self):
        state = RecoveryState()
        operation, manual_generation = state.begin_band(now=1.0)

        self.assertTrue(state.begin_manual_restore(now=21.0))
        self.assertFalse(state.begin_test_setter(now=21.0, operation_generation=operation, manual_generation=manual_generation))

    def test_only_one_normal_restore_owner_can_start(self):
        state = RecoveryState()
        self.assertTrue(state.begin_automatic_restore(now=20.0))
        self.assertFalse(state.begin_automatic_restore(now=20.0))
        self.assertFalse(state.begin_manual_restore(now=39.9))

    def test_stale_automatic_restore_does_not_block_explicit_emergency_restore(self):
        state = RecoveryState()
        self.assertTrue(state.begin_automatic_restore(now=20.0))
        self.assertTrue(state.begin_manual_restore(now=40.0))

        state.end_manual_restore()
        self.assertTrue(state.automatic_restore_in_progress)
        state.end_automatic_restore()
        self.assertFalse(state.automatic_restore_in_progress)

    def test_new_band_operation_cannot_start_during_any_restore(self):
        automatic = RecoveryState(automatic_restore_in_progress=True)
        manual = RecoveryState(manual_restore_in_progress=True)

        self.assertIsNone(automatic.begin_band(now=1.0))
        self.assertIsNone(manual.begin_band(now=1.0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
