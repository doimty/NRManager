#!/usr/bin/env python3
"""A version number must still identify exactly one package.

Every other version check compares the three in-repo literals against each other.
They all passed while 1.6.2 shipped twice with different contents, because
agreeing with each other is not the same as being unambiguous. This test compares
the release version against the record of what has already been delivered.

The rule is not "never reuse a delivered number". Immediately after a delivery the
tree legitimately holds the number it just shipped, and failing there would leave
the suite red for an ordinary reason, which is how a gate gets ignored. The rule is
that a delivered number must still point at the commit it was delivered from.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
LEDGER = REPO / "docs/delivered-packages.json"
sys.path.insert(0, str(REPO / "scripts"))

import verify_release_source  # noqa: E402


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def delivered_by_version() -> dict:
    return {entry["version"]: entry for entry in ledger()["delivered"]}


def version_tuple(version: str) -> tuple:
    return tuple(int(piece) for piece in version.split("."))


def head_commit() -> str:
    """The commit under test, or "" when git cannot answer.

    An unavailable git is reported as a skip rather than a pass: silently
    succeeding is the exact failure mode this file exists to remove.
    """
    try:
        completed = subprocess.run(
            ["git", "-C", str(REPO), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if completed.returncode != 0:
        return ""
    return completed.stdout.strip()


class DeliveredVersionLedgerTests(unittest.TestCase):
    def test_the_ledger_is_well_formed(self) -> None:
        data = ledger()
        self.assertEqual(data["schemaVersion"], 1)
        entries = data["delivered"]
        self.assertIsInstance(entries, list)
        self.assertTrue(entries, "an empty ledger silently disables this gate")

        seen: set = set()
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

    def test_a_delivered_version_still_points_at_its_delivered_commit(self) -> None:
        current = verify_release_source.RELEASE_VERSION
        entry = delivered_by_version().get(current)
        if entry is None:
            self.skipTest(f"{current} has not been delivered")

        head = head_commit()
        if not head:
            self.skipTest("git could not report HEAD")

        self.assertEqual(
            head,
            entry["sourceSha"],
            "version {0} was delivered from {1} (run {2}, package {3}), but HEAD is "
            "{4}. Two packages with different contents under one version number "
            "cannot be told apart on the device: the About row shows the same string "
            "for both, so device feedback cannot be attributed to a build. Bump the "
            "version.".format(
                current,
                entry["sourceSha"][:12],
                entry["runId"],
                entry["sha256"][:12],
                head[:12],
            ),
        )

    def test_the_release_version_never_moves_backward(self) -> None:
        # Absence from the ledger is not enough on its own: the ledger does not
        # claim to be complete for old releases, so an unrecorded older number
        # would otherwise pass unnoticed.
        highest = max(version_tuple(entry["version"]) for entry in ledger()["delivered"])
        self.assertGreaterEqual(
            version_tuple(verify_release_source.RELEASE_VERSION),
            highest,
            "the release version must not be below any delivered version",
        )

    def test_the_three_version_literals_still_agree(self) -> None:
        # The pre-existing invariant, asserted here too so this file fails as a
        # unit. A bump that misses one literal is red either way, and the two
        # failures name different causes.
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
