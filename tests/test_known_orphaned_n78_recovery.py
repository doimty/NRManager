#!/usr/bin/env python3
"""Behavior and source contracts for the one-time known-device n78 recovery."""

from dataclasses import dataclass, field
from pathlib import Path
import copy
import json
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICY_HEADER = ROOT / "networkmanagerprefs/CCNMN78PolicyController.h"
POLICY_SOURCE = ROOT / "networkmanagerprefs/CCNMN78PolicyController.m"
SETTINGS_SOURCE = ROOT / "networkmanagerprefs/CCNMRootListController.m"
ROOT_PLIST = ROOT / "networkmanagerprefs/Resources/Root.plist"
PRERM_SOURCE = ROOT / "package-actions/prerm.m"
CC_SOURCE = ROOT / "CCNetworkManager.x"
EVIDENCE_FIXTURE = ROOT / "tests/fixtures/known_orphaned_n78_evidence.json"

EVIDENCE_SHA256 = "9e6230dfae679537b5b827518975e7675abf864cd403e96f97f11de63316ac76"
RECOVERY_SOURCE = "known-device-orphaned-n78"
TARGET_UUID = "00000000-0000-0000-0000-000000000001"
NR_KEY = "kCTRegistrationRadioAccessTechnologyNR"

HISTORICAL_ORIGINAL = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": list(range(1, 21)),
    "kCTRegistrationRadioAccessTechnologyGSM": list(range(1, 10)),
    "kCTRegistrationRadioAccessTechnologyLTE": [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19, 20,
        21, 24, 25, 26, 27, 28, 29, 30, 33, 34, 35, 36, 37, 38, 39, 40,
        41, 42, 43, 46, 48, 66, 71,
    ],
    NR_KEY: [
        1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 30, 34, 38,
        39, 40, 41, 48, 50, 51, 53, 65, 66, 70, 71, 74, 75, 76, 77, 78,
        79, 80, 81, 82, 83, 84, 85, 86, 257, 258, 259, 260, 261,
    ],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": [1, 2, 3, 4, 5, 6],
    "kCTRegistrationRadioAccessTechnologyUTRAN": list(range(1, 12)),
}

HISTORICAL_SUPPORTED = {
    "kCTRegistrationRadioAccessTechnologyCDMAHybrid": [1, 2, 3, 12],
    "kCTRegistrationRadioAccessTechnologyGSM": [1, 2, 7, 9],
    "kCTRegistrationRadioAccessTechnologyLTE": [
        1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 30,
        34, 38, 39, 40, 41, 42, 46, 48, 66,
    ],
    NR_KEY: [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 30, 38, 40, 41, 48, 66, 77, 78, 79],
    "kCTRegistrationRadioAccessTechnologyTDSCDMA": [],
    "kCTRegistrationRadioAccessTechnologyUTRAN": [1, 2, 4, 5, 6, 8],
}


def orphan_active() -> dict:
    active = copy.deepcopy(HISTORICAL_ORIGINAL)
    active[NR_KEY] = [78]
    return active


def clean_state() -> dict:
    return {
        "requestedMode": "systemDefault",
        "appliedPolicy": "verifiedSystemDefault",
        "recoveryState": "clean",
        "uncertain": False,
    }


def verified_restore_state(*, provenance: bool) -> dict:
    state = clean_state() | {
        "subscriptionUUID": TARGET_UUID,
        "verifiedAt": 1787034816933,
        "restoredBaselineCreatedAt": 1787034476960,
        "verifiedActiveBands": copy.deepcopy(HISTORICAL_ORIGINAL),
    }
    if provenance:
        state |= {
            "recoverySource": RECOVERY_SOURCE,
            "evidenceSHA256": EVIDENCE_SHA256,
        }
    return state


def verified_restore_upgrade_eligible(state: dict) -> bool:
    base_matches = (
        state.get("requestedMode") == "systemDefault"
        and state.get("appliedPolicy") == "verifiedSystemDefault"
        and state.get("recoveryState") == "clean"
        and state.get("subscriptionUUID") == TARGET_UUID
        and state.get("uncertain") is False
        and isinstance(state.get("verifiedAt"), int)
        and isinstance(state.get("restoredBaselineCreatedAt"), int)
        and state.get("verifiedActiveBands") == HISTORICAL_ORIGINAL
    )
    fixed_provenance = (
        state.get("recoverySource") == RECOVERY_SOURCE
        and state.get("evidenceSHA256") == EVIDENCE_SHA256
    )
    legacy_shape = "recoverySource" not in state and "evidenceSHA256" not in state
    return base_matches and (fixed_provenance or legacy_shape)


def exact_orphan_eligible(snapshot: dict) -> bool:
    if snapshot.get("model") != "iPhone14,3":
        return False
    if snapshot.get("version") != "15.1.1" or snapshot.get("build") != "19B81":
        return False
    contexts = snapshot.get("contexts")
    present = [item for item in contexts or [] if item.get("present")]
    if len(present) != 1:
        return False
    sim = present[0]
    if sim != {"slot": 1, "present": True, "good": True, "uuid": TARGET_UUID}:
        return False
    state = snapshot.get("state")
    if state is not None and state != clean_state():
        return False
    if (snapshot.get("baseline") is not None or snapshot.get("intent") is not None or
            snapshot.get("inflight") is not None or snapshot.get("removal_guard") is not None):
        return False
    active = snapshot.get("active")
    if not isinstance(active, dict) or set(active) != set(HISTORICAL_ORIGINAL):
        return False
    if active.get(NR_KEY) != [78]:
        return False
    for key, values in HISTORICAL_ORIGINAL.items():
        if key != NR_KEY and active.get(key) != values:
            return False
    return snapshot.get("supported") == HISTORICAL_SUPPORTED


def eligible_fixture() -> dict:
    return {
        "model": "iPhone14,3",
        "version": "15.1.1",
        "build": "19B81",
        "contexts": [
            {"slot": 1, "present": True, "good": True, "uuid": TARGET_UUID},
            {"slot": 2, "present": False, "good": True,
             "uuid": "00000000-0000-0000-0000-000000000002"},
        ],
        "state": clean_state(),
        "baseline": None,
        "intent": None,
        "inflight": None,
        "removal_guard": None,
        "active": orphan_active(),
        "supported": copy.deepcopy(HISTORICAL_SUPPORTED),
    }


@dataclass
class RecoveryModel:
    snapshot: dict = field(default_factory=eligible_fixture)
    lock_acquisitions: int = 0
    lock_held: bool = False
    lock_retained: bool = False
    modem_writes: int = 0
    checkpoints: list[str] = field(default_factory=list)

    def recover(self, *, drift_before_setter=False, setter="success", readback="match") -> bool:
        self.lock_acquisitions += 1
        self.lock_held = True
        if not exact_orphan_eligible(self.snapshot):
            self.lock_held = False
            return False

        self.snapshot["baseline"] = {
            "active": copy.deepcopy(HISTORICAL_ORIGINAL),
            "recoverySource": RECOVERY_SOURCE,
            "evidenceSHA256": EVIDENCE_SHA256,
        }
        self.checkpoints.append("baseline")
        self.snapshot["state"] = {
            "requestedMode": "n78Preferred",
            "appliedPolicy": "verifiedN78Only",
            "recoveryState": "enabledWithBaseline",
            "uncertain": False,
            "readBackVerified": True,
            "verifiedActiveBands": orphan_active(),
            "targetNRBands": [78],
            "nonNRUnchanged": True,
            "recoverySource": RECOVERY_SOURCE,
            "evidenceSHA256": EVIDENCE_SHA256,
        }
        self.checkpoints.append("adopted")
        self.snapshot["intent"] = "restore"
        self.checkpoints.append("intent")
        self.snapshot["state"]["recoveryState"] = "restorePending"
        self.checkpoints.append("pending")
        self.snapshot["inflight"] = "restore"
        self.checkpoints.append("inflight")

        if drift_before_setter:
            self.snapshot["active"]["kCTRegistrationRadioAccessTechnologyLTE"] = [1]
        if self.snapshot["active"] != orphan_active() or self.snapshot["supported"] != HISTORICAL_SUPPORTED:
            self.lock_held = False
            return False

        self.modem_writes += 1
        if setter == "timeout":
            self.lock_retained = True
            self.snapshot["state"]["recoveryState"] = "rebootRequired"
            return False
        if setter != "success" or readback != "match":
            self.snapshot["state"]["recoveryState"] = "recoveryFailed"
            self.lock_held = False
            return False

        self.snapshot["active"] = copy.deepcopy(HISTORICAL_ORIGINAL)
        self.snapshot["baseline"] = None
        self.snapshot["intent"] = None
        self.snapshot["inflight"] = None
        self.snapshot["state"] = clean_state() | {
            "recoverySource": RECOVERY_SOURCE,
            "evidenceSHA256": EVIDENCE_SHA256,
        }
        self.lock_held = False
        return True


class KnownOrphanEligibilityTests(unittest.TestCase):
    def test_exact_known_orphan_is_eligible(self):
        self.assertTrue(exact_orphan_eligible(eligible_fixture()))

    def test_absent_state_is_also_eligible(self):
        fixture = eligible_fixture()
        fixture["state"] = None
        self.assertTrue(exact_orphan_eligible(fixture))

    def test_each_identity_or_durable_field_rejects(self):
        mutations = (
            ("model", "iPhone14,2"),
            ("version", "15.1"),
            ("build", "19B74"),
            ("state", clean_state() | {"requestedMode": "n78Preferred"}),
            ("baseline", {}),
            ("intent", {}),
            ("inflight", {}),
            ("removal_guard", {}),
        )
        for field_name, replacement in mutations:
            with self.subTest(field=field_name):
                fixture = eligible_fixture()
                fixture[field_name] = replacement
                self.assertFalse(exact_orphan_eligible(fixture))

    def test_each_sim_topology_change_rejects(self):
        fixtures = []
        for field_name, replacement in (
            ("slot", 2), ("good", False),
            ("uuid", "00000000-0000-0000-0000-000000000003"),
        ):
            fixture = eligible_fixture()
            fixture["contexts"][0][field_name] = replacement
            fixtures.append((field_name, fixture))
        second_present = eligible_fixture()
        second_present["contexts"][1]["present"] = True
        fixtures.append(("secondPresent", second_present))
        for name, fixture in fixtures:
            with self.subTest(field=name):
                self.assertFalse(exact_orphan_eligible(fixture))

    def test_each_live_band_deviation_rejects(self):
        for key in HISTORICAL_ORIGINAL:
            fixture = eligible_fixture()
            fixture["active"][key] = [999]
            with self.subTest(key=key):
                self.assertFalse(exact_orphan_eligible(fixture))
        fixture = eligible_fixture()
        fixture["active"]["foreign"] = []
        self.assertFalse(exact_orphan_eligible(fixture))

    def test_each_supported_band_deviation_rejects(self):
        for key in HISTORICAL_SUPPORTED:
            fixture = eligible_fixture()
            fixture["supported"][key] = fixture["supported"][key] + [999]
            with self.subTest(key=key):
                self.assertFalse(exact_orphan_eligible(fixture))

    def test_exact_legacy_and_provenance_restore_states_can_upgrade(self):
        self.assertTrue(verified_restore_upgrade_eligible(
            verified_restore_state(provenance=False)
        ))
        self.assertTrue(verified_restore_upgrade_eligible(
            verified_restore_state(provenance=True)
        ))

    def test_incomplete_or_drifted_restore_proof_cannot_upgrade(self):
        mutations = (
            ("subscriptionUUID", "00000000-0000-0000-0000-000000000002"),
            ("verifiedAt", None),
            ("restoredBaselineCreatedAt", None),
            ("recoverySource", RECOVERY_SOURCE),
        )
        for key, value in mutations:
            state = verified_restore_state(provenance=False)
            state[key] = value
            with self.subTest(key=key):
                self.assertFalse(verified_restore_upgrade_eligible(state))
        state = verified_restore_state(provenance=False)
        state["verifiedActiveBands"][NR_KEY] = [78]
        self.assertFalse(verified_restore_upgrade_eligible(state))


class KnownOrphanRecoveryLifecycleTests(unittest.TestCase):
    def test_one_lock_spans_adoption_restore_and_cleanup(self):
        model = RecoveryModel()
        self.assertTrue(model.recover())
        self.assertEqual(model.lock_acquisitions, 1)
        self.assertFalse(model.lock_held)
        self.assertEqual(model.modem_writes, 1)
        self.assertEqual(model.checkpoints, ["baseline", "adopted", "intent", "pending", "inflight"])
        self.assertEqual(model.snapshot["active"], HISTORICAL_ORIGINAL)

    def test_final_historical_guard_rejects_drift_without_modem_write(self):
        model = RecoveryModel()
        self.assertFalse(model.recover(drift_before_setter=True))
        self.assertEqual(model.lock_acquisitions, 1)
        self.assertEqual(model.modem_writes, 0)
        self.assertIsNotNone(model.snapshot["baseline"])

    def test_timeout_transfers_lock_and_preserves_recovery_evidence(self):
        model = RecoveryModel()
        self.assertFalse(model.recover(setter="timeout"))
        self.assertTrue(model.lock_retained)
        self.assertTrue(model.lock_held)
        self.assertIsNotNone(model.snapshot["baseline"])
        self.assertEqual(model.snapshot["state"]["recoveryState"], "rebootRequired")

    def test_readback_mismatch_preserves_evidence_and_blocks_clean_state(self):
        model = RecoveryModel()
        self.assertFalse(model.recover(readback="different"))
        self.assertIsNotNone(model.snapshot["baseline"])
        self.assertEqual(model.snapshot["state"]["recoveryState"], "recoveryFailed")

    def test_every_crash_checkpoint_is_fail_closed(self):
        for checkpoint in ("baseline", "adopted", "intent", "pending", "inflight"):
            model = RecoveryModel()
            model.snapshot["baseline"] = {"active": copy.deepcopy(HISTORICAL_ORIGINAL)}
            if checkpoint != "baseline":
                model.snapshot["state"] = {
                    "requestedMode": "n78Preferred",
                    "appliedPolicy": "verifiedN78Only" if checkpoint == "adopted" else "applying",
                    "recoveryState": "enabledWithBaseline" if checkpoint == "adopted" else "restorePending",
                    "uncertain": False,
                }
            if checkpoint in ("intent", "pending", "inflight"):
                model.snapshot["intent"] = "restore"
            if checkpoint == "inflight":
                model.snapshot["inflight"] = "restore"
            with self.subTest(checkpoint=checkpoint):
                self.assertFalse(exact_orphan_eligible(model.snapshot))
                self.assertIsNotNone(model.snapshot["baseline"])

    def test_provenance_is_fixed_and_survives_success(self):
        model = RecoveryModel()
        self.assertTrue(model.recover())
        self.assertEqual(model.snapshot["state"]["recoverySource"], RECOVERY_SOURCE)
        self.assertEqual(model.snapshot["state"]["evidenceSHA256"], EVIDENCE_SHA256)


class KnownOrphanRecoverySourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = POLICY_HEADER.read_text()
        cls.policy = POLICY_SOURCE.read_text()
        cls.settings = SETTINGS_SOURCE.read_text()
        cls.prerm = PRERM_SOURCE.read_text()
        cls.cc = CC_SOURCE.read_text()
        cls.items = plistlib.loads(ROOT_PLIST.read_bytes())["items"]

    def test_public_api_is_dedicated_and_eligibility_is_read_only(self):
        self.assertIn("CCNMReadKnownOrphanedN78RecoveryEligibility", self.header)
        self.assertIn("CCNMReadKnownOrphanedN78RemovalSafety", self.header)
        self.assertIn("CCNMRecoverKnownOrphanedN78WithCompletion", self.header)
        probe_start = self.policy.index("CCNMEvaluateKnownOrphanEligibilityWithHeldLock")
        probe_end = self.policy.index("static id<CCNMBandInfo> CCNMCreateBandPayload", probe_start)
        probe = self.policy[probe_start:probe_end]
        for forbidden in ("CCNMPersistState", "CCNMCreateDurableRecord", "CCNMCallSetter"):
            self.assertNotIn(forbidden, probe)

    def test_fixed_evidence_and_exact_historical_predicate_are_compiled_in(self):
        self.assertIn(EVIDENCE_SHA256, self.policy)
        self.assertIn(RECOVERY_SOURCE, self.policy)
        self.assertIn(TARGET_UUID, self.policy)
        self.assertIn("CCNMKnownOrphanHistoricalOriginalBands", self.policy)
        self.assertIn("CCNMKnownOrphanHistoricalSupportedBands", self.policy)
        self.assertIn("CCNMValidateKnownOrphanedN78HistoricalPredicate", self.policy)
        self.assertNotIn("dictionaryWithContentsOfURL", self.policy)

    def test_compiled_constants_match_the_sanitized_reviewed_evidence_fixture(self):
        evidence = json.loads(EVIDENCE_FIXTURE.read_text())
        self.assertEqual(evidence["reviewedSourceSHA256"], EVIDENCE_SHA256)
        self.assertEqual(evidence["deviceModel"], "iPhone14,3")
        self.assertEqual(evidence["systemVersion"], "15.1.1")
        self.assertEqual(evidence["systemBuild"], "19B81")
        self.assertEqual(evidence["slotID"], 1)
        self.assertEqual(evidence["targetSubscriptionUUID"], TARGET_UUID)
        self.assertTrue(evidence["transactionCompletedSafely"])
        self.assertTrue(evidence["restoreReadBackEqual"])
        self.assertEqual(evidence["originalActiveBands"], HISTORICAL_ORIGINAL)
        self.assertEqual(evidence["supportedBandsAtSelection"], HISTORICAL_SUPPORTED)

    def test_adoption_and_restore_share_one_lock_descriptor(self):
        self.assertIn("performRestoreOperation:operation", self.policy)
        self.assertIn("heldLockDescriptor:(int *)lockDescriptor", self.policy)
        start = self.policy.index("- (NSDictionary *)performKnownOrphanedN78Recovery")
        end = self.policy.index("- (NSDictionary *)performRestoreOperation:(NSString *)operation", start)
        adoption = self.policy[start:end]
        self.assertEqual(adoption.count("CCNMAcquirePolicyLock"), 1)
        self.assertIn("heldLockDescriptor:&lockDescriptor", adoption)
        core_start = self.policy.index("heldLockDescriptor:(int *)lockDescriptor")
        core = self.policy[core_start:self.policy.index("@end", core_start)]
        self.assertNotIn("CCNMAcquirePolicyLock", core)
        self.assertIn("lockDescriptor, details, &failure", core)

    def test_baseline_precedes_adopted_state_and_provenance_is_durable(self):
        start = self.policy.index("performKnownOrphanedN78Recovery")
        body = self.policy[start:self.policy.index("@end", start)]
        self.assertLess(body.index("CCNMN78PolicyBaselinePath"), body.index("CCNMAppliedPolicyVerifiedN78Only"))
        self.assertIn('@"readBackVerified": @YES', body)
        self.assertIn('@"targetNRBands": @[ @78 ]', body)
        self.assertIn('@"nonNRUnchanged": @YES', body)
        self.assertIn('@"recoverySource"', body)
        self.assertIn('@"evidenceSHA256"', body)

    def test_cleanup_after_baseline_retirement_preserves_provenance(self):
        self.assertIn(
            '[state[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource]',
            self.policy,
        )
        self.assertIn(
            '[state[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256]',
            self.policy,
        )
        self.assertIn('cleanupProof[@"recoverySource"]', self.policy)
        self.assertIn('cleanupProof[@"evidenceSHA256"]', self.policy)

    def test_final_guard_reruns_historical_predicate_before_setter(self):
        restore_start = self.policy.index("performRestoreOperation:operation")
        restore = self.policy[restore_start:self.policy.index("@end", restore_start)]
        self.assertIn("BOOL knownEvidenceBaseline = baselineExists", restore)
        self.assertIn(
            "requireKnownOrphanFinalGuard || knownEvidenceBaseline",
            restore,
        )
        predicate = restore.rindex("CCNMValidateKnownOrphanedN78HistoricalPredicate")
        setter = restore.index("CCNMCallSetter", predicate)
        self.assertLess(predicate, setter)

    def test_tagged_baseline_is_bound_to_fixed_uuid_and_exact_original_bands(self):
        start = self.policy.index("CCNMKnownOrphanBaselineMatchesEvidence")
        body = self.policy[start:self.policy.index("static NSDictionary *CCNMDeepCopyDictionary", start)]
        self.assertIn("CCNMKnownOrphanSubscriptionUUID", body)
        self.assertIn("CCNMKnownOrphanHistoricalOriginalBands", body)
        self.assertIn("CCNMDictionariesEqual", body)
        validator = self.policy[
            self.policy.index("static BOOL CCNMValidateBaselineRecord"):
            self.policy.index("static NSDictionary *CCNMBuildIntentRecord")
        ]
        self.assertIn("CCNMKnownOrphanBaselineMatchesEvidence(baseline)", validator)

    def test_settings_action_is_separate_hidden_and_confirmation_gated(self):
        rows = [item for item in self.items if item.get("id") == "recoverKnownOrphanedN78"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].get("action"), "confirmKnownOrphanedN78Recovery:")
        for token in (
            "knownOrphanedN78RecoveryEligible",
            "CCNMReadKnownOrphanedN78RecoveryEligibility()",
            "CCNMRecoverKnownOrphanedN78WithCompletion",
            "knownOrphanRecoveryProbeGeneration",
            "probeGeneration != self.knownOrphanRecoveryProbeGeneration",
            "UIAlertActionStyleDestructive",
        ):
            self.assertIn(token, self.settings)
        self.assertNotIn("CCNMRecoverKnownOrphanedN78", self.cc)

    def test_verified_known_restore_can_upgrade_without_dpkg_telephony_permission(self):
        summary = self.policy[
            self.policy.index("static NSDictionary *CCNMSummaryFromState"):
            self.policy.index("static NSDictionary *CCNMReadPolicyStateInternal")
        ]
        self.assertIn('"verifiedKnownOrphanRestore"', summary)
        self.assertIn("CCNMStateHasVerifiedKnownOrphanRestore(base)", summary)
        restore_validator = self.policy[
            self.policy.index("static BOOL CCNMStateHasVerifiedKnownOrphanRestore"):
            self.policy.index("static NSDictionary *CCNMDeepCopyDictionary")
        ]
        self.assertIn("CCNMKnownOrphanHistoricalOriginalBands", restore_validator)
        self.assertIn("CCNMKnownOrphanSubscriptionUUID", restore_validator)
        self.assertIn("CCNMKnownOrphanRecoverySource", restore_validator)
        self.assertIn("CCNMKnownOrphanEvidenceSHA256", restore_validator)
        self.assertIn("legacyVerifiedShape", restore_validator)
        trusted = self.prerm.index('current[@"verifiedKnownOrphanRestore"]')
        probe = self.prerm.index("CCNMReadKnownOrphanedN78RemovalSafety()")
        self.assertLess(trusted, probe)
        self.assertIn('![current[@"removalGuardPresent"] boolValue]', self.prerm)

    def test_prerm_blocks_exact_orphan_without_automatic_modem_write(self):
        probe = self.prerm.index("CCNMReadKnownOrphanedN78RemovalSafety()")
        existing_guard_acceptance = self.prerm.index(
            "CCNMSummaryAllowsRemoval(current)", probe
        )
        guard = self.prerm.index("CCNMArmN78PolicyRemovalGuard", probe)
        self.assertLess(probe, existing_guard_acceptance)
        self.assertLess(probe, guard)
        self.assertIn("allowValidRemovalGuard", self.policy)
        self.assertIn("CCNMValidateRemovalGuardRecord(removalGuard", self.policy)
        self.assertIn("confirm the reviewed one-time NR recovery in Settings", self.prerm)
        self.assertNotIn("CCNMRecoverKnownOrphanedN78WithCompletion", self.prerm)
        self.assertIn("return CCNMPrermBlocked", self.prerm)


if __name__ == "__main__":
    unittest.main(verbosity=2)
