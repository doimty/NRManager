#!/usr/bin/env python3
"""Which write path gets a target gate, and what the gate is allowed to decide.

This file used to pin a split into two gates, because there were two kinds of
write:

* Self-sourced. ``performEnable`` reads live BandInfo and resends it with the NR
  array narrowed, and ``performRestoreOperation:`` resent a baseline this device
  had written about itself. Every byte originated on the device receiving it.

* Historical replay. The known-orphan path carried a reviewed BandInfo table
  captured from one device, and wrote values it had not read from the modem in
  front of it. It proceeded only after the live active and supported dictionaries
  matched that table exactly.

Only the first kind is left. Undoing an enable is a carrier defaults reload now,
which discards the whole carrier configuration and therefore needs no record of
what was narrowed -- so both the baseline replay and the historical replay lost
their reason to exist, and with them the second gate.

What has to stay pinned is narrower than a split but not weaker: one gate, on the
one path that writes; it reads identity itself instead of trusting the reporting
dictionary; and it renders no verdict about which device or OS is acceptable. The
last part is the regression to guard, because a model allowlist is the thing that
was removed and it is a natural thing to reach for again.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
POLICY = REPO / "networkmanagerprefs/CCNMN78PolicyController.m"
READER = REPO / "networkmanagerprefs/CCNMN78PolicyReader.m"
# Real BandInfo captured from the device the known-orphan path was written for.
# The replay is gone, but the evidence still says something the validators depend
# on: see test_a_baselines_active_nr_is_not_required_to_be_supported_nr.
ORPHAN_FIXTURE = REPO / "tests/fixtures/known_orphaned_n78_evidence.json"

WRITE_GATE = "CCNMValidateSelfSourcedWriteTarget"
RETIRED_REPLAY_GATE = "CCNMValidateHistoricalReplayTarget"

# The only method that may reach the modem setter, and so the only one that may
# call the gate. `performRestoreOperation:` used to be here too.
WRITE_CALLERS = {"performEnable"}

_ENCLOSING = re.compile(
    r"^(?:static\s+[\w\s*<>]+?(?P<fn>CCNM\w+)\s*\(|- \([\w\s*<>]+\)(?P<sel>\w+:?))"
)


def gate_call_sites(source: str, gate: str) -> set[str]:
    """The set of functions that call `gate`, excluding its own definition."""
    callers: set[str] = set()
    enclosing = "<file scope>"
    for line in source.splitlines():
        match = _ENCLOSING.match(line)
        if match:
            enclosing = match.group("fn") or match.group("sel")
        if f"{gate}(" in line and not line.startswith("static BOOL"):
            callers.add(enclosing)
    return callers


class WritePathTargetGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = POLICY.read_text(encoding="utf-8")
        cls.reader = READER.read_text(encoding="utf-8")

    def compatibility_sources(self):
        """The controller and the reader must agree; the daemon uses the reader."""
        return (("controller", self.source), ("reader", self.reader))

    @staticmethod
    def function_body(source: str, name: str) -> str:
        start = source.index(f"BOOL {name}(")
        return source[start : source.index("\n}\n", start)]

    def test_the_gate_is_named_for_the_invariant_it_records(self) -> None:
        """One gate, and not the unqualified name it had before the split.

        `CCNMValidateTarget` was a single gate over both kinds of write. The name
        survives as a prefix of `CCNMValidateTargetIdentity`, so the trailing
        parenthesis is load-bearing here.
        """
        self.assertNotIn("CCNMValidateTarget(", self.source)
        self.assertIn(f"static BOOL {WRITE_GATE}(", self.source)

    def test_the_replay_gate_is_gone_with_the_path_it_guarded(self) -> None:
        self.assertNotIn(RETIRED_REPLAY_GATE, self.source)
        self.assertNotIn(RETIRED_REPLAY_GATE, self.reader)
        # And so is the reviewed table it was gating, in either half.
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                self.assertNotIn("CCNMKnownOrphanHistorical", source)
                self.assertNotIn("CCNMKnownOrphanBandInfoMatches", source)

    def test_only_the_enable_path_is_gated_because_only_it_writes(self) -> None:
        self.assertEqual(gate_call_sites(self.source, WRITE_GATE), WRITE_CALLERS)
        # Exactly one call and one definition. A second call would mean a second
        # write path appeared without this file noticing.
        self.assertEqual(self.source.count(f"{WRITE_GATE}("), 2)

    def test_the_gate_runs_before_the_setter_is_reached(self) -> None:
        """Ordering, not just presence: a gate after the write decides nothing."""
        enable = self.source[self.source.index("- (NSDictionary *)performEnable"):]
        enable = enable[: enable.index("\n}\n")]
        self.assertIn(WRITE_GATE, enable)
        self.assertLess(enable.index(WRITE_GATE), enable.index("CCNMCreateClient"))
        self.assertLess(enable.index(WRITE_GATE), enable.index("CCNMBuildSelectedNRPayload"))
        self.assertIn("CCNMN78PolicyErrorUnsupportedTarget", enable)

    def test_identity_is_read_by_the_gate_not_taken_from_the_caller(self) -> None:
        """A baseline cannot be written without model, version, and build.

        CCNMBuildBaselineRecord refuses a baseline whose identity fields are
        empty, and an enable that cannot record a baseline must not reach the
        setter. So the gate judges locals it read itself rather than reading back
        out of the reporting dictionary, which a caller may pass as nil.
        """
        body = self.function_body(self.source, "CCNMValidateTargetIdentity")
        self.assertIn('CCNMSysctlString("hw.machine")', body)
        self.assertIn('CCNMSysctlString("kern.osversion")', body)
        self.assertIn("CCNMSystemVersionString()", body)
        self.assertIn("!model.length || !build.length || !version.length", body)
        # The verdict must not depend on the reporting dictionary, because the
        # signature permits nil there.
        self.assertNotIn('details[@"deviceModel"] length]', body)
        # Unreadable identity is the only refusal. The values themselves are
        # recorded as evidence, never compared against a list.
        self.assertIn("return YES;", body)
        self.assertIn("CCNMRecordDeviceIdentity(details, model, build, version);", body)
        self.assertNotIn("iPhone14,3", self.source)
        self.assertNotIn("19B81", self.source)

    def test_the_gate_adds_no_verdict_of_its_own(self) -> None:
        """It is a named wrapper, and the name is the point.

        Folding it into CCNMValidateTargetIdentity would lose the record that
        every write in this build is self-sourced, and lose the place a second
        gate belongs if a path that is not ever comes back.
        """
        body = self.function_body(self.source, WRITE_GATE)
        self.assertIn("return CCNMValidateTargetIdentity(details, failure);", body)
        self.assertNotIn("return NO", body)

    def test_identity_recording_renders_no_verdict(self) -> None:
        body = self.source[
            self.source.index("static void CCNMRecordDeviceIdentity") :
        ]
        body = body[: body.index("\n}\n")]
        self.assertNotIn("iPhone14,3", body)
        self.assertNotIn("19B81", body)
        self.assertNotIn("return NO", body)

    def test_a_baselines_active_nr_is_not_required_to_be_supported_nr(self) -> None:
        """The fixture is why, and it is real BandInfo from a real device.

        Its active NR array contains a band absent from its supported NR array,
        and the restore of that same baseline read back equal. So a validator that
        treated active NR as a subset of supported NR would reject a baseline the
        modem itself had already accepted.

        Nothing replays a baseline any more, but the baseline is still read: the
        daemon uses it to decide whether the policy it sees is the one this device
        established. Rejecting it there would make a valid enable look foreign.
        """
        evidence = json.loads(ORPHAN_FIXTURE.read_text(encoding="utf-8"))
        active_nr = set(evidence["originalActiveBands"]["kCTRegistrationRadioAccessTechnologyNR"])
        supported_nr = set(evidence["supportedBandsAtSelection"]["kCTRegistrationRadioAccessTechnologyNR"])
        self.assertTrue(active_nr - supported_nr)
        self.assertTrue(evidence["restoreReadBackEqual"])
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                validate = self.function_body(source, "CCNMValidateBaselineRecord")
                # Both dictionaries are shape-checked; neither is checked against
                # the other.
                self.assertIn('CCNMValidateBandDictionary(baseline[@"supportedBands"], failure)', validate)
                self.assertIn("CCNMValidateBandDictionary(bands, failure)", validate)
                self.assertNotIn("containsObject", validate)
                self.assertNotIn("FitCurrentCapability", validate)

    def test_the_two_baseline_validators_stay_identical(self) -> None:
        """The daemon reads through the reader, Settings through the controller.

        One file must not be legal policy evidence to one of them and a foreign
        file to the other, so the two copies are compared token by token rather
        than clause by clause.
        """
        def normalised(source: str) -> str:
            body = self.function_body(source, "CCNMValidateBaselineRecord")
            return re.sub(r"\s+", " ", body)

        self.assertEqual(normalised(self.source), normalised(self.reader))

    def test_baselines_without_capability_evidence_stay_readable(self) -> None:
        """Older baselines predate the capability snapshot and must stay usable.

        A baseline written before those fields existed is still the record of what
        this device established. Refusing it for lacking a field that did not
        exist when it was written would make an enable performed by an earlier
        version unrecognisable to this one.
        """
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                validate = self.function_body(source, "CCNMValidateBaselineRecord")
                self.assertIn(
                    "BOOL capabilitySnapshotValid = !hasCapabilitySnapshot ||", validate
                )
                # All-or-nothing: a partial snapshot is a malformed record, not an
                # old one, so the presence test names every field the branch then
                # requires.
                for field in ('"deviceModel"', '"systemVersion"', '"systemBuild"',
                              '"supportedBands"', '"modifiedBandKeys"'):
                    self.assertIn(field, validate)

    def test_the_retired_compatibility_check_left_no_stub_behind(self) -> None:
        """It compared a baseline against the live modem before replaying it.

        With no replay there is no write for it to guard, and an exported
        predicate with no caller reads as protection that is still running.
        """
        for name, source in self.compatibility_sources():
            with self.subTest(source=name):
                self.assertNotIn("CCNMValidateBaselineCompatibility", source)
                self.assertNotIn("CCNMBaselineNRBandsFitCurrentCapability", source)
        header = (REPO / "networkmanagerprefs/CCNMN78PolicyReader.h").read_text(encoding="utf-8")
        self.assertNotIn("CCNMValidateBaselineCompatibility", header)

    def test_the_error_code_it_produced_stays_mapped_for_older_state(self) -> None:
        """Retired producer, retained mapping, and the two are different things.

        1.5.0 shipped this code and persisted it into the state record's
        errorCode. A device upgrading from that state would otherwise be shown the
        generic failure string in place of the reason.
        """
        controller = self.source
        ui = (REPO / "networkmanagerprefs/CCNMRootListController.m").read_text(encoding="utf-8")
        support = (REPO / "networkmanagerprefs/CCNMN78PolicySupport.h").read_text(encoding="utf-8")
        implementation = (REPO / "networkmanagerprefs/CCNMN78PolicySupport.m").read_text(encoding="utf-8")
        for text in (support, implementation, ui):
            self.assertIn("CCNMN78PolicyErrorBaselineIncompatible", text)
        self.assertIn("POLICY_ERROR_BASELINE_INCOMPATIBLE", ui)
        # No producer left, and that is the assertion, not an omission.
        self.assertNotIn("CCNMN78PolicyErrorBaselineIncompatible", controller)


if __name__ == "__main__":
    unittest.main()
