#!/usr/bin/env python3
"""Behavioural tests for the shell maintainer scripts.

These render the real templates the way scripts/patch-maintenance-launchd.py
does and run them through /bin/sh with a stubbed jbroot, so prefix resolution,
the exports and every diagnostic branch are executed rather than asserted
against source text.

Why the maintainer scripts are shell at all: on roothide the jbroot path
redirection and the sandbox exemption both come from basebin/bootstrap.dylib,
injected via DYLD_INSERT_LIBRARIES. A compiled maintainer script on the
reporting device ran as euid 0 and could stat, read and parse inside the
jailbreak root but got EPERM on every write and child exec, and saw bare paths
as ENOENT. The shell half therefore owns everything that depends on being the
redirected process: resolving the jailbreak root and handing it to a helper that
is not redirected.

What these tests no longer cover, deliberately: postinst used to substitute an
@JBROOT@ placeholder in the launchd plist with the live jailbreak root. That was
wrong on roothide -- launchctl prepends the root itself, so the result was a
doubled path -- and the plist now ships complete. The substitution needed plutil,
a textual sed over a possibly-binary plist, and three-valued grep handling, and
every one of those was a way to corrupt the file or skip it silently. They are
gone with the mechanism that needed them, and one test below asserts the
dependency is really gone rather than merely unused.
"""

import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "patch_maintenance_launchd", REPO / "scripts" / "patch-maintenance-launchd.py")
patcher = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(patcher)

POSTINST_TEMPLATE = REPO / "package-actions" / "postinst.sh.in"
PRERM_TEMPLATE = REPO / "package-actions" / "prerm.sh.in"
LABEL = "me.nixuge.networkmanager.maintenance"
PLIST_RELATIVE = f"Library/LaunchDaemons/{LABEL}.plist"


# The substitution mechanism this build retired, and the three tools it needed.
# Matched on word boundaries: a plain substring test for "sed " also matches the
# middle of "used ", which made an earlier version of this assertion pass for a
# reason that had nothing to do with the template.
RETIRED_TOOLS = re.compile(r"\b(plutil|sed|grep)\b")
RETIRED_PLACEHOLDER = "@JBROOT@"


def assertRetiredToolsAbsent(case, template):
    """Fail if a template names @JBROOT@ or any tool the substitution needed.

    Only the executable body is examined. The header comments deliberately
    explain why plutil, sed and grep are gone, and that prose is worth keeping.
    """
    text = template.read_text()
    body = text[text.index("SCHEME_PREFIX="):]
    case.assertNotIn(RETIRED_PLACEHOLDER, body, template.name)
    for line in body.splitlines():
        code = line.split("#", 1)[0]
        found = RETIRED_TOOLS.search(code)
        case.assertIsNone(
            found, f"{template.name} still reaches for {found.group(0) if found else ''}: {line}")


def staged_plist(prefix):
    """The plist as the packaging step leaves it: prefix already applied."""
    return {
        "Label": LABEL,
        "ProgramArguments": [
            prefix + patcher.PROGRAM_RELATIVE,
            "--daemon",
        ],
        "KeepAlive": {
            "PathState": {prefix + patcher.BASELINE_RELATIVE: True}
        },
        "UserName": "root",
        "EnvironmentVariables": {"DISABLE_TWEAKS": "1"},
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
        "ProcessType": "Background",
        "ThrottleInterval": 1,
    }


class ShellScriptBase(unittest.TestCase):
    template = POSTINST_TEMPLATE
    guard_name = "networkmanager-install-guard"
    scheme = "roothide"

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        # The jailbreak root the stubbed jbroot reports. For the rootless lane
        # this doubles as the fixed install prefix.
        self.prefix = self.dir / "root"
        self.bin = self.dir / "bin"
        for path in (self.bin, self.prefix / "Library/LaunchDaemons",
                     self.prefix / "usr/libexec",
                     self.prefix / "var/lib/dpkg/info"):
            path.mkdir(parents=True, exist_ok=True)
        self.set_jbroot(str(self.prefix))
        self.guard_log = self.dir / "guard.log"
        self.install_guard(0)
        self.plist = self.prefix / PLIST_RELATIVE
        # Binary, because Theos converts every staged plist in its FINALPACKAGE
        # internal-package step, which runs after before-package. This is the
        # shape that actually reaches the device.
        self.write_plist(staged_plist(self.plist_prefix()), binary=True)

    def plist_prefix(self):
        """The lane's real plist prefix, independent of the temporary tree.

        Not repointed for rootless the way SCHEME_PREFIX is: this value is a
        package-time constant that must not depend on the host, and postinst no
        longer reads the plist at all, so its contents and its location are
        genuinely independent here.
        """
        return "" if self.scheme == "roothide" else patcher.ROOTLESS_PREFIX

    def set_jbroot(self, value):
        if value is None:
            self.stub("jbroot", "#!/bin/sh\nexit 1\n")
        else:
            self.stub("jbroot", f'#!/bin/sh\nprintf "%s\\n" "{value}${{1:-}}"\n')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def install_guard(self, exit_code, body=None):
        path = self.prefix / "usr/libexec" / self.guard_name
        path.write_text(body or (
            f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.guard_log}"\n'
            f'exit {exit_code}\n'))
        path.chmod(0o755)
        return path

    def install_env_reporting_guard(self):
        """A guard that reports what the shell handed it, set-ness included.

        `${VAR-absent}` distinguishes unset from empty, which is the whole point
        of the contract: an empty *launchd* prefix is the correct roothide answer,
        while an absent *install* prefix means nothing resolved and the guard must
        fail closed rather than read the wrong root.
        """
        return self.install_guard(0, body=(
            '#!/bin/sh\n'
            f'{{\n'
            f'  printf "install=%s\\n" "${{NETWORKMANAGER_INSTALL_PREFIX-absent}}"\n'
            f'  printf "launchd=%s\\n" "${{NETWORKMANAGER_LAUNCHD_PREFIX-absent}}"\n'
            f'}} >> "{self.guard_log}"\n'
            'exit 0\n'))

    def guard_environment(self):
        report = {}
        for line in self.guard_log.read_text().splitlines():
            key, _, value = line.partition("=")
            report[key] = value
        return report

    def write_plist(self, payload, binary=True):
        fmt = plistlib.FMT_BINARY if binary else plistlib.FMT_XML
        self.plist.write_bytes(plistlib.dumps(payload, fmt=fmt))
        os.chmod(self.plist, 0o644)

    def read_plist(self):
        return plistlib.loads(self.plist.read_bytes())

    def render(self, repoint_primary=False):
        """Render exactly as the packaging step does, then return the path.

        Two documented harness substitutions, both of data lines only, never of
        logic, and both asserted so a template rename cannot silently turn this
        into a no-op:

        - The rootless lane's fixed prefix is /var/jb and a test may not create
          that on the host, so SCHEME_PREFIX is repointed at the temporary tree.
        - repoint_primary makes the roothide lane's *bare* candidate resolve,
          which on a real redirected device it does and on this host it cannot.
          Needed to reach the branch where the bare path resolves but jbroot
          fails.
        """
        staging = self.dir / "staging"
        (staging / "DEBIAN").mkdir(parents=True, exist_ok=True)
        patcher.render_maintainer_scripts(
            staging, REPO / "package-actions", self.scheme)
        name = "postinst" if self.template == POSTINST_TEMPLATE else "prerm"
        script = staging / "DEBIAN" / name
        if self.scheme == "rootless":
            text = script.read_text()
            needle = f"SCHEME_PREFIX='{patcher.ROOTLESS_PREFIX}'"
            self.assertIn(needle, text)
            script.write_text(text.replace(
                needle, f"SCHEME_PREFIX='{self.prefix}'"))
            script.chmod(0o755)
        if repoint_primary:
            text = script.read_text()
            needle = "    PREFIX_PRIMARY=''\n"
            self.assertIn(needle, text)
            script.write_text(text.replace(
                needle, f"    PREFIX_PRIMARY='{self.prefix}'\n", 1))
            script.chmod(0o755)
        return script

    def run_script(self, *args, path_extra=None, cwd=None, repoint_primary=False):
        script = self.render(repoint_primary=repoint_primary)
        env = dict(os.environ)
        env["PATH"] = f"{path_extra or self.bin}:{env['PATH']}"
        return subprocess.run([str(script), *args], capture_output=True,
                              text=True, env=env, cwd=cwd)

    def assertNoWarning(self, result):
        self.assertNotIn("warning —", result.stderr)


class RenderingTests(unittest.TestCase):
    def test_the_roothide_plist_prefix_is_empty_and_rootless_is_var_jb(self):
        # The roothide plist must hold bare paths: launchctl is a redirected
        # binary that rewrites every absolute path in the file as jbroot(path)
        # before launchd sees it, guarding re-entry only with a __Patched flag it
        # sets itself. A plist already carrying the root gets a second one, which
        # is the doubled program path the reporting device showed.
        self.assertEqual(patcher.plist_prefix("roothide"), "")
        self.assertEqual(patcher.script_prefix("roothide"), "")
        self.assertEqual(patcher.plist_prefix("rootless"), "/var/jb")
        self.assertEqual(patcher.script_prefix("rootless"), "/var/jb")

    def test_rendering_leaves_no_placeholder_and_marks_the_scripts_executable(self):
        for scheme in ("roothide", "rootless"):
            with tempfile.TemporaryDirectory() as directory:
                staging = pathlib.Path(directory)
                written = patcher.render_maintainer_scripts(
                    staging, REPO / "package-actions", scheme)
                self.assertEqual([path.name for path in written],
                                 ["postinst", "prerm"])
                for path in written:
                    text = path.read_text()
                    for placeholder in ("@PREFIX@", "@LAUNCHD_PREFIX@",
                                        "@NEEDS_JBROOT@"):
                        self.assertNotIn(placeholder, text)
                    self.assertTrue(text.startswith("#!/bin/sh\n"))
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)

    def test_the_staged_plist_carries_the_lane_prefix_and_no_sentinel(self):
        for scheme, expected in (("roothide", ""), ("rootless", "/var/jb")):
            with self.subTest(scheme=scheme):
                with tempfile.TemporaryDirectory() as directory:
                    staging = pathlib.Path(directory)
                    target = staging / patcher.PLIST_RELATIVE
                    target.parent.mkdir(parents=True)
                    shutil.copy(
                        REPO / "layout" / patcher.PLIST_RELATIVE, target)
                    patcher.patch_launchd_plist(
                        staging, patcher.plist_prefix(scheme))
                    raw = target.read_bytes()
                    # Nothing on the device rewrites this file any more, so an
                    # unresolved token would be permanent.
                    self.assertNotIn(patcher.TEMPLATE_SENTINEL.encode(), raw)
                    self.assertNotIn(patcher.ROOTHIDE_PLACEHOLDER.encode(), raw)
                    payload = plistlib.loads(raw)
                    self.assertEqual(payload["ProgramArguments"][0],
                                     expected + patcher.PROGRAM_RELATIVE)
                    self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                                     [expected + patcher.BASELINE_RELATIVE])

    def test_a_sentinel_that_survives_patching_is_refused(self):
        # The patcher rewrites both path-bearing keys wholesale, so this can only
        # fire if a future template grows a third path. Failing the build is the
        # point: there is no device-side step left to repair it.
        with tempfile.TemporaryDirectory() as directory:
            staging = pathlib.Path(directory)
            target = staging / patcher.PLIST_RELATIVE
            target.parent.mkdir(parents=True)
            payload = staged_plist("")
            payload["WorkingDirectory"] = (
                patcher.TEMPLATE_SENTINEL + "/usr/libexec")
            target.write_bytes(plistlib.dumps(payload))
            with self.assertRaises(SystemExit) as raised:
                patcher.patch_launchd_plist(staging, "")
            self.assertIn(patcher.TEMPLATE_SENTINEL, str(raised.exception))


class PostinstLaunchdPlistTests(ShellScriptBase):
    def test_the_shipped_plist_is_left_exactly_as_packaged(self):
        # The whole rewrite is gone. postinst touching this file at all is the
        # regression: on roothide the correct contents are the bare paths that
        # shipped, and launchctl supplies the root on load.
        before = self.plist.read_bytes()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertEqual(self.plist.stat().st_mode & 0o777, 0o644)
        payload = self.read_plist()
        self.assertEqual(payload["ProgramArguments"][0],
                         patcher.PROGRAM_RELATIVE)
        self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                         [patcher.BASELINE_RELATIVE])

    def test_no_scratch_file_is_left_beside_the_plist(self):
        self.run_script("configure")
        siblings = sorted(p.name for p in self.plist.parent.iterdir())
        self.assertEqual(siblings, [f"{LABEL}.plist"], siblings)

    def test_running_twice_is_a_no_op(self):
        # dpkg reruns postinst on reconfigure and on a repeated install.
        self.run_script("configure")
        first = self.plist.read_bytes()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plist.read_bytes(), first)
        self.assertNoWarning(result)

    def test_a_binary_plist_needs_no_plutil_grep_or_sed(self):
        # Three separate portability traps, all retired with the substitution.
        # plutil is absent on some bootstraps; the grep on the macOS runners
        # reports no match for a pattern demonstrably present in a binary plist,
        # and "no match" was the success branch; and sed rewriting a longer path
        # into a length-prefixed binary string leaves the offset table stale, so
        # launchd cannot parse the file while every later check passes.
        self.assertEqual(self.plist.read_bytes()[:8], b"bplist00")
        for tool in ("plutil", "grep", "sed"):
            self.stub(tool, f'#!/bin/sh\necho "{tool} must not be used" >&2\nexit 99\n')
        before = self.plist.read_bytes()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertNotIn("must not be used", result.stderr)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertTrue(self.guard_log.exists())

    def test_the_template_does_not_reach_for_those_tools_at_all(self):
        # The stub test above proves they are not reached on the happy path. This
        # proves they are not named anywhere, so no diagnostic branch can bring
        # the dependency back in.
        assertRetiredToolsAbsent(self, POSTINST_TEMPLATE)


class PostinstPrefixHandoffTests(ShellScriptBase):
    def test_the_prefixes_are_handed_to_the_guard(self):
        # The guard cannot re-derive these: it is invoked through a bare path, so
        # its own executable path carries no jbroot component. Executed rather
        # than asserted against source text, because export ordering, quoting and
        # set-ness are exactly what a source-text check cannot prove.
        self.install_env_reporting_guard()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = self.guard_environment()
        # The install prefix is a filesystem root for a process nothing
        # redirects, so it must be the real jailbreak root. On this host the bare
        # path cannot exist, so the jbroot fallback wins.
        self.assertEqual(environment["install"], str(self.prefix))
        # The launchd prefix is a different question -- what must literally
        # appear inside the plist -- and empty is the roothide answer. Empty, not
        # absent: absent would mean the script never said.
        self.assertEqual(environment["launchd"], "")

    def test_the_launchd_prefix_matches_what_was_written_into_the_plist(self):
        # One value, two consumers. If these diverge the guard rejects a plist
        # that is actually correct, or accepts one launchd cannot start.
        self.install_env_reporting_guard()
        self.run_script("configure")
        launchd = self.guard_environment()["launchd"]
        payload = self.read_plist()
        self.assertEqual(payload["ProgramArguments"][0],
                         launchd + patcher.PROGRAM_RELATIVE)
        self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                         [launchd + patcher.BASELINE_RELATIVE])

    def test_the_install_prefix_is_reported(self):
        # Which prefix the maintainer-script shell actually sees is the open
        # question this build answers, so it has to appear in the install log.
        result = self.run_script("configure")
        self.assertIn("handing the guard install prefix", result.stderr)
        self.assertIn(str(self.prefix), result.stderr)

    def test_a_trailing_slash_is_normalised_not_rejected(self):
        # roothide's own jbroot takes an optional argument and can return a value
        # with a trailing separator. Rejecting that would be a false negative;
        # passing it through verbatim would hand the guard a doubled separator.
        self.install_env_reporting_guard()
        self.stub("jbroot", f'#!/bin/sh\nprintf "%s/\\n" "{self.prefix}"\n')
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertEqual(self.guard_environment()["install"], str(self.prefix))

    def test_an_unusable_jbroot_leaves_the_install_prefix_unset(self):
        # The branch that matters on a device where the bare path resolves but
        # jbroot does not: the guard must be told nothing rather than be handed a
        # prefix that would send every policy read to the wrong root. Absent, not
        # empty, because the guard reads those differently and "absent" is what
        # makes it fail closed.
        self.install_env_reporting_guard()
        self.set_jbroot(None)
        result = self.run_script("configure", repoint_primary=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not be resolved", result.stderr)
        self.assertIn("jbroot produced no output", result.stderr)
        environment = self.guard_environment()
        self.assertEqual(environment["install"], "absent")
        # The launchd prefix does not depend on the device at all, so it is still
        # a real answer.
        self.assertEqual(environment["launchd"], "")

    def test_an_implausible_jbroot_is_never_handed_over(self):
        # jbroot's output is an external input. A non-empty but implausible value
        # must not become a prefix: the guard would read a root that does not
        # exist, find no policy records, and "absent" is indistinguishable from a
        # clean band configuration -- the one conclusion the removal gate exists
        # to refuse to reach by accident.
        cases = {
            "relative path": ('#!/bin/sh\nprintf "relative/root\\n"\n',
                              "relative path"),
            "two lines": ('#!/bin/sh\nprintf "/a\\n/b\\n"\n',
                          "more than one line"),
            "not a directory": ('#!/bin/sh\nprintf "%s\\n" "$0"\n',
                                "not a directory"),
        }
        for label, (stub, reason) in cases.items():
            with self.subTest(case=label):
                self.guard_log.unlink(missing_ok=True)
                self.install_env_reporting_guard()
                self.stub("jbroot", stub)
                result = self.run_script("configure", repoint_primary=True)
                self.assertIn(reason, result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.guard_environment()["install"], "absent")

    def test_the_bare_prefix_is_tried_before_the_jbroot_prefix(self):
        script = self.render().read_text()
        primary = script.index("PREFIX_PRIMARY=''")
        fallback = script.index('PREFIX_FALLBACK="$JBROOT_PREFIX"')
        self.assertLess(primary, fallback)
        # And the resolver must consult primary first.
        resolver = script.index("resolve() {")
        self.assertLess(resolver, script.index('${PREFIX_FALLBACK}${_relative}'))
        self.assertLess(script.index('${PREFIX_PRIMARY}${_relative}'),
                        script.index('${PREFIX_FALLBACK}${_relative}'))


class PostinstRootlessTests(ShellScriptBase):
    scheme = "rootless"

    def test_the_rootless_lane_does_not_depend_on_jbroot(self):
        # The prefix is baked in at package time and jbroot does not exist on
        # that platform, so the script must not depend on it. This is also the
        # only lane where the primary prefix is a real path, so it covers the
        # primary branch of the resolver.
        (self.bin / "jbroot").unlink()
        before = self.plist.read_bytes()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn(str(self.prefix), result.stderr)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertTrue(self.guard_log.exists())

    def test_the_launchd_prefix_is_the_lane_constant_not_the_install_prefix(self):
        # No jbroot on this platform, so the install prefix is the baked-in one.
        # The launchd prefix is a different question and here it is a real path:
        # nothing on rootless rewrites the plist, so /var/jb has to be inside it.
        #
        # These two differ in this test only because the harness repoints
        # SCHEME_PREFIX at a temporary tree and deliberately leaves the launchd
        # prefix alone, which is what makes the separation observable at all.
        (self.bin / "jbroot").unlink()
        self.install_env_reporting_guard()
        self.run_script("configure")
        environment = self.guard_environment()
        self.assertEqual(environment["install"], str(self.prefix))
        self.assertEqual(environment["launchd"], patcher.ROOTLESS_PREFIX)
        # And what was handed over still describes the plist that shipped.
        payload = self.read_plist()
        self.assertEqual(payload["ProgramArguments"][0],
                         environment["launchd"] + patcher.PROGRAM_RELATIVE)
        self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                         [environment["launchd"] + patcher.BASELINE_RELATIVE])


class PostinstGuardDelegationTests(ShellScriptBase):
    def test_the_guard_receives_the_dpkg_arguments(self):
        self.run_script("configure", "1.4.3")
        self.assertEqual(self.guard_log.read_text().strip(), "configure 1.4.3")

    def test_the_guard_exit_code_is_propagated(self):
        self.install_guard(74)
        self.assertEqual(self.run_script("configure").returncode, 74)

    def test_a_missing_guard_is_reported_without_failing_the_install(self):
        (self.prefix / "usr/libexec" / self.guard_name).unlink()
        result = self.run_script("configure")
        self.assertIn("install guard was not found under", result.stderr)
        self.assertIn("the redirected root (bare paths)", result.stderr)
        self.assertIn(str(self.prefix), result.stderr)
        self.assertEqual(result.returncode, 0)

    def test_the_plist_survives_a_rejecting_guard(self):
        # The plist is what makes the job loadable at the next boot, so a policy
        # verdict must not affect it either way.
        self.install_guard(74)
        before = self.plist.read_bytes()
        self.assertEqual(self.run_script("configure").returncode, 74)
        self.assertEqual(self.plist.read_bytes(), before)


class PrermTests(ShellScriptBase):
    template = PRERM_TEMPLATE
    guard_name = "networkmanager-removal-guard"

    def test_a_clean_guard_verdict_allows_removal(self):
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.guard_log.read_text().strip(), "remove")

    def test_the_removal_guard_also_receives_both_prefixes(self):
        # Removal is the fail-closed direction: a guard that read the wrong root
        # would report a clean policy state and authorize removal while a forced
        # band configuration is still applied.
        self.install_env_reporting_guard()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = self.guard_environment()
        self.assertEqual(environment["install"], str(self.prefix))
        self.assertNotEqual(environment["install"], "absent")
        self.assertEqual(environment["launchd"], "")
        self.assertNotEqual(environment["launchd"], "absent")

    def test_an_unusable_jbroot_leaves_the_install_prefix_unset(self):
        # Removal is where this matters most, so the reason has to be in the dpkg
        # log beside the block the guard is about to produce.
        self.install_env_reporting_guard()
        self.set_jbroot(None)
        result = self.run_script("remove", repoint_primary=True)
        self.assertIn("could not be resolved", result.stderr)
        self.assertIn("jbroot produced no output", result.stderr)
        self.assertEqual(self.guard_environment()["install"], "absent")

    def test_a_blocking_guard_verdict_is_propagated(self):
        self.install_guard(73)
        self.assertEqual(self.run_script("remove").returncode, 73)

    def test_a_missing_guard_blocks_removal_fail_closed(self):
        # A forced NR configuration must not be left behind with no installed
        # way to restore it, so an absent guard is not an implicit approval.
        (self.prefix / "usr/libexec" / self.guard_name).unlink()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 73)
        self.assertIn("removal blocked", result.stderr)
        self.assertIn("was not found under", result.stderr)
        self.assertIn("to override", result.stderr)

    def test_an_unstartable_guard_is_not_read_as_a_verdict(self):
        # 126/127 are the shell's own refusal codes, not the guard's answer.
        for label in ("not executable", "bad interpreter"):
            with self.subTest(case=label):
                guard = self.install_guard(0)
                if label == "not executable":
                    guard.chmod(0o644)
                else:
                    guard.write_text("#!/nonexistent/interpreter\n")
                    guard.chmod(0o755)
                result = self.run_script("remove")
                self.assertEqual(result.returncode, 73, result.stderr)
                self.assertIn("could not be started", result.stderr)
                self.assertIn("to override", result.stderr)

    def test_the_override_path_is_named_so_removal_cannot_deadlock(self):
        self.install_guard(0).chmod(0o644)
        result = self.run_script("remove")
        self.assertIn("var/lib/dpkg/info/me.nixuge.networkmanager.prerm",
                      result.stderr)

    def test_the_override_path_is_named_under_the_prefix_that_holds_it(self):
        # dpkg's info directory lives inside the jailbreak root. A bare path is
        # only correct for a redirected shell, and the user reading this message
        # is already blocked, so the message has to name a path that exists.
        override = self.prefix / "var/lib/dpkg/info/me.nixuge.networkmanager.prerm"
        override.write_text("#!/bin/sh\nexit 0\n")
        (self.prefix / "usr/libexec" / self.guard_name).unlink()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 73)
        self.assertIn(f"delete {override} and retry", result.stderr)

    def test_an_unfindable_override_names_every_candidate(self):
        # Nothing resolved, so neither candidate can be confirmed. Naming only
        # one would send the user to a path that does not exist.
        (self.prefix / "usr/libexec" / self.guard_name).unlink()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 73)
        self.assertIn("/var/lib/dpkg/info/me.nixuge.networkmanager.prerm or "
                      f"{self.prefix}/var/lib/dpkg/info/me.nixuge.networkmanager.prerm",
                      result.stderr)

    def test_an_implausible_jbroot_cannot_supply_the_guard_that_authorises_removal(self):
        # The fail-closed direction, and the reason prerm validates jbroot too.
        # A relative jbroot resolves against the current directory, which dpkg
        # does not guarantee. Any binary found that way would be answering the
        # one question this gate exists to answer, so it must not be consulted at
        # all: rejecting the value leaves PREFIX_FALLBACK empty and the removal
        # blocks, which is the correct conservative outcome.
        elsewhere = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, elsewhere, ignore_errors=True)
        stale = elsewhere / "relative/root/usr/libexec" / self.guard_name
        stale.parent.mkdir(parents=True)
        stale.write_text("#!/bin/sh\nexit 0\n")   # would authorise removal
        stale.chmod(0o755)

        (self.prefix / "usr/libexec" / self.guard_name).unlink()
        self.stub("jbroot", '#!/bin/sh\nprintf "relative/root\\n"\n')
        result = self.run_script("remove", cwd=str(elsewhere))

        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn("removal blocked", result.stderr)
        self.assertIn("relative path", result.stderr)
        self.assertIn("to override", result.stderr)


class TemplateContractTests(unittest.TestCase):
    def test_both_templates_carry_every_placeholder_the_patcher_fills(self):
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            text = template.read_text()
            self.assertTrue(text.startswith("#!/bin/sh\n"), template.name)
            for placeholder in ("@PREFIX@", "@LAUNCHD_PREFIX@", "@NEEDS_JBROOT@"):
                self.assertIn(placeholder, text, template.name)
            self.assertIn("jbroot", text, template.name)

    def test_neither_template_substitutes_anything_into_the_plist(self):
        # The retired mechanism, asserted at the template level so it cannot come
        # back through either script.
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            with self.subTest(template=template.name):
                assertRetiredToolsAbsent(self, template)

    def test_the_templates_pass_the_shell_parser_for_both_schemes(self):
        for scheme in ("roothide", "rootless"):
            with tempfile.TemporaryDirectory() as directory:
                staging = pathlib.Path(directory)
                for path in patcher.render_maintainer_scripts(
                        staging, REPO / "package-actions", scheme):
                    result = subprocess.run(["/bin/sh", "-n", str(path)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0,
                                     f"{scheme}/{path.name}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
