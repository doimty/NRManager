"""Behavioral tests for the launchctl probe ordering used by maintainer scripts.

Two device rounds were lost to guessing this list. The device evidence that
settled it:

    /bin/launchctl -> .jbroot/usr/bin/launchctl   (a dangling relative symlink)
    /usr/bin/launchctl                             (the real binary)
    ls / -> Applications bin basebin ... rootfs usr var

So the maintainer script's own view of `/` already contains a working
`/usr/bin/launchctl`, while `/bin/launchctl` is a symlink whose target only
resolves from a different vantage point. The previous ordering probed the
rooted prefix and then the bare paths, which meant `<jbroot>/basebin`,
`<jbroot>/bin`, ... then `/basebin`, `/bin` — and never the surviving
`/usr/bin` before giving up, because the jbroot-prefixed candidates and the
bare ones were the only two families tried.

These tests compile and run the real C implementation over recorded device
shapes rather than asserting on source text, because the risk is ordering and
coverage, not wording.
"""

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "package-actions" / "CCNMLaunchctlProbe.c"
HEADER_DIR = ROOT / "package-actions"
MAINTAINER_SOURCE = ROOT / "package-actions" / "CCNMMaintainerEnvironment.m"
ACTIONS_MAKEFILE = ROOT / "package-actions" / "Makefile"

BASENAMES = (
    "/basebin/launchctl",
    "/bin/launchctl",
    "/sbin/launchctl",
    "/usr/bin/launchctl",
    "/usr/sbin/launchctl",
)

# The jbroot observed on the user's device.
DEVICE_JBROOT = "/var/containers/Bundle/Application/.jbroot-5029FE44E9576A17"

HARNESS = r"""
#include <stdio.h>
#include <stdlib.h>
#include "CCNMLaunchctlProbe.h"

int main(int argc, char **argv) {
    const char *jbroot = argc > 1 && argv[1][0] != '\0' ? argv[1] : NULL;
    const char *path = argc > 2 && argv[2][0] != '\0' ? argv[2] : NULL;
    char *buffer[64];
    size_t count = CCNMBuildLaunchctlProbeOrder(jbroot, path, buffer, 64);
    for (size_t index = 0; index < count; index++) {
        printf("%s\n", buffer[index]);
        free(buffer[index]);
    }
    return 0;
}
"""


class LaunchctlProbeOrderTests(unittest.TestCase):
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

    def order(self, jbroot="", env_path=""):
        completed = subprocess.run(
            [str(self.binary), jbroot, env_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout.split()

    def test_device_shape_reaches_the_binary_that_actually_exists(self):
        # The regression this module exists for: /usr/bin/launchctl is present
        # in the script's own view of '/' and must be probed.
        order = self.order(DEVICE_JBROOT)
        self.assertIn("/usr/bin/launchctl", order)
        # It must be reached before the search would have given up, i.e. it is
        # in the bare-root family, not only behind some prefix.
        self.assertLess(
            order.index("/usr/bin/launchctl"),
            order.index("/rootfs/basebin/launchctl"),
        )

    def test_jbroot_family_is_preferred_over_the_current_view(self):
        # A jbroot-aware wrapper translates jbroot paths; the system copy does
        # not, so it stays the first preference when it exists.
        order = self.order(DEVICE_JBROOT)
        self.assertEqual(order[0], f"{DEVICE_JBROOT}/basebin/launchctl")
        for basename in BASENAMES:
            self.assertLess(
                order.index(DEVICE_JBROOT + basename),
                order.index(basename),
            )

    def test_prefix_families_appear_in_documented_order(self):
        order = self.order(DEVICE_JBROOT)
        families = ("/basebin/launchctl", "/rootfs/basebin/launchctl",
                    "/var/jb/basebin/launchctl")
        positions = [order.index(entry) for entry in families]
        self.assertEqual(positions, sorted(positions))

    def test_every_prefix_covers_every_basename(self):
        order = self.order(DEVICE_JBROOT)
        for prefix in (DEVICE_JBROOT, "", "/rootfs", "/var/jb"):
            for basename in BASENAMES:
                with self.subTest(prefix=prefix, basename=basename):
                    self.assertIn(prefix + basename, order)

    def test_path_entries_are_probed_last_and_filtered(self):
        order = self.order(
            DEVICE_JBROOT, "/usr/local/bin:relative/bin::/opt/tools"
        )
        self.assertIn("/usr/local/bin/launchctl", order)
        self.assertIn("/opt/tools/launchctl", order)
        # Relative and empty PATH entries are ambiguous inside dpkg.
        self.assertNotIn("relative/bin/launchctl", order)
        self.assertFalse([entry for entry in order if not entry.startswith("/")])
        # PATH is the least controlled input, so it comes after the known views.
        self.assertGreater(
            order.index("/usr/local/bin/launchctl"),
            order.index("/var/jb/usr/sbin/launchctl"),
        )

    def test_duplicates_are_removed_keeping_highest_preference(self):
        # A PATH that repeats a known directory must not add a second entry.
        order = self.order(DEVICE_JBROOT, "/usr/bin:/usr/bin:/bin")
        self.assertEqual(order.count("/usr/bin/launchctl"), 1)
        self.assertEqual(order.count("/bin/launchctl"), 1)
        self.assertEqual(len(order), len(set(order)))

    def test_jbroot_equal_to_a_known_prefix_does_not_duplicate(self):
        order = self.order("/var/jb")
        self.assertEqual(order.count("/var/jb/bin/launchctl"), 1)
        self.assertEqual(len(order), len(set(order)))

    def test_trailing_slashes_do_not_defeat_duplicate_detection(self):
        order = self.order("/rootfs/")
        self.assertEqual(order.count("/rootfs/bin/launchctl"), 1)
        self.assertNotIn("/rootfs//bin/launchctl", order)

    def test_missing_jbroot_still_probes_every_view(self):
        order = self.order("")
        self.assertIn("/usr/bin/launchctl", order)
        self.assertIn("/rootfs/usr/bin/launchctl", order)
        self.assertIn("/var/jb/basebin/launchctl", order)
        self.assertEqual(order[0], "/basebin/launchctl")

    def test_all_candidates_are_absolute(self):
        for entry in self.order(DEVICE_JBROOT, "/usr/local/bin"):
            self.assertTrue(entry.startswith("/"), entry)


class LaunchctlDiagnosticsTests(unittest.TestCase):
    def test_maintainer_uses_the_shared_ordering_and_ships_it(self):
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMBuildLaunchctlProbeOrder", source)
        makefile = ACTIONS_MAKEFILE.read_text()
        for line in makefile.splitlines():
            if line.startswith(("postinst_FILES", "prerm_FILES")):
                self.assertIn("CCNMLaunchctlProbe.c", line)

    def test_lookup_failure_reports_every_probed_path_with_errno(self):
        # Two rounds were spent asking the user to run `ls` by hand. The failure
        # message must carry the evidence itself.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static NSString *CCNMLaunchctlResolution"):
                      source.index("static NSString *CCNMLaunchctlPath")]
        self.assertIn("errno = 0;", body)
        self.assertIn("errno %d", body)
        self.assertIn("probed", body)
        # Output must stay bounded so one failure cannot flood the dpkg log.
        self.assertIn("CCNMLaunchctlReportLimit", body)
        self.assertIn("and %lu more", body)

    def test_both_launchctl_failures_share_the_diagnostic_message(self):
        source = MAINTAINER_SOURCE.read_text()
        # The old messages carried no evidence at all.
        self.assertNotIn('@"launchctl is unavailable."', source)
        self.assertNotIn("not found under the jailbreak root or the system paths",
                         source)
        self.assertEqual(source.count("CCNMLaunchctlUnavailableMessage()"), 2)
        self.assertIn("static NSString *CCNMLaunchctlUnavailableMessage(void)", source)

    def test_resolution_is_computed_once(self):
        # access() results are cached deliberately: a maintainer script is
        # short-lived, and repeating the probe would repeat the report.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static NSString *CCNMLaunchctlResolution"):
                      source.index("static NSString *CCNMLaunchctlPath")]
        self.assertIn("dispatch_once", body)


if __name__ == "__main__":
    unittest.main()
