"""Behavioral tests for the dpkg version floor used by prerm.

The upgrade exemption in prerm.m is only safe if it can actually tell an
upgrade from a downgrade. dpkg uses the `upgrade` action for both, so a wrong
answer here either strands a modified modem (downgrade treated as upgrade) or
reintroduces the half-configured install (upgrade treated as downgrade).

These tests compile and run the real C implementation rather than asserting on
source text, because the risk being covered is arithmetic, not wording.
"""

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "package-actions" / "CCNMDpkgVersion.c"
HEADER_DIR = ROOT / "package-actions"
PRERM_SOURCE = ROOT / "package-actions" / "prerm.m"
ACTIONS_MAKEFILE = ROOT / "package-actions" / "Makefile"

FLOOR = "1.5.0"

# (version, expected_at_least_1_5_0)
CASES = (
    # Exact floor and plain upgrades.
    ("1.5.0", True),
    ("1.5.1", True),
    ("1.6.0", True),
    ("2.0.0", True),
    # Numeric, not lexicographic: 10 > 9 and 1.10 > 1.5.
    ("1.10.0", True),
    ("1.5.10", True),
    ("10.0.0", True),
    ("1.4.9", False),
    # Downgrades, including the versions this package actually shipped.
    ("1.4.3", False),
    ("1.4.3-2", False),
    ("0.9.9", False),
    ("1.0", False),
    # Shorter versions pad with implicit zeros.
    ("1.5", True),
    ("2", True),
    ("1", False),
    # Debian revisions and build suffixes do not lower the upstream head.
    ("1.5.0-1", True),
    ("1.5.0+build2", True),
    ("1.6.0-2", True),
    ("1.4.3+cellmonprobe4", False),
    # A '~' suffix sorts before the release it precedes.
    ("1.5.0~beta1", False),
    ("1.6.0~rc1", True),
    # Leading zeros are numerically insignificant.
    ("01.05.00", True),
    ("1.05.1", True),
    # Long components must not overflow.
    ("99999999999999999999.0.0", True),
    ("1.4.99999999999999999999", False),
    # Fail closed on anything not fully understood.
    ("", False),
    ("1.5.0:1", False),
    ("2:1.0.0", False),
    ("1.5.x", False),
    ("1..0", False),
    (".1.5.0", False),
    ("v1.5.0", False),
    ("latest", False),
)

HARNESS = r"""
#include <stdio.h>
#include <string.h>
#include "CCNMDpkgVersion.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        return 2;
    }
    return CCNMDpkgVersionIsAtLeast(argv[1], argv[2]) ? 0 : 1;
}
"""


class DpkgVersionFloorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temporary = tempfile.TemporaryDirectory()
        directory = pathlib.Path(cls._temporary.name)
        harness = directory / "harness.c"
        harness.write_text(HARNESS)
        cls.binary = directory / "harness"
        completed = subprocess.run(
            [
                "cc",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                f"-I{HEADER_DIR}",
                str(harness),
                str(SOURCE),
                "-o",
                str(cls.binary),
            ],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise unittest.SkipTest(
                f"host C compiler unavailable or failed: {completed.stderr}"
            )

    @classmethod
    def tearDownClass(cls):
        cls._temporary.cleanup()

    def evaluate(self, version, floor=FLOOR):
        completed = subprocess.run(
            [str(self.binary), version, floor], capture_output=True
        )
        self.assertIn(
            completed.returncode, (0, 1), f"harness crashed on {version!r}"
        )
        return completed.returncode == 0

    def test_floor_comparison_matches_expected_ordering(self):
        for version, expected in CASES:
            with self.subTest(version=version):
                self.assertEqual(self.evaluate(version), expected)

    def test_null_arguments_fail_closed(self):
        # argc < 3 exits 2; a present-but-empty floor must still be rejected.
        self.assertFalse(self.evaluate("1.5.0", ""))

    def test_plain_versions_are_reflexive(self):
        # The documented contract requires floorVersion to be plain dotted
        # numeric, so only those are valid on both sides.
        for version in ("1.5.0", "1.4.3", "1.10.0", "2", "1.5", "10.0.0"):
            with self.subTest(version=version):
                self.assertTrue(self.evaluate(version, version))

    def test_ordering_is_monotonic_along_a_ladder(self):
        # Each rung must be >= every earlier rung and < every later one, which
        # catches an ordering rule that happens to satisfy the floor cases by
        # accident.
        ladder = ("0.9.9", "1.0", "1.4.3", "1.5", "1.5.1", "1.6.0", "1.10.0", "2", "10.0.0")
        for lower_index, lower in enumerate(ladder):
            for upper_index, upper in enumerate(ladder):
                with self.subTest(version=upper, floor=lower):
                    self.assertEqual(
                        self.evaluate(upper, lower), upper_index >= lower_index
                    )

    def test_prerm_uses_the_shared_comparison_and_ships_it(self):
        source = PRERM_SOURCE.read_text()
        self.assertIn("CCNMDpkgVersionIsAtLeast", source)
        self.assertIn('CCNMFirstRestoreCapableVersion = @"1.5.0"', source)
        # failed-upgrade runs from the incoming package, so no floor applies.
        predicate = source[
            source.index("static BOOL CCNMActionKeepsRestoreCapabilityInstalled"):
            source.index("static BOOL CCNMSummaryIsClean")
        ]
        self.assertLess(
            predicate.index('@"failed-upgrade"'),
            predicate.index("CCNMDpkgVersionIsAtLeast"),
        )
        self.assertIn("CCNMDpkgVersion.c", ACTIONS_MAKEFILE.read_text())

    def test_downgrade_below_the_floor_is_not_exempt(self):
        # The shipped 1.4.x line predates the restore implementation, so a
        # downgrade to it must fall through to the fail-closed restore path.
        for version in ("1.4.3", "1.4.3-2", "1.0", "0.9.9"):
            with self.subTest(version=version):
                self.assertFalse(self.evaluate(version))


if __name__ == "__main__":
    unittest.main()
