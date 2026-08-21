#!/usr/bin/env python3
"""Host-side tests for the CI test-count gates.

The LiveCC workflow guards against a discovery or import error that silently
collects almost nothing and still exits zero. That guard was originally written
as an exact-count match, which turns every legitimately added test into a red
build: the literal sat at 100 while ``tests/`` had grown to 279, so the lane
failed on a commit that had nothing to do with it and the packaging job was
skipped.

These tests pin the shape that keeps the guard useful without making it a
maintenance tax: assert a floor, keep the floor at or below what discovery
actually collects, and never reintroduce the exact-count form.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
LIVECC_WORKFLOW = REPO / ".github/workflows/livecc-prototype.yml"

# Mirrors `python3 -m unittest discover -s <dir>` exactly: same start directory,
# same implicit top-level directory. Run out of process because discovery imports
# every module under <dir>, including this one, and because doing it in-process
# would mutate the import state of the suite currently running.
_COUNT_PROGRAM = (
    "import sys, unittest;"
    "print(unittest.TestLoader().discover(sys.argv[1]).countTestCases())"
)


def collected_test_count(start_dir: Path) -> int:
    """Count tests unittest would collect, without running them."""
    completed = subprocess.run(
        [sys.executable, "-c", _COUNT_PROGRAM, str(start_dir)],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )
    return int(completed.stdout.strip())


def pinned_floors(workflow_text: str) -> dict[str, int]:
    return {
        label: int(count)
        for count, label in re.findall(
            r"assert_test_floor\s+\"\$\w+\"\s+(\d+)\s+(\w+)", workflow_text
        )
    }


class LiveCCTestGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = LIVECC_WORKFLOW.read_text(encoding="utf-8")

    def test_gate_asserts_a_floor_not_an_exact_count(self) -> None:
        self.assertIn("assert_test_floor() {", self.workflow)
        self.assertIn("-lt", self.workflow)
        # The exact-count form is what broke this lane. A literal "Ran <N> tests"
        # equality check anywhere in the gate means adding a test breaks CI.
        self.assertNotRegex(self.workflow, r"grep -Eq '\^Ran \d+ tests in ")
        self.assertNotRegex(self.workflow, r"-eq\s+\$?\{?\w*count")

    def test_gate_reads_the_last_summary_line(self) -> None:
        """Two suites write to two logs, but a rerun can append to one.

        Taking the first match would let a stale earlier summary satisfy the
        floor for a later short run.
        """
        self.assertRegex(self.workflow, r"sed -n 's/\^Ran .*tail -n 1")

    def test_gate_rejects_a_missing_summary_line(self) -> None:
        """An import error produces no summary at all; empty must not pass."""
        self.assertRegex(self.workflow, r'if \[ -z "\$count" \]')

    def test_both_suites_are_gated(self) -> None:
        floors = pinned_floors(self.workflow)
        self.assertEqual(sorted(floors), ["livecc", "root"])

    def test_pinned_floors_are_at_or_below_what_discovery_collects(self) -> None:
        """The floor must never exceed reality.

        This is the assertion that would have caught the stale literal: it fails
        the moment a floor is raised past the suite it guards, or a suite shrinks
        below its floor, instead of leaving the workflow to discover it.
        """
        floors = pinned_floors(self.workflow)
        for label, start_dir in (
            ("livecc", REPO / "livecc/tests"),
            ("root", REPO / "tests"),
        ):
            with self.subTest(suite=label):
                collected = collected_test_count(start_dir)
                self.assertGreater(collected, 0)
                self.assertLessEqual(
                    floors[label],
                    collected,
                    f"{label} floor {floors[label]} exceeds the {collected} tests "
                    "discovery collects; lower the floor or restore the tests",
                )

    def test_job_name_does_not_advertise_a_stale_exact_count(self) -> None:
        floors = pinned_floors(self.workflow)
        name = re.search(r"name: LiveCC host gates \(([^)]*)\)", self.workflow)
        self.assertIsNotNone(name)
        label = name.group(1)
        self.assertIn(str(floors["root"]), label)
        self.assertIn(str(floors["livecc"]), label)


if __name__ == "__main__":
    unittest.main()
