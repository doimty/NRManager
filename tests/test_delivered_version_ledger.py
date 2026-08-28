#!/usr/bin/env python3
"""The version number must be new, not merely self-consistent.

Every existing version check compares the three in-repo literals against each
other. They all passed while 1.6.2 shipped twice with different contents, because
agreeing with each other is not the same as being unused. This test compares the
release version against the record of what has already been delivered.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
LEDGER = REPO / "docs/delivered-packages.json"
sys.path.insert(0, str(REPO / "scripts"))

import verify_release_source  # noqa: E402


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


class DeliveredVersionLedgerTests(unittest.TestCase):
    def test_the_ledger_is_well_formed(self) -> None:
        data = ledger()
        self.assertEqual(data["schemaVersion"], 1)
        entries = data["delivered"]
        self.assertIsInstance(entries, list)
        self.assertTrue(entries, "an empty ledger silently disables this gate")

        seen: set[str] = set()
        for entry in entries:
            version = entry["version"]
            self.assertRegex(version, r"^\d+\.\d+\.\d+$", entry)
            # A duplicate here would mean the very defect this file records has
            # happened again and been written down instead of caught.
            self.assertNotIn(version, seen, f"{version} is listed twice")
            seen.add(version)
            self.assertRegex(entry["sourceSha"], r"^[0-9a-f]{40}$", entry)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$", entry)
            self.assertRegex(entry["runId"], r"^\d+$", entry)
            self.assertIsInstance(entry["sizeBytes"], int)
            self.assertGreater(entry["sizeBytes"], 0, entry)

    def test_the_release_version_has_not_already_been_delivered(self) -> None:
        delivered = {entry["version"]: entry for entry in ledger()["delivered"]}
        current = verify_release_source.RELEASE_VERSION
        self.assertNotIn(
            current,
            delivered,
            "version {0} was already delivered as {1} (run {2}). Two packages with "
            "different contents under one version number cannot be told apart on "
            "the device: the About row shows the same string for both, so device "
            "feedback cannot be attributed to a build. Bump the version.".format(
                current,
                delivered.get(current, {}).get("sha256", "?")[:12],
                delivered.get(current, {}).get("runId", "?"),
            ),
        )

    def test_the_release_version_moves_forward(self) -> None:
        # Reusing a number below the high-water mark is the same failure as reusing
        # the highest one, and it is not caught by absence from the ledger alone,
        # because the ledger does not claim to be complete for old releases.
        def parts(version: str) -> tuple:
            return tuple(int(piece) for piece in version.split("."))

        highest = max(parts(entry["version"]) for entry in ledger()["delivered"])
        self.assertGreater(
            parts(verify_release_source.RELEASE_VERSION),
            highest,
            "the release version must be above every delivered version",
        )

    def test_the_three_version_literals_still_agree(self) -> None:
        # The pre-existing invariant, asserted here too so that this file fails as
        # a unit: a bump that updates the ledger check but misses one literal is a
        # red test either way, and the two failures name different causes.
        expected = verify_release_source.RELEASE_VERSION
        control = verify_release_source.read_control(REPO / "control")
        self.assertEqual(control["version"], expected)

        root_plist = (REPO / "networkmanagerprefs/Resources/Root.plist").read_text(
            encoding="utf-8"
        )
        match = re.search(
            r"<string>version</string>.*?<key>value</key>\s*<string>([^<]+)</string>",
            root_plist,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "no About version row in Root.plist")
        self.assertEqual(match.group(1), expected)


if __name__ == "__main__":
    unittest.main()
