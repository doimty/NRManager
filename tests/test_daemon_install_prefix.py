#!/usr/bin/env python3
"""Behavioral tests for the maintenance daemon's install-prefix recovery.

The daemon had never started once. launchd reported

    runs = 108
    successive crashes = 108
    last exit reason = OS_REASON_DYLD

and running it by hand with a cleaned environment printed the cause:

    dyld: Library not loaded: @loader_path/.jbroot/usr/lib/libroothide.dylib
      Referenced from: <jbroot>/usr/libexec/nrmanager-maintenance
      Reason: tried: '<jbroot>/usr/libexec/.jbroot/usr/lib/libroothide.dylib'
        (no such file), '/usr/local/lib/libroothide.dylib' (no such file),
        '/usr/lib/libroothide.dylib' (no such file)

libroothide is reachable only through a .jbroot symlink beside the loading binary
or from a process that already has it loaded. The bootstrap ships such a symlink in
each of its own directories, and injected processes have the library, which is why
the Control Center and Preferences bundles link it safely. A launchd daemon is
neither: launchd applies no bootstrap injection and dpkg does not create a .jbroot
beside an installed helper.

So the daemon recovers its prefix from its own executable path. The arithmetic is
kept in plain C precisely so these tests can compile and run the shipped
implementation on any host: the risk is in the string handling, where a prefix
recovered one component short still looks plausible and would read policy from a
directory that does not exist -- which CCNMPolicySummaryIsStableEnabled would then
report as "not enabled", indistinguishable from a real disabled state.
"""

import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DAEMON = ROOT / "maintenance-daemon"
SOURCE = DAEMON / "CCNMDaemonRoot.c"
OBJC_SOURCE = DAEMON / "CCNMDaemonRoot.m"
HEADER = DAEMON / "CCNMDaemonRoot.h"
MAKEFILE = DAEMON / "Makefile"
READER = ROOT / "nrmanagerprefs" / "CCNMN78PolicyReader.m"
RECORD = ROOT / "nrmanagerprefs" / "CCNMAutomaticMaintenanceRecord.m"
INSTALLED = "/usr/libexec/nrmanager-maintenance"

# The jbroot on the reporting device, in both spellings it appeared in. dyld named
# the /private form while launchctl and the user's shell used the short one.
DEVICE_JBROOT = "/var/containers/Bundle/Application/.jbroot-FD0B70513C6A9312"
DEVICE_JBROOT_PRIVATE = "/private" + DEVICE_JBROOT

HARNESS = r"""
#include <stdio.h>
#include "CCNMDaemonRoot.h"

int main(int argc, char *argv[]) {
    if (argc < 2) {
        return 2;
    }
    ssize_t length = CCNMDaemonPrefixLength(argv[1]);
    if (length < 0) {
        printf("nil\n");
        return 0;
    }
    printf("[%.*s]\n", (int)length, argv[1]);
    return 0;
}
"""


class PrefixRecoveryTests(unittest.TestCase):
    """Runs the shipped implementation. Assertions on source text cannot catch an
    off-by-one in the suffix arithmetic, which is the failure mode that matters."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.mkdtemp()
        harness = pathlib.Path(cls.directory) / "harness.c"
        harness.write_text(HARNESS)
        cls.binary = pathlib.Path(cls.directory) / "harness"
        build = subprocess.run(
            ["cc", "-std=c11", "-Wall", "-Werror", "-I", str(DAEMON),
             str(harness), str(SOURCE), "-o", str(cls.binary)],
            capture_output=True, text=True)
        if build.returncode != 0:
            raise AssertionError(f"cannot build harness: {build.stderr}")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.directory, ignore_errors=True)

    def prefix(self, path):
        result = subprocess.run([str(self.binary), path],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout.strip()
        if output == "nil":
            return None
        self.assertTrue(output.startswith("[") and output.endswith("]"), output)
        return output[1:-1]

    def test_the_reporting_devices_path_yields_its_jailbreak_root(self):
        self.assertEqual(self.prefix(DEVICE_JBROOT + INSTALLED), DEVICE_JBROOT)

    def test_the_private_var_spelling_yields_that_same_spelling(self):
        # Both spellings name the same directory and both are usable prefixes, so
        # the /private form must not be rejected for being non-canonical. dyld
        # reported this one.
        self.assertEqual(self.prefix(DEVICE_JBROOT_PRIVATE + INSTALLED),
                         DEVICE_JBROOT_PRIVATE)

    def test_the_rootless_lane_yields_var_jb(self):
        self.assertEqual(self.prefix("/var/jb" + INSTALLED), "/var/jb")

    def test_a_bare_install_yields_an_empty_prefix_not_a_failure(self):
        # An empty prefix is the successful answer meaning "bare paths already
        # resolve". Treating it as failure would break the rootful lane and any
        # bootstrap that installs at the real root.
        self.assertEqual(self.prefix(INSTALLED), "")

    def test_a_relative_path_is_refused(self):
        # It resolves against a working directory launchd does not guarantee, so
        # it cannot identify a root.
        self.assertIsNone(self.prefix("usr/libexec/nrmanager-maintenance"))
        self.assertIsNone(self.prefix("./usr/libexec/nrmanager-maintenance"))

    def test_a_different_executable_is_refused(self):
        self.assertIsNone(self.prefix("/usr/libexec/some-other-tool"))
        self.assertIsNone(self.prefix("/usr/bin/nrmanager-maintenance"))

    def test_an_empty_or_root_path_is_refused(self):
        self.assertIsNone(self.prefix(""))
        self.assertIsNone(self.prefix("/"))

    def test_a_prefix_that_repeats_the_install_path_keeps_only_the_last_match(self):
        # Suffix arithmetic, not a component search. A search for the first
        # occurrence would cut here and produce a prefix that is a real directory,
        # so every later read would fail quietly rather than visibly.
        self.assertEqual(self.prefix(INSTALLED + INSTALLED), INSTALLED)

    def test_a_near_miss_suffix_is_refused(self):
        # Guards against matching on something that is not a component boundary.
        self.assertIsNone(
            self.prefix("/var/jb/usr/libexec/nrmanager-maintenance-old"))
        self.assertIsNone(
            self.prefix("/var/jb/usr/libexec/xnrmanager-maintenance"))

    def test_a_path_shorter_than_the_suffix_is_refused_without_reading_past_it(self):
        # The length guard, exercised directly. Built with -Werror, and a missing
        # guard here is an out-of-bounds read rather than a wrong answer.
        for short in ("/usr", "/usr/libexec", "/nrmanager-maintenance"):
            with self.subTest(path=short):
                self.assertIsNone(self.prefix(short))


class DaemonRootSourceTests(unittest.TestCase):
    def test_the_daemon_does_not_link_libroothide(self):
        # This is the fix. Linking it puts
        # @loader_path/.jbroot/usr/lib/libroothide.dylib in LC_LOAD_DYLIB, and
        # nothing resolves that for a launchd daemon.
        makefile = MAKEFILE.read_text()
        code = "\n".join(line for line in makefile.splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertNotIn("LIBRARIES = roothide", code)
        self.assertNotIn("-lroothide", code)
        # And the reason has to stay in the file, because the obvious "fix" for an
        # unresolved jbroot symbol is to link the library back in.
        self.assertIn("OS_REASON_DYLD", makefile)

    def test_the_daemon_link_does_not_defer_missing_symbols(self):
        # -undefined dynamic_lookup turns an absent symbol into a successful link
        # and a runtime death when dyld binds it -- the same failure shape as the
        # libroothide crash, from a different cause. Verified by removing
        # CCNMDaemonRoot.m from the file list: with the flag the link succeeds,
        # without it the link fails on _CCNMDaemonRootedPath.
        code = "\n".join(line for line in MAKEFILE.read_text().splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertNotIn("dynamic_lookup", code)
        self.assertNotIn("flat_namespace", code)
        # No lane may reintroduce it, so there must be no scheme conditional left
        # in this makefile at all.
        self.assertNotIn("THEOS_PACKAGE_SCHEME", code)

    def test_both_prefix_sources_are_built_into_the_daemon(self):
        makefile = MAKEFILE.read_text()
        self.assertIn("CCNMDaemonRoot.c", makefile)
        self.assertIn("CCNMDaemonRoot.m", makefile)

    def test_the_daemon_lane_switch_is_set_for_every_scheme(self):
        # rootless installs under /var/jb and needs a prefix too, so the switch
        # must not sit inside an ifeq on roothide.
        makefile = MAKEFILE.read_text()
        define = "-DCCNM_MAINTENANCE_DAEMON"
        self.assertIn(define, makefile)
        lines = makefile.splitlines()
        index = next(i for i, line in enumerate(lines) if define in line)
        conditional = re.compile(r"^\s*(ifeq|ifneq|ifdef|ifndef)\b")
        depth = 0
        for line in lines[:index]:
            if conditional.match(line):
                depth += 1
            elif line.strip() == "endif":
                depth -= 1
        self.assertEqual(depth, 0, "the define is inside a conditional")

    def test_both_policy_path_sources_switch_onto_the_daemon_prefix(self):
        # These two files own every path the daemon reads or writes. One left on
        # jbroot() would reintroduce the link requirement through the back door.
        for path in (READER, RECORD):
            with self.subTest(source=path.name):
                text = path.read_text()
                self.assertIn("#if defined(CCNM_MAINTENANCE_DAEMON)", text)
                branch = text[text.index("#if defined(CCNM_MAINTENANCE_DAEMON)"):
                              text.index("#elif __has_include(<roothide.h>)")]
                code = "\n".join(line for line in branch.splitlines()
                                 if not line.lstrip().startswith("//"))
                self.assertIn("CCNMDaemonRootedPath(path)", code)
                self.assertNotIn("jbroot", code)

    def test_an_unresolvable_prefix_produces_an_unusable_path(self):
        # The one thing that must never happen is a policy read that silently
        # targets the wrong root: it would report a clean state, and a clean state
        # is what authorises removing a package that still holds a forced band
        # configuration.
        source = OBJC_SOURCE.read_text()
        self.assertIn("nrmanager-unresolved-install-prefix", source)
        rooted = source[source.index("NSString *CCNMDaemonRootedPath"):]
        self.assertIn("if (!prefix)", rooted)

    def test_a_non_canonical_spelling_falls_back_to_realpath(self):
        # _NSGetExecutablePath returns whatever launchd exec'd, which need not be
        # canonical. Rejecting it outright would strand the daemon on a lane where
        # the path is reached through a symlink.
        source = OBJC_SOURCE.read_text()
        self.assertIn("realpath(", source)
        self.assertLess(source.index("_NSGetExecutablePath"),
                        source.index("realpath("))

    def test_access_is_not_used_to_validate_the_recovered_path(self):
        # Same platform trap as the maintainer guards: access(X_OK) is routed
        # through an exec-authorization hook and returned EPERM for binaries that
        # run fine. The prefix is a string operation on a path the kernel already
        # exec'd, so no filesystem predicate is needed at all.
        for path in (SOURCE, OBJC_SOURCE):
            with self.subTest(source=path.name):
                code = "\n".join(line for line in path.read_text().splitlines()
                                 if not line.lstrip().startswith("//"))
                self.assertNotIn("access(", code)

    def test_the_prefix_is_resolved_once(self):
        self.assertIn("dispatch_once", OBJC_SOURCE.read_text())


if __name__ == "__main__":
    unittest.main()
