#!/usr/bin/env python3
"""Contracts for selecting and retaining the actual single usable SIM slot."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
READER = ROOT / "networkmanagerprefs/CCNMN78PolicyReader.m"
PROVIDER_H = ROOT / "networkmanagerprefs/CCNMServingStatusProvider.h"
PROVIDER_M = ROOT / "networkmanagerprefs/CCNMServingStatusProvider.m"
DAEMON = ROOT / "maintenance-daemon/main.m"
AUTOMATIC_RECORD = ROOT / "networkmanagerprefs/CCNMAutomaticMaintenanceRecord.m"


def select_target(subscriptions, required_uuid=None, required_slot=None):
    """Small model of the write gate; raises when a modem write is ambiguous."""
    present = [item for item in subscriptions if item.get("present")]
    usable = [
        item for item in present
        if item.get("good") and item.get("uuid") and item.get("slot", 0) > 0
    ]
    if len(present) != 1 or len(usable) != 1:
        raise ValueError("ambiguous subscription")
    target = usable[0]
    if required_uuid is not None and target["uuid"] != required_uuid:
        raise ValueError("subscription changed")
    if required_slot is not None and target["slot"] != required_slot:
        raise ValueError("slot changed")
    return target


class WritePathSubscriptionSlotModelTests(unittest.TestCase):
    def test_slot_one_single_sim_stays_supported(self):
        target = select_target([
            {"slot": 1, "present": True, "good": True, "uuid": "one"},
            {"slot": 2, "present": False, "good": True, "uuid": "two"},
        ])
        self.assertEqual(target["slot"], 1)

    def test_slot_two_single_sim_is_supported(self):
        target = select_target([
            {"slot": 1, "present": False, "good": True, "uuid": "one"},
            {"slot": 2, "present": True, "good": True, "uuid": "two"},
        ])
        self.assertEqual(target, {"slot": 2, "present": True, "good": True, "uuid": "two"})

    def test_two_present_sims_remain_rejected(self):
        with self.assertRaises(ValueError):
            select_target([
                {"slot": 1, "present": True, "good": True, "uuid": "one"},
                {"slot": 2, "present": True, "good": True, "uuid": "two"},
            ])

    def test_missing_uuid_and_nonpositive_slot_remain_rejected(self):
        for subscription in (
            {"slot": 2, "present": True, "good": True, "uuid": ""},
            {"slot": 0, "present": True, "good": True, "uuid": "two"},
        ):
            with self.subTest(subscription=subscription), self.assertRaises(ValueError):
                select_target([subscription])

    def test_revalidation_binds_both_uuid_and_actual_slot(self):
        subscription = {"slot": 2, "present": True, "good": True, "uuid": "two"}
        self.assertEqual(select_target([subscription], "two", 2), subscription)
        with self.assertRaises(ValueError):
            select_target([subscription], "two", 1)
        with self.assertRaises(ValueError):
            select_target([subscription], "one", 2)


class WritePathSubscriptionSlotSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = CONTROLLER.read_text()
        cls.reader = READER.read_text()
        cls.provider_h = PROVIDER_H.read_text()
        cls.provider_m = PROVIDER_M.read_text()
        cls.daemon = DAEMON.read_text()
        cls.automatic_record = AUTOMATIC_RECORD.read_text()

    @staticmethod
    def function(source, marker):
        start = source.index(marker)
        return source[start:source.index("\n}\n", start) + 3]

    def test_target_selector_accepts_the_only_usable_positive_slot(self):
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertNotIn("slot == 1", body)
        self.assertNotIn("slot 1 is required", body)
        self.assertIn("slot > 0 && present && good && uuid.length > 0", body)
        self.assertIn('details[@"targetSlotID"] = slotID', body)
        self.assertIn("requiredSlotID", body)

    def test_normal_transaction_records_use_the_selected_slot(self):
        baseline = self.function(self.controller, "static NSDictionary *CCNMBuildBaselineRecord")
        self.assertIn("NSNumber *slotID", baseline)
        self.assertIn('@"slotID": slotID', baseline)
        self.assertNotIn('@"slotID": @1', baseline)
        for marker in (
            "static NSDictionary *CCNMBuildIntentRecord",
            "static NSDictionary *CCNMBuildInFlightRecord",
        ):
            with self.subTest(marker=marker):
                body = self.function(self.controller, marker)
                self.assertIn('baseline[@"slotID"]', body)
                self.assertNotIn('@"slotID": @1', body)

    def test_controller_and_reader_validate_a_positive_slot_and_record_links(self):
        for name, source in (("controller", self.controller), ("reader", self.reader)):
            with self.subTest(source=name):
                self.assertIn("CCNMValidSlotID", source)
                baseline = self.function(source, "CCNMValidateBaselineRecord")
                self.assertIn('CCNMValidSlotID(baseline[@"slotID"])', baseline)
                intent = self.function(source, "CCNMValidateIntentRecord")
                self.assertIn('[intent[@"slotID"] isEqual:baseline[@"slotID"]]', intent)
                inflight = self.function(source, "CCNMValidateInFlightRecord")
                self.assertIn('[record[@"slotID"] isEqual:baseline[@"slotID"]]', inflight)

    def test_known_orphan_replay_remains_pinned_to_slot_one(self):
        predicate = self.function(
            self.controller,
            "static BOOL CCNMValidateKnownOrphanedN78HistoricalPredicate",
        )
        self.assertIn("CCNMKnownOrphanSubscriptionUUID, @1", predicate)
        known_baseline = self.function(self.controller, "static BOOL CCNMKnownOrphanBaselineMatchesEvidence")
        self.assertIn('[baseline[@"slotID"] isEqual:@1]', known_baseline)

    def test_structured_serving_summary_exports_the_actual_slot(self):
        self.assertIn("CCNMServingSummarySlotIDKey", self.provider_h)
        self.assertIn('CCNMServingSummarySlotIDKey = @"slotID"', self.provider_m)
        self.assertIn("summary[CCNMServingSummarySlotIDKey] = slotID ?: @0", self.provider_m)
        self.assertIn("CCNMServingSummarySlotIDKey", self.daemon)
        self.assertNotIn('@"slotID": @1', self.daemon)

    def test_automatic_maintenance_identity_includes_slot(self):
        identity_match = self.function(self.automatic_record, "static BOOL CCNMAIdentitySnapshotMatchesRecord")
        self.assertIn("CCNMARecordSlotIDKey", identity_match)
        record_builder = self.function(self.automatic_record, "NSDictionary *CCNMABuildRecord")
        self.assertNotIn('? identity[@"slotID"] : @1', record_builder)
        self.assertIn("CCNMValidAutomaticSlotID", record_builder)

    def test_disabled_pass_retires_the_record_instead_of_keeping_stale_drop_state(self):
        # Refusing to invent slot 1 means a disabled pass no longer rewrites the
        # record, so the daemon has to retire it explicitly. Without this a
        # disable then re-enable inside one boot could inherit a consumed attempt.
        body = self.function(self.daemon, "- (void)persistWithDecision:")
        self.assertIn("CCNMADeleteRecord()", body)
        self.assertIn("decision == CCNMAutomaticMaintenanceDisabled", body)
        self.assertIn("!CCNMPolicySummaryIsStableEnabled(policy)", body)
        # The delete must not be driven by a nil record during an enabled pass:
        # there a missing identity has to leave a consumed attempt consumed.
        self.assertLess(body.index("CCNMADeleteRecord()"), body.index("CCNMABuildRecord("))


if __name__ == "__main__":
    unittest.main(verbosity=2)
