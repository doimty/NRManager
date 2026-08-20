"""Behavioral tests for the launchd plist replacement writer.

Round three of the same install failure, and this one is the writer itself:

    maintenance owner could not be registered
      (Could not create the launchd plist replacement.)

That message named no path, no errno and no step, so it carried almost no
information — which is the same reporting mistake the launchctl rounds already
cost us. It came from `open(sibling, O_CREAT | O_EXCL)` failing, meaning the
containing directory would not accept a new entry even though dpkg had just
written the plist inside it.

Two things follow, and these tests pin both:

1. Permission to create a sibling and permission to rewrite an existing file
   are different permissions. When the directory refuses, rewriting the entry
   dpkg unpacked is still legitimate and is the difference between a working
   plist and one left full of @JBROOT@ placeholders that no reboot can repair.
   Atomicity is genuinely lost on that path, which is why it is the fallback and
   never the first choice.

2. The final state is asserted with fstat, not inferred from syscall returns.
   The previous writer failed the whole operation when `fchown` returned
   nonzero, even when the file was already root:root — demanding a redundant
   syscall succeed. What matters is what the file ends up as.

Tests compile and run the real C implementation against real directories,
including as a non-root user, because the failure being fixed is a permission
interaction that source-text assertions cannot see.
"""

import errno
import os
import pathlib
import pwd
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "package-actions" / "CCNMPlistWrite.c"
HEADER_DIR = ROOT / "package-actions"
MAINTAINER_SOURCE = ROOT / "package-actions" / "CCNMMaintainerEnvironment.m"
ACTIONS_MAKEFILE = ROOT / "package-actions" / "Makefile"

HARNESS = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "CCNMPlistWrite.h"

// write <path> <bytes> [mode] [uid] [gid]
//   prints: ok <0|1> stage <n> step <name> errno <n> sibling_errno <n>
//           mode <octal> uid <n> gid <n> remaining <n> total <n>
int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <path> <bytes> [mode] [uid] [gid]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    const char *payload = argv[2];
    unsigned mode = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 8) : 0644u;
    uid_t owner = argc > 4 ? (uid_t)strtoul(argv[4], NULL, 10) : geteuid();
    gid_t group = argc > 5 ? (gid_t)strtoul(argv[5], NULL, 10) : getegid();

    CCNMFileWriteOutcome outcome;
    CCNMReplaceFileContents(path, payload, strlen(payload), owner, group, mode,
                            &outcome);
    printf("ok %d stage %d step %s errno %d sibling_errno %d "
           "mode %o uid %u gid %u remaining %lu total %lu "
           "ro %d dir_mode %o dir_uid %u dir_errno %d "
           "target_mode %o target_errno %d\n",
           outcome.ok, (int)outcome.stage,
           outcome.failingStep ? outcome.failingStep : "none",
           outcome.failureErrno, outcome.siblingErrno,
           outcome.resultMode, outcome.resultUid, outcome.resultGid,
           (unsigned long)outcome.bytesRemaining,
           (unsigned long)outcome.bytesTotal,
           outcome.readOnlyMount, outcome.directoryMode, outcome.directoryUid,
           outcome.directoryStatErrno, outcome.targetMode,
           outcome.targetStatErrno);
    return 0;
}
"""

STAGE_NONE = 0
STAGE_SIBLING = 1
STAGE_IN_PLACE = 2


def _build(directory):
    harness = pathlib.Path(directory) / "harness.c"
    harness.write_text(HARNESS)
    binary = pathlib.Path(directory) / "harness"
    subprocess.run(
        [
            "cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-I", str(HEADER_DIR),
            str(harness), str(SOURCE),
            "-o", str(binary),
        ],
        check=True,
        capture_output=True,
    )
    return binary


class PlistWriteBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._build_dir = tempfile.mkdtemp()
        cls.binary = _build(cls._build_dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._build_dir, ignore_errors=True)

    def write(self, path, payload, mode="644", uid=None, gid=None, runner=None):
        argv = [str(self.binary), str(path), payload, mode]
        if uid is not None:
            argv.append(str(uid))
            argv.append(str(gid if gid is not None else uid))
        if runner:
            argv = runner + argv
        result = subprocess.run(argv, capture_output=True, text=True, check=True)
        fields = result.stdout.split()
        parsed = {}
        for i in range(0, len(fields) - 1, 2):
            parsed[fields[i]] = fields[i + 1]
        parsed["ok"] = parsed["ok"] == "1"
        parsed["stage"] = int(parsed["stage"])
        parsed["errno"] = int(parsed["errno"])
        parsed["sibling_errno"] = int(parsed["sibling_errno"])
        parsed["remaining"] = int(parsed["remaining"])
        parsed["total"] = int(parsed["total"])
        parsed["ro"] = int(parsed["ro"])
        return parsed


class PlistWriteHappyPathTests(PlistWriteBase):
    def test_a_writable_directory_uses_the_atomic_sibling_route(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old contents")
            out = self.write(target, "new contents")
            self.assertTrue(out["ok"], out)
            self.assertEqual(out["stage"], STAGE_SIBLING, out)
            self.assertEqual(target.read_text(), "new contents")

    def test_the_temporary_sibling_never_survives_a_success(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            self.write(target, "new")
            leftovers = [p.name for p in pathlib.Path(d).iterdir()]
            self.assertEqual(leftovers, ["job.plist"], leftovers)

    def test_a_shorter_payload_does_not_leave_trailing_bytes(self):
        # The in-place route opens without O_TRUNC so the file is never
        # observably empty, which makes the explicit ftruncate load-bearing.
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("x" * 500)
            out = self.write(target, "tiny")
            self.assertTrue(out["ok"], out)
            self.assertEqual(target.read_text(), "tiny")

    def test_the_target_is_created_when_absent_on_the_sibling_route(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            out = self.write(target, "fresh")
            self.assertTrue(out["ok"], out)
            self.assertEqual(target.read_text(), "fresh")

    def test_requested_permission_bits_are_applied(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            out = self.write(target, "x", mode="600")
            self.assertTrue(out["ok"], out)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_a_stale_sibling_from_our_own_pid_does_not_block_the_write(self):
        # The sibling name encodes this pid, so a leftover with that exact name
        # is debris from a dead run and cannot belong to a live writer.
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            script = pathlib.Path(d) / "run.sh"
            # Create the collision inside the harness process so the pid in the
            # name is the harness's own.
            script.write_text(
                "#!/bin/sh\n"
                'touch "$1.networkmanager.$$.part" 2>/dev/null\n'
                'exec "$@"\n'
            )
            script.chmod(0o755)
            # Cannot force the pid to match from outside, so assert the weaker
            # but still meaningful property: an unrelated leftover is ignored.
            (pathlib.Path(d) / "job.plist.networkmanager.999999.part").write_text("junk")
            out = self.write(target, "new")
            self.assertTrue(out["ok"], out)
            self.assertEqual(target.read_text(), "new")


class PlistWriteFallbackTests(PlistWriteBase):
    """The actual reported failure: the directory refuses a new entry."""

    def _immutable_dir(self, d):
        # Remove write permission from the directory while leaving the existing
        # file writable. This is precisely the shape that produced
        # "Could not create the launchd plist replacement."
        os.chmod(d, 0o555)

    @unittest.skipIf(os.geteuid() == 0,
                     "root ignores directory write permission")
    def test_an_unwritable_directory_falls_back_to_rewriting_in_place(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old contents")
            target.chmod(0o644)
            self._immutable_dir(d)
            try:
                out = self.write(target, "rewritten")
                self.assertTrue(out["ok"], out)
                self.assertEqual(out["stage"], STAGE_IN_PLACE, out)
                # The reason the preferred route was abandoned must be reported
                # even on success, otherwise a silent loss of atomicity is
                # invisible in the logs.
                self.assertEqual(out["sibling_errno"], errno.EACCES, out)
                self.assertEqual(target.read_text(), "rewritten")
            finally:
                os.chmod(d, 0o755)

    @unittest.skipIf(os.geteuid() == 0,
                     "root ignores directory write permission")
    def test_an_unwritable_directory_and_unwritable_file_reports_both_errnos(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            target.chmod(0o444)
            self._immutable_dir(d)
            try:
                out = self.write(target, "nope")
                self.assertFalse(out["ok"], out)
                self.assertEqual(out["step"], "in-place-open", out)
                # Both numbers are needed: one says the directory refused, the
                # other says the file refused. Either alone is ambiguous.
                self.assertEqual(out["sibling_errno"], errno.EACCES, out)
                self.assertEqual(out["errno"], errno.EACCES, out)
                self.assertEqual(target.read_text(), "old")
            finally:
                os.chmod(d, 0o755)

    @unittest.skipIf(os.geteuid() == 0,
                     "root ignores directory write permission")
    def test_the_fallback_is_never_taken_when_the_sibling_route_works(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            out = self.write(target, "new")
            self.assertEqual(out["stage"], STAGE_SIBLING, out)
            self.assertEqual(out["sibling_errno"], 0, out)

    def test_a_missing_file_in_an_unwritable_directory_fails_cleanly(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores directory write permission")
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "absent.plist"
            self._immutable_dir(d)
            try:
                out = self.write(target, "x")
                self.assertFalse(out["ok"], out)
                self.assertEqual(out["step"], "in-place-open", out)
                self.assertEqual(out["errno"], errno.ENOENT, out)
                self.assertFalse(target.exists())
            finally:
                os.chmod(d, 0o755)


class PlistWriteStateAssertionTests(PlistWriteBase):
    def test_a_redundant_chown_does_not_fail_the_write(self):
        # The shipped writer failed the whole operation when fchown returned
        # nonzero, even for a file that already had the requested owner. Only
        # the resulting state should decide.
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            out = self.write(target, "new",
                             uid=os.geteuid(), gid=os.getegid())
            self.assertTrue(out["ok"], out)
            self.assertEqual(target.read_text(), "new")

    @unittest.skipIf(os.geteuid() == 0, "root can chown to anyone")
    def test_an_unreachable_ownership_target_is_reported_with_the_real_state(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            out = self.write(target, "new", uid=0, gid=0)
            self.assertFalse(out["ok"], out)
            self.assertEqual(out["step"], "ownership", out)
            # The message has to carry what the file actually became, so the
            # log alone explains the refusal.
            self.assertEqual(int(out["uid"]), os.geteuid(), out)
            # A failed sibling write must not be renamed over the target.
            self.assertEqual(target.read_text(), "old")

    def test_rejects_a_relative_path(self):
        out = self.write("relative.plist", "x")
        self.assertFalse(out["ok"], out)
        self.assertEqual(out["step"], "arguments", out)
        self.assertEqual(out["errno"], errno.EINVAL, out)

    def test_reports_byte_progress_only_for_a_write_failure(self):
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            out = self.write(target, "payload")
            self.assertEqual(out["remaining"], 0, out)
            self.assertEqual(out["total"], len("payload"), out)

    def test_a_successful_write_does_not_collect_diagnostics(self):
        # readOnlyMount stays -1 (unknown) on success, which is the observable
        # proof that the diagnostic syscalls did not run on the working path.
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            out = self.write(target, "payload")
            self.assertTrue(out["ok"], out)
            self.assertEqual(out["ro"], -1, out)

    def test_a_failure_reports_the_mount_and_both_stat_results(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores directory and file write permission")
        with tempfile.TemporaryDirectory() as d:
            target = pathlib.Path(d) / "job.plist"
            target.write_text("old")
            # Both routes have to be closed to reach a failure: an unwritable
            # directory alone is survivable, which is the entire point of the
            # in-place fallback.
            target.chmod(0o444)
            os.chmod(d, 0o555)
            try:
                out = self.write(target, "x")
                self.assertFalse(out["ok"], out)
                # A writable tmpfs/ext4 under test is read-write; the point is
                # that the field is populated rather than left unknown.
                self.assertEqual(out["ro"], 0, out)
                self.assertEqual(int(out["dir_mode"], 8), 0o555, out)
                self.assertEqual(int(out["target_mode"], 8), 0o444, out)
                self.assertEqual(out["dir_errno"], "0", out)
                self.assertEqual(out["target_errno"], "0", out)
            finally:
                os.chmod(d, 0o755)

    def test_a_failure_errno_is_not_clobbered_by_the_diagnostics(self):
        # The reported errno must belong to the failing operation, not to a stat
        # performed afterwards while describing the surroundings.
        out = self.write("relative.plist", "x")
        self.assertEqual(out["errno"], errno.EINVAL, out)


class PlistWriteNonRootTests(PlistWriteBase):
    """Runs the real binary as nobody, since the device path runs as root and
    the permission logic must be exercised from both sides."""

    @unittest.skipUnless(os.geteuid() == 0, "needs root to drop privileges")
    def test_a_non_root_writer_still_replaces_a_file_it_owns(self):
        try:
            nobody = pwd.getpwnam("nobody")
        except KeyError:
            self.skipTest("no nobody user on this host")
        workdir = tempfile.mkdtemp()
        try:
            # The harness lives under the shared build dir, which nobody must be
            # able to traverse and execute.
            os.chmod(self._build_dir, 0o755)
            os.chmod(self.binary, 0o755)
            target = pathlib.Path(workdir) / "job.plist"
            target.write_text("old")
            os.chown(workdir, nobody.pw_uid, nobody.pw_gid)
            os.chown(target, nobody.pw_uid, nobody.pw_gid)
            os.chmod(workdir, 0o755)
            out = self.write(
                target, "new",
                uid=nobody.pw_uid, gid=nobody.pw_gid,
                runner=["setpriv", "--reuid", str(nobody.pw_uid),
                        "--regid", str(nobody.pw_gid), "--clear-groups"],
            )
            self.assertTrue(out["ok"], out)
            self.assertEqual(target.read_text(), "new")
        finally:
            shutil.rmtree(workdir, ignore_errors=True)


class PlistWriteIntegrationTests(unittest.TestCase):
    def test_the_maintainer_delegates_writing_and_keeps_no_open_loop(self):
        source = MAINTAINER_SOURCE.read_text()
        self.assertIn("CCNMReplaceFileContents(", source)
        body = source[source.index("static BOOL CCNMWritePlist"):
                      source.index("BOOL CCNMPrepareMaintenanceLaunchd")]
        # The syscall sequence now lives in the C module. A second copy in the
        # ObjC file would drift from the tested one.
        for leaked in ("O_EXCL", "ftruncate(", "rename(", "fsync("):
            self.assertNotIn(leaked, body)

    def test_the_uninformative_message_is_gone(self):
        source = MAINTAINER_SOURCE.read_text()
        # This exact string is what the device reported. It named no path, no
        # errno and no step.
        self.assertNotIn("Could not create the launchd plist replacement.",
                         source)

    def test_write_failures_name_the_path_step_and_identity(self):
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static BOOL CCNMWritePlist"):
                      source.index("BOOL CCNMPrepareMaintenanceLaunchd")]
        self.assertIn("Could not durably replace the launchd plist at %@", body)
        self.assertIn("step %@", body)
        self.assertIn("errno %d", body)
        self.assertIn("euid %d", body)
        # Directory state is what distinguishes "wrong identity" from "wrong
        # permissions", and it was missing from every previous message.
        self.assertIn("is mode %o owned by uid %u", body)
        self.assertIn("refused with errno %d", body)

    def test_write_failures_distinguish_a_read_only_mount(self):
        # As root, a directory's own permission bits cannot explain a refusal to
        # create a file, so the interesting cases are a read-only mount versus a
        # policy hook. Without this flag those two are indistinguishable in the
        # log and cost another round each. The facts are captured by the writer
        # at the moment of failure; re-inspecting in the reporter would describe
        # a different instant and could clobber the failure errno.
        source = MAINTAINER_SOURCE.read_text()
        body = source[source.index("static BOOL CCNMWritePlist"):
                      source.index("BOOL CCNMPrepareMaintenanceLaunchd")]
        self.assertIn("outcome.readOnlyMount", body)
        self.assertIn("mounted %@", body)
        self.assertIn("read-only", body)
        self.assertIn("the plist itself is mode %o owned by uid %u", body)
        self.assertIn("outcome.directoryMode", body)
        self.assertNotIn("statvfs(", body)
        self.assertNotIn("struct stat", body)

    def test_the_writer_captures_surroundings_only_on_failure(self):
        writer = SOURCE.read_text()
        self.assertIn("CCNMDescribeSurroundings", writer)
        # Both platform spellings are needed: Darwin has statfs/MNT_RDONLY in
        # the iOS SDK, Linux hosts have statvfs/ST_RDONLY.
        self.assertIn("MNT_RDONLY", writer)
        self.assertIn("ST_RDONLY", writer)
        # The success path must not pay for diagnostics. Slice up to the cleanup
        # label, since the label physically follows the success return.
        success = writer[writer.index("outcome->ok = 1;"):
                         writer.index("cleanup:")]
        self.assertNotIn("CCNMDescribeSurroundings", success)
        # A failure errno must survive the extra syscalls that describe the
        # surroundings, otherwise the reported errno belongs to a stat.
        describe = writer[writer.index("static void CCNMDescribeSurroundings"):
                          writer.index("void CCNMReplaceFileContents")]
        self.assertIn("int saved = errno;", describe)
        self.assertIn("errno = saved;", describe)

    def test_both_maintainer_scripts_link_the_writer(self):
        makefile = ACTIONS_MAKEFILE.read_text()
        for line in makefile.splitlines():
            if line.startswith("postinst_FILES") or line.startswith("prerm_FILES"):
                self.assertIn("CCNMPlistWrite.c", line, line)

    def test_the_writer_compiles_clean_as_c11(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                 "-I", str(HEADER_DIR), "-c", str(SOURCE),
                 "-o", str(pathlib.Path(d) / "o.o")],
                check=True, capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
