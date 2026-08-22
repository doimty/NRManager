#!/usr/bin/env python3
"""Which write path gets which target gate, and why.

The six write-path gate call sites are not one policy. Splitting them was the
point of this change, so the split needs to be pinned or a later edit will
quietly merge them back.

Two kinds of write exist in this controller:

* Self-sourced. ``performEnable`` reads live BandInfo and resends it with the NR
  array narrowed. ``performRestoreOperation:`` resends a baseline this device
  wrote about itself. Every byte written originated on the device receiving it,
  so allowing an unverified model is a confidence judgement.

* Historical replay. The known-orphan paths contain
  ``CCNMKnownOrphanHistoricalOriginalBands()``, a reviewed BandInfo table, but
  they only proceed after the current active and supported dictionaries match
  that table exactly, the subscription UUID matches, and durable state is clean.
  The current model and OS version are evidence fields, not a second allowlist.

The two gates remain separate because they protect different data flows, even
though both now use runtime identity/capability checks rather than a model
allowlist.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
POLICY = REPO / "networkmanagerprefs/CCNMN78PolicyController.m"
READER = REPO / "networkmanagerprefs/CCNMN78PolicyReader.m"

SELF_SOURCED_GATE = "CCNMValidateSelfSourcedWriteTarget"
REPLAY_GATE = "CCNMValidateHistoricalReplayTarget"

# Objective-C method or C function that encloses each gate call.
SELF_SOURCED_CALLERS = {"performEnable", "performRestoreOperation:"}
REPLAY_CALLERS = {
    "CCNMValidateKnownOrphanedN78HistoricalPredicate",
    "CCNMEvaluateKnownOrphanEligibilityWithHeldLock",
    "performKnownOrphanedN78Recovery",
}

_ENCLOSING = re.compile(
    r"^(?:static\s+[\w\s*<>]+?(?P<fn>CCNM\w+)\s*\(|- \([\w\s*<>]+\)(?P<sel>\w+:?))"
)


def gate_call_sites(source: str) -> dict[str, set[str]]:
    """Map each gate name to the set of functions that call it."""
    calls: dict[str, set[str]] = {SELF_SOURCED_GATE: set(), REPLAY_GATE: set()}
    enclosing = "<file scope>"
    for line in source.splitlines():
        match = _ENCLOSING.match(line)
        if match:
            enclosing = match.group("fn") or match.group("sel")
        for gate in calls:
            # Skip the definition itself.
            if f"{gate}(" in line and not line.startswith("static BOOL"):
                calls[gate].add(enclosing)
    return calls


class WritePathTargetGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = POLICY.read_text(encoding="utf-8")
        cls.reader = READER.read_text(encoding="utf-8")
        cls.calls = gate_call_sites(cls.source)

    def compatibility_sources(self):
        """The controller and the reader must agree; the daemon uses the reader."""
        return (("controller", self.source), ("reader", self.reader))

    @staticmethod
    def function_body(source: str, name: str) -> str:
        start = source.index(f"BOOL {name}(")
        return source[start : source.index("\n}\n", start)]

    def test_the_old_single_gate_is_gone(self) -> None:
        """One gate for both kinds of write is the thing being fixed."""
        self.assertNotIn("CCNMValidateTarget(", self.source)

    def test_self_sourced_writes_use_the_self_sourced_gate(self) -> None:
        self.assertEqual(self.calls[SELF_SOURCED_GATE], SELF_SOURCED_CALLERS)

    def test_replay_writes_use_the_replay_gate(self) -> None:
        self.assertEqual(self.calls[REPLAY_GATE], REPLAY_CALLERS)

    def test_every_gate_call_site_is_accounted_for(self) -> None:
        """Six sites existed before the split; none may go ungated."""
        total = sum(len(sites) for sites in self.calls.values())
        self.assertEqual(total, len(SELF_SOURCED_CALLERS) + len(REPLAY_CALLERS))
        self.assertEqual(
            self.source.count(f"{SELF_SOURCED_GATE}(")
            + self.source.count(f"{REPLAY_GATE}("),
            # Six calls plus the two definitions.
            8,
        )

    def test_enable_and_restore_share_one_gate(self) -> None:
        """A device that may create a baseline must be allowed to put it back.

        Gating these differently would let a device reach the setter and then be
        refused permission to restore, which is the exact outcome the gate
        exists to prevent.
        """
        self.assertIn("performEnable", self.calls[SELF_SOURCED_GATE])
        self.assertIn("performRestoreOperation:", self.calls[SELF_SOURCED_GATE])
        self.assertEqual(
            self.calls[SELF_SOURCED_GATE] & self.calls[REPLAY_GATE], set()
        )

    def test_replay_gate_uses_exact_capability_evidence_not_model_allowlist(self) -> None:
        """n78 alone is insufficient; exact active/supported evidence is the gate."""
        body = self.source[
            self.source.index(f"static BOOL {REPLAY_GATE}") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertIn("CCNMValidateTargetIdentity", body)
        self.assertNotIn("CCNMIsReferenceVerifiedTarget", self.source)
        self.assertIn("CCNMKnownOrphanBandInfoMatches", self.source)
        self.assertIn("CCNMKnownOrphanHistoricalActiveBands()", self.source)
        self.assertIn("CCNMKnownOrphanHistoricalSupportedBands()", self.source)
        self.assertIn("CCNMN78PolicyErrorUnsupportedTarget", self.source)

    def test_identity_is_read_before_any_verdict(self) -> None:
        """A baseline cannot be written without model, version, and build.

        CCNMBuildBaselineRecord refuses a baseline whose identity fields are
        empty, and an enable that cannot record a baseline must not reach the
        setter. So the gate judges locals it read itself rather than reading back
        out of the reporting dictionary, which a caller may pass as nil.
        """
        body = self.source[
            self.source.index("static BOOL CCNMValidateTargetIdentity") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertIn('CCNMSysctlString("hw.machine")', body)
        self.assertIn('CCNMSysctlString("kern.osversion")', body)
        self.assertIn("CCNMSystemVersionString()", body)
        self.assertIn("!model.length || !build.length || !version.length", body)
        # The verdict must not depend on the reporting dictionary, because the
        # signature permits nil there.
        self.assertNotIn('details[@"deviceModel"] length]', body)
        # The identity check is the only early target verdict. Model and OS
        # values are recorded for evidence, not used as an allowlist.
        self.assertIn("return YES;", body)
        self.assertNotIn("iPhone14,3", self.source)
        self.assertNotIn("19B81", self.source)

    def test_identity_recording_renders_no_verdict(self) -> None:
        body = self.source[
            self.source.index("static void CCNMRecordDeviceIdentity") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertNotIn("iPhone14,3", body)
        self.assertNotIn("19B81", body)
        self.assertNotIn("return NO", body)

    def test_both_gates_use_the_same_identity_validator(self) -> None:
        """Both write families reject unreadable identity and otherwise proceed."""
        for gate in (SELF_SOURCED_GATE, REPLAY_GATE):
            with self.subTest(gate=gate):
                body = self.source[self.source.index(f"static BOOL {gate}") :]
                body = body[: body.index("\n}\n")]
                self.assertIn("CCNMValidateTargetIdentity(details, failure)", body)
        identity = self.source[
            self.source.index("static BOOL CCNMValidateTargetIdentity") :
        ]
        identity = identity[: identity.index("\n}\n")]
        self.assertIn("CCNMRecordDeviceIdentity(details, model, build, version);", identity)
        self.assertIn("!model.length || !build.length || !version.length", identity)

    def test_restore_is_bound_to_hardware_and_capability_not_os_build(self) -> None:
        """An OS update must not strand a baseline that still fits the modem."""
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                compatibility = self.function_body(source, "CCNMValidateBaselineCompatibility")
                self.assertIn('baseline[@"deviceModel"] isEqual:identity[@"deviceModel"]', compatibility)
                self.assertNotIn('baseline[@"systemVersion"] isEqual:', compatibility)
                self.assertNotIn('baseline[@"systemBuild"] isEqual:', compatibility)

    def test_replayed_nr_bands_are_capability_checked(self) -> None:
        """A restore writes exactly one array, so that array needs the proof.

        CCNMBuildRestorePayload keeps live values for every RAT except NR. The
        saved NR bands are therefore the only values the modem has not just
        reported, and the only ones that can be unsupported.
        """
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                compatibility = self.function_body(source, "CCNMValidateBaselineCompatibility")
                self.assertIn(
                    "CCNMBaselineNRBandsFitCurrentCapability(savedActive[CCNMNRKey]",
                    compatibility,
                )
                # Nil-guarded before subscripting, because a keyed subscript on a
                # non-dictionary raises inside SpringBoard.
                self.assertIn(
                    'NSDictionary *savedActive = [baseline[@"activeBands"] isKindOfClass:NSDictionary.class]',
                    compatibility,
                )
                # Applies to every baseline, before the evidence branch.
                self.assertLess(
                    compatibility.index("CCNMBaselineNRBandsFitCurrentCapability"),
                    compatibility.index("if (!hasCapabilitySnapshot)"),
                )

    def test_baselines_without_capability_evidence_stay_restorable(self) -> None:
        """Older baselines predate the capability snapshot and must stay usable.

        A baseline is the only way back from an enable. Refusing one for lacking
        a field that did not exist when it was written would strand the device it
        was written to protect, so the NR capability check above is the evidence
        such a baseline offers instead.
        """
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                validate = self.function_body(source, "CCNMValidateBaselineRecord")
                self.assertIn(
                    "BOOL capabilitySnapshotValid = !hasCapabilitySnapshot ||", validate
                )
                compatibility = self.function_body(source, "CCNMValidateBaselineCompatibility")
                branch = compatibility[compatibility.index("if (!hasCapabilitySnapshot)") :]
                self.assertIn("return YES;", branch[: branch.index("\n    }")])


if __name__ == "__main__":
    unittest.main()
