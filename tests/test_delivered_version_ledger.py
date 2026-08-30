#!/usr/bin/env python3
"""A version number must still identify exactly one package.

Every other version check compares the three in-repo literals against each other.
They all passed while 1.6.2 shipped twice with different contents, because
agreeing with each other is not the same as being unambiguous. This test compares
the release version against the record of what has already been delivered.

The rule is not "never reuse a delivered number". Immediately after a delivery the
tree legitimately holds the number it just shipped, and failing there would leave
the suite red for an ordinary reason, which is how a gate gets ignored. The rule is
that a delivered number must still describe the same shipping source, so prose and
test commits are free and a source change is not.
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

import shipping_digest  # noqa: E402
import verify_release_source  # noqa: E402


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def delivered_by_version() -> dict:
    return {entry["version"]: entry for entry in ledger()["delivered"]}


def version_tuple(version: str) -> tuple:
    return tuple(int(piece) for piece in version.split("."))


class DeliveredVersionLedgerTests(unittest.TestCase):
    def test_the_ledger_is_well_formed(self) -> None:
        data = ledger()
        self.assertEqual(data["schemaVersion"], 2)
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
            self.assertRegex(entry["shippingDigest"], r"^[0-9a-f]{64}$", entry)
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$", entry)
            self.assertRegex(entry["runId"], r"^\d+$", entry)
            self.assertIsInstance(entry["sizeBytes"], int)
            self.assertGreater(entry["sizeBytes"], 0, entry)

    def test_a_delivered_version_still_describes_its_delivered_source(self) -> None:
        current = verify_release_source.RELEASE_VERSION
        entry = delivered_by_version().get(current)
        if entry is None:
            self.skipTest(f"{current} has not been delivered")

        actual = shipping_digest.digest(shipping_digest.shipping_files())
        self.assertEqual(
            actual,
            entry["shippingDigest"],
            "version {0} was delivered from shipping source {1} (commit {2}, run "
            "{3}, package {4}), but the tree now hashes to {5}. Two packages with "
            "different contents under one version number cannot be told apart on "
            "the device: the About row shows the same string for both, so device "
            "feedback cannot be attributed to a build. Bump the version.".format(
                current,
                entry["shippingDigest"][:12],
                entry["sourceSha"][:12],
                entry["runId"],
                entry["sha256"][:12],
                actual[:12],
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

    def test_the_shipping_digest_covers_what_reaches_the_package(self) -> None:
        # The digest is only meaningful if its scope is right. Excluding a source
        # directory would silently let a delivered version cover changed bytes.
        paths = set(shipping_digest.shipping_paths())
        for required in (
            "control",
            "Makefile",
            "CCNetworkManager.x",
            "layout/Library/LaunchDaemons/com.doimty.nrmanager.maintenance.plist",
            "networkmanagerprefs/Resources/Root.plist",
            "networkmanagerprefs/CCNMRootListController.m",
            "networkmanagerprefs/Resources/en.lproj/NetworkManagerPrefs.strings",
            "networkmanagerprefs/Resources/zh-Hans.lproj/NetworkManagerPrefs.strings",
            "maintenance-daemon/main.m",
            "package-actions/postinst.sh.in",
            "package-actions/prerm.sh.in",
            # The workflow selects the toolchain, so it changes the built bytes.
            ".github/workflows/build.yml",
        ):
            self.assertIn(required, paths, f"{required} must feed the digest")

        for excluded in (
            "progress.md",
            "README.md",
            "docs/delivered-packages.json",
            "tests/test_delivered_version_ledger.py",
            "scripts/verify_release_source.py",
            # A nested test tree is matched by shape, not by being listed.
            "livecc/tests/test_livecc_prototype.py",
        ):
            self.assertNotIn(excluded, paths, f"{excluded} must not feed the digest")

        # Inclusion is the default: a hypothetical new source path is covered
        # without editing the exclusion list.
        self.assertTrue(shipping_digest.is_shipping("newmodule/CCNMNewThing.m"))
        self.assertTrue(shipping_digest.is_shipping("newmodule/Makefile"))
        self.assertFalse(shipping_digest.is_shipping("docs/whatever.md"))
        self.assertFalse(shipping_digest.is_shipping("anywhere/tests/test_thing.py"))
        # A source file whose name merely contains "tests" is not a test tree.
        self.assertTrue(shipping_digest.is_shipping("networkmanagerprefs/CCNMTests.m"))

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
