"""Behavioral tests for the version floor prerm uses on an upgrade.

dpkg spells upgrade and downgrade with the same `upgrade` action and passes the
incoming version as the second argument, so prerm has to decide which one it is.
The stakes are asymmetric. Treating a downgrade as an upgrade hands a narrowed
modem to a version that cannot reload carrier defaults, leaving the user no
in-package way back. Treating an upgrade as a downgrade resets the modem on every
update, silently and repeatedly, while the policy records still claim the
configuration is applied.

The comparison is delegated to dpkg rather than reimplemented. This file
previously compiled a hand-written C comparator, which is the thing being retired:
the process asking the question is already running inside dpkg, and dpkg's own
ordering is the only answer that is correct for epochs, Debian revisions and `~`
suffixes. What is left to test is that prerm asks, that it asks the right
question, and that each answer routes to the right behaviour.
"""

import importlib.util
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PRERM_TEMPLATE = ROOT / "package-actions" / "prerm.sh.in"
CARRIER_INCLUDE = ROOT / "package-actions" / "carrier-reset.sh.inc"

_spec = importlib.util.spec_from_file_location(
    "patch_maintenance_launchd", ROOT / "scripts" / "patch-maintenance-launchd.py")
patcher = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(patcher)

FLOOR = patcher.CARRIER_RESET_FLOOR

# (version, is_at_or_above_the_floor). Every entry is a version this project
# either shipped or could plausibly be handed, and the expectations are dpkg's
# ordering, which the test below confirms against the real tool rather than
# trusting this table.
CASES = (
    # Exact floor and plain upgrades.
    (FLOOR, True),
    ("1.6.1", True),
    ("1.7.0", True),
    ("2.0.0", True),
    # Numeric, not lexicographic: 10 > 9 and 1.10 > 1.6.
    ("1.10.0", True),
    ("1.6.10", True),
    ("10.0.0", True),
    # Every version this package actually shipped before the reload existed.
    ("1.5.0", False),
    ("1.4.3", False),
    ("1.4.3-2", False),
    ("1.4.3+cellmonprobe4", False),
    ("0.9.9", False),
    # Debian revisions and build suffixes do not lower the upstream head.
    ("1.6.0-1", True),
    ("1.6.0+build2", True),
    # '~' sorts before the release it precedes, so a prerelease of the floor is
    # below the floor.
    ("1.6.0~beta1", False),
    ("1.7.0~rc1", True),
    # An epoch outranks everything without one.
    ("2:1.0.0", True),
)


@unittest.skipIf(shutil.which("dpkg") is None, "dpkg is not available")
class DpkgOrderingTests(unittest.TestCase):
    """The delegation target answers the way this project assumes it does.

    Not a test of dpkg. A test that the floor is meaningful under dpkg's ordering
    for the versions in play -- in particular that no shipped 1.4.x/1.5.x version
    is read as being at or above it.
    """

    def test_the_expectations_match_dpkg(self):
        for version, expected in CASES:
            with self.subTest(version=version):
                completed = subprocess.run(
                    ["dpkg", "--compare-versions", version, "ge", FLOOR])
                self.assertIn(completed.returncode, (0, 1), version)
                self.assertEqual(completed.returncode == 0, expected)

    def test_the_floor_is_reflexive_and_ordered(self):
        ladder = ("0.9.9", "1.4.3", "1.5.0", "1.6.0~rc1", FLOOR,
                  "1.6.1", "1.7.0", "1.10.0", "2.0.0")
        for lower_index, lower in enumerate(ladder):
            for upper_index, upper in enumerate(ladder):
                with self.subTest(version=upper, floor=lower):
                    completed = subprocess.run(
                        ["dpkg", "--compare-versions", upper, "ge", lower])
                    self.assertEqual(
                        completed.returncode == 0, upper_index >= lower_index)


class PrermVersionFloorTests(unittest.TestCase):
    """What the rendered prerm does with each answer.

    The script is exercised rather than pattern-matched: the routing is a chain of
    elif branches whose failure mode is taking the wrong one, and source text
    cannot show which branch ran.
    """

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.dpkg_log = self.dir / "dpkg.log"
        self.killall_log = self.dir / "killall.log"
        self.delay_candidates = DELAY_CANDIDATES
        # jbroot resolves to a directory the test owns, so both the killall
        # lookup and the record cleanup stay inside the fixture.
        self.prefix = self.dir / "jbroot"
        (self.prefix / "usr/bin").mkdir(parents=True)
        self.stub("jbroot", f'#!/bin/sh\nprintf "%s\\n" "{self.prefix}"\n')
        self.stub_at(self.prefix / "usr/bin/killall",
                     '#!/bin/sh\n'
                     f'printf "%s\\n" "$*" >> "{self.killall_log}"\nexit 0\n')

    def stub(self, name, body):
        self.stub_at(self.bin / name, body)

    def stub_at(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)

    def install_dpkg(self, verdict):
        """A dpkg stub that records the comparison and answers `verdict`.

        Deliberately not the real dpkg: this asserts the arguments prerm builds,
        and DpkgOrderingTests separately confirms the real tool agrees with the
        expectations those arguments are chosen against.
        """
        self.stub_at(
            self.prefix / "usr/bin/dpkg",
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.dpkg_log}"\n'
            f'exit {0 if verdict else 1}\n')

    def logged(self, path):
        if not path.exists():
            return []
        return [line for line in path.read_text().splitlines() if line]

    def render(self):
        staging = self.dir / "staging"
        patcher.render_maintainer_scripts(
            staging, ROOT / "package-actions", "roothide")
        script = staging / "DEBIAN" / "prerm"
        text = script.read_text()
        # The host's own /usr/bin/killall and /usr/bin/dpkg are real on a macOS or
        # Linux runner, and this test runs `killall -9 CommCenter`. Both bare
        # candidate lists are stripped so only the fixture's copies can be
        # reached. Asserted, not tolerated: a change to either shipped list fails
        # here rather than quietly letting the host binary back in.
        for bare in (BARE_KILLALL, BARE_DPKG):
            self.assertIn(bare, text)
            text = text.replace(bare, "    :", 1)
        # Same discipline for the delay candidates: assert the shipped list is
        # present, then substitute, so a rename fails here instead of silently
        # leaving the real /bin/sleep in place and making
        # test_an_unboundable_comparison a no-op that passes.
        self.assertIn(DELAY_CANDIDATES, text)
        text = text.replace(DELAY_CANDIDATES, self.delay_candidates, 1)
        script.write_text(text)
        script.chmod(0o755)
        return script

    def hide_delay_commands(self):
        """Make resolve_delay_command fail, without touching the host's /bin.

        The candidate list is fixed paths on purpose, so the only honest way to
        simulate its absence is to rewrite the rendered list.
        """
        self.delay_candidates = str(self.dir / "absent-sleep")

    def run_prerm(self, *args):
        script = self.render()
        return subprocess.run(
            [str(script), *args], capture_output=True, text=True, timeout=120,
            cwd=str(self.dir), env={"PATH": f"{self.bin}:/usr/bin:/bin"})

    def test_an_upgrade_to_a_supporting_version_resets_nothing(self):
        self.install_dpkg(verdict=True)
        result = self.run_prerm("upgrade", "1.7.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged(self.dpkg_log),
                         [f"--compare-versions 1.7.0 ge {FLOOR}"])
        self.assertEqual(self.logged(self.killall_log), [])
        self.assertIn("supports the carrier defaults reload", result.stderr)

    def test_a_downgrade_below_the_floor_reloads_carrier_defaults(self):
        # The asymmetric case. The target version cannot undo a narrowed modem,
        # so this is the last moment anything can.
        self.install_dpkg(verdict=False)
        result = self.run_prerm("upgrade", "1.5.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged(self.dpkg_log),
                         [f"--compare-versions 1.5.0 ge {FLOOR}"])
        self.assertEqual(self.logged(self.killall_log),
                         ["-9 CommCenter", "-9 CommCenter"])
        self.assertIn("predates the carrier defaults reload", result.stderr)

    def test_an_unanswerable_comparison_reloads_carrier_defaults(self):
        # Fails toward an un-narrowed modem. A reset the user did not need is
        # undone with one tap; a downgrade that skipped it is not.
        for label, version, expected in (
                ("no version", None, "dpkg named no incoming version"),
                ("no dpkg", "1.5.0", "no usable dpkg was found"),
        ):
            with self.subTest(case=label):
                self.setUp()
                if label != "no dpkg":
                    self.install_dpkg(verdict=True)
                args = ["upgrade"] + ([version] if version else [])
                result = self.run_prerm(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stderr)
                self.assertEqual(self.logged(self.killall_log),
                                 ["-9 CommCenter", "-9 CommCenter"])

    def test_an_unboundable_comparison_reloads_carrier_defaults(self):
        # No delay command means no child can be bounded, so the comparison
        # cannot be run at all. Distinct from a missing dpkg, and reported
        # separately, because the dpkg log has to say which one it was. The reset
        # itself is skipped for the same reason, so the warning is the only
        # outcome -- and this is the one fail-open path that cannot act on its
        # own conclusion.
        self.install_dpkg(verdict=True)
        self.hide_delay_commands()
        result = self.run_prerm("upgrade", "1.7.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged(self.dpkg_log), [])
        self.assertIn("no usable delay command", result.stderr)
        self.assertIn("could not be compared", result.stderr)
        self.assertIn("could not be bounded and was skipped", result.stderr)
        self.assertEqual(self.logged(self.killall_log), [])

    def test_remove_never_consults_the_floor(self):
        # There is no successor to compare against, and asking would be a way to
        # get a wrong answer on the one action whose meaning is unambiguous.
        self.install_dpkg(verdict=True)
        result = self.run_prerm("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.logged(self.dpkg_log), [])
        self.assertEqual(self.logged(self.killall_log),
                         ["-9 CommCenter", "-9 CommCenter"])

    def test_the_other_actions_reset_nothing_and_ask_nothing(self):
        # failed-upgrade runs from the incoming package and deconfigure leaves
        # this one unpacked. Neither is a retirement.
        for action in ("failed-upgrade", "deconfigure"):
            with self.subTest(action=action):
                self.setUp()
                self.install_dpkg(verdict=False)
                result = self.run_prerm(action, "1.5.0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.logged(self.dpkg_log), [])
                self.assertEqual(self.logged(self.killall_log), [])
                self.assertIn("keeps this package installed", result.stderr)

    def test_the_comparison_is_bounded_like_every_other_child(self):
        # dpkg is invoked through launchctl_run, so it inherits the descriptor
        # detach and the deadline. An unbounded child in a maintainer script is
        # what wedged the package manager on the reporting device.
        self.stub_at(self.prefix / "usr/bin/dpkg",
                     '#!/bin/sh\nwhile : ; do :; done\n')
        result = self.run_prerm("upgrade", "1.7.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        # A comparison that never answers is not an answer, so it takes the same
        # route as a missing dpkg.
        self.assertEqual(self.logged(self.killall_log),
                         ["-9 CommCenter", "-9 CommCenter"])


class VersionFloorSourceTests(unittest.TestCase):
    def test_the_floor_is_a_package_time_constant_not_the_current_version(self):
        # Read from the patcher, and deliberately not from `control`. Once 1.6.1
        # ships, a floor tracking the current version would make every
        # 1.6.1 -> 1.6.0 downgrade reset a modem 1.6.0 can undo perfectly well.
        self.assertRegex(FLOOR, r"^\d+\.\d+\.\d+$")
        self.assertIn("@CARRIER_RESET_FLOOR@", PRERM_TEMPLATE.read_text())
        self.assertIn("@CARRIER_RESET_FLOOR@",
                      patcher.REQUIRED_PLACEHOLDERS["prerm"])
        self.assertNotIn("@CARRIER_RESET_FLOOR@",
                         patcher.REQUIRED_PLACEHOLDERS["postinst"])

    def test_the_comparison_is_never_reimplemented_in_shell(self):
        # The retired mechanism. A hand-written comparator is what this file used
        # to test, and the failure mode was lexicographic ordering reading 1.10
        # as below 1.5.
        include = CARRIER_INCLUDE.read_text()
        self.assertIn("--compare-versions", include)
        for token in ("IFS=.", "expr ", "sort -V", "awk "):
            self.assertNotIn(token, include, token)

    def test_every_dpkg_call_goes_through_the_bounded_runner(self):
        include = CARRIER_INCLUDE.read_text()
        # Command position only. `[ -n "$DPKG_COMMAND" ]` names the variable
        # without running it, and demanding a bounded runner around a test is how
        # a test starts asserting its own phrasing instead of the behaviour.
        invocations = [line.strip() for line in include.splitlines()
                       if re.search(r'(^|[;&|]|\bthen\b|\bdo\b)\s*"\$DPKG_COMMAND"', line)
                       or re.search(r'bounded_run\s+"\$DPKG_COMMAND"', line)]
        self.assertTrue(invocations)
        for line in invocations:
            self.assertIn("bounded_run", line, line)

    def test_neither_reset_child_latches_on_launchd(self):
        # The bug this pins. launchctl_run sets LAUNCHCTL_STUCK on a deadline and
        # then short-circuits every later call, which is right for launchd -- one
        # unanswered request means none of the rest will answer -- and wrong for
        # anything else. Routed through it, a dpkg comparison that hung made both
        # killall invocations return 124 without running, so a removal silently
        # skipped the reset it had just decided to perform.
        #
        # Call sites only. The adapter documents this choice in prose, and a plain
        # substring search would match the comment explaining it.
        include = CARRIER_INCLUDE.read_text()
        code = [line.strip() for line in include.splitlines()
                if not line.lstrip().startswith("#")]
        self.assertEqual([line for line in code if "launchctl_run" in line], [])
        for child in ('"$DPKG_COMMAND"', '"$CARRIER_KILLALL"'):
            self.assertTrue(any(f"bounded_run {child}" in line for line in code),
                            child)

    def test_the_latch_still_guards_launchd_itself(self):
        # The other half: bounded_run must not have taken the latch with it.
        # launchctl calls make up to six requests in a row, and bounding each one
        # separately still lets an unresponsive launchd cost six deadlines.
        launchctl = (ROOT / "package-actions" / "launchctl.sh.inc").read_text()
        self.assertIn("LAUNCHCTL_STUCK=1", launchctl)
        body = launchctl[launchctl.index("launchctl_run() {"):]
        body = body[:body.index("\n}")]
        self.assertIn("LAUNCHCTL_STUCK", body)
        self.assertIn("bounded_run", body)

    def test_the_comparison_needs_a_bounded_runner_before_it_is_trusted(self):
        # The bug this pins: version_is_at_least goes through bounded_run, which
        # returns 125 when no delay command was resolved. A caller that reads that
        # 125 as an ordering answer concludes "below the floor" and resets the
        # modem on every ordinary upgrade.
        template = PRERM_TEMPLATE.read_text()
        resolve = template.index("resolve_delay_command")
        self.assertLess(resolve, template.index("version_is_at_least"),
                        "the delay command must be resolved before the comparison")
        self.assertLess(resolve, template.index("carrier_reset_defaults"),
                        "the delay command must be resolved before the reset")


def _bare_list(include_text, marker):
    """The candidate block for one tool, exactly as shipped.

    Extracted rather than duplicated so the neutralisation in render() cannot
    drift from the list it is meant to strip.
    """
    start = include_text.index(marker)
    start = include_text.rindex("    printf '%s\\n' \\", 0, start)
    end = include_text.index("\n\n", start)
    block = include_text[start:end]
    # Stop at the first line that is not part of the bare list.
    lines = []
    for line in block.splitlines():
        if lines and not line.startswith("        /"):
            break
        lines.append(line)
    return "\n".join(lines)


_INCLUDE = CARRIER_INCLUDE.read_text()
BARE_KILLALL = _bare_list(_INCLUDE, "/usr/bin/killall")
BARE_DPKG = _bare_list(_INCLUDE, "/usr/bin/dpkg")
# The shipped delay candidates, as one `for` list, so hide_delay_commands can
# replace them with a path that does not exist. Read from the include rather than
# retyped, for the same reason as the bare lists above.
DELAY_CANDIDATES = "/bin/sleep /usr/bin/sleep"
assert DELAY_CANDIDATES in pathlib.Path(
    ROOT / "package-actions" / "launchctl.sh.inc").read_text(), (
    "the shipped delay candidate list changed; update DELAY_CANDIDATES")


if __name__ == "__main__":
    unittest.main()
