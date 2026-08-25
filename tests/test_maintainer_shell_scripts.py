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
import time
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

# The same hazard, and a worse one. On the macOS packaging runner /usr/bin/killall
# is real, so a prerm test would resolve it and actually run `killall -9
# CommCenter` against the build machine. Stripped from the rendered script for
# every test, exactly like the launchctl list, so the only reachable killall is a
# stub this harness controls. The list itself is a source-level contract,
# asserted verbatim in tests/test_carrier_reset.py.
BARE_KILLALL_CANDIDATES = """    printf '%s\\n' \\
        /usr/bin/killall \\
        /bin/killall \\
        /usr/sbin/killall \\
        /sbin/killall \\
        /basebin/killall"""

# And dpkg, for a subtler reason than the other two. The host's own dpkg is real
# on a Linux runner and answers --compare-versions perfectly well, so a test that
# does not strip it passes while silently testing the host's dpkg instead of the
# fixture's. That hides the two cases worth covering: a comparison that cannot be
# run at all, and a comparison that hangs. Stripped for the same reason, and
# asserted for the same reason.
BARE_DPKG_CANDIDATES = """    printf '%s\\n' \\
        /usr/bin/dpkg \\
        /bin/dpkg \\
        /usr/local/bin/dpkg"""


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
                          loaded=False):
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
            f'  kickstart) exit 0 ;;\n'
            'esac\n'
            'exit 0\n')
        path.chmod(0o755)
        return path

    def launchctl_calls(self):
        if not getattr(self, "launchctl_log", None) or not self.launchctl_log.exists():
            return []
        return [line.split()[0]
                for line in self.launchctl_log.read_text().splitlines() if line]

    # ------------------------------------------------------------------
    # killall
    #
    # Same candidate-path design as launchctl, and reachable in tests only
    # through the jbroot-absolute form, because render() strips the bare list.
    # ------------------------------------------------------------------
    def install_killall(self, exit_code=0, second_exit_code=None, hangs=False):
        """A killall stub that records each invocation.

        second_exit_code models the case the reset contract is about: the first
        kill succeeds, the second does not, so the observed two-invocation
        sequence did not complete and the script must not claim carrier defaults
        were reloaded.
        """
        self.killall_log = self.dir / "killall.log"
        counter = self.dir / "killall.count"
        path = self.prefix / "usr/bin/killall"
        path.parent.mkdir(parents=True, exist_ok=True)
        if second_exit_code is None:
            second_exit_code = exit_code
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.killall_log}"\n'
            f'if [ -e "{counter}" ]; then\n'
            f'  exit {second_exit_code}\n'
            'fi\n'
            f': > "{counter}"\n'
            + ('while : ; do :; done\n' if hangs else '')
            + f'exit {exit_code}\n')
        path.chmod(0o755)
        return path

    def killall_calls(self):
        if not getattr(self, "killall_log", None) or not self.killall_log.exists():
            return []
        return [line for line in self.killall_log.read_text().splitlines() if line]

    # ------------------------------------------------------------------
    # dpkg
    #
    # Only prerm's version comparison uses it. Deliberately a stub with a fixed
    # verdict rather than the host's real dpkg: this asserts which branch the
    # script takes for a given answer, and tests/test_dpkg_version_floor.py
    # separately checks the real tool agrees with the expectations those branches
    # are chosen against.
    # ------------------------------------------------------------------
    def install_dpkg(self, at_least=True, hangs=False):
        self.dpkg_log = self.dir / "dpkg.log"
        path = self.prefix / "usr/bin/dpkg"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.dpkg_log}"\n'
            + ('while : ; do :; done\n' if hangs else '')
            + f'exit {0 if at_least else 1}\n')
        path.chmod(0o755)
        return path

    def dpkg_calls(self):
        if not getattr(self, "dpkg_log", None) or not self.dpkg_log.exists():
            return []
        return [line for line in self.dpkg_log.read_text().splitlines() if line]

    def install_launchctl_that_hangs(self, on="bootstrap", loaded=False):
        """A launchctl whose named subcommand never returns.

        Models the reporting device's hang directly. Every other subcommand
        behaves, so a test can show that the sequence continues past the stuck
        call instead of stopping the install.
        """
        self.launchctl_log = self.dir / "launchctl.log"
        state = self.dir / "launchd-loaded"
        if loaded:
            state.write_text("")
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

    def install_launchctl_that_stops_answering(self):
        """A launchctl that probes fine and then never answers launchd.

        The state the reporting device was in. `version` asks launchd nothing and
        returns, so the binary resolves; every subcommand that does ask launchd
        hangs. This is what makes a per-call deadline insufficient on its own: the
        script makes several such calls in a row, so the install pays the deadline
        once per call unless the first one is taken as a verdict on launchd.
        """
        self.launchctl_log = self.dir / "launchctl.log"
        path = self.prefix / "usr/bin/launchctl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$*" >> "{self.launchctl_log}"\n'
            'case "$1" in\n'
            '  version) exit 0 ;;\n'
            'esac\n'
            'while : ; do :; done\n')
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
        text = text.replace(BARE_LAUNCHCTL_CANDIDATES, "    :", 1)
        if name == "prerm":
            # Asserted rather than tolerated: if the shipped list stops matching,
            # this fails loudly instead of quietly letting the host's real
            # /usr/bin/killall back into a test that runs `killall -9 CommCenter`.
            self.assertIn(BARE_KILLALL_CANDIDATES, text)
            text = text.replace(BARE_KILLALL_CANDIDATES, "    :", 1)
            self.assertIn(BARE_DPKG_CANDIDATES, text)
            text = text.replace(BARE_DPKG_CANDIDATES, "    :", 1)
        script.write_text(text)
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
        # from asking launchd. That code only occurs for a job that is still
        # bootstrapped, which is why bootout has to have failed here -- and that
        # failure is separately reported, so the assertion is specifically that no
        # load failure is claimed.
        self.install_launchctl(bootstrap_exit=37, loaded=True, bootout_works=False)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("declined to load it", result.stderr)
        self.assertIn("could not be removed", result.stderr)

    def test_a_load_launchd_refuses_is_reported_without_failing_configure(self):
        self.install_launchctl(bootstrap_exit=5)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("launchd declined to load it", result.stderr)
        self.assertIn("bootstrap exit 5", result.stderr)

    def test_the_install_never_kickstarts_the_job(self):
        # kickstart was the only call that ever hit the deadline on the reporting
        # device. It is also redundant: the plist's KeepAlive PathState names the
        # policy baseline, so bootstrapping a job whose condition is already
        # satisfied starts it, and bootout+bootstrap already replaced any earlier
        # definition. Both with and without the baseline, because the old code
        # made the call conditional on it.
        self.install_launchctl()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        # A first install has nothing loaded, so there is nothing to boot out.
        self.assertEqual(self.launchctl_calls(),
                         ["version", "print", "bootstrap", "print"])

        # Second install over the first, which is the state the device was in.
        self.launchctl_log.unlink()
        self.install_baseline()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertEqual(self.launchctl_calls(),
                         ["version", "print", "bootout", "print", "bootstrap",
                          "print"])

    def test_a_kickstart_that_hangs_can_no_longer_delay_the_install(self):
        # The exact shape of the second device report: bootstrap fine, job loaded,
        # kickstart stuck. With no kickstart call left, this install must finish
        # promptly and quietly rather than spending the deadline and warning.
        self.install_launchctl_that_hangs(on="kickstart")
        self.install_baseline()
        started = time.monotonic()
        result = self.run_script("configure", timeout=120)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertNotIn("kickstart", self.launchctl_calls())
        self.assertLess(elapsed, 20, f"took {elapsed:.1f}s; a deadline was paid")

    def test_a_launchd_that_stops_answering_costs_one_deadline_not_several(self):
        # The reporting device's install stalled for far longer than one deadline,
        # and this is why: bounding each call individually still lets the script
        # spend the deadline once per call, and it makes several launchd calls in a
        # row. The first unanswered request is taken as a verdict on launchd, so
        # the rest are skipped.
        self.install_launchctl_that_stops_answering()
        self.install_baseline()
        started = time.monotonic()
        result = self.run_script("configure", timeout=300)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("launchd did not answer", result.stderr)
        # One deadline plus the 2s escalation and process overhead, and nowhere
        # near the two-plus deadlines the previous version would have paid.
        self.assertLess(elapsed, 32, f"took {elapsed:.1f}s; more than one deadline")
        # Every launchd-facing call after the first stuck one is skipped, so the
        # log stops at the one that hung.
        self.assertEqual(self.launchctl_calls(), ["version", "print"])

    def test_a_stuck_bootout_still_costs_only_one_deadline(self):
        # The latch has to hold across the rest of the script, not just within one
        # helper: bootout hanging leaves bootstrap and its verification still to
        # come, and each would otherwise pay the deadline again.
        # Pre-loaded, or bootout is never reached: nothing is booted out on a
        # first install, which is the whole point of the early return in
        # launchd_bootout.
        self.install_launchctl_that_hangs(on="bootout", loaded=True)
        started = time.monotonic()
        result = self.run_script("configure", timeout=300)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 32, f"took {elapsed:.1f}s; more than one deadline")
        self.assertEqual(self.launchctl_calls(),
                         ["version", "print", "bootout"])

    def test_the_script_says_when_it_returns(self):
        # Both device reports ended with a line of ours and an install that
        # appeared to stop, and neither log could answer "is this script still
        # running?". This line is that answer, and it has to be on the failure
        # paths too, which is why it is a trap rather than a line before exit.
        self.install_launchctl()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stderr.rstrip().endswith("setup finished."),
                        result.stderr)

        # An early exit: no guard at all, which returns before any launchd work.
        (self.prefix / "usr/libexec/networkmanager-install-guard").unlink()
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stderr.rstrip().endswith("setup finished."),
                        result.stderr)

    def test_a_clean_install_says_the_job_is_loaded(self):
        # A user read a log whose only lines were the prefix note and "setup
        # finished." and asked whether that was normal. Success was inferable only
        # from the absence of warnings, which is not something a log should ask
        # anyone to do.
        #
        # Loaded, not running: `print` confirms launchd holds the job, and the
        # KeepAlive PathState decides whether it is up.
        self.install_launchctl(loaded=False)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNoWarning(result)
        self.assertIn("the maintenance owner is loaded", result.stderr)
        self.assertNotIn("is running", result.stderr)

    def test_a_surviving_definition_that_cannot_be_removed_is_reported(self):
        # bootstrap returns EALREADY without replacing a definition launchd already
        # holds, so a survivor means launchd keeps running the previous version's
        # job while every later check here reports it as loaded. The log would
        # otherwise read as success.
        #
        # Deliberately not attributed to an earlier jailbreak root. launchd is pid 1
        # and its system-domain job table does not survive a reboot, and both ways
        # the root changes restart launchd, so a definition pointing into a root
        # that no longer exists is only reachable inside a single boot -- which is
        # the case where the root did not change.
        self.install_launchctl(loaded=True, bootout_works=False)
        result = self.run_script("configure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not be removed", result.stderr)
        self.assertIn("Installing the package again", result.stderr)
        self.assertNotIn("jailbreak root", result.stderr)
        # launchd answers "loaded" whichever definition it holds, so the success
        # line would read as though the loaded job were this package's.
        self.assertNotIn("the maintenance owner is loaded", result.stderr)

    def test_an_unanswered_bootout_is_not_reported_as_a_stale_definition(self):
        # The other half of the three-outcome rule, and the direction that would
        # invent evidence rather than lose it: a bootout whose verification never
        # came back says only that launchd stopped answering. Claiming a surviving
        # stale definition on that basis would point the user at the wrong problem.
        self.install_launchctl_that_hangs(on="bootout", loaded=True)
        result = self.run_script("configure", timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("could not be removed", result.stderr)
        self.assertIn("launchd did not answer", result.stderr)

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
        self.assertIn("Reinstall the package", result.stderr)

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
        self.assertIn("launchd did not answer", result.stderr)
        # A timeout is not a verdict on the job, so it is not booted out. This
        # stub marks it loaded before hanging, and launchd may equally have
        # accepted the real one before the deadline.
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
        #
        # postinst only: prerm has no guard left to invoke. Removal used to ask a
        # compiled binary whether a band configuration still needed restoring
        # before the package could go; the reset primitive needs no such record,
        # so the question and the binary that answered it are both gone.
        body = POSTINST_TEMPLATE.read_text()
        invocation = [line for line in body.splitlines()
                      if '"$guard" "$@"' in line]
        self.assertTrue(invocation, POSTINST_TEMPLATE.name)
        for line in invocation:
            self.assertIn("</dev/null", line, POSTINST_TEMPLATE.name)
        self.assertNotIn('"$guard" "$@"', PRERM_TEMPLATE.read_text())

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
        self.assertIn("Reinstall the package", result.stderr)
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


class PrermCarrierResetTests(ShellScriptBase):
    """Removal reloads carrier defaults before dpkg unlinks anything.

    This replaces the removal guard entirely. The guard's job was to decide
    whether the package still held a band configuration that had to be restored
    before it could be removed, and to block removal until the user did that in
    Settings. The reset primitive needs no such record -- it discards the whole
    carrier configuration, so it undoes a narrowed modem without knowing what was
    narrowed -- which means removal has nothing left to refuse. The direction of
    the gate is therefore inverted on purpose: it used to be fail-closed against
    dpkg, and it is now unconditionally non-blocking.
    """

    template = PRERM_TEMPLATE

    def setUp(self):
        super().setUp()
        # A guard binary is no longer installed by prerm's fixture, and its
        # absence must not matter. Removing the one ShellScriptBase created keeps
        # every test here honest about that.
        guard = self.prefix / "usr/libexec/networkmanager-removal-guard"
        if guard.exists():
            guard.unlink()

    def test_the_double_kill_runs_before_anything_is_unlinked(self):
        # Two separate invocations, not one. The device evidence is literal about
        # this, and a single kill is the shape that did not reload the defaults.
        self.install_killall()
        self.install_launchctl(loaded=True)
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killall_calls(), ["-9 CommCenter", "-9 CommCenter"])
        self.assertIn("carrier defaults reloaded", result.stderr)

    def test_a_confirmed_reset_discards_the_policy_records(self):
        records = self.policy_records()
        for record in records:
            record.parent.mkdir(parents=True, exist_ok=True)
            record.write_text("stale")
        self.install_killall()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        for record in records:
            self.assertFalse(record.exists(), record.name)

    def test_an_unconfirmed_reset_keeps_the_records_and_still_allows_removal(self):
        # The records are the only remaining evidence that the modem was left
        # narrowed. Deleting them here would tell the next install that there is
        # nothing to recover, which is the one wrong answer available.
        records = self.policy_records()
        for record in records:
            record.parent.mkdir(parents=True, exist_ok=True)
            record.write_text("stale")
        self.install_killall(exit_code=0, second_exit_code=1)
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not complete", result.stderr)
        self.assertIn("removal continues", result.stderr)
        for record in records:
            self.assertTrue(record.exists(), record.name)

    def test_the_pending_band_selection_is_discarded_on_removal_only(self):
        # Not policy evidence, so it is not in the policy record set and is not
        # gated on the reset having worked. It is discarded because a stored band
        # the current SIM no longer offers makes the toggle refuse, and nothing in
        # Settings names the stored value -- so remove-and-reinstall, the remedy
        # every user reaches for, would silently inherit the same broken value.
        #
        # Upgrade is the opposite case: the successor package reads the same file
        # and the user still owns the choice. Discarding it there would look like
        # the tweak forgetting its setting on every update.
        for action, survives in (
                ("upgrade", True),
                ("failed-upgrade", True),
                ("deconfigure", True),
                ("remove", False),
        ):
            with self.subTest(action=action):
                selection = (self.prefix / "var/mobile/Library/Preferences"
                             / "me.nixuge.networkmanager.n78-selection.plist")
                selection.parent.mkdir(parents=True, exist_ok=True)
                selection.write_text("chosen bands")
                self.install_killall()
                # Only `upgrade` reads a version, and only it consults dpkg. The
                # successor supports the reload, so this is the branch that must
                # leave everything alone.
                self.install_dpkg(at_least=True)
                args = (action, "1.7.0") if action == "upgrade" else (action,)
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(selection.exists(), survives, action)

    def test_nothing_is_reset_or_discarded_on_an_upgrade(self):
        # The regression this guards against is silent and repeating: a reset on
        # every upgrade would undo the user's configuration each time they
        # updated, and look like the tweak randomly forgetting its setting.
        records = self.policy_records()
        for record in records:
            record.parent.mkdir(parents=True, exist_ok=True)
            record.write_text("still ours")
        self.install_killall()
        self.install_dpkg(at_least=True)
        result = self.run_script("upgrade", "1.7.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killall_calls(), [])
        for record in records:
            self.assertTrue(record.exists(), record.name)
        self.assertEqual(self.dpkg_calls(),
                         [f"--compare-versions 1.7.0 ge {patcher.CARRIER_RESET_FLOOR}"])
        self.assertIn("supports the carrier defaults reload", result.stderr)

    def test_a_downgrade_below_the_floor_is_treated_as_a_retirement(self):
        # `upgrade` is also how dpkg spells a downgrade, and this half is not
        # benign: a version below the floor cannot reload carrier defaults, so it
        # would leave the user no in-package way to undo a narrowed modem. The
        # records go too, because that version does not understand them either.
        records = self.policy_records()
        for record in records:
            record.parent.mkdir(parents=True, exist_ok=True)
            record.write_text("stale")
        self.install_killall()
        self.install_dpkg(at_least=False)
        result = self.run_script("upgrade", "1.5.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killall_calls(),
                         ["-9 CommCenter", "-9 CommCenter"])
        for record in records:
            self.assertFalse(record.exists(), record.name)
        self.assertIn("predates the carrier defaults reload", result.stderr)

    def test_an_unanswerable_comparison_reloads_rather_than_assuming(self):
        # Fails toward an un-narrowed modem. A reset the user did not need is one
        # tap to undo; a downgrade that skipped it is not. Both causes are
        # reported distinctly, because the dpkg log is the only place anyone will
        # ever see which one it was.
        for label, install, expected in (
                ("no dpkg at all", lambda: None, "no usable dpkg was found"),
                ("dpkg never answers", lambda: self.install_dpkg(hangs=True),
                 "predates the carrier defaults reload"),
        ):
            with self.subTest(case=label):
                self.install_killall()
                install()
                result = self.run_script("upgrade", "1.7.0")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stderr)
                self.assertEqual(self.killall_calls(),
                                 ["-9 CommCenter", "-9 CommCenter"])
                self.setUp()

    def test_a_hung_comparison_does_not_suppress_the_reset(self):
        # The bug this pins. Both the comparison and the reset run bounded
        # children, and routing both through the *latching* launchd wrapper made
        # the first deadline short-circuit everything after it -- so a dpkg that
        # hung caused prerm to decide a reset was needed and then skip it, with
        # nothing in the log to say the kills never ran.
        self.install_killall()
        self.install_dpkg(hangs=True)
        result = self.run_script("upgrade", "1.7.0", timeout=180)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killall_calls(),
                         ["-9 CommCenter", "-9 CommCenter"])
        self.assertIn("carrier defaults reloaded", result.stderr)

    def test_a_missing_killall_does_not_block_removal(self):
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no usable killall", result.stderr)
        self.assertIn("removal continues", result.stderr)

    def test_a_killall_that_hangs_does_not_hang_removal(self):
        # The reset goes through launchctl_run, so it inherits the descriptor
        # close and the deadline. Without both, this is the shape that wedged
        # dpkg permanently on the reporting device.
        self.install_killall(hangs=True)
        result = self.run_script("remove", timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("removal continues", result.stderr)

    def test_the_reset_never_consults_policy_state_to_decide(self):
        # A reset that only ran when the records said it was needed would be
        # useless in exactly the case it exists for: records that are missing,
        # stale or written by a version that crashed mid-transition.
        self.install_killall()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.killall_calls(), ["-9 CommCenter", "-9 CommCenter"])

    def policy_records(self):
        base = self.prefix / "var/mobile/Library/Preferences"
        return [base / f"me.nixuge.networkmanager.n78-policy.{suffix}.plist"
                for suffix in ("state", "baseline", "intent", "inflight",
                               "removal-guard")]


class PrermLaunchdBootoutTests(ShellScriptBase):
    template = PRERM_TEMPLATE

    def test_the_daemon_is_stopped_on_removal(self):
        # Unconditional now. There is no verdict left to wait for, and leaving a
        # running instance behind is the only live risk removal can create.
        self.install_launchctl(loaded=True)
        self.install_killall()
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

    def test_the_reset_runs_before_the_daemon_is_stopped(self):
        # Order matters: the daemon watches policy state, and stopping it first
        # would leave the reset unobserved by the one component that reports on it.
        self.install_launchctl(loaded=True)
        self.install_killall()
        result = self.run_script("remove")
        self.assertEqual(result.returncode, 0, result.stderr)
        reset_line = result.stderr.index("carrier defaults reloaded")
        self.assertTrue(self.killall_calls())
        self.assertIn("bootout", self.launchctl_calls())
        self.assertGreater(len(result.stderr), reset_line)


class PrermTests(ShellScriptBase):
    template = PRERM_TEMPLATE

    def test_removal_always_succeeds(self):
        # Every failure path in this script degrades to a warning. Nothing it does
        # is worth leaving a package half-removed for.
        for label, setup in (
                ("nothing installed", lambda: None),
                ("killall present", lambda: self.install_killall()),
                ("reset fails", lambda: self.install_killall(exit_code=1)),
                ("launchctl present", lambda: self.install_launchctl(loaded=True)),
        ):
            with self.subTest(case=label):
                setup()
                result = self.run_script("remove")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unusable_jbroot_is_reported_and_does_not_block(self):
        self.set_jbroot(None)
        result = self.run_script("remove", repoint_primary=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not be resolved", result.stderr)
        self.assertIn("jbroot produced no output", result.stderr)

    def test_an_implausible_jbroot_is_rejected_rather_than_used(self):
        # A relative jbroot resolves against the current directory, which dpkg
        # does not guarantee. Using it would send both the killall lookup and the
        # record deletion at a directory chosen by whatever the cwd happened to
        # be, so the value is refused outright and only bare paths are tried.
        elsewhere = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, elsewhere, ignore_errors=True)
        stray = elsewhere / "relative/root/var/mobile/Library/Preferences"
        stray.mkdir(parents=True)
        victim = stray / "me.nixuge.networkmanager.n78-policy.state.plist"
        victim.write_text("not ours to delete")

        self.stub("jbroot", '#!/bin/sh\nprintf "relative/root\\n"\n')
        result = self.run_script("remove", cwd=str(elsewhere))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("relative path", result.stderr)
        self.assertTrue(victim.exists())
        self.assertEqual(victim.read_text(), "not ours to delete")

    def test_no_removal_guard_is_invoked(self):
        # The retired mechanism. Asserted at the rendered-script level so it
        # cannot come back through the template or through the include.
        text = self.render().read_text()
        self.assertNotIn("networkmanager-removal-guard", text)
        self.assertNotIn("removal blocked", text)
        self.assertNotIn("to override", text)


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
