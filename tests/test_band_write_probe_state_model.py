#!/usr/bin/env python3
import unittest
from dataclasses import dataclass


@dataclass
class SetterMarker:
    boot_id: int
    operation_generation: int
    valid: bool = True


@dataclass
class DurableRecoveryState:
    snapshot: bool = True
    intent: bool = True
    marker: SetterMarker | None = None
    lock_owner: str | None = None

    def acquire_lock(self, owner: str) -> bool:
        if self.lock_owner is not None:
            return False
        self.lock_owner = owner
        return True

    def release_lock(self, owner: str):
        if self.lock_owner == owner:
            self.lock_owner = None


@dataclass
class RecoveryProcess:
    process_id: str
    boot_id: int
    durable: DurableRecoveryState
    band_in_progress: bool = False
    automatic_restore_in_progress: bool = False
    manual_restore_in_progress: bool = False
    test_setter_in_progress: bool = False
    setter_call_started: bool = False
    setter_timeout_uncertain: bool = False
    operation_generation: int = 0
    manual_recovery_generation: int = 0

    def begin_band(self):
        if (
            self.band_in_progress
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.setter_timeout_uncertain
        ):
            return None
        self.band_in_progress = True
        self.operation_generation += 1
        return self.operation_generation, self.manual_recovery_generation

    def begin_test_setter(self, operation_generation: int, manual_generation: int) -> bool:
        if (
            not self.band_in_progress
            or self.operation_generation != operation_generation
            or self.manual_recovery_generation != manual_generation
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.test_setter_in_progress
            or self.setter_timeout_uncertain
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.test_setter_in_progress = True
        self.durable.marker = SetterMarker(self.boot_id, operation_generation)
        return True

    def mark_setter_call_started(self):
        if not self.test_setter_in_progress or self.setter_timeout_uncertain:
            return False
        self.setter_call_started = True
        return True

    def watchdog_timeout(self, operation_generation: int) -> bool:
        if (
            self.test_setter_in_progress
            and self.setter_call_started
            and self.band_in_progress
            and self.operation_generation == operation_generation
        ):
            self.setter_timeout_uncertain = True
            return True
        return False

    def finish_test_setter(self) -> bool:
        timeout_was_observed = self.setter_timeout_uncertain
        self.test_setter_in_progress = False
        self.setter_call_started = False
        self.durable.release_lock(self.process_id)
        return timeout_was_observed

    def begin_automatic_restore(self) -> bool:
        if (
            not self.band_in_progress
            or self.test_setter_in_progress
            or self.setter_timeout_uncertain
            or self.automatic_restore_in_progress
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.automatic_restore_in_progress = True
        return True

    def finish_automatic_restore(self, readback_equal: bool):
        if readback_equal:
            self.durable.marker = None
        self.automatic_restore_in_progress = False
        self.durable.release_lock(self.process_id)

    def begin_manual_restore(self) -> bool:
        marker = self.durable.marker
        if (
            self.band_in_progress
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.test_setter_in_progress
            or self.setter_timeout_uncertain
            or marker is None
            or not marker.valid
            or marker.boot_id == self.boot_id
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.manual_restore_in_progress = True
        return True

    def finish_manual_restore(self, readback_equal: bool):
        if readback_equal:
            self.durable.snapshot = False
            self.durable.intent = False
            self.durable.marker = None
        self.manual_restore_in_progress = False
        self.durable.release_lock(self.process_id)

    def clear_recovery_state(self, live_equals_snapshot: bool) -> bool:
        marker = self.durable.marker
        if (
            not live_equals_snapshot
            or (marker is not None and (not marker.valid or marker.boot_id == self.boot_id))
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.durable.snapshot = False
        self.durable.intent = False
        self.durable.marker = None
        self.durable.release_lock(self.process_id)
        return True

    def end_band(self):
        self.band_in_progress = False
        self.test_setter_in_progress = False
        self.setter_call_started = False
        self.durable.release_lock(self.process_id)


class BandWriteProbeStateModelTests(unittest.TestCase):
    def start_setter(self, process: RecoveryProcess):
        operation, manual_generation = process.begin_band()
        self.assertTrue(process.begin_test_setter(operation, manual_generation))
        self.assertTrue(process.mark_setter_call_started())
        return operation

    def test_timeout_survives_preferences_relaunch_in_same_boot(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        operation = self.start_setter(writer)
        self.assertTrue(writer.watchdog_timeout(operation))
        self.assertTrue(writer.finish_test_setter())
        writer.end_band()

        relaunched = RecoveryProcess("relaunched", 100, durable)
        self.assertFalse(relaunched.begin_manual_restore())
        self.assertFalse(relaunched.clear_recovery_state(live_equals_snapshot=True))
        self.assertIsNotNone(durable.marker)

    def test_device_reboot_allows_manual_restore_of_matching_marker(self):
        durable = DurableRecoveryState(marker=SetterMarker(100, 1))
        after_reboot = RecoveryProcess("after-reboot", 200, durable)
        self.assertTrue(after_reboot.begin_manual_restore())
        after_reboot.finish_manual_restore(readback_equal=True)
        self.assertFalse(durable.snapshot)
        self.assertFalse(durable.intent)
        self.assertIsNone(durable.marker)

    def test_late_setter_completion_never_clears_uncertain_marker_or_restores(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        operation = self.start_setter(writer)
        writer.watchdog_timeout(operation)

        self.assertTrue(writer.finish_test_setter())
        self.assertFalse(writer.begin_automatic_restore())
        self.assertIsNotNone(durable.marker)

    def test_verified_automatic_restore_is_the_only_normal_marker_cleanup(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)
        self.assertFalse(writer.finish_test_setter())
        self.assertTrue(writer.begin_automatic_restore())
        writer.finish_automatic_restore(readback_equal=True)
        self.assertIsNone(durable.marker)

        no_evidence = RecoveryProcess("relaunch", 200, durable)
        self.assertFalse(no_evidence.begin_manual_restore())

    def test_failed_automatic_or_manual_restore_preserves_all_evidence(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)
        writer.finish_test_setter()
        self.assertTrue(writer.begin_automatic_restore())
        writer.finish_automatic_restore(readback_equal=False)
        self.assertTrue(durable.snapshot and durable.intent and durable.marker)

        after_reboot = RecoveryProcess("after-reboot", 200, durable)
        self.assertTrue(after_reboot.begin_manual_restore())
        after_reboot.finish_manual_restore(readback_equal=False)
        self.assertTrue(durable.snapshot and durable.intent and durable.marker)

    def test_recovery_lock_excludes_a_second_process(self):
        durable = DurableRecoveryState(marker=SetterMarker(100, 1), lock_owner="hung-writer")
        after_reboot = RecoveryProcess("restorer", 200, durable)
        self.assertFalse(after_reboot.begin_manual_restore())
        self.assertEqual(durable.lock_owner, "hung-writer")

    def test_after_reboot_clear_is_allowed_only_when_live_matches_snapshot(self):
        mismatch = DurableRecoveryState(marker=SetterMarker(100, 1))
        process = RecoveryProcess("clearer", 200, mismatch)
        self.assertFalse(process.clear_recovery_state(live_equals_snapshot=False))
        self.assertTrue(mismatch.snapshot and mismatch.intent and mismatch.marker)

        matched = DurableRecoveryState(marker=SetterMarker(100, 1))
        process = RecoveryProcess("clearer", 200, matched)
        self.assertTrue(process.clear_recovery_state(live_equals_snapshot=True))
        self.assertFalse(matched.snapshot)
        self.assertFalse(matched.intent)
        self.assertIsNone(matched.marker)

    def test_invalid_marker_fails_closed_after_reboot(self):
        durable = DurableRecoveryState(marker=SetterMarker(100, 1, valid=False))
        process = RecoveryProcess("after-reboot", 200, durable)
        self.assertFalse(process.begin_manual_restore())
        self.assertFalse(process.clear_recovery_state(live_equals_snapshot=True))

    def test_generation_guard_rejects_stale_prewrite_path(self):
        durable = DurableRecoveryState()
        process = RecoveryProcess("writer", 100, durable)
        operation, manual_generation = process.begin_band()
        process.manual_recovery_generation += 1
        self.assertFalse(process.begin_test_setter(operation, manual_generation))
        self.assertIsNone(durable.marker)


if __name__ == "__main__":
    unittest.main(verbosity=2)
