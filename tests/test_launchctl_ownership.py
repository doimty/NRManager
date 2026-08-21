#!/usr/bin/env python3
"""Which process is allowed to run launchctl, and what may never come back.

Three rounds were spent inside the compiled guards trying to find a launchctl
they could exec. The shipped probe table finally answered it, and the decisive
column was errno:

    <jbroot>/bin/launchctl(spawn errno 1)      the relative symlink
    <jbroot>/usr/bin/launchctl(spawn errno 1)  the real 113664-byte binary
    18 other probed paths do not exist

errno 1 is EPERM from posix_spawn itself, not ENOENT, and the second path is the
real binary. Two further facts from the same dpkg run identify the cause: the
guard saw every bare path as ENOENT while jbroot-absolute paths resolved, so it
has no path redirection, and the shell that exec'd it ran both `jbroot` and the
guard without trouble. On roothide the redirection and the exec exemption both
arrive through basebin/bootstrap.dylib via DYLD_INSERT_LIBRARIES, which a
compiled maintainer-script child does not get.

So the restriction was on the guard's process, not on the paths it tried, and no
probe table could have fixed it. The candidate list, the spawn probe and the
twenty-path report are retired along with the approach. What these tests pin is
the resulting split:

  - the shell maintainer scripts own every launchctl invocation, from one shared
    include rather than two hand-maintained copies;
  - the compiled guards read, parse and report, and hand back a single
    machine-readable verdict on stdout;
  - the plist is never rewritten on the device, by either half.

The behaviour of the shell's launchctl handling is exercised for real in
tests/test_maintainer_shell_scripts.py, which renders the templates and runs
them. This file covers the ownership boundary itself, which is a property of
which source names what.
"""

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MAINTAINER_SOURCE = ROOT / "package-actions" / "CCNMMaintainerEnvironment.m"
MAINTAINER_HEADER = ROOT / "package-actions" / "CCNMMaintainerEnvironment.h"
POSTINST_SOURCE = ROOT / "package-actions" / "postinst.m"
PRERM_SOURCE = ROOT / "package-actions" / "prerm.m"
ACTIONS_MAKEFILE = ROOT / "package-actions" / "Makefile"
LAUNCHCTL_INCLUDE = ROOT / "package-actions" / "launchctl.sh.inc"
POSTINST_TEMPLATE = ROOT / "package-actions" / "postinst.sh.in"
PRERM_TEMPLATE = ROOT / "package-actions" / "prerm.sh.in"

COMPILED_SOURCES = (MAINTAINER_SOURCE, POSTINST_SOURCE, PRERM_SOURCE)


def code_only(text):
    """The source with whole-line comments removed.

    The comments deliberately record why launchctl and access(2) are gone, and
    that prose has to survive a ban on the calls themselves.
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith("//")
    )


def shell_code_only(text):
    """The same, for the maintainer-script templates.

    Their comments explain at length why a call was removed, so a ban on the call
    has to look at the code alone or the explanation would trip it.
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith("#")
    )


class CompiledGuardsDoNotExecTests(unittest.TestCase):
    def test_no_compiled_guard_source_spawns_anything(self):
        # The retired approach in one assertion. A guard that spawns is a guard
        # that has to resolve a binary, and resolution is what was impossible.
        for source in COMPILED_SOURCES:
            with self.subTest(source=source.name):
                code = code_only(source.read_text())
                for symbol in ("posix_spawn", "execve", "execvp", "execl",
                               "NSTask", "system(", "popen("):
                    self.assertNotIn(symbol, code)

    def test_no_compiled_guard_source_names_a_launchctl_subcommand(self):
        for source in COMPILED_SOURCES:
            with self.subTest(source=source.name):
                code = code_only(source.read_text())
                for subcommand in ('@"bootout"', '@"bootstrap"', '@"kickstart"',
                                   '@"version"', '@"print"'):
                    self.assertNotIn(subcommand, code)

    def test_the_retired_probe_is_gone_from_the_tree_and_the_build(self):
        # Deleted, not merely unreferenced: leaving it compiled-out invites the
        # next round to reach for it again.
        self.assertFalse(
            (ROOT / "package-actions" / "CCNMLaunchctlProbe.c").exists())
        self.assertFalse(
            (ROOT / "package-actions" / "CCNMLaunchctlProbe.h").exists())
        makefile = ACTIONS_MAKEFILE.read_text()
        self.assertNotIn("CCNMLaunchctlProbe", makefile)
        for source in COMPILED_SOURCES:
            self.assertNotIn("CCNMLaunchctlProbe", source.read_text())

    def test_no_candidate_path_table_survives_in_the_guards(self):
        # The shell owns the candidate list now, and it has to be the only one:
        # two lists in two languages is how they drift apart.
        for source in COMPILED_SOURCES:
            with self.subTest(source=source.name):
                code = code_only(source.read_text())
                for candidate in ("/usr/bin/launchctl", "/bin/launchctl",
                                  "/basebin/launchctl", "/rootfs"):
                    self.assertNotIn(candidate, code)

    def test_access_is_never_used_as_a_usability_oracle(self):
        # access(X_OK) is routed through an exec-authorization hook on this
        # platform and returned EPERM for the real launchctl binary and for the
        # freshly unpacked helper. Any surviving call is a latent repeat.
        for source in COMPILED_SOURCES:
            with self.subTest(source=source.name):
                self.assertNotIn("access(", code_only(source.read_text()))


class ContractVerificationTests(unittest.TestCase):
    def test_verification_is_the_only_launchd_entry_point_left(self):
        header = MAINTAINER_HEADER.read_text()
        self.assertIn("CCNMVerifyMaintenanceLaunchdContract", header)
        # The registration state machine described a launchctl outcome this
        # process can no longer observe, so it cannot be left in the header for a
        # caller to switch on.
        for retired in ("CCNMPrepareMaintenanceLaunchd",
                        "CCNMRegisterMaintenanceLaunchd",
                        "CCNMStopMaintenanceLaunchd",
                        "CCNMMaintenanceRegistration"):
            self.assertNotIn(retired, header)
        source = MAINTAINER_SOURCE.read_text()
        for retired in ("CCNMRegisterMaintenanceLaunchd",
                        "CCNMStopMaintenanceLaunchd"):
            self.assertNotIn(retired, source)

    def test_verification_never_writes_the_plist(self):
        # Two independent reasons, either one sufficient. The plist ships
        # complete, because on roothide the correct contents are the bare paths
        # launchctl will prefix on load; and this process cannot write at all,
        # since the device returned EPERM for every write from a
        # maintainer-script child running as euid 0.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("BOOL CCNMVerifyMaintenanceLaunchdContract"):]
        for writer in ("writeToFile", "mutableCopy", "CCNMWritePlist",
                       "NSPropertyListSerialization dataWithPropertyList"):
            self.assertNotIn(writer, body)

    def test_the_installed_plist_is_compared_exactly_not_by_suffix(self):
        # A doubled prefix and a bare path both end with the right relative
        # path, and only one of them is loadable. The doubled shape is what the
        # reporting device actually ran, so suffix matching would have passed it.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("BOOL CCNMVerifyMaintenanceLaunchdContract"):]
        self.assertIn("isEqualToString:expectedProgram", body)
        self.assertIn("isEqualToString:expectedBaseline", body)
        self.assertNotIn("hasSuffix:CCNMMaintenanceExecutableRelativePath", body)
        self.assertNotIn("hasSuffix:CCNMMaintenanceBaselineRelativePath", body)
        # The mismatch is the only evidence in the dpkg log that the shipped
        # plist is wrong, so it has to name both sides.
        self.assertIn("does not point at this install", body)
        self.assertIn("expected %@ and %@", body)

    def test_each_missing_input_is_reported_separately(self):
        # One combined "plist, executable or prefix is unavailable" message is
        # not actionable: these fail for unrelated reasons and each needs a
        # different fix on the device.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("BOOL CCNMVerifyMaintenanceLaunchdContract"):]
        self.assertIn("The install prefix could not be determined", body)
        self.assertIn("The launchd path prefix could not be determined", body)
        self.assertIn("not set by the maintainer script", body)
        self.assertIn("is not readable at %@", body)
        self.assertIn("is missing at %@", body)
        self.assertIn("is not executable at %@", body)
        # And each names the path and the reason, so a device report is enough
        # without asking the user to run `ls` by hand.
        self.assertIn("stat errno %d", body)
        self.assertIn("mode %o", body)
        self.assertIn("readError.localizedDescription", body)
        # Path checks precede the plist contract checks: an absent file is not a
        # contract violation.
        self.assertLess(body.index("is not executable at %@"),
                        body.index("CCNMMaintainerErrorPlist"))


class SentinelHandoffTests(unittest.TestCase):
    def test_the_sentinel_is_the_only_thing_the_guard_writes_to_stdout(self):
        # stdout is a verdict channel the shell parses; stderr is prose for the
        # dpkg log. Mixing them would make the shell's decision depend on
        # wording.
        source = POSTINST_SOURCE.read_text()
        self.assertIn("CCNMMaintenanceLaunchdVerifiedSentinel", source)
        stdout_writes = re.findall(r"^\s*(?:printf|puts|fputs|fwrite)\s*\(.*",
                                   source, flags=re.MULTILINE)
        self.assertEqual(len(stdout_writes), 1, stdout_writes)
        self.assertIn("CCNMMaintenanceLaunchdVerifiedSentinel", stdout_writes[0])
        self.assertIn("fflush(stdout)", source)
        # The removal guard has no verdict to hand back at all: prerm boots the
        # job out unconditionally once the policy check is clean.
        self.assertNotIn("CCNMMaintenanceLaunchdVerifiedSentinel",
                         code_only(PRERM_SOURCE.read_text()))
        # The shared file defines the sentinel, which is the point of it being
        # shared, but it must not print anything itself: a library writing to the
        # channel the shell reads as a verdict could emit one without the
        # verification that verdict claims.
        maintainer = code_only(MAINTAINER_SOURCE.read_text())
        self.assertIn("CCNMMaintenanceLaunchdVerifiedSentinel =", maintainer)
        self.assertIsNone(
            re.search(r"^\s*(?:printf|puts|fputs|fwrite)\s*\(", maintainer,
                      flags=re.MULTILINE))

    def test_the_sentinel_is_emitted_only_after_verification_succeeds(self):
        source = POSTINST_SOURCE.read_text()
        verify = source.index("CCNMVerifyMaintenanceLaunchdContract(&launchdError)")
        emit = source.index("printf(\"%s\\n\", CCNMMaintenanceLaunchdVerifiedSentinel")
        self.assertLess(verify, emit)
        # And the failing branch says so on stderr instead of staying silent: no
        # sentinel means the shell will not load the job, and the reason has to
        # be in the log next to that decision.
        failure = source[source.index("} else {"):]
        self.assertIn("warning", failure)
        self.assertIn("launchdError.localizedDescription", failure)

    def test_one_definition_of_the_sentinel_shared_by_shell_and_guard(self):
        # A hand-copied literal on either side silently disables the load path:
        # the guard would print a line the shell never recognises, and configure
        # would look successful with no daemon running.
        literal = "launchd-contract-verified"
        self.assertIn(f'@"{literal}"', MAINTAINER_SOURCE.read_text())
        self.assertIn(f"GUARD_LAUNCHD_VERIFIED='{literal}'",
                      POSTINST_TEMPLATE.read_text())
        # prerm has no use for it; it boots the job out unconditionally once the
        # policy verdict is clean.
        self.assertNotIn(literal, PRERM_TEMPLATE.read_text())

    def test_a_failed_verification_does_not_fail_configure(self):
        # The daemon only provides automatic serving-state monitoring and owns no
        # policy or modem state. Failing configure would strand the package
        # half-installed and take away the Settings UI that performs recovery.
        source = POSTINST_SOURCE.read_text()
        verify = source.index("CCNMVerifyMaintenanceLaunchdContract(&launchdError)")
        self.assertNotIn("return CCNMPostinstBlocked", source[verify:])
        self.assertIn("return CCNMInstallAllowed", source[verify:])

    def test_prerm_leaves_stopping_the_daemon_to_the_shell(self):
        # Same exec restriction, and the ordering matters in the other direction
        # too: on a blocked removal the daemon must keep running, because the
        # package stays installed.
        source = PRERM_SOURCE.read_text()
        code = code_only(source)
        self.assertNotIn("Launchd", code)
        prerm_shell = PRERM_TEMPLATE.read_text()
        block = prerm_shell.index('if [ "$status" -ne 0 ]; then')
        self.assertLess(block, prerm_shell.index("launchd_bootout"))


class ShellOwnsLaunchctlTests(unittest.TestCase):
    def test_the_exec_logic_exists_once_and_is_substituted_into_both_scripts(self):
        self.assertTrue(LAUNCHCTL_INCLUDE.exists())
        include = LAUNCHCTL_INCLUDE.read_text()
        for helper in ("launchctl_candidates()", "resolve_launchctl()",
                       "launchd_job_is_loaded()", "launchd_bootout()"):
            self.assertIn(helper, include)
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            with self.subTest(template=template.name):
                text = template.read_text()
                self.assertIn("@LAUNCHCTL_SUPPORT@", text)
                # Definitions come from the include only.
                for helper in ("resolve_launchctl()", "launchd_bootout()"):
                    self.assertNotIn(helper, text)

    def test_the_include_does_not_test_executability_with_dash_x(self):
        # `[ -x ]` is access(X_OK), the check that returned EPERM for the real
        # binary. The exec attempt is the authority, and 126/127 are the only
        # refusals the shell can trust.
        code = "\n".join(
            line.split("#", 1)[0] for line in LAUNCHCTL_INCLUDE.read_text().splitlines())
        self.assertNotIn("-x ", code)
        self.assertIn("126", code)
        self.assertIn("127", code)

    def test_resolution_probes_with_a_side_effect_free_subcommand(self):
        # Resolution spawns real processes, so if a wrong binary sits on a
        # candidate path the first thing sent to it must be harmless.
        include = LAUNCHCTL_INCLUDE.read_text()
        resolve = include[include.index("resolve_launchctl() {"):
                          include.index("launchd_job_is_loaded() {")]
        self.assertIn('"$_candidate" version', resolve)
        # Comments stripped: the prose after this helper explains why bootstrap's
        # exit code is not trusted, and naming it there is the point.
        code = "\n".join(line.split("#", 1)[0] for line in resolve.splitlines())
        for destructive in ("bootout", "bootstrap", "kickstart"):
            self.assertNotIn(destructive, code)

    def test_candidates_are_fixed_paths_rather_than_resolved_through_path(self):
        # PATH is inherited from dpkg and this runs as root, so resolving through
        # it would let whatever is first in PATH be exec'd as root.
        include = LAUNCHCTL_INCLUDE.read_text()
        candidates = include[include.index("launchctl_candidates() {"):
                             include.index("LAUNCHCTL=''")]
        self.assertNotIn("$PATH", candidates)
        self.assertNotIn("command -v", candidates)
        for absolute in ("/usr/bin/launchctl", "/bin/launchctl",
                         "/basebin/launchctl"):
            self.assertIn(absolute, candidates)
        # roothide keeps a jbroot-aware copy in basebin, and the jbroot-absolute
        # forms cover a shell that turns out not to be redirected.
        self.assertIn('"${PREFIX_FALLBACK}/usr/bin/launchctl"', candidates)
        self.assertIn('"${PREFIX_FALLBACK}/basebin/launchctl"', candidates)

    def test_loadedness_is_asked_of_launchd_not_inferred_from_an_exit_code(self):
        # `bootstrap` returns 37/EALREADY for an already-bootstrapped job, which
        # is a success for our purposes and is exactly what the device reported.
        include = LAUNCHCTL_INCLUDE.read_text()
        loaded = include[include.index("launchd_job_is_loaded() {"):
                         include.index("launchd_bootout() {")]
        self.assertIn('print', loaded)
        postinst = POSTINST_TEMPLATE.read_text()
        bootstrap = postinst.index('"$LAUNCHCTL" bootstrap system "$LAUNCHD_PLIST"')
        verdict = postinst.index("launchd_job_is_loaded\nloaded_status=$?")
        self.assertLess(bootstrap, verdict)
        # The exit status is reported as evidence but is not the decision.
        self.assertIn("bootstrap_status=$?", postinst)
        self.assertNotIn('if [ "$bootstrap_status" -ne 0 ]', postinst)

    def test_an_unanswered_launchd_is_not_reported_as_a_refusal(self):
        # Three outcomes, not two. Collapsing "launchd did not answer" into "not
        # loaded" is a false negative that reads as good news: a bootout that
        # timed out would be reported as a job successfully removed, and a
        # bootstrap whose verification timed out as a job launchd refused.
        include = shell_code_only(LAUNCHCTL_INCLUDE.read_text())
        loaded = include[include.index("launchd_job_is_loaded() {"):
                         include.index("launchd_bootout() {")]
        self.assertIn("124|125) return 2", loaded)
        # And the callers distinguish it rather than testing truthiness, which
        # would silently fold 2 in with 1.
        self.assertNotIn("if ! launchd_job_is_loaded", include)
        self.assertNotIn("launchd_job_is_loaded ||", include)
        postinst = shell_code_only(POSTINST_TEMPLATE.read_text())
        self.assertNotIn("if ! launchd_job_is_loaded", postinst)
        self.assertIn('[ "$loaded_status" -eq 2 ]', postinst)

    def test_the_install_never_kickstarts_the_job(self):
        # kickstart was the only call that ever hit the deadline on the reporting
        # device, and it buys nothing. The plist's KeepAlive PathState names the
        # policy baseline, so launchd starts the job itself once that file exists;
        # bootout+bootstrap already guarantees the loaded definition is this
        # package's. kickstart -k on a job launchd had just started only kills it
        # and pays ThrottleInterval to start it again.
        for text in (POSTINST_TEMPLATE.read_text(), PRERM_TEMPLATE.read_text(),
                     LAUNCHCTL_INCLUDE.read_text()):
            self.assertNotIn("kickstart", shell_code_only(text))

    def test_a_stale_definition_is_booted_out_before_bootstrap_and_reported(self):
        # bootstrap returns 37/EALREADY without reloading, so launchd would keep a
        # previous version's definition. On the reporting device that is also what
        # preserved runs = 108 and the 1200-second backoff across attempts.
        #
        # And the failure is reported. The reporting device's jbroot identifier
        # changed between two installs, so a definition left by the earlier one
        # names an executable under a bootstrap that no longer exists. launchd then
        # holds a job it can never start, which looks exactly like "loaded and
        # healthy" in the log unless bootout says it could not clear it.
        postinst = POSTINST_TEMPLATE.read_text()
        self.assertLess(postinst.index("launchd_bootout"),
                        postinst.index('"$LAUNCHCTL" bootstrap system'))
        self.assertIn("bootout_status=$?", postinst)
        self.assertNotIn("launchd_bootout || :", postinst)

    def test_an_unusable_launchctl_is_a_notice_rather_than_a_warning(self):
        # The plist is correct on disk and this package's own postinst is the only
        # thing that loads it, so only the immediate load was impossible.
        postinst = POSTINST_TEMPLATE.read_text()
        branch = postinst[postinst.index("if ! resolve_launchctl; then"):
                          postinst.index("launchd_bootout")]
        self.assertIn("note ", branch)
        self.assertNotIn("warn ", branch)
        self.assertIn("Reinstall the package", branch)
        self.assertIn("LAUNCHCTL_REPORT", branch)

    def test_no_message_offers_a_reboot_as_the_way_to_start_the_daemon(self):
        # Wrong advice this project shipped once and must not ship again. Two
        # independent reasons, both specific to this platform: nothing in the
        # jailbreak walks <jbroot>/Library/LaunchDaemons at startup -- the ordinary
        # daemons in the bootstrap tarball are loaded by their own extrainst_, and
        # basebin's by bootstrapd through the native API -- and a plain reboot ends
        # the jailbreak entirely, with re-jailbreaking relocating the tree to a
        # freshly randomised jailbreak root. So a reboot is the one thing that
        # cannot start this job. Reinstalling is the retry.
        #
        # Scoped to starting, because the opposite direction is true and prerm says
        # it: a reboot does stop a daemon that is already running.
        starting = ("start", "load", "running", "begin")
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            messages = [line for line in template.read_text().splitlines()
                        if line.lstrip().startswith(("note ", "warn "))]
            self.assertTrue(messages, template)
            for line in messages:
                for claim in ("after the next reboot", "at the next reboot",
                              "at the next boot"):
                    if claim not in line:
                        continue
                    clause = line[:line.index(claim)].rsplit(".", 1)[-1].lower()
                    for verb in starting:
                        self.assertNotIn(verb, clause, line)

    def test_the_label_and_plist_path_are_rendered_not_hand_copied(self):
        # A label copied by hand could drift from the one inside the plist, and
        # the contract check would not catch it: launchctl would load the plist
        # and the verification would then ask launchd about a job nobody
        # registered.
        for template in (POSTINST_TEMPLATE, PRERM_TEMPLATE):
            with self.subTest(template=template.name):
                text = template.read_text()
                self.assertIn("LAUNCHD_LABEL='@LAUNCHD_LABEL@'", text)
                self.assertIn('LAUNCHD_TARGET="system/${LAUNCHD_LABEL}"', text)
                body = text[text.index("SCHEME_PREFIX="):]
                self.assertNotIn("me.nixuge.networkmanager.maintenance", body)
        self.assertIn("LAUNCHD_PLIST='@LAUNCHD_PLIST@'",
                      POSTINST_TEMPLATE.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
