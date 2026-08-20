"""Behavioral tests for the launchctl probe used by maintainer scripts.

Three rounds were lost here. The shipped probe table finally settled it, and the
decisive detail is the errno column:

    <jbroot>/bin/launchctl(errno 1)      the relative symlink
    <jbroot>/usr/bin/launchctl(errno 1)  the real 113664-byte binary
    every bare, /rootfs and /var/jb candidate(errno 2)

errno 1 is EPERM, not ENOENT. The file is there and `access(X_OK)` refuses to
answer for it, because on this platform the X_OK check goes through an
exec-authorization hook. So access(X_OK) was never a usable oracle, and the
earlier rounds were asking the wrong question of the filesystem. The ENOENT on
every bare candidate separately proves the maintainer script's `/` is not the
jbroot, even though the user's shell sees it that way, so jbroot-relative
probing is required.

Consequence, and what these tests pin: stat(2) may only rule a candidate out
when it is definitively absent or not a regular file; anything inconclusive
(notably EPERM/EACCES) must still be tried, and the exec attempt is the real
arbiter. PATH-derived candidates additionally have to be root-owned and not
group/world writable, since a root process must not exec a binary a non-root
user could have replaced.

Tests compile and run the real C implementation over recorded device shapes
rather than asserting on source text, because the risk is ordering, gating and
coverage, not wording.
"""

import errno
import os
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
#include <string.h>
#include "CCNMLaunchctlProbe.h"

static int order_main(const char *jbroot, const char *path) {
    char *buffer[64];
    size_t boundary = 0;
    size_t count = CCNMBuildLaunchctlProbeOrder(
        jbroot && jbroot[0] ? jbroot : NULL,
        path && path[0] ? path : NULL,
        buffer, 64, &boundary);
    printf("boundary %zu\n", boundary);
    for (size_t index = 0; index < count; index++) {
        printf("%s\n", buffer[index]);
        free(buffer[index]);
    }
    return 0;
}

static int gate_main(const char *path, const char *mode) {
    int probeErrno = -1;
    int unusable = CCNMLaunchctlCandidateIsUnusable(
        path && path[0] ? path : NULL, strcmp(mode, "strict") == 0, &probeErrno);
    printf("%d %d\n", unusable, probeErrno);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "gate") == 0) {
        return gate_main(argc > 2 ? argv[2] : "", argc > 3 ? argv[3] : "lenient");
    }
    return order_main(argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : "");
}
"""


def build_harness():
    directory = pathlib.Path(tempfile.mkdtemp())
    harness = directory / "harness.c"
    harness.write_text(HARNESS)
    binary = directory / "harness"
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
            str(binary),
        ],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise unittest.SkipTest(
            f"host C compiler unavailable or failed: {completed.stderr}"
        )
    return directory, binary


class LaunchctlProbeOrderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory, cls.binary = build_harness()

    def run_order(self, jbroot="", env_path=""):
        completed = subprocess.run(
            [str(self.binary), jbroot, env_path],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        lines = completed.stdout.split("\n")
        boundary = int(lines[0].split()[1])
        return boundary, [line for line in lines[1:] if line]

    def order(self, jbroot="", env_path=""):
        return self.run_order(jbroot, env_path)[1]

    def test_device_shape_reaches_the_binary_that_actually_exists(self):
        # /usr/bin/launchctl must be probed both under the jbroot (where the
        # device reported EPERM, i.e. it is really there) and bare.
        order = self.order(DEVICE_JBROOT)
        self.assertIn(f"{DEVICE_JBROOT}/usr/bin/launchctl", order)
        self.assertIn("/usr/bin/launchctl", order)
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

    def test_boundary_marks_where_path_candidates_begin(self):
        # The caller applies the stricter ownership gate from this index on, so a
        # wrong boundary would either skip the gate or over-apply it.
        boundary, order = self.run_order(DEVICE_JBROOT, "/usr/local/bin")
        self.assertEqual(order[boundary], "/usr/local/bin/launchctl")
        self.assertTrue(all(
            not entry.startswith("/usr/local/bin/") for entry in order[:boundary]
        ))

    def test_boundary_equals_count_when_path_is_empty(self):
        boundary, order = self.run_order(DEVICE_JBROOT, "")
        self.assertEqual(boundary, len(order))

    def test_boundary_accounts_for_path_entries_dropped_as_duplicates(self):
        # A PATH that only repeats known directories contributes nothing, so no
        # candidate may be treated as PATH-sourced.
        boundary, order = self.run_order(DEVICE_JBROOT, "/usr/bin:/bin")
        self.assertEqual(boundary, len(order))

    def test_duplicates_are_removed_keeping_highest_preference(self):
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


class LaunchctlCandidateGateTests(unittest.TestCase):
    """The gate may only rule out candidates a spawn could not possibly use."""

    @classmethod
    def setUpClass(cls):
        cls.directory, cls.binary = build_harness()
        cls.sandbox = pathlib.Path(tempfile.mkdtemp())

    def gate(self, path, strict=False):
        completed = subprocess.run(
            [str(self.binary), "gate", str(path), "strict" if strict else "lenient"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        unusable, reported = completed.stdout.split()
        return int(unusable), int(reported)

    def make(self, name, mode=0o755, content=b"#!/bin/sh\n"):
        path = self.sandbox / name
        path.write_bytes(content)
        path.chmod(mode)
        return path

    def test_regular_executable_file_is_accepted(self):
        unusable, reported = self.gate(self.make("plain"))
        self.assertEqual((unusable, reported), (0, 0))

    def test_missing_path_is_rejected_as_absent(self):
        unusable, reported = self.gate(self.sandbox / "absent")
        self.assertEqual(unusable, 1)
        self.assertEqual(reported, errno.ENOENT)

    def test_dangling_symlink_is_rejected(self):
        # This is exactly /bin/launchctl -> .jbroot/usr/bin/launchctl on device.
        link = self.sandbox / "dangling"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(self.sandbox / "nowhere")
        unusable, reported = self.gate(link)
        self.assertEqual(unusable, 1)
        self.assertEqual(reported, errno.ENOENT)

    def test_live_symlink_is_judged_by_its_target(self):
        target = self.make("target")
        link = self.sandbox / "live"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
        self.assertEqual(self.gate(link), (0, 0))

    def test_directory_is_rejected(self):
        directory = self.sandbox / "adir"
        directory.mkdir(exist_ok=True)
        unusable, _ = self.gate(directory)
        self.assertEqual(unusable, 1)

    def test_empty_and_null_paths_are_rejected(self):
        unusable, reported = self.gate("")
        self.assertEqual(unusable, 1)
        self.assertEqual(reported, errno.EINVAL)

    def test_non_executable_regular_file_is_still_attempted(self):
        # The regression that cost the last round: executability is not the
        # gate's business, because access(X_OK) lied about the real binary.
        # Only the exec attempt decides.
        self.assertEqual(self.gate(self.make("noexec", mode=0o644)), (0, 0))

    def test_unreadable_parent_directory_is_inconclusive_not_rejected(self):
        # An EACCES from stat means "cannot tell", which must not be treated as
        # absent. Skips when running as root, where the permission does not bite.
        if os.geteuid() == 0:
            self.skipTest("root bypasses directory permissions")
        closed = self.sandbox / "closed"
        closed.mkdir(exist_ok=True)
        target = closed / "launchctl"
        target.write_bytes(b"#!/bin/sh\n")
        target.chmod(0o755)
        closed.chmod(0o000)
        try:
            unusable, reported = self.gate(target)
        finally:
            closed.chmod(0o755)
        self.assertEqual(unusable, 0, "EACCES must stay inconclusive")
        self.assertEqual(reported, errno.EACCES)

    def test_strict_mode_rejects_group_or_world_writable_binaries(self):
        # PATH is inherited from dpkg; a root process must not exec a binary a
        # non-root user could have replaced.
        writable = self.make("groupwritable", mode=0o775)
        self.assertEqual(self.gate(writable, strict=False), (0, 0))
        unusable, reported = self.gate(writable, strict=True)
        self.assertEqual(unusable, 1)
        if os.geteuid() == 0:
            # Owned by root, so the write-permission check is what rejects it.
            self.assertEqual(reported, errno.EACCES)
        else:
            # Owned by the test user, so either guard may fire first.
            self.assertIn(reported, (errno.EPERM, errno.EACCES))

    def test_strict_mode_rejects_non_root_owned_binaries(self):
        if os.geteuid() == 0:
            self.skipTest("cannot create a non-root-owned file as root")
        owned = self.make("useowned")
        unusable, reported = self.gate(owned, strict=True)
        self.assertEqual(unusable, 1)
        self.assertEqual(reported, errno.EPERM)

    def test_strict_mode_accepts_a_root_owned_non_writable_binary(self):
        if os.geteuid() != 0:
            self.skipTest("cannot create a root-owned file as a normal user")
        self.assertEqual(self.gate(self.make("rootowned"), strict=True), (0, 0))


class LaunchctlDiagnosticsTests(unittest.TestCase):
    def test_maintainer_uses_the_shared_ordering_and_ships_it(self):
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMBuildLaunchctlProbeOrder", source)
        makefile = ACTIONS_MAKEFILE.read_text()
        for line in makefile.splitlines():
            if line.startswith(("postinst_FILES", "prerm_FILES")):
                self.assertIn("CCNMLaunchctlProbe.c", line)

    def test_access_x_ok_is_never_used_to_resolve_launchctl(self):
        # The whole point of this round: on device the real binary returned
        # EPERM from access(X_OK). Resolution must come from the spawn.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("// launchctl lookup."):
                      source.index("static BOOL CCNMJobIsLoaded")]
        code = "\n".join(
            line for line in body.splitlines()
            if not line.lstrip().startswith("//")
        )
        self.assertNotIn("access(", code)
        self.assertIn("posix_spawn", code)
        self.assertIn("spawnErrno", code)

    def test_resolution_survives_a_nonzero_exit_status(self):
        # launchctl answering "no such job" still proves the binary runs, so
        # resolution must key on the exec result, not the exit code.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static int CCNMRunLaunchctl"):
                      source.index("static BOOL CCNMLaunchctlIsUsable")]
        self.assertIn("if (spawnErrno == 0) {", body)
        self.assertIn("CCNMLaunchctlResolved = candidate;", body)

    def test_availability_probe_uses_a_side_effect_free_subcommand(self):
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static BOOL CCNMLaunchctlIsUsable"):
                      source.index("static NSString *CCNMLaunchctlUnavailableMessage")]
        self.assertIn('@"version"', body)
        for destructive in ("bootout", "bootstrap", "kickstart"):
            self.assertNotIn(destructive, body)

    def test_path_sourced_candidates_get_the_stricter_gate(self):
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMLaunchctlPathSourcedFrom", source)
        body = source[source.index("static int CCNMRunLaunchctl"):
                      source.index("static BOOL CCNMLaunchctlIsUsable")]
        self.assertIn("pathSourced", body)

    def test_lookup_failure_reports_every_probed_path_with_errno(self):
        # Rounds were spent asking the user to run `ls` by hand. The failure
        # message must carry the evidence, and distinguish the two rejection
        # kinds, because that distinction is what finally diagnosed this.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static int CCNMRunLaunchctl"):
                      source.index("static BOOL CCNMLaunchctlIsUsable")]
        self.assertIn("stat errno %d", body)
        self.assertIn("spawn errno %d", body)
        self.assertIn("probed", body)
        # Output must stay bounded so one failure cannot flood the dpkg log.
        self.assertIn("CCNMLaunchctlReportLimit", body)
        self.assertIn("and %lu more", body)

    def test_both_launchctl_failures_share_the_diagnostic_message(self):
        source = MAINTAINER_SOURCE.read_text()
        # Older messages carried no evidence, or claimed the file was missing
        # when it was present but unspawnable.
        self.assertNotIn('@"launchctl is unavailable."', source)
        self.assertNotIn("not found under the jailbreak root or the system paths",
                         source)
        self.assertNotIn("launchctl was not found in any known location", source)
        self.assertIn("could not be run from any known location", source)
        self.assertEqual(source.count("CCNMLaunchctlUnavailableMessage()"), 2)
        self.assertIn("static NSString *CCNMLaunchctlUnavailableMessage(void)", source)

    def test_no_destructive_subcommand_can_be_the_resolving_call(self):
        # Resolution spawns real commands, so if a wrong binary sat on one of
        # the candidate paths, the first thing sent to it must be harmless.
        # Both public entry points resolve through `version` before issuing
        # bootout/bootstrap/kickstart.
        source = MAINTAINER_SOURCE.read_text()
        stop = source[source.index("BOOL CCNMStopMaintenanceLaunchd"):
                      source.index("CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd")]
        self.assertLess(stop.index("CCNMLaunchctlIsUsable()"),
                        stop.index('@"bootout"'))
        register = source[
            source.index("CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd"):]
        self.assertLess(register.index("CCNMLaunchctlIsUsable()"),
                        register.index('@"bootstrap"'))

    def test_a_missing_launchctl_does_not_discard_the_written_plist(self):
        # The plist is what makes the job loadable at the next boot, so an
        # unusable launchctl must degrade to deferred, not fail. Preparing the
        # plist must therefore not require launchctl at all.
        source = MAINTAINER_SOURCE.read_text()
        prepare = source[source.index("BOOL CCNMPrepareMaintenanceLaunchd"):
                         source.index("BOOL CCNMStopMaintenanceLaunchd")]
        self.assertNotIn("CCNMLaunchctlIsUsable", prepare)
        self.assertNotIn("CCNMMaintainerErrorLaunchctl", prepare)
        register = source[
            source.index("CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd"):]
        # Prepare runs first and is the only hard failure before launchctl.
        self.assertLess(register.index("CCNMPrepareMaintenanceLaunchd(error)"),
                        register.index("CCNMLaunchctlIsUsable()"))
        self.assertIn("return CCNMMaintenanceRegistrationDeferred;", register)
        # postinst must distinguish deferred from failed.
        postinst = (ROOT / "package-actions" / "postinst.m").read_text()
        self.assertIn("CCNMMaintenanceRegistrationDeferred", postinst)
        self.assertIn("after the next reboot", postinst)
        self.assertNotIn(
            "will be unavailable.\\n\",\n                launchdError", postinst[
                postinst.index("CCNMMaintenanceRegistrationDeferred"):
                postinst.index("CCNMMaintenanceRegistrationFailed")])

    def test_prerm_does_not_advise_manual_launchd_cleanup(self):
        # dpkg removes the plist with the package, so there is no stale entry to
        # clean up by hand and no useful action to hand the user.
        prerm = (ROOT / "package-actions" / "prerm.m").read_text()
        self.assertNotIn("cleaned up manually", prerm)
        self.assertIn("will not return after a reboot", prerm)

    def test_a_failed_resolution_is_not_retried(self):
        # Resolution spawns real processes. Retrying on every subsequent call
        # would multiply the spawn attempts and rebuild the same report, and
        # nothing on disk changes during a maintainer script's lifetime.
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMLaunchctlResolutionFailed = YES;", source)
        body = source[source.index("static int CCNMRunLaunchctl"):
                      source.index("static BOOL CCNMLaunchctlIsUsable")]
        self.assertIn("if (CCNMLaunchctlResolutionFailed) {", body)

    def test_probe_order_is_computed_once(self):
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static NSArray<NSString *> *CCNMLaunchctlProbeOrder"):
                      source.index("static int CCNMSpawnLaunchctl")]
        self.assertIn("dispatch_once", body)


if __name__ == "__main__":
    unittest.main()
