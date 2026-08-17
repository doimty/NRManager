#!/usr/bin/env python3
import unittest
from dataclasses import dataclass


@dataclass
class SetterMarker:
    boot_id: int | None
    operation_generation: int
    valid: bool = True


@dataclass
class RestoreMarker:
    boot_id: int | None
    operation_generation: int
    valid: bool = True
    snapshot_matches: bool = True


@dataclass
class DurableRecoveryState:
    snapshot: bool = True
    intent: bool = True
    marker: SetterMarker | None = None
    restore_marker: RestoreMarker | None = None
    lock_owner: str | None = None

    def acquire_lock(self, owner: str) -> bool:
        if self.lock_owner is not None:
            return False
        self.lock_owner = owner
        return True

    def release_lock(self, owner: str):
        if self.lock_owner == owner:
            self.lock_owner = None

    def try_control_center_radio_mutation(self, owner: str) -> bool:
        if not self.acquire_lock(owner):
            return False
        try:
            return not (
                self.snapshot
                or self.intent
                or self.marker is not None
                or self.restore_marker is not None
            )
        finally:
            self.release_lock(owner)


@dataclass
class DurableCreateAttempt:
    path_exists: bool = False
    exact_match: bool = False
    parent_synced: bool = True

    def create(self, *, parent_sync_succeeds: bool) -> bool:
        if self.path_exists:
            return False
        self.path_exists = True
        self.exact_match = True
        self.parent_synced = parent_sync_succeeds
        return parent_sync_succeeds

    @property
    def should_be_tracked_as_created(self) -> bool:
        return self.path_exists and self.exact_match


@dataclass(frozen=True)
class RecoveryRecord:
    identity: str


@dataclass(frozen=True)
class RecoveryCleanupMarker:
    cleanup_kind: str
    snapshot: RecoveryRecord
    intent: RecoveryRecord | None
    setter: RecoveryRecord | None
    restore_read_back_equal: bool
    valid: bool = True


@dataclass
class RecoveryCleanupProtocol:
    snapshot: RecoveryRecord | None
    intent: RecoveryRecord | None
    setter: RecoveryRecord | RecoveryCleanupMarker | None
    restore: RecoveryRecord | None = None
    setter_calls: int = 0

    def install(self, cleanup_kind: str, expected_snapshot: RecoveryRecord,
                expected_intent: RecoveryRecord | None,
                expected_setter: RecoveryRecord | None,
                restore_read_back_equal: bool) -> bool:
        if self.restore is not None:
            return False
        if self.snapshot != expected_snapshot or self.intent != expected_intent:
            return False
        if self.setter != expected_setter:
            return False
        if cleanup_kind in {"verified_restore", "verified_live_match"} and (
            not restore_read_back_equal
            or expected_intent is None
            or expected_setter is None
        ):
            return False
        if cleanup_kind == "verified_legacy_nr78_live_match" and (
            not restore_read_back_equal
            or expected_intent is None
            or expected_setter is not None
        ):
            return False
        if cleanup_kind == "pre_setter" and restore_read_back_equal:
            return False
        self.setter = RecoveryCleanupMarker(
            cleanup_kind,
            expected_snapshot,
            expected_intent,
            expected_setter,
            restore_read_back_equal,
        )
        return True

    def resume(self, crash_after: str | None = None) -> bool:
        marker = self.setter
        if not isinstance(marker, RecoveryCleanupMarker) or not marker.valid:
            return False
        verified_cleanup = marker.cleanup_kind in {"verified_restore", "verified_live_match"}
        legacy_nr78_cleanup = marker.cleanup_kind == "verified_legacy_nr78_live_match"
        if marker.cleanup_kind not in {
            "pre_setter",
            "verified_restore",
            "verified_live_match",
            "verified_legacy_nr78_live_match",
        }:
            return False
        if verified_cleanup and (
            not marker.restore_read_back_equal
            or marker.intent is None
            or marker.setter is None
        ):
            return False
        if legacy_nr78_cleanup and (
            not marker.restore_read_back_equal
            or marker.intent is None
            or marker.setter is not None
        ):
            return False
        if marker.cleanup_kind == "pre_setter" and marker.restore_read_back_equal:
            return False
        if self.restore is not None:
            return False
        if self.snapshot not in {None, marker.snapshot}:
            return False
        if self.intent not in {None, marker.intent}:
            return False

        self.snapshot = None
        if crash_after == "snapshot":
            return False
        self.intent = None
        if crash_after == "intent":
            return False
        if self.setter != marker:
            return False
        self.setter = None
        return True


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
    test_setter_returned_generation: int = 0
    test_setter_started_at: float | None = None
    restore_attempt_serial: int = 0
    active_restore_attempt_token: int | None = None
    restore_setter_started_at: float | None = None

    def begin_band(self):
        if (
            self.band_in_progress
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.setter_timeout_uncertain
            or self.durable.restore_marker is not None
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
            or self.durable.restore_marker is not None
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.test_setter_in_progress = True
        self.durable.marker = SetterMarker(self.boot_id, operation_generation)
        return True

    def mark_setter_call_started(self, now: float = 0.0):
        if not self.test_setter_in_progress or self.setter_timeout_uncertain:
            return False
        self.setter_call_started = True
        self.test_setter_started_at = now
        return True

    def watchdog_timeout(self, operation_generation: int, now: float = 20.0) -> bool:
        if (
            self.test_setter_in_progress
            and self.setter_call_started
            and self.band_in_progress
            and self.operation_generation == operation_generation
            and self.test_setter_started_at is not None
            and now - self.test_setter_started_at >= 20.0
        ):
            self.setter_timeout_uncertain = True
            return True
        return False

    def finish_test_setter(self, returned_normally: bool = True, now: float = 1.0) -> bool:
        call_was_started = self.setter_call_started
        deadline_exceeded = (
            call_was_started
            and self.test_setter_started_at is not None
            and now - self.test_setter_started_at >= 20.0
        )
        if call_was_started and (not returned_normally or deadline_exceeded):
            self.setter_timeout_uncertain = True
        uncertain = self.setter_timeout_uncertain
        self.test_setter_in_progress = False
        self.setter_call_started = False
        self.test_setter_started_at = None
        if call_was_started and returned_normally and not uncertain:
            self.test_setter_returned_generation = self.operation_generation
        return uncertain

    def _start_restore_setter(self, operation_generation: int, now: float) -> int:
        self.restore_attempt_serial += 1
        self.active_restore_attempt_token = self.restore_attempt_serial
        self.restore_setter_started_at = now
        self.durable.restore_marker = RestoreMarker(self.boot_id, operation_generation)
        return self.active_restore_attempt_token

    def begin_automatic_restore(self, now: float = 0.0):
        marker = self.durable.marker
        if (
            not self.band_in_progress
            or self.test_setter_in_progress
            or self.setter_timeout_uncertain
            or self.automatic_restore_in_progress
            or marker is None
            or not marker.valid
            or self.test_setter_returned_generation != self.operation_generation
            or self.durable.restore_marker is not None
            or self.durable.lock_owner != self.process_id
        ):
            return None
        # The test setter and automatic restore remain under one lock. The recovery
        # setter gets a distinct attempt token as well as a durable current-boot marker.
        self.automatic_restore_in_progress = True
        return self._start_restore_setter(self.operation_generation, now)

    def restore_watchdog_timeout(self, restore_attempt_token: int, now: float = 20.0) -> bool:
        if (
            restore_attempt_token != self.active_restore_attempt_token
            or self.restore_setter_started_at is None
            or now - self.restore_setter_started_at < 20.0
        ):
            return False
        self.setter_timeout_uncertain = True
        return True

    def _finish_restore_setter(
        self,
        restore_attempt_token: int | None,
        returned_normally: bool,
        finished_at: float,
    ) -> bool:
        matches = (
            restore_attempt_token is not None
            and restore_attempt_token == self.active_restore_attempt_token
            and self.restore_setter_started_at is not None
        )
        deadline_exceeded = (
            matches and finished_at - self.restore_setter_started_at >= 20.0
        )
        if not matches or not returned_normally or deadline_exceeded:
            self.setter_timeout_uncertain = True
        self.active_restore_attempt_token = None
        self.restore_setter_started_at = None
        return self.setter_timeout_uncertain

    def finish_automatic_restore(
        self,
        readback_equal: bool,
        *,
        restore_attempt_token: int | None = None,
        returned_normally: bool = True,
        finished_at: float = 1.0,
        retire_all_records: bool = False,
    ):
        token = restore_attempt_token or self.active_restore_attempt_token
        uncertain = self._finish_restore_setter(token, returned_normally, finished_at)
        if readback_equal and not uncertain:
            self.durable.restore_marker = None
            self.durable.marker = None
            if retire_all_records:
                self.durable.intent = False
                self.durable.snapshot = False
        self.automatic_restore_in_progress = False

    def cleanup_unattempted_recovery_records(self, records_match: bool = True) -> bool:
        if (
            not self.band_in_progress
            or self.setter_call_started
            or self.setter_timeout_uncertain
            or self.durable.lock_owner != self.process_id
            or not records_match
        ):
            return False
        self.durable.marker = None
        self.durable.intent = False
        self.durable.snapshot = False
        return True

    def begin_manual_restore(self) -> bool:
        marker = self.durable.marker
        restore_marker = self.durable.restore_marker
        if (
            self.band_in_progress
            or self.automatic_restore_in_progress
            or self.manual_restore_in_progress
            or self.test_setter_in_progress
            or self.setter_timeout_uncertain
            or marker is None
            or not marker.valid
            or marker.boot_id is None
            or marker.boot_id == self.boot_id
            or (
                restore_marker is not None
                and (
                    not restore_marker.valid
                    or not restore_marker.snapshot_matches
                    or restore_marker.boot_id is None
                    or restore_marker.boot_id == self.boot_id
                )
            )
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.manual_recovery_generation += 1
        self.manual_restore_in_progress = True
        return True

    def start_manual_restore_setter(self, now: float = 0.0):
        if (
            not self.manual_restore_in_progress
            or self.setter_timeout_uncertain
            or self.durable.lock_owner != self.process_id
        ):
            return None
        # This assignment models atomic replacement: observers see either the
        # validated earlier-boot marker or the new current-boot marker, never none.
        return self._start_restore_setter(self.manual_recovery_generation, now)

    def finish_manual_restore(
        self,
        readback_equal: bool,
        *,
        restore_attempt_token: int | None = None,
        returned_normally: bool = True,
        finished_at: float = 1.0,
    ):
        uncertain = False
        if self.active_restore_attempt_token is not None:
            token = restore_attempt_token or self.active_restore_attempt_token
            uncertain = self._finish_restore_setter(token, returned_normally, finished_at)
        if readback_equal and not uncertain:
            self.durable.snapshot = False
            self.durable.intent = False
            self.durable.restore_marker = None
            self.durable.marker = None
        self.manual_restore_in_progress = False
        self.durable.release_lock(self.process_id)

    def clear_recovery_state(self, live_equals_snapshot: bool) -> bool:
        marker = self.durable.marker
        restore_marker = self.durable.restore_marker
        if (
            not live_equals_snapshot
            or marker is None
            or not isinstance(marker, SetterMarker)
            or not marker.valid
            or marker.boot_id is None
            or marker.boot_id == self.boot_id
            or (
                restore_marker is not None
                and (
                    not restore_marker.valid
                    or not restore_marker.snapshot_matches
                    or restore_marker.boot_id is None
                    or restore_marker.boot_id == self.boot_id
                )
            )
            or not self.durable.acquire_lock(self.process_id)
        ):
            return False
        self.durable.snapshot = False
        self.durable.intent = False
        self.durable.restore_marker = None
        self.durable.marker = None
        self.durable.release_lock(self.process_id)
        return True

    def end_band(self):
        self.band_in_progress = False
        self.test_setter_in_progress = False
        self.setter_call_started = False
        self.test_setter_started_at = None
        self.active_restore_attempt_token = None
        self.restore_setter_started_at = None
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
        writer.end_band()
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
        writer.end_band()
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

    def test_after_reboot_clear_refuses_a_missing_setter_marker(self):
        durable = DurableRecoveryState(marker=None)
        process = RecoveryProcess("clearer", 200, durable)
        self.assertFalse(process.clear_recovery_state(live_equals_snapshot=True))
        self.assertTrue(durable.snapshot)
        self.assertTrue(durable.intent)

    def test_verified_legacy_n78_result_can_authorize_markerless_cleanup_handoff(self):
        snapshot = RecoveryRecord("legacy-n78-snapshot")
        intent = RecoveryRecord("legacy-n78-intent")
        state = RecoveryCleanupProtocol(snapshot, intent, None)
        self.assertTrue(state.install(
            "verified_legacy_nr78_live_match",
            snapshot,
            intent,
            None,
            restore_read_back_equal=True,
        ))
        self.assertTrue(state.resume())
        self.assertIsNone(state.snapshot)
        self.assertIsNone(state.intent)
        self.assertIsNone(state.setter)
        self.assertEqual(state.setter_calls, 0)

    def test_cleanup_handoff_survives_each_payload_removal_crash_point(self):
        for crash_after in ("snapshot", "intent"):
            with self.subTest(crash_after=crash_after):
                snapshot = RecoveryRecord("snapshot-v1")
                intent = RecoveryRecord("intent-v1")
                setter = RecoveryRecord("setter-v1")
                state = RecoveryCleanupProtocol(snapshot, intent, setter)
                self.assertTrue(state.install(
                    "verified_restore",
                    snapshot,
                    intent,
                    setter,
                    restore_read_back_equal=True,
                ))
                self.assertFalse(state.resume(crash_after=crash_after))
                self.assertIsInstance(state.setter, RecoveryCleanupMarker)
                self.assertTrue(state.resume())
                self.assertIsNone(state.snapshot)
                self.assertIsNone(state.intent)
                self.assertIsNone(state.setter)
                self.assertEqual(state.setter_calls, 0)

    def test_cleanup_handoff_preserves_marker_on_conflict_or_record_change(self):
        snapshot = RecoveryRecord("snapshot-v1")
        intent = RecoveryRecord("intent-v1")
        setter = RecoveryRecord("setter-v1")
        state = RecoveryCleanupProtocol(snapshot, intent, setter)
        self.assertTrue(state.install(
            "verified_live_match",
            snapshot,
            intent,
            setter,
            restore_read_back_equal=True,
        ))
        marker = state.setter

        state.intent = RecoveryRecord("foreign-intent")
        self.assertFalse(state.resume())
        self.assertIs(state.setter, marker)
        self.assertEqual(state.intent, RecoveryRecord("foreign-intent"))

        state.intent = intent
        state.restore = RecoveryRecord("restore-in-flight")
        self.assertFalse(state.resume())
        self.assertIs(state.setter, marker)
        self.assertTrue(state.snapshot and state.intent)
        self.assertEqual(state.setter_calls, 0)

    def test_cleanup_handoff_requires_exact_source_records(self):
        snapshot = RecoveryRecord("snapshot-v1")
        intent = RecoveryRecord("intent-v1")
        setter = RecoveryRecord("setter-v1")
        foreign_setter = RecoveryRecord("setter-v2")
        state = RecoveryCleanupProtocol(snapshot, intent, setter)

        self.assertFalse(state.install(
            "verified_live_match",
            snapshot,
            intent,
            foreign_setter,
            restore_read_back_equal=True,
        ))
        self.assertEqual(state.setter, setter)
        self.assertTrue(state.snapshot and state.intent)

    def test_invalid_marker_fails_closed_after_reboot(self):
        durable = DurableRecoveryState(marker=SetterMarker(100, 1, valid=False))
        process = RecoveryProcess("after-reboot", 200, durable)
        self.assertFalse(process.begin_manual_restore())
        self.assertFalse(process.clear_recovery_state(live_equals_snapshot=True))

    def test_restore_marker_blocks_new_write_until_verified_recovery_retires_it(self):
        durable = DurableRecoveryState(
            marker=SetterMarker(100, 1),
            restore_marker=RestoreMarker(100, 1),
        )
        after_reboot = RecoveryProcess("after-reboot", 200, durable)
        self.assertIsNone(after_reboot.begin_band())
        self.assertTrue(after_reboot.begin_manual_restore())
        after_reboot.finish_manual_restore(readback_equal=True)
        self.assertIsNone(durable.restore_marker)
        self.assertIsNone(durable.marker)
        self.assertIsNotNone(after_reboot.begin_band())

    def test_current_unknown_or_mismatched_restore_marker_fails_closed(self):
        for restore_marker in (
            RestoreMarker(200, 1),
            RestoreMarker(None, 1),
            RestoreMarker(100, 1, snapshot_matches=False),
            RestoreMarker(100, 1, valid=False),
        ):
            with self.subTest(restore_marker=restore_marker):
                durable = DurableRecoveryState(
                    marker=SetterMarker(100, 1),
                    restore_marker=restore_marker,
                )
                process = RecoveryProcess("after-reboot", 200, durable)
                self.assertFalse(process.begin_manual_restore())
                self.assertFalse(process.clear_recovery_state(live_equals_snapshot=True))
                self.assertTrue(durable.snapshot and durable.intent)
                self.assertIs(durable.restore_marker, restore_marker)
                self.assertIsNotNone(durable.marker)

    def test_automatic_restore_requires_returned_test_setter_and_no_restore_marker(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        operation = self.start_setter(writer)
        self.assertFalse(writer.begin_automatic_restore())
        self.assertFalse(writer.finish_test_setter())

        durable.restore_marker = RestoreMarker(99, 1)
        self.assertFalse(writer.begin_automatic_restore())
        durable.restore_marker = None
        self.assertTrue(writer.begin_automatic_restore())
        writer.finish_automatic_restore(readback_equal=True)
        self.assertIsNone(durable.marker)
        self.assertIsNone(durable.restore_marker)
        self.assertEqual(writer.test_setter_returned_generation, operation)

    def test_lte_b1_verified_automatic_restore_retires_all_recovery_records(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)
        self.assertFalse(writer.finish_test_setter())
        self.assertTrue(writer.begin_automatic_restore())

        writer.finish_automatic_restore(
            readback_equal=True,
            retire_all_records=True,
        )

        self.assertFalse(durable.snapshot)
        self.assertFalse(durable.intent)
        self.assertIsNone(durable.marker)
        self.assertIsNone(durable.restore_marker)

    def test_pre_setter_failure_removes_only_matching_unattempted_records(self):
        durable = DurableRecoveryState(lock_owner="writer")
        writer = RecoveryProcess("writer", 100, durable)
        self.assertIsNotNone(writer.begin_band())

        self.assertFalse(writer.cleanup_unattempted_recovery_records(records_match=False))
        self.assertTrue(durable.snapshot and durable.intent)
        self.assertTrue(writer.cleanup_unattempted_recovery_records(records_match=True))
        self.assertFalse(durable.snapshot)
        self.assertFalse(durable.intent)

    def test_pre_setter_cleanup_is_forbidden_after_call_start(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)

        self.assertFalse(writer.cleanup_unattempted_recovery_records())
        self.assertTrue(durable.snapshot and durable.intent)
        self.assertIsNotNone(durable.marker)

    def test_parent_directory_fsync_failure_tracks_exact_record_for_cleanup(self):
        create = DurableCreateAttempt()
        saved = create.create(parent_sync_succeeds=False)
        self.assertFalse(saved)
        self.assertTrue(create.path_exists)
        self.assertTrue(create.exact_match)
        self.assertFalse(create.parent_synced)
        self.assertTrue(create.should_be_tracked_as_created)

        durable = DurableRecoveryState(snapshot=False, intent=False, lock_owner="writer")
        writer = RecoveryProcess("writer", 100, durable)
        self.assertIsNotNone(writer.begin_band())
        durable.snapshot = create.should_be_tracked_as_created
        self.assertTrue(writer.cleanup_unattempted_recovery_records())
        self.assertFalse(durable.snapshot)

    def test_generation_guard_rejects_stale_prewrite_path(self):
        durable = DurableRecoveryState()
        process = RecoveryProcess("writer", 100, durable)
        operation, manual_generation = process.begin_band()
        process.manual_recovery_generation += 1
        self.assertFalse(process.begin_test_setter(operation, manual_generation))
        self.assertIsNone(durable.marker)

    def test_finish_detects_over_deadline_return_before_watchdog_runs(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)

        self.assertTrue(writer.finish_test_setter(returned_normally=True, now=20.001))
        self.assertFalse(writer.begin_automatic_restore())
        self.assertIsNotNone(durable.marker)

    def test_setter_exception_is_uncertain_and_never_auto_restores(self):
        durable = DurableRecoveryState()
        writer = RecoveryProcess("writer", 100, durable)
        self.start_setter(writer)

        self.assertTrue(writer.finish_test_setter(returned_normally=False, now=1.0))
        self.assertFalse(writer.begin_automatic_restore())
        self.assertIsNotNone(durable.marker)

    def test_stale_restore_watchdog_cannot_latch_a_new_attempt_with_same_generation(self):
        durable = DurableRecoveryState(marker=SetterMarker(90, 1))
        process = RecoveryProcess("preferences", 100, durable)
        self.assertTrue(process.begin_manual_restore())
        old_token = process.start_manual_restore_setter(now=0.0)
        self.assertEqual(old_token, 1)
        process.finish_manual_restore(
            readback_equal=True,
            restore_attempt_token=old_token,
            finished_at=1.0,
        )

        # In the same process, the first test operation and the prior manual
        # recovery both have generation 1. Only the unique attempt token separates
        # their still-pending watchdog blocks.
        durable.snapshot = True
        durable.intent = True
        operation = self.start_setter(process)
        self.assertEqual(operation, 1)
        self.assertFalse(process.finish_test_setter(returned_normally=True, now=5.0))
        new_token = process.begin_automatic_restore(now=5.0)
        self.assertEqual(new_token, 2)
        self.assertFalse(process.restore_watchdog_timeout(old_token, now=20.0))
        self.assertFalse(process.setter_timeout_uncertain)

    def test_restore_finish_detects_deadline_or_exception_without_cleanup(self):
        for returned_normally, finished_at in ((True, 20.001), (False, 1.0)):
            with self.subTest(returned_normally=returned_normally, finished_at=finished_at):
                durable = DurableRecoveryState(marker=SetterMarker(90, 1))
                process = RecoveryProcess("preferences", 100, durable)
                self.assertTrue(process.begin_manual_restore())
                token = process.start_manual_restore_setter(now=0.0)
                process.finish_manual_restore(
                    readback_equal=True,
                    restore_attempt_token=token,
                    returned_normally=returned_normally,
                    finished_at=finished_at,
                )
                self.assertTrue(process.setter_timeout_uncertain)
                self.assertTrue(durable.snapshot and durable.intent)
                self.assertIsNotNone(durable.marker)
                self.assertIsNotNone(durable.restore_marker)

    def test_prior_boot_restore_marker_is_atomically_replaced(self):
        prior = RestoreMarker(90, 1)
        durable = DurableRecoveryState(marker=SetterMarker(90, 1), restore_marker=prior)
        process = RecoveryProcess("preferences", 100, durable)
        self.assertTrue(process.begin_manual_restore())
        self.assertIs(durable.restore_marker, prior)
        token = process.start_manual_restore_setter(now=0.0)
        self.assertIsNotNone(token)
        self.assertIsNotNone(durable.restore_marker)
        self.assertEqual(durable.restore_marker.boot_id, 100)

    def test_control_center_radio_setter_uses_lock_and_recovery_marker_gate(self):
        active = DurableRecoveryState(marker=SetterMarker(100, 1))
        self.assertFalse(active.try_control_center_radio_mutation("control-center"))

        locked = DurableRecoveryState(
            snapshot=False,
            intent=False,
            lock_owner="preferences",
        )
        self.assertFalse(locked.try_control_center_radio_mutation("control-center"))

        clean = DurableRecoveryState(snapshot=False, intent=False)
        self.assertTrue(clean.try_control_center_radio_mutation("control-center"))
        self.assertIsNone(clean.lock_owner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
