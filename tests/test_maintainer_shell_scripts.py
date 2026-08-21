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
redirected process: resolving the jailbreak root, running launchctl, and handing
the root to a helper that is not redirected.

Running launchctl is the part that moved here last. The compiled guard tried
twenty candidate paths and posix_spawn refused every one that existed, including
the real 113664-byte <jbroot>/usr/bin/launchctl, with EPERM -- while the shell
that exec'd that guard ran both `jbroot` and the guard itself. The restriction
was on the guard's process, so no probe table could have fixed it. What the guard
still answers is the one question a shell cannot: whether the shipped binary
plist matches the reviewed contract. It says so with a single line on stdout, and
these tests cover both halves of that handoff.

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
# The single line postinst reads from the guard's stdout as permission to load
# the job. Defined here from the same literal both halves use, so a divergence
# shows up as a failing test rather than as a device that silently never starts
# the daemon.
GUARD_SENTINEL = "launchd-contract-verified"
_DEFAULT = object()

# The bare half of the launchctl candidate list, removed by the harness before
# every run. See ShellScriptBase.render for why. Kept as one literal so a change
# to the shipped list fails the assertion in render rather than quietly letting
# the host's own launchctl back in.
BARE_LAUNCHCTL_CANDIDATES = """    printf '%s\\n' \\
        /usr/bin/launchctl \\
        /bin/launchctl \\
        /usr/sbin/launchctl \\
        /sbin/launchctl \\
        /basebin/launchctl"""


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

    def install_guard(self, exit_code, body=None, verdict=_DEFAULT):
        """Install a stub guard.

        The install guard emits the launchd contract verdict by default, because
        the default fixture is a device where the shipped plist is correct and
        postinst refuses to load the job without that line on stdout. Pass
        verdict=None to model a guard that rejected the plist. The removal guard
        emits nothing: prerm never reads stdout, it boots the job out once the
        policy verdict is clean.
        """
        if verdict is _DEFAULT:
            verdict = (GUARD_SENTINEL if self.template == POSTINST_TEMPLATE
                       else None)
        path = self.prefix / "usr/libexec" / self.guard_name
        path.write_text(body or (
            f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.guard_log}"\n'
            + (f'printf "%s\\n" "{verdict}"\n' if verdict else "")
            + f'exit {exit_code}\n'))
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
            + (f'printf "%s\\n" "{GUARD_SENTINEL}"\n'
               if self.template == POSTINST_TEMPLATE else "")
            + 'exit 0\n'))

    # ------------------------------------------------------------------
    # launchctl
    #
    # Reachable only on the roothide lane, and that is a property of the design
    # rather than of the harness: the candidate list is fixed absolute paths and
    # deliberately not $PATH, so the jbroot-absolute forms are the only ones a
    # test can create on the host. That is also the shape the device has, where
    # <jbroot>/usr/bin/launchctl is the real 113664-byte binary and every bare
    # candidate is absent.
    #
    # The stub keeps real load state rather than fixed exit codes, because the
    # behaviour under test is a sequence -- boot out a stale definition, then
    # bootstrap, then ask launchd whether that worked -- and fixed codes cannot
    # distinguish "loaded" from "the command returned zero".
    # ------------------------------------------------------------------
    def install_launchctl(self, bootstrap_exit=0, bootout_works=True,
                          kickstart_exit=0, loaded=False):
        self.launchctl_log = self.dir / "launchctl.log"
        state = self.dir / "launchd-loaded"
        if loaded:
            state.write_text("")
        path = self.prefix / "usr/bin/launchctl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.launchctl_log}"\n'
            'case "$1" in\n'
            f'  version) exit 0 ;;\n'
            f'  print) [ -e "{state}" ] && exit 0 ; exit 113 ;;\n'
            f'  bootstrap) [ {bootstrap_exit} -eq 0 ] && : > "{state}" ;'
            f' exit {bootstrap_exit} ;;\n'
            f'  bootout) [ {int(bootout_works)} -eq 1 ] && rm -f "{state}" ;'
            f' exit 0 ;;\n'
            f'  kickstart) exit {kickstart_exit} ;;\n'
            'esac\n'
            'exit 0\n')
        path.chmod(0o755)
        return path

    def launchctl_calls(self):
        if not getattr(self, "launchctl_log", None) or not self.launchctl_log.exists():
            return []
        return [line.split()[0]
                for line in self.launchctl_log.read_text().splitlines() if line]

    def install_launchctl_that_hangs(self, on="bootstrap"):
        """A launchctl whose named subcommand never returns.

        Models the reporting device's hang directly. Every other subcommand
        behaves, so a test can show that the sequence continues past the stuck
        call instead of stopping the install.
        """
        self.launchctl_log = self.dir / "launchctl.log"
        state = self.dir / "launchd-loaded"
        path = self.prefix / "usr/bin/launchctl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.launchctl_log}"\n'
            f'if [ "$1" = "{on}" ]; then\n'
            f'  [ "{on}" = bootstrap ] && : > "{state}"\n'
            '  while : ; do :; done\n'
            'fi\n'
            'case "$1" in\n'
            '  version) exit 0 ;;\n'
            f'  print) [ -e "{state}" ] && exit 0 ; exit 113 ;;\n'
            f'  bootstrap) : > "{state}" ; exit 0 ;;\n'
            f'  bootout) rm -f "{state}" ; exit 0 ;;\n'
            '  kickstart) exit 0 ;;\n'
            'esac\n'
            'exit 0\n')
        path.chmod(0o755)
        return path

    def install_launchctl_that_leaks_a_child(self):
        """A launchctl that returns immediately but leaves a child running.

        This is what launchd does on a successful bootstrap: the daemon it starts
        outlives the command. If that child inherits dpkg's stdout, the package
        manager waits on the pipe long after the maintainer script has exited --
        the install appears stuck at "Configuring" with the script already gone.
        The child here holds whatever descriptors it was given for well past any
        test timeout, so an inherited one is a hang and a detached one is not.
        """
        self.launchctl_log = self.dir / "launchctl.log"
        state = self.dir / "launchd-loaded"
        self.leaked_child_pid = self.dir / "leaked.pid"
        path = self.prefix / "usr/bin/launchctl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.launchctl_log}"\n'
            'case "$1" in\n'
            '  version) exit 0 ;;\n'
            f'  print) [ -e "{state}" ] && exit 0 ; exit 113 ;;\n'
            '  bootstrap)\n'
            f'    : > "{state}"\n'
            '    sleep 120 &\n'
            f'    printf "%s\\n" "$!" > "{self.leaked_child_pid}"\n'
            '    exit 0 ;;\n'
            f'  bootout) rm -f "{state}" ; exit 0 ;;\n'
            '  kickstart) exit 0 ;;\n'
            'esac\n'
            'exit 0\n')
        path.chmod(0o755)
        self.addCleanup(self._reap_leaked_child)
        return path

    def _reap_leaked_child(self):
        try:
            pid = int(self.leaked_child_pid.read_text().strip())
        except (OSError, ValueError, AttributeError):
            return
        try:
            os.kill(pid, 9)
        except OSError:
            pass

    def install_baseline(self):
        path = self.prefix / patcher.BASELINE_RELATIVE.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps({"createdAt": 0}))
        return path

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

        Three documented harness substitutions, all of data lines only, never of
        logic, and all asserted so a template rename cannot silently turn this
        into a no-op:

        - The rootless lane's fixed prefix is /var/jb and a test may not create
          that on the host, so SCHEME_PREFIX is repointed at the temporary tree.
        - repoint_primary makes the roothide lane's *bare* candidate resolve,
          which on a real redirected device it does and on this host it cannot.
          Needed to reach the branch where the bare path resolves but jbroot
          fails.
        - The bare launchctl candidates are removed. On the macOS packaging
          runner /usr/bin/launchctl is real, answers `version` successfully, and
          would then be handed this fixture's plist -- the runner reported
          "Bootstrap failed: 5: Input/output error" for exactly that. Every test
          below is about which sequence the script runs and what it reports, not
          about the host's launchd, so the only reachable launchctl must be a stub
          this harness controls. That is also the device's shape: bare candidates
          were ENOENT there and <jbroot>/usr/bin/launchctl was the real binary.
          The bare list itself is a source-level contract, asserted verbatim in
          tests/test_launchctl_ownership.py.
        """
        staging = self.dir / "staging"
        (staging / "DEBIAN").mkdir(parents=True, exist_ok=True)
        patcher.render_maintainer_scripts(
            staging, REPO / "package-actions", self.scheme)
        name = "postinst" if self.template == POSTINST_TEMPLATE else "prerm"
        script = staging / "DEBIAN" / name
        text = script.read_text()
        self.assertIn(BARE_LAUNCHCTL_CANDIDATES, text)
        script.write_text(text.replace(BARE_LAUNCHCTL_CANDIDATES, "    :", 1))
        script.chmod(0o755)
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

    def run_script(self, *args, path_extra=None, cwd=None, repoint_primary=False,
                   timeout=120):
        script = self.render(repoint_primary=repoint_primary)
        env = dict(os.environ)
        env["PATH"] = f"{path_extra or self.bin}:{env['PATH']}"
        # capture_output reads both pipes to EOF, which is exactly how the package
        # manager decides the script is finished. A child that inherits a
        # descriptor therefore hangs this call the same way it hung the device, so
        # the timeout is a real assertion and not just harness hygiene.
        return subprocess.run([str(script), *args], capture_output=True,
                              text=True, env=env, cwd=cwd, timeout=timeout)

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


class PostinstLaunchdLoadTests(ShellScriptBase):
    """Loading the job: the sequence, and what each failure is allowed to cost.

    Nothing here may fail configure. The daemon only provides automatic
    serving-state monitoring and owns no policy or modem state, so a host where
    launchctl or the plist is unusable must still end up with a fully configured
    package rather than a permanently half-installed one whose Settings UI -- the
    only way to run a recovery -- is unavailable.
    """

    def test_the_job_is_booted_out_before_it_is_bootstrapped(self):
        # bootstrap returns 37/EALREADY for an already-bootstrapped job and does
        # not reload it, so without the bootout launchd would keep the previous
        # version's definition. On the reporting device that is also what carried
        # runs = 108 and the 1200-second crash backoff across attempts.
        self.install_launchctl(loaded=True)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        calls = self.launchctl_calls()
        self.assertIn("bootout", calls)
        self.assertIn("bootstrap", calls)
        self.assertLess(calls.index("bootout"), calls.index("bootstrap"))

    def test_a_first_install_does_not_report_the_missing_stale_definition(self):
        # Nothing is loaded on a first install, so bootout has nothing to do and
        # its failure is not evidence of anything.
        self.install_launchctl(loaded=False)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn("bootstrap", self.launchctl_calls())

    def test_the_plist_is_bootstrapped_by_the_path_launchctl_resolves(self):
        # Bare on roothide: launchctl is itself redirected and prepends the
        # jailbreak root to every absolute path in the file on load. Passing a
        # rooted path here is what produced the doubled program path.
        self.install_launchctl()
        self.run_script("configure")
        bootstrap = [line for line in self.launchctl_log.read_text().splitlines()
                     if line.startswith("bootstrap")]
        self.assertEqual(bootstrap,
                         [f"bootstrap system {self.plist_prefix()}/{PLIST_RELATIVE}"])

    def test_launchd_decides_whether_the_load_worked_not_the_exit_code(self):
        # 37/EALREADY is a success for our purposes, so the verdict has to come
        # from asking launchd.
        self.install_launchctl(bootstrap_exit=37, loaded=True, bootout_works=False)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)

    def test_a_load_launchd_refuses_is_reported_without_failing_configure(self):
        self.install_launchctl(bootstrap_exit=5)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("launchd declined to load it", result.stderr)
        self.assertIn("bootstrap exit 5", result.stderr)

    def test_the_job_is_started_now_only_when_the_baseline_exists(self):
        # Without the baseline the daemon reads the policy as disabled and exits
        # immediately, so kickstarting it would produce a pointless launch and a
        # throttled restart. Its KeepAlive PathState watches the baseline, so
        # launchd starts it by itself when one appears.
        self.install_launchctl()
        self.run_script("configure")
        self.assertNotIn("kickstart", self.launchctl_calls())

        self.install_launchctl()
        self.install_baseline()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn("kickstart", self.launchctl_calls())

    def test_kickstart_never_waits_for_a_pid(self):
        # `kickstart -p` waits for launchd to report a PID. The reporting device
        # had the job in a crash-and-backoff loop with minimum runtime 1200, and
        # -kp hung; -k alone returns immediately.
        self.install_launchctl()
        self.install_baseline()
        self.run_script("configure")
        kickstart = [line for line in self.launchctl_log.read_text().splitlines()
                     if line.startswith("kickstart")]
        self.assertEqual(kickstart, [f"kickstart -k system/{LABEL}"])

    def test_a_failed_start_leaves_the_job_loaded(self):
        # Booting it out here would guarantee nothing runs until reboot, which is
        # strictly worse than a failed immediate start: the job is bootstrapped
        # and launchd can still start it from the PathState watch.
        self.install_launchctl(kickstart_exit=3)
        self.install_baseline()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not be started now", result.stderr)
        self.assertNotIn("bootout", self.launchctl_calls()[-1:])

    def test_an_unusable_launchctl_is_a_notice_not_a_warning(self):
        # No launchctl is installed at all here, which is the state of this
        # harness by default and a real possibility on a stripped bootstrap. The
        # plist is correct on disk, which is what makes the job loadable when
        # launchd next reads the jailbreak LaunchDaemons directory, so this is not
        # a warning.
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn("not running yet", result.stderr)
        self.assertIn("after the next reboot", result.stderr)

    def test_a_launchctl_that_cannot_be_exec_d_is_reported_with_what_was_tried(self):
        # 126 is the shell's "found but not executable". The exec attempt is the
        # authority here, because access(X_OK) returned EPERM for the real binary
        # on device and is not a usable oracle.
        path = self.prefix / "usr/bin/launchctl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("not a program")
        path.chmod(0o644)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("launchctl could not be run", result.stderr)
        self.assertIn(str(path), result.stderr)

    # ------------------------------------------------------------------
    # The hung install. A reinstall on the reporting device stopped at
    # "Configuring me.nixuge.networkmanager" and never returned.
    #
    # Both mechanisms below produce that same symptom, both were possible in the
    # shipped script, and both are covered here because the evidence did not
    # distinguish them: the install had to be recovered by rebooting, so no
    # process listing was ever taken.
    #
    # This is also the first release in which the daemon does not die instantly in
    # dyld, so a successful bootstrap that leaves a live child is a new state that
    # had never been reached before.
    # ------------------------------------------------------------------
    def test_a_launchctl_that_never_returns_does_not_hang_the_install(self):
        # bootstrap was the one call in the shipped script with no redirection and
        # no bound. If launchd blocks, an unbounded call blocks dpkg forever.
        self.install_launchctl_that_hangs(on="bootstrap")
        result = self.run_script("configure", timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("did not return within", result.stderr)
        # A timeout is not a verdict on the job. This stub marks it loaded before
        # hanging, so the install must go on to ask launchd and find it loaded
        # rather than boot it out.
        self.assertNotIn("bootout", self.launchctl_calls()[2:])

    def test_a_bootstrap_that_leaks_a_live_child_does_not_hang_the_install(self):
        # The mechanism that needs no failure at all: bootstrap succeeds, and the
        # daemon launchd started inherits dpkg's stdout. The script exits, the
        # pipe stays open, and the package manager waits on a descriptor held by a
        # process it has never heard of. run_script reads both pipes to EOF, so an
        # inherited descriptor makes this time out.
        self.install_launchctl_that_leaks_a_child()
        self.install_baseline()
        result = self.run_script("configure", timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn("bootstrap", self.launchctl_calls())
        # And the child really did outlive the script, or this proves nothing.
        pid = int(self.leaked_child_pid.read_text().strip())
        os.kill(pid, 0)

    def test_every_launchctl_call_is_bounded_and_detached(self):
        # Source-level backstop for the two behavioural tests above. They cover
        # bootstrap; this covers the whole set, because the next call added here
        # would otherwise reintroduce the bug silently. Every launchctl invocation
        # must go through launchctl_run, which owns both the deadline and the
        # redirection.
        text = (REPO / "package-actions" / "launchctl.sh.inc").read_text()
        body = "\n".join(line for line in text.splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertIn("launchctl_run()", body)
        self.assertIn('</dev/null >/dev/null 2>&1 &', body)
        for script in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            script_body = "\n".join(
                line for line in script.read_text().splitlines()
                if not line.lstrip().startswith("#"))
            for line in script_body.splitlines():
                if '"$LAUNCHCTL"' not in line:
                    continue
                self.assertIn(
                    "launchctl_run", line,
                    f"{script.name} invokes launchctl outside launchctl_run: {line}")

    def test_the_guard_cannot_hold_dpkgs_stdin(self):
        # Same class of defect, other child process. The guard's stdout is
        # captured and its stderr is meant to reach the log, so stdin is the one
        # descriptor that needs closing explicitly.
        for script in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            body = script.read_text()
            invocation = [line for line in body.splitlines()
                          if '"$guard" "$@"' in line]
            self.assertTrue(invocation, script.name)
            for line in invocation:
                self.assertIn("</dev/null", line, script.name)

    def test_the_immediate_load_is_skipped_when_it_cannot_be_bounded(self):
        # No usable delay command means no deadline is enforceable. Running
        # launchctl unbounded to save a reboot is exactly the trade that caused
        # this bug, so the load is skipped and the plist is left to do its job at
        # boot. The delay command is looked up by absolute path rather than through
        # PATH -- $PATH is not trustworthy in a maintainer script -- so it cannot be
        # hidden by emptying PATH, and the resolver's candidate list is repointed
        # instead.
        self.install_launchctl()
        script = self.render()
        text = script.read_text()
        needle = "    for _delay in /bin/sleep /usr/bin/sleep; do"
        self.assertIn(needle, text)
        script.write_text(text.replace(
            needle, "    for _delay in /nonexistent/sleep; do", 1))
        script.chmod(0o755)
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        result = subprocess.run([str(script), "configure"], capture_output=True,
                                text=True, env=env, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no usable sleep command", result.stderr)
        self.assertIn("after the next reboot", result.stderr)
        self.assertEqual(self.launchctl_calls(), [])

    def test_nothing_is_loaded_when_the_guard_rejects_the_plist(self):
        # Loading a plist the guard just reported as not matching the contract
        # would start something other than what was reviewed. Hard stop for the
        # load, no-op for the install.
        self.install_launchctl()
        self.install_guard(0, verdict=None)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("did not match the reviewed contract", result.stderr)
        self.assertEqual(self.launchctl_calls(), [])

    def test_a_guard_verdict_line_is_not_confused_with_its_prose(self):
        # stdout is the verdict channel and stderr is the log. A guard that only
        # talks about the contract on stderr has not verified it.
        self.install_launchctl()
        self.install_guard(0, body=(
            '#!/bin/sh\n'
            f'printf "%s\\n" "{GUARD_SENTINEL}" >&2\n'
            'exit 0\n'))
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("did not match the reviewed contract", result.stderr)
        self.assertEqual(self.launchctl_calls(), [])

    def test_the_guards_prose_still_reaches_the_dpkg_log(self):
        # stdout is captured to read the verdict, so the human-readable half has
        # to be on stderr or it would vanish from the install log.
        self.install_launchctl()
        self.install_guard(0, body=(
            '#!/bin/sh\n'
            'printf "something worth reading\\n" >&2\n'
            f'printf "%s\\n" "{GUARD_SENTINEL}"\n'
            'exit 0\n'))
        result = self.run_script("configure")
        self.assertIn("something worth reading", result.stderr)
        self.assertNotIn(GUARD_SENTINEL, result.stdout)

    def test_a_blocking_guard_stops_before_launchctl_runs(self):
        self.install_launchctl()
        self.install_guard(74, verdict=None)
        self.assertEqual(self.run_script("configure").returncode, 74)
        self.assertEqual(self.launchctl_calls(), [])


class PrermLaunchdBootoutTests(ShellScriptBase):
    template = PRERM_TEMPLATE
    guard_name = "networkmanager-removal-guard"

    def test_the_daemon_is_stopped_only_after_the_guard_allows_removal(self):
        # Stopping it on a blocked path would be a side effect on a path that just
        # refused to proceed: the package stays installed, the user is told to
        # recover in Settings, and monitoring should keep working while they do.
        self.install_launchctl(loaded=True)
        self.install_guard(73)
        self.assertEqual(self.run_script("remove").returncode, 73)
        self.assertEqual(self.launchctl_calls(), [])

        self.install_launchctl(loaded=True)
        self.install_guard(0)
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bootout", self.launchctl_calls())

    def test_a_daemon_that_will_not_stop_does_not_block_removal(self):
        # dpkg removes the plist with the package, so a job that cannot be booted
        # out now cannot come back after a reboot either. The only live risk is a
        # still-running instance, which is why it is still reported.
        self.install_launchctl(loaded=True, bootout_works=False)
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not be stopped", result.stderr)
        self.assertIn("will not return", result.stderr)

    def test_an_absent_launchctl_does_not_block_removal(self):
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("launchctl could not be run", result.stderr)

    def test_prerm_never_reads_the_guards_stdout(self):
        # It has no verdict to read: prerm boots the job out unconditionally once
        # the policy verdict is clean, so a guard printing anything at all must
        # not change the outcome.
        self.install_launchctl(loaded=True)
        self.install_guard(0, verdict="unexpected chatter")
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bootout", self.launchctl_calls())


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
