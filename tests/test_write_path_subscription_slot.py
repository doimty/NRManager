#!/usr/bin/env python3
"""Contracts for selecting and retaining the actual single usable SIM slot."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "nrmanagerprefs/CCNMN78PolicyController.m"
READER = ROOT / "nrmanagerprefs/CCNMN78PolicyReader.m"
PROVIDER_H = ROOT / "nrmanagerprefs/CCNMServingStatusProvider.h"
PROVIDER_M = ROOT / "nrmanagerprefs/CCNMServingStatusProvider.m"
DAEMON = ROOT / "maintenance-daemon/main.m"
AUTOMATIC_RECORD = ROOT / "nrmanagerprefs/CCNMAutomaticMaintenanceRecord.m"


def select_target(subscriptions, required_uuid=None, required_slot=None,
                  data_line_uuid=None, first_enable=False):
    """Small model of the write gate; raises when a modem write is ambiguous.

    Mirrors CCNMSafeTargetContext. A recorded target is looked up and never
    re-chosen; only a first enable may choose, and on a dual-SIM phone it may
    only choose the line CoreTelephony itself reports as the data line.
    """
    present = [item for item in subscriptions if item.get("present")]
    writable = [
        item for item in present
        if item.get("good") and item.get("uuid") and item.get("slot", 0) > 0
    ]
    recorded = required_uuid is not None or required_slot is not None
    if first_enable and recorded:
        raise ValueError("a recorded target cannot be reselected")
    if required_slot is not None and required_slot <= 0:
        raise ValueError("invalid recorded slot")
    if not writable:
        raise ValueError("no writable subscription")
    by_uuid = {item["uuid"]: item for item in writable}
    by_slot = {item["slot"]: item for item in writable}
    if len(by_uuid) != len(writable) or len(by_slot) != len(writable):
        raise ValueError("duplicate slot or identity")

    if required_uuid is not None:
        target = by_uuid.get(required_uuid)
        if target is None:
            raise ValueError("recorded subscription is gone")
    elif required_slot is not None:
        target = by_slot.get(required_slot)
        if target is None:
            raise ValueError("recorded slot has no writable subscription")
    elif len(present) == 1:
        target = writable[0]
    elif not first_enable:
        # A record predating the identity fields, on a phone holding two SIMs:
        # which line it described cannot be recovered.
        raise ValueError("recorded target cannot be identified")
    else:
        target = by_uuid.get(data_line_uuid) if data_line_uuid else None
        if target is None:
            raise ValueError("the data line cannot take this write")
    if required_slot is not None and target["slot"] != required_slot:
        raise ValueError("slot changed")
    return target


class WritePathSubscriptionSlotModelTests(unittest.TestCase):
    DUAL = (
        {"slot": 1, "present": True, "good": True, "uuid": "one"},
        {"slot": 2, "present": True, "good": True, "uuid": "two"},
    )

    def test_slot_one_single_sim_stays_supported(self):
        target = select_target([
            {"slot": 1, "present": True, "good": True, "uuid": "one"},
            {"slot": 2, "present": False, "good": True, "uuid": "two"},
        ], first_enable=True)
        self.assertEqual(target["slot"], 1)

    def test_slot_two_single_sim_is_supported(self):
        target = select_target([
            {"slot": 1, "present": False, "good": True, "uuid": "one"},
            {"slot": 2, "present": True, "good": True, "uuid": "two"},
        ], first_enable=True)
        self.assertEqual(target, {"slot": 2, "present": True, "good": True, "uuid": "two"})

    def test_dual_sim_first_enable_follows_the_reported_data_line(self):
        # The refusal a dual-line user actually hit. Nothing about the second SIM
        # makes the data line ambiguous, so the write is allowed to land on it.
        target = select_target(list(self.DUAL), data_line_uuid="two", first_enable=True)
        self.assertEqual(target["slot"], 2)

    def test_dual_sim_first_enable_without_a_data_line_answer_is_rejected(self):
        # No answer from CoreTelephony means no target. Picking either line would
        # be a guess about which line the user meant, and it would also decide
        # which subscription a later restore has to find.
        with self.assertRaises(ValueError):
            select_target(list(self.DUAL), first_enable=True)

    def test_dual_sim_first_enable_rejects_an_unwritable_data_line(self):
        # Falling through to the other SIM would silently apply the preference to
        # a line the user was not asking about.
        with self.assertRaises(ValueError):
            select_target([
                {"slot": 1, "present": True, "good": True, "uuid": "one"},
                {"slot": 2, "present": True, "good": False, "uuid": "two"},
            ], data_line_uuid="two", first_enable=True)

    def test_missing_uuid_and_nonpositive_slot_remain_rejected(self):
        for subscription in (
            {"slot": 2, "present": True, "good": True, "uuid": ""},
            {"slot": 0, "present": True, "good": True, "uuid": "two"},
        ):
            with self.subTest(subscription=subscription), self.assertRaises(ValueError):
                select_target([subscription], first_enable=True)

    def test_revalidation_binds_both_uuid_and_actual_slot(self):
        subscription = {"slot": 2, "present": True, "good": True, "uuid": "two"}
        self.assertEqual(select_target([subscription], "two", 2), subscription)
        with self.assertRaises(ValueError):
            select_target([subscription], "two", 1)
        with self.assertRaises(ValueError):
            select_target([subscription], "one", 2)

    def test_revalidation_survives_a_second_present_sim(self):
        # The reason the enable gate and the revalidation gate had to change
        # together: an enable that succeeded on a dual-SIM phone must still be
        # verifiable and restorable there, or it lands in reboot-required.
        target = select_target(list(self.DUAL), "two", 2)
        self.assertEqual(target["uuid"], "two")

    def test_revalidation_ignores_the_data_line(self):
        # The data line moves at runtime. Consulting it here would abandon the
        # subscription the policy was written to as soon as iOS switched lines.
        target = select_target(list(self.DUAL), "one", 1, data_line_uuid="two")
        self.assertEqual(target["uuid"], "one")

    def test_a_recorded_target_is_never_reselected(self):
        with self.assertRaises(ValueError):
            select_target(list(self.DUAL), "two", 2, data_line_uuid="two", first_enable=True)

    def test_legacy_record_naming_no_line_is_rejected_on_a_dual_sim_phone(self):
        # A record written before the identity fields names nothing. On one SIM
        # there is no choice to make; on two there is no way to know which line
        # it described, and the data line is an answer about now, not about then.
        single = select_target([
            {"slot": 1, "present": True, "good": True, "uuid": "one"},
            {"slot": 2, "present": False, "good": True, "uuid": "two"},
        ])
        self.assertEqual(single["uuid"], "one")
        with self.assertRaises(ValueError):
            select_target(list(self.DUAL), data_line_uuid="two")

    def test_duplicate_slot_or_identity_is_rejected(self):
        for subscriptions in (
            [
                {"slot": 1, "present": True, "good": True, "uuid": "same"},
                {"slot": 2, "present": True, "good": True, "uuid": "same"},
            ],
            [
                {"slot": 1, "present": True, "good": True, "uuid": "one"},
                {"slot": 1, "present": True, "good": True, "uuid": "two"},
            ],
        ):
            with self.subTest(subscriptions=subscriptions), self.assertRaises(ValueError):
                select_target(subscriptions, data_line_uuid="one", first_enable=True)


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

    @classmethod
    def method(cls, source, signature):
        """A method body, skipping any forward declaration of the same signature.

        `performRestoreOperation:` is declared in the private class extension
        before it is defined, and that declaration ends in a semicolon with no
        body. Slicing from the first match returns whatever method follows the
        extension instead, which parses fine and asserts nothing.
        """
        position = 0
        while True:
            start = source.index(signature, position)
            rest = source[start:]
            brace = rest.find("{")
            semicolon = rest.find(";")
            if brace != -1 and (semicolon == -1 or brace < semicolon):
                return rest[: rest.index("\n}\n") + 3]
            position = start + len(signature)

    @staticmethod
    def calls_to(source, marker):
        """Every call to marker, rejoined across line wraps, declarations aside."""
        calls = []
        index = source.find(marker)
        while index != -1:
            line_start = source.rfind("\n", 0, index) + 1
            end = source.index(";", index)
            call = " ".join(source[line_start:end].split())
            if not call.startswith("static "):
                calls.append(call)
            index = source.find(marker, end)
        return calls

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
                # Definitions, matched with the return type and the open paren. A
                # bare name also matches the cross-reference comments the two
                # copies carry about each other, which would hand back the wrong
                # function body.
                baseline = self.function(source, "BOOL CCNMValidateBaselineRecord(")
                self.assertIn('CCNMValidSlotID(baseline[@"slotID"])', baseline)
                intent = self.function(source, "BOOL CCNMValidateIntentRecord(")
                self.assertIn('[intent[@"slotID"] isEqual:baseline[@"slotID"]]', intent)
                inflight = self.function(source, "BOOL CCNMValidateInFlightRecord(")
                self.assertIn('[record[@"slotID"] isEqual:baseline[@"slotID"]]', inflight)

    def test_the_sole_sim_resolution_mode_is_gone_with_its_only_caller(self):
        # A third resolution mode existed for the known-orphan replay, which
        # carried BandInfo reviewed on a single-SIM reference device and so had to
        # refuse a phone holding two. The replay is gone -- the restore replays
        # only a baseline this device wrote about itself, which cannot be evidence
        # from someone else's phone -- and a stricter mode with no caller is a
        # trap: the next path that wants "be careful here" would reach for it
        # without the reviewed evidence that made the strictness meaningful.
        for token in ("CCNMTargetResolutionRecordedSoleSIM",
                      "CCNMKnownOrphan",
                      "approved only for a phone holding one SIM"):
            with self.subTest(token=token):
                self.assertNotIn(token, self.controller)
        enum = self.function(self.controller, "typedef NS_ENUM(NSUInteger, CCNMTargetResolution)")
        self.assertIn("CCNMTargetResolutionRecorded = 0", enum)
        self.assertIn("CCNMTargetResolutionFirstEnable = 1", enum)
        self.assertNotIn("= 2", enum)

    def test_no_shipped_path_defaults_a_missing_slot_to_one(self):
        # A record written before the slot field existed has no slot at all.
        # Defaulting that to 1 would claim a slot the device was never observed
        # on, which is exactly the bug this change set removes. Every slot value
        # must come from a revalidated subscription instead.
        for name, source in (
            ("controller", self.controller),
            ("reader", self.reader),
            ("daemon", self.daemon),
            ("automatic record", self.automatic_record),
        ):
            with self.subTest(source=name):
                self.assertNotIn('slotID"] ?: @1', source)
                self.assertNotIn('slotID"] ?: @(1)', source)

    def test_the_resumable_cleanup_records_only_a_slot_it_could_validate(self):
        # The branch that finishes a restore whose read-back already matched. Its
        # baseline is gone by definition -- retiring it is the step that proves the
        # read-back matched -- so the slot cannot come from there, and the state
        # record it is resuming may predate the slot field entirely.
        #
        # So the slot comes from the subscription the branch just revalidated, and
        # an absent one is a refusal rather than a default: a record claiming slot
        # 1 on a phone never observed there is worse than no record, because every
        # later revalidation would bind to it.
        body = self.method(self.controller, "- (NSDictionary *)performRestoreOperation:")
        self.assertIn('NSNumber *cleanupSlotID = [details[@"targetSlotID"] isKindOfClass:NSNumber.class]',
                      body)
        self.assertIn("if (!CCNMValidSlotID(cleanupSlotID)) {", body)
        self.assertIn("CCNMN78PolicyErrorUnsafeSubscription", body)
        self.assertIn('@"slotID": cleanupSlotID', body)
        self.assertNotIn('@"slotID": @1', body)
        # `targetSlotID` is published by the revalidation, so the read has to come
        # after it. Reading it earlier would pick up whatever a previous call left.
        self.assertLess(body.index("CCNMSafeTargetContext("), body.index("cleanupSlotID"))
        # The writing path in the same method has a baseline, and takes the slot
        # from it: CCNMValidateBaselineRecord has already refused a baseline whose
        # slot is absent or invalid, so there is nothing left to default.
        self.assertIn('@"slotID": baseline[@"slotID"]', body)

    def test_refusal_names_the_observed_layout_not_just_the_rule(self):
        # The device screenshot that started this work said only "exactly one
        # present/good SIM with a stable UUID in a positive slot is required",
        # which is the rule, not the observation. A dual-line user cannot tell
        # from that whether their slot, their UUID, or their second line is the
        # problem, and the same sentence appeared both before and after the slot
        # fix so it could not distinguish a stale install from a real refusal.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertNotIn("Exactly one present/good SIM", body)
        self.assertIn("CCNMSubscriptionLayoutSummary(reports)", body)
        self.assertIn("%lu SIMs are present", body)
        summary = self.function(self.controller, "static NSString *CCNMSubscriptionLayoutSummary")
        for field in ('@"slotID"', '@"isSimPresent"', '@"isSimGood"', '@"subscriptionUUID"'):
            self.assertIn(field, summary)
        # The layout line reports only whether a UUID exists, never its value.
        self.assertIn("hasUUID", summary)
        self.assertNotIn("UUIDString", summary)

    def test_observed_layout_is_rendered_after_the_whole_scan(self):
        # Rendering it mid-scan would report only the slots walked so far, so a
        # refusal about the second SIM could describe just the first one.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertEqual(body.count("CCNMSubscriptionLayoutSummary("), 1)
        self.assertLess(body.index('details[@"subscriptions"] = reports'),
                        body.index("CCNMSubscriptionLayoutSummary("))

    def test_dual_sim_is_no_longer_refused_outright(self):
        # The gate used to require exactly one present SIM unconditionally, which
        # refused every dual-line phone before it ever looked at which line was
        # the data line. Nothing refuses on the count now: the sole caller that
        # did was the known-orphan replay, whose reviewed evidence came from a
        # single-SIM device.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertEqual(
            [line.strip() for line in body.splitlines() if "presentCount != 1" in line], [])
        # What the count still does is decide whether there is anything to
        # disambiguate, which is a different question from whether to refuse.
        self.assertIn("presentCount == 1", body)
        self.assertIn("CCNMCurrentDataLineUUID(client", body)

    def test_only_a_first_enable_may_choose_a_target(self):
        # The data line moves at runtime, so it may pick a target but must never
        # validate one. Every revalidation and restore call site has to arrive in
        # the recorded mode, or a line switch would silently retarget the policy.
        calls = self.calls_to(self.controller, "CCNMSafeTargetContext(")
        self.assertGreater(len(calls), 1)
        for call in calls:
            with self.subTest(call=call):
                self.assertIn("CCNMTargetResolution", call)
        first_enable = [call for call in calls if "CCNMTargetResolutionFirstEnable" in call]
        self.assertEqual(len(first_enable), 1)
        # The one selecting call passes no recorded identity, and every other call
        # passes one. Anything else means a recorded target reached selection mode.
        self.assertIn("nil, nil", first_enable[0])
        for call in calls:
            if call in first_enable:
                continue
            with self.subTest(call=call):
                self.assertNotIn("Recorded, nil, nil", call)

    def test_recorded_mode_refuses_instead_of_consulting_the_data_line(self):
        # A record predating the identity fields names no line. On a dual-SIM
        # phone the current data line is an answer about now, not about the boot
        # the record was written in, so it must not stand in for the recorded id.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertEqual(body.count("CCNMCurrentDataLineUUID("), 1)
        self.assertIn("resolution != CCNMTargetResolutionFirstEnable", body)
        self.assertIn("names no subscription and %lu SIMs are present", body)
        self.assertLess(body.index("resolution != CCNMTargetResolutionFirstEnable"),
                        body.index("CCNMCurrentDataLineUUID("))
        # And a caller holding a record cannot ask to re-pick.
        self.assertIn("A recorded write target cannot be reselected.", body)

    def test_data_line_probe_is_abi_guarded_and_never_guesses(self):
        body = self.function(self.controller, "static NSString *CCNMCurrentDataLineUUID")
        self.assertIn("CCNMValidateObjectErrorABI(client", body)
        self.assertIn("@catch (NSException *exception)", body)
        # Every no-answer path returns nil with a reason. The write path must not
        # inherit the reader's quiet degradation to userDataPreferred or to the
        # only usable line.
        self.assertNotIn("userDataPreferred", body)
        self.assertEqual(body.count("return nil;"), 4)
        self.assertNotIn("UUIDString]);", body)

    def test_duplicate_slot_or_identity_is_refused_before_any_lookup(self):
        # Two lines sharing a slot or an identity would make every lookup below
        # silently pick one of them.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertIn("Two subscriptions report the same slot or identity", body)
        self.assertLess(body.index("Two subscriptions report the same slot or identity"),
                        body.index("id<CCNMSubscriptionContext> target = nil;"))

    def test_drift_refusal_distinguishes_a_moved_sim_from_a_swapped_one(self):
        # Slot drift and UUID drift need different user responses, and the
        # combined message could not tell them apart. A card sitting in the
        # recorded slot under a different identity was swapped; nothing there at
        # all was removed, and only that case is fixed by putting it back.
        body = self.function(self.controller, "static id<CCNMSubscriptionContext> CCNMSafeTargetContext")
        self.assertNotIn("The target subscription UUID or slot changed", body)
        self.assertIn("The target SIM moved: expected slot %@, found slot %@", body)
        self.assertIn("no longer matches the recorded target", body)
        self.assertIn("is not a writable line on this device", body)
        self.assertIn("is not a valid slot identifier", body)
        # An invalid recorded slot is answered before it can be reported as a
        # missing line or a moved SIM.
        self.assertLess(body.index("!requiredSlotValid) {"),
                        body.index("target = candidateByUUID[required];"))

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
