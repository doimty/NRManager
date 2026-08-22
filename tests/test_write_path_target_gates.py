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

* Historical replay. The known-orphan paths write
  ``CCNMKnownOrphanHistoricalOriginalBands()``, a band table captured from the
  reference handset, against a placeholder subscription UUID. On a different
  device that is another phone's radio capability set. Allowing an unverified
  model there is not a confidence judgement, it is writing the wrong data.

That asymmetry is why the replay gate must stay pinned even if the self-sourced
gate is ever opened up, and why the two must not share an implementation.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
POLICY = REPO / "networkmanagerprefs/CCNMN78PolicyController.m"

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
        cls.calls = gate_call_sites(cls.source)

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

    def test_replay_gate_refuses_any_device_but_the_reference_handset(self) -> None:
        """This one is a correctness bound, not a confidence threshold.

        The data being written came from one specific phone. No amount of
        runtime self-proof on a different phone makes that table correct for it,
        so this assertion must survive any later loosening of the write path.
        """
        body = self.source[
            self.source.index(f"static BOOL {REPLAY_GATE}") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertIn("CCNMIsReferenceVerifiedTarget()", body)
        self.assertIn("CCNMN78PolicyErrorUnsupportedTarget", self.source)

    def test_identity_is_read_before_any_verdict(self) -> None:
        """A baseline cannot be written without model, version, and build.

        CCNMBuildBaselineRecord refuses a baseline whose identity fields are
        empty, and an enable that cannot record a baseline must not reach the
        setter. So the gate judges locals it read itself rather than reading back
        out of the reporting dictionary, which a caller may pass as nil.
        """
        body = self.source[
            self.source.index(f"static BOOL {SELF_SOURCED_GATE}") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertIn('CCNMSysctlString("hw.machine")', body)
        self.assertIn('CCNMSysctlString("kern.osversion")', body)
        self.assertIn("CCNMSystemVersionString()", body)
        self.assertIn("!model.length || !build.length || !version.length", body)
        # The verdict must not depend on the reporting dictionary, because the
        # signature permits nil there.
        self.assertNotIn('details[@"deviceModel"] length]', body)
        # The identity check must precede the model verdict; a device that
        # cannot report itself is refused for that reason, not for its model.
        self.assertLess(
            body.index("!model.length"),
            body.index("CCNMIsReferenceVerifiedTarget()"),
        )

    def test_identity_recording_renders_no_verdict(self) -> None:
        body = self.source[
            self.source.index("static void CCNMRecordDeviceIdentity") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertNotIn("iPhone14,3", body)
        self.assertNotIn("19B81", body)
        self.assertNotIn("return NO", body)

    def test_both_gates_report_identity_even_when_they_refuse(self) -> None:
        """A refusal has to say which device it measured, not only which it wants."""
        for gate in (SELF_SOURCED_GATE, REPLAY_GATE):
            with self.subTest(gate=gate):
                body = self.source[self.source.index(f"static BOOL {gate}") :]
                body = body[: body.index("\n}\n")]
                self.assertIn("CCNMRecordDeviceIdentity(details", body)
                self.assertLess(
                    body.index("CCNMRecordDeviceIdentity(details"),
                    body.index("return NO;"),
                )


if __name__ == "__main__":
    unittest.main()
