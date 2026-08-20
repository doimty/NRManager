#!/usr/bin/env python3
"""Behavioural tests for the shell maintainer scripts.

These render the real templates the way scripts/patch-maintenance-launchd.py
does and run them through /bin/sh with stubbed jbroot/plutil, so the prefix
resolution, the substitution, the idempotence and every diagnostic branch are
executed rather than asserted against source text.

Why the maintainer scripts are shell at all: on roothide the jbroot path
redirection and the sandbox exemption both come from basebin/bootstrap.dylib,
injected via DYLD_INSERT_LIBRARIES. A compiled maintainer script on the
reporting device ran as euid 0 and could stat, read and parse inside the
jailbreak root but got EPERM on every write and child exec, and saw bare paths
as ENOENT. The substitution is therefore done the way roothide's own packages do
it, with plutil and sed.
"""

import os
import pathlib
import plistlib
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

PLUTIL_STUB = """#!/bin/sh
# Apple's plutil spells this -convert xml1; the bootstrap's spells it -xml.
if [ "$1" = "-convert" ]; then shift 2; elif [ "$1" = "-xml" ]; then shift; else exit 64; fi
python3 - "$1" <<'PY'
import plistlib, sys
path = sys.argv[1]
data = plistlib.loads(open(path, 'rb').read())
open(path, 'wb').write(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))
PY
"""


def staged_plist(prefix):
    """The plist as the packaging step leaves it: XML, prefix applied."""
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
        self.stub("plutil", PLUTIL_STUB)
        self.guard_log = self.dir / "guard.log"
        self.install_guard(0)
        self.plist = self.prefix / PLIST_RELATIVE
        self.write_plist(staged_plist(self.plist_prefix()), binary=True)

    def plist_prefix(self):
        return (patcher.ROOTHIDE_PLACEHOLDER if self.scheme == "roothide"
                else str(self.prefix))

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
        of the contract: an empty install prefix is a valid roothide answer, an
        absent one means nothing resolved.
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

    def render(self):
        """Render exactly as the packaging step does, then return the path.

        One documented harness substitution: the rootless lane's fixed prefix is
        /var/jb, and a test may not create that on the host, so the rendered
        SCHEME_PREFIX data line is repointed at the temporary tree. Only that
        assignment is touched, never the logic, and the substitution is asserted
        so a template rename cannot silently turn this into a no-op.
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
        return script

    def run_script(self, *args, path_extra=None, cwd=None):
        script = self.render()
        env = dict(os.environ)
        env["PATH"] = f"{path_extra or self.bin}:{env['PATH']}"
        return subprocess.run([str(script), *args], capture_output=True,
                              text=True, env=env, cwd=cwd)

    def assertNoWarning(self, result):
        self.assertNotIn("warning —", result.stderr)


class RenderingTests(unittest.TestCase):
    def test_the_roothide_script_prefix_is_empty_and_rootless_is_var_jb(self):
        # Two different prefixes are in play. The plist needs a real absolute
        # path because launchd is not redirected; the script's own prefix is
        # empty on roothide, where a bare path already resolves inside the
        # jailbreak root.
        self.assertEqual(patcher.plist_prefix("roothide"), "@JBROOT@")
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
                    self.assertNotIn("@PREFIX@", text)
                    self.assertNotIn("@NEEDS_JBROOT@", text)
                    self.assertTrue(text.startswith("#!/bin/sh\n"))
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o755)

    def test_the_launchd_plist_is_written_as_xml_with_the_scheme_prefix(self):
        for scheme, expected in (("roothide", "@JBROOT@"), ("rootless", "/var/jb")):
            with tempfile.TemporaryDirectory() as directory:
                staging = pathlib.Path(directory)
                target = staging / patcher.PLIST_RELATIVE
                target.parent.mkdir(parents=True)
                target.write_bytes(plistlib.dumps(staged_plist("@JBROOT@"),
                                                  fmt=plistlib.FMT_BINARY))
                patcher.patch_launchd_plist(staging, patcher.plist_prefix(scheme))
                # XML, because the on-device substitution is textual. A binary
                # plist would leave the placeholder unmatched with nothing in the
                # install log to show it.
                self.assertTrue(target.read_bytes().lstrip().startswith(b"<?xml"))
                payload = plistlib.loads(target.read_bytes())
                self.assertEqual(payload["ProgramArguments"][0],
                                 expected + patcher.PROGRAM_RELATIVE)
                self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                                 [expected + patcher.BASELINE_RELATIVE])


class PostinstSubstitutionTests(ShellScriptBase):
    def test_the_placeholder_is_replaced_with_the_live_jbroot(self):
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        payload = self.read_plist()
        self.assertEqual(payload["ProgramArguments"][0],
                         f"{self.prefix}{patcher.PROGRAM_RELATIVE}")
        self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                         [f"{self.prefix}{patcher.BASELINE_RELATIVE}"])
        self.assertNotIn(b"@JBROOT@", self.plist.read_bytes())

    def test_a_binary_plist_is_converted_before_substitution(self):
        # sed cannot match a placeholder inside a binary plist, so a package that
        # skipped the conversion would silently ship an unpatched daemon.
        self.assertEqual(self.plist.read_bytes()[:8], b"bplist00")
        self.run_script("configure")
        self.assertTrue(self.plist.read_bytes().lstrip().startswith(b"<?xml"))

    def test_the_rewrite_keeps_the_mode_and_leaves_no_scratch_file(self):
        self.run_script("configure")
        self.assertEqual(self.plist.stat().st_mode & 0o777, 0o644)
        siblings = sorted(p.name for p in self.plist.parent.iterdir())
        self.assertEqual(siblings, [f"{LABEL}.plist"], siblings)

    def test_running_twice_is_a_no_op_the_second_time(self):
        # dpkg reruns postinst on reconfigure and on a repeated install.
        self.run_script("configure")
        first = self.plist.read_bytes()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plist.read_bytes(), first)
        self.assertNoWarning(result)

    def test_the_resolved_prefix_is_reported(self):
        # Which prefix the maintainer-script shell actually sees is the open
        # question this build answers, so it has to appear in the install log.
        # On this host the bare path cannot exist, so the jbroot fallback wins
        # and the log must name it rather than claiming the redirected root.
        result = self.run_script("configure")
        self.assertIn("resolved the launchd plist under", result.stderr)
        self.assertIn(str(self.prefix), result.stderr)

    def test_the_resolved_prefixes_are_handed_to_the_guard(self):
        # The guard cannot re-derive these: it is invoked through a bare path, so
        # its own executable path carries no jbroot component. Executed rather
        # than asserted against source text, because export ordering and quoting
        # are exactly what a source-text check cannot prove.
        self.install_env_reporting_guard()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = self.guard_environment()
        # On this host the bare path cannot exist, so the jbroot fallback wins
        # and both prefixes are the stubbed jailbreak root.
        self.assertEqual(environment["install"], str(self.prefix))
        self.assertEqual(environment["launchd"], str(self.prefix))

    def test_the_launchd_prefix_matches_what_was_written_into_the_plist(self):
        # One prefix, two consumers. If these diverge, the guard rejects a plist
        # that is actually correct, or accepts one launchd cannot start.
        self.install_env_reporting_guard()
        self.run_script("configure")
        launchd = self.guard_environment()["launchd"]
        payload = self.read_plist()
        self.assertEqual(payload["ProgramArguments"][0],
                         launchd + patcher.PROGRAM_RELATIVE)
        self.assertEqual(list(payload["KeepAlive"]["PathState"]),
                         [launchd + patcher.BASELINE_RELATIVE])

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

    def test_the_rootless_lane_needs_no_substitution_and_no_jbroot(self):
        # The prefix is baked in at package time and jbroot does not exist on
        # that platform, so the script must not depend on it. This is also the
        # only lane where the primary prefix is a real path, so it covers the
        # primary branch of the resolver.
        (self.bin / "jbroot").unlink()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn(str(self.prefix), result.stderr)
        self.assertEqual(self.read_plist()["ProgramArguments"][0],
                         f"{self.prefix}{patcher.PROGRAM_RELATIVE}")
        self.assertTrue(self.guard_log.exists())

    def test_both_prefixes_are_the_baked_in_one(self):
        # No jbroot on this platform, so the fixed prefix has to serve both
        # roles. This is also the only lane where the primary prefix resolves,
        # so it covers the primary branch of the resolver.
        (self.bin / "jbroot").unlink()
        self.install_env_reporting_guard()
        self.run_script("configure")
        environment = self.guard_environment()
        self.assertEqual(environment["install"], str(self.prefix))
        self.assertEqual(environment["launchd"], str(self.prefix))


class PostinstDiagnosticTests(ShellScriptBase):
    def test_a_missing_plist_names_every_prefix_it_tried(self):
        self.plist.unlink()
        result = self.run_script("configure")
        self.assertIn("was not found under", result.stderr)
        self.assertIn("the redirected root (bare paths)", result.stderr)
        self.assertIn(str(self.prefix), result.stderr)
        # The policy guard still has to run; the daemon is the optional part.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.guard_log.exists())

    def test_an_unresolvable_jbroot_is_reported_and_nothing_is_changed(self):
        # With jbroot broken the fallback prefix is gone, so on a host where the
        # bare path does not exist nothing resolves. The failure has to name the
        # jbroot status, otherwise the log looks like a missing-file problem.
        self.set_jbroot(None)
        result = self.run_script("configure")
        self.assertIn("was not found under", result.stderr)
        self.assertIn("jbroot: could not be resolved", result.stderr)
        self.assertIn("the redirected root (bare paths)", result.stderr)
        self.assertIn(b"@JBROOT@", self.plist.read_bytes())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_empty_jbroot_is_treated_as_unresolvable(self):
        self.stub("jbroot", "#!/bin/sh\necho\n")
        result = self.run_script("configure")
        self.assertIn("jbroot: could not be resolved", result.stderr)
        self.assertIn(b"@JBROOT@", self.plist.read_bytes())

    def test_an_implausible_jbroot_is_rejected_rather_than_substituted(self):
        # jbroot's output is an external input that ends up inside the plist. A
        # non-empty but implausible value would be substituted as-is: the
        # placeholder disappears, every later check passes, and launchd holds a
        # path that cannot exist. That is worse than not substituting, because it
        # reports success. Each case must name why it was rejected, since the
        # install log is the only evidence available on the device.
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
                self.write_plist(staged_plist("@JBROOT@"), binary=True)
                self.stub("jbroot", stub)
                result = self.run_script("configure")
                self.assertIn(reason, result.stderr)
                self.assertIn(b"@JBROOT@", self.plist.read_bytes())
                self.assertNotIn("wrote the jailbreak root", result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_trailing_slash_is_normalised_not_rejected(self):
        # roothide's own jbroot takes an optional argument and can return a value
        # with a trailing separator. Rejecting that would be a false negative;
        # using it verbatim would put a doubled separator into the plist, so the
        # daemon path would be wrong in a way nothing downstream checks.
        self.stub("jbroot", f'#!/bin/sh\nprintf "%s/\\n" "{self.prefix}"\n')
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertEqual(self.read_plist()["ProgramArguments"][0],
                         f"{self.prefix}{patcher.PROGRAM_RELATIVE}")
        self.assertNotIn("//", self.read_plist()["ProgramArguments"][0])

    def test_a_substitution_that_changes_nothing_is_caught(self):
        # sed exiting 0 without substituting would otherwise ship a placeholder
        # plist while the install log looks clean.
        self.stub("sed", '#!/bin/sh\nshift\ncat "$1"\n')
        result = self.run_script("configure")
        self.assertIn("placeholder survived", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_failing_plutil_does_not_stop_an_already_xml_plist(self):
        # Both dialects are tried and neither failing is fatal when the plist is
        # already XML, which is the shape the packaging step ships.
        self.write_plist(staged_plist("@JBROOT@"), binary=False)
        self.stub("plutil", "#!/bin/sh\nexit 1\n")
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b"@JBROOT@", self.plist.read_bytes())

    def test_a_binary_plist_is_refused_rather_than_corrupted(self):
        # The failure this guards against is worse than not substituting. grep -a
        # matches @JBROOT@ inside a binary plist, so without an XML check sed
        # would rewrite 8 bytes to a longer path inside a length-prefixed string,
        # leaving the trailer's offset table stale. launchd then cannot parse the
        # file at all, and every later check passes because the placeholder
        # really is gone. Unsubstituted is recoverable; corrupt-and-report-success
        # is not.
        self.stub("plutil", "#!/bin/sh\nexit 1\n")
        before = self.plist.read_bytes()
        self.assertEqual(before[:8], b"bplist00")
        result = self.run_script("configure")
        self.assertIn("is not XML", result.stderr)
        self.assertNotIn("wrote the jailbreak root", result.stderr)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["Label"], LABEL)
        # Still not an install failure: the daemon is the optional part.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.guard_log.exists())

    def test_an_unreadable_plist_is_not_read_as_already_substituted(self):
        # grep's status is three-valued: 0 match, 1 no match, 2+ error. Used as a
        # boolean, an error is indistinguishable from "no placeholder left",
        # which is the success case, so the placeholder would survive with a
        # clean install log.
        self.write_plist(staged_plist("@JBROOT@"), binary=False)
        self.stub("grep", (
            '#!/bin/sh\n'
            '# Answers the XML question honestly, errors on the placeholder one.\n'
            'for argument in "$@"; do\n'
            '    if [ "$argument" = "@JBROOT@" ]; then exit 2; fi\n'
            'done\n'
            'exit 0\n'))
        result = self.run_script("configure")
        self.assertIn("grep exit 2", result.stderr)
        self.assertNotIn("wrote the jailbreak root", result.stderr)
        self.assertIn(b"@JBROOT@", self.plist.read_bytes())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unverifiable_substitution_is_not_reported_as_success(self):
        # Mirror of the above at the other end: after sed runs, a grep error must
        # not read as "the placeholder is gone".
        self.write_plist(staged_plist("@JBROOT@"), binary=False)
        self.stub("grep", (
            '#!/bin/sh\n'
            'log="$0.calls"\n'
            'case "$*" in\n'
            '    *@JBROOT@*)\n'
            '        if [ -e "$log" ]; then exit 2; fi\n'
            '        : > "$log"\n'
            '        exit 0 ;;\n'
            'esac\n'
            'exit 0\n'))
        result = self.run_script("configure")
        self.assertIn("could not confirm the substitution", result.stderr)
        self.assertNotIn("wrote the jailbreak root", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_write_refusal_names_the_path_and_keeps_the_plist(self):
        # This is the shell-side reproduction of the EPERM that a compiled
        # maintainer script hit on the device.
        if os.geteuid() == 0:
            self.skipTest("root ignores directory and file write permission")
        os.chmod(self.plist.parent, 0o555)
        self.addCleanup(os.chmod, self.plist.parent, 0o755)
        result = self.run_script("configure")
        self.assertIn("could not create a replacement next to", result.stderr)
        self.assertIn(str(self.plist), result.stderr)
        self.assertIn("euid", result.stderr)
        self.assertIn(b"@JBROOT@", self.plist.read_bytes())


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
        self.assertEqual(result.returncode, 0)

    def test_the_daemon_is_patched_even_when_the_guard_rejects(self):
        # Order matters: the plist must be correct on disk regardless of the
        # policy verdict, because it is what makes the job loadable at boot.
        self.install_guard(74)
        self.run_script("configure")
        self.assertNotIn(b"@JBROOT@", self.plist.read_bytes())


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
        self.assertEqual(environment["launchd"], str(self.prefix))
        self.assertNotEqual(environment["install"], "absent")
        self.assertNotEqual(environment["launchd"], "absent")

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
    def test_both_templates_are_shell_and_use_the_roothide_convention(self):
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            text = template.read_text()
            self.assertTrue(text.startswith("#!/bin/sh\n"), template.name)
            self.assertIn("@PREFIX@", text)
            self.assertIn("@NEEDS_JBROOT@", text)
        postinst = POSTINST_TEMPLATE.read_text()
        self.assertIn("@JBROOT@", postinst)
        self.assertIn("jbroot", postinst)
        self.assertLess(postinst.index("plutil"), postinst.index("sed "))

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
