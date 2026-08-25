#!/usr/bin/env python3
"""Host-side tests for formal release packaging and CI policy.

The version is read from ``verify_release_source.RELEASE_VERSION`` rather than
written here as a literal. Two independent literals for one release number is how
the control file and the verifier drift apart, and the verifier is the thing CI
actually runs against a built package.
"""

from __future__ import annotations

import importlib.util
import plistlib
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import machofixtures  # noqa: E402


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

import verify_build_log  # noqa: E402
import verify_release_package  # noqa: E402
import verify_release_source  # noqa: E402


class ReleaseMetadataTests(unittest.TestCase):
    def test_control_is_neutral_release_metadata(self) -> None:
        fields = verify_release_source.read_control(REPO / "control")
        self.assertEqual(fields["package"], "me.nixuge.networkmanager")
        self.assertEqual(fields["name"], "NetworkManagerReborn")
        self.assertEqual(fields["version"], verify_release_source.RELEASE_VERSION)
        self.assertEqual(fields["architecture"], "iphoneos-arm64")
        self.assertNotRegex(fields["name"], re.compile("roothide", re.IGNORECASE))
        self.assertNotRegex(fields["description"], re.compile("roothide", re.IGNORECASE))
        self.assertEqual(verify_release_source.validate_control_fields(fields), [])

    def test_source_plists_and_diagnostic_gate_pass(self) -> None:
        result = verify_release_source.validate_source(REPO)
        self.assertEqual(result["failures"], [], result)
        self.assertEqual(result["forbidden"], [], result)

    def test_external_theos_tree_is_not_treated_as_project_source(self) -> None:
        self.assertIn("theos", verify_release_source.SKIP_PARTS)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dependency = root / "theos/vendor/templates/invalid.plist"
            dependency.parent.mkdir(parents=True)
            dependency.write_text("<not-a-project-plist>", encoding="utf-8")
            self.assertEqual(verify_release_source.scan_forbidden_strings(root), [])
            self.assertNotIn(dependency, list(verify_release_source.iter_source_text_files(root)))

    def test_forbidden_diagnostic_scanner_detects_discarded_action(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Controller.m"
            source.write_text("- (void)confirmSameValueBandWrite:(id)sender {}\n", encoding="utf-8")
            findings = verify_release_source.scan_forbidden_strings(root)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["category"], "diagnostic action")

    def test_the_shell_maintainer_templates_are_inside_the_diagnostic_gate(self) -> None:
        # These ship to the device. They used to be postinst.m / prerm.m, which
        # the .m suffix already covered, so the move to shell would otherwise
        # have silently dropped two files out of this scan.
        repo_templates = {
            "package-actions/postinst.sh.in",
            "package-actions/prerm.sh.in",
        }
        scanned = {
            str(path.relative_to(REPO))
            for path in verify_release_source.iter_source_text_files(REPO)
        }
        self.assertLessEqual(repo_templates, scanned)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "package-actions/postinst.sh.in"
            template.parent.mkdir(parents=True)
            template.write_text(
                "#!/bin/sh\n# nr78_only leftover\n", encoding="utf-8")
            findings = verify_release_source.scan_forbidden_strings(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertEqual(findings[0]["category"], "diagnostic operation")


class BuildConfigurationTests(unittest.TestCase):
    def test_all_product_and_maintainer_targets_use_ios_14_minimum(self) -> None:
        for relative in ("Makefile", "networkmanagerprefs/Makefile", "package-actions/Makefile"):
            text = (REPO / relative).read_text(encoding="utf-8")
            self.assertIn("export TARGET = iphone:clang:latest:14.0", text, relative)
            self.assertNotIn("iphone:clang:latest:11.0", text, relative)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = (REPO / ".github/workflows/build.yml").read_text(encoding="utf-8")
        cls.rootless = cls.workflow.split("  rootless:\n", 1)[1].split("  roothide:\n", 1)[0]
        cls.roothide = cls.workflow.split("  roothide:\n", 1)[1]

    def test_validation_triggers_are_non_publishing(self) -> None:
        self.assertRegex(self.workflow, r"(?m)^  push:$")
        self.assertRegex(self.workflow, r"(?m)^  pull_request:$")
        self.assertRegex(self.workflow, r"(?m)^  workflow_dispatch:$")
        for forbidden in (
            "actions/create-release",
            "softprops/action-gh-release",
            "gh release",
            "git tag",
        ):
            self.assertNotIn(forbidden, self.workflow)

    def test_rootless_and_roothide_are_separate_macos_14_jobs(self) -> None:
        self.assertIn("runs-on: macos-14", self.rootless)
        self.assertIn("runs-on: macos-14", self.roothide)
        self.assertIn("needs: host-tests", self.rootless)
        self.assertIn("needs: host-tests", self.roothide)
        self.assertIn("THEOS_PACKAGE_SCHEME: rootless", self.rootless)
        self.assertIn("THEOS_PACKAGE_SCHEME: roothide", self.roothide)

    def test_actions_and_dependencies_are_immutable(self) -> None:
        action_refs = re.findall(r"uses:\s*[^\s@]+@([^\s]+)", self.workflow)
        self.assertGreaterEqual(len(action_refs), 7)
        for action_ref in action_refs:
            self.assertRegex(action_ref, r"^[0-9a-f]{40}$")
        for commit in (
            "88506b2c22e9e07dd4ed055f23c9e398a117a2c7",
            "0222fd5413cf4b9af096f37b4621afa2688572f7",
            "ec20c982b3f74f2f0500a83761363384e92a0ca3",
        ):
            self.assertIn(commit, self.workflow)
        self.assertIn("checkout --detach \"$THEOS_COMMIT\"", self.workflow)
        self.assertIn("checkout --detach \"$THEOS_SDK_COMMIT\"", self.workflow)
        self.assertIn("checkout --detach \"$CCSUPPORT_COMMIT\"", self.workflow)

    def test_toolchain_is_pinned_and_printed(self) -> None:
        for expected in (
            "Xcode 15.4",
            "Build version 15F31d",
            "Apple clang version 15\\.0\\.0",
            "ld-1053\\.12",
            'test "$system_sdk" = "17.5"',
        ):
            self.assertIn(expected, self.rootless)
            self.assertIn(expected, self.roothide)
        self.assertIn('"version"[[:space:]]*:[[:space:]]*"1053\\.12"', self.rootless)
        self.assertIn('"version"[[:space:]]*:[[:space:]]*"1053\\.12"', self.roothide)

    def test_only_rootless_build_receives_explicit_sysroot(self) -> None:
        self.assertIn('make package SYSROOT="$THEOS/sdks/iPhoneOS16.5.sdk"', self.rootless)
        self.assertNotRegex(self.roothide, r"make package\s+SYSROOT=")
        self.assertIn("unset SYSROOT", self.roothide)
        self.assertIn("make package 2>&1", self.roothide)
        self.assertIn("--expected-sdk 17.5", self.roothide)
        # Theos prefers SDKs under $THEOS/sdks: the roothide lane must keep the
        # pinned 16.5 SDK out of the toolchain tree so the system SDK 17.5 is
        # used, and the rootless lane materializes it for its explicit SYSROOT.
        self.assertIn('mkdir -p "$THEOS/sdks"', self.rootless)
        self.assertNotIn('"$THEOS/sdks/iPhoneOS16.5.sdk"', self.roothide)
        self.assertIn("roothide must use system SDK", self.roothide)

    def test_build_and_artifact_gates_are_present_per_lane(self) -> None:
        for lane in (self.rootless, self.roothide):
            self.assertIn("python3 -m unittest discover -s tests -v", lane)
            self.assertIn("build_status=${PIPESTATUS[0]}", lane)
            self.assertIn("test -s \"$build_log\"", lane)
            self.assertIn("scripts/verify_build_log.py", lane)
            self.assertIn('if [[ "${#debs[@]}" -ne 1 ]]', lane)
            self.assertIn("scripts/verify_release_package.py", lane)
            self.assertIn("verification-report.json", lane)
            self.assertIn("SHA256SUMS", lane)
            self.assertIn("--checksum-name", lane)
            self.assertIn("ld_version_number", lane)
            self.assertIn("if-no-files-found: error", lane)
            self.assertIn("--require-mach-o", lane)

    def test_host_tests_job_runs_full_suite_before_packaging(self) -> None:
        host = self.workflow.split("  rootless:\n", 1)[0]
        self.assertEqual(host.count("python3 -m unittest discover -s tests -v"), 1)
        self.assertIn("python3 -m py_compile scripts/*.py", host)
        self.assertIn("git diff --check", host)


class VerificationHelperTests(unittest.TestCase):
    def test_build_log_gate_rejects_empty_and_fatal_lines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            empty = root / "empty.log"
            empty.write_text("\n", encoding="utf-8")
            self.assertTrue(verify_build_log.verify_log(empty))

            clean = root / "clean.log"
            clean.write_text("Compiling CCNetworkManager.x\nLinking NetworkManager\n", encoding="utf-8")
            self.assertEqual(verify_build_log.verify_log(clean), [])

            bad = root / "bad.log"
            bad.write_text("ld: error: incompatible arm64e object\n", encoding="utf-8")
            failures = verify_build_log.verify_log(bad)
            self.assertTrue(failures)
            self.assertIn("incompatible arm64e", failures[0])

    def test_vtool_parser_and_minimum_versions(self) -> None:
        output = """
Load command 1
      cmd LC_BUILD_VERSION
 platform IOS
    minos 14.0
      sdk 17.5
"""
        self.assertEqual(verify_release_package.parse_build_versions(output), [("14.0", "17.5")])
        self.assertTrue(verify_release_package.version_at_least("14.0.0", "14.0"))
        self.assertFalse(verify_release_package.version_at_least("13.7", "14.0"))
        self.assertTrue(verify_release_package.versions_equal("14.0.0", "14.0"))
        self.assertFalse(verify_release_package.versions_equal("15.2", "14.0"))

    def test_required_manifest_covers_binaries_and_plists(self) -> None:
        required = verify_release_package.REQUIRED_PAYLOAD_FILES
        for binary in verify_release_package.BINARY_PAYLOAD_FILES:
            self.assertIn(binary, required)
        self.assertIn(
            "Library/PreferenceLoader/Preferences/NetworkManagerPrefs.plist",
            required,
        )
        self.assertIn(
            "Library/PreferenceBundles/NetworkManagerPrefs.bundle/en.lproj/NetworkManagerPrefs.strings",
            required,
        )
        self.assertIn(
            "Library/PreferenceBundles/NetworkManagerPrefs.bundle/zh-Hans.lproj/NetworkManagerPrefs.strings",
            required,
        )
        self.assertIn("telegram@2x.png", verify_release_package.FORBIDDEN_LEGACY_PAYLOAD_BASENAMES)

    def test_arm64e_header_parser_accepts_mach_header_spacing(self) -> None:
        self.assertTrue(
            verify_release_package.has_arm64e_usr00_header(
                "MH_MAGIC_64    ARM64          E USR00       DYLIB"
            )
        )
        self.assertFalse(
            verify_release_package.has_arm64e_usr00_header(
                "MH_MAGIC_64    ARM64          ALL       DYLIB"
            )
        )

    def test_fat_otool_dependencies_exclude_headers_and_bundle_install_id(self) -> None:
        output = """/tmp/NetworkManager (architecture arm64):
\t/Library/ControlCenter/Bundles/NetworkManager.bundle/NetworkManager (compatibility version 0.0.0, current version 0.0.0)
\t/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)
/tmp/NetworkManager (architecture arm64e):
\t/Library/ControlCenter/Bundles/NetworkManager.bundle/NetworkManager (compatibility version 0.0.0, current version 0.0.0)
\t/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)
"""
        self.assertEqual(
            verify_release_package.normalized_dependencies(output, "NetworkManager"),
            ["/usr/lib/libobjc.A.dylib"],
        )

    def test_maintainer_scripts_must_be_shell_not_macho(self) -> None:
        # The inverse of the old rule. A compiled maintainer script on roothide
        # runs without the bootstrap injection and gets EPERM on every write and
        # child exec inside the jailbreak root, which is what broke installs.
        template = (
            "#!/bin/sh\n"
            "GUARD=\"/usr/libexec/networkmanager-install-guard\"\n"
            "\"$GUARD\" \"$@\"\n"
        )
        # prerm delegates to nothing. Its privileged work is a carrier reset and a
        # record cleanup, both of which the shell does itself.
        removal = (
            "#!/bin/sh\n"
            "killall -9 CommCenter\n"
            "exit 0\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "postinst").write_text(template)
            (root / "prerm").write_text(removal)
            for name in ("postinst", "prerm"):
                (root / name).chmod(0o755)

            failures: list = []
            evidence = verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertEqual(evidence["status"], "passed", failures)
            self.assertEqual(failures, [])

            # A prerm that reaches for the retired removal guard is rejected. That
            # binary blocked removal until the user restored bands in Settings, so
            # shipping it beside a prerm that never blocks would put a fail-closed
            # gate back on an unconditionally non-blocking path.
            (root / "prerm").write_text(
                "#!/bin/sh\n"
                "GUARD=\"/usr/libexec/networkmanager-removal-guard\"\n"
                "\"$GUARD\" \"$@\"\n"
            )
            (root / "prerm").chmod(0o755)
            failures = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(
                any("retired networkmanager-removal-guard" in failure
                    for failure in failures), failures)
            (root / "prerm").write_text(removal)
            (root / "prerm").chmod(0o755)

            (root / "postinst").write_bytes(b"\xca\xfe\xba\xbe" + b"\0" * 32)
            (root / "postinst").chmod(0o755)
            failures = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(
                any("must be a shell script" in failure for failure in failures), failures
            )

            (root / "postinst").write_text(template)
            (root / "postinst").chmod(0o644)
            failures = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(any("exact mode 755" in failure for failure in failures))

    def test_an_unrendered_template_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "postinst").write_text(
                "#!/bin/sh\nPREFIX='@PREFIX@'\nnetworkmanager-install-guard\n"
            )
            (root / "prerm").write_text("#!/bin/sh\nexit 0\n")
            for name in ("postinst", "prerm"):
                (root / name).chmod(0o755)
            failures: list = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(
                any("@PREFIX@ placeholder" in failure for failure in failures), failures
            )

    def test_a_script_that_does_not_delegate_is_rejected(self) -> None:
        # postinst only. prerm delegating to nothing is now the correct shape, so
        # it is the one script this rule must not apply to.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "postinst").write_text("#!/bin/sh\nexit 0\n")
            (root / "prerm").write_text("#!/bin/sh\nexit 0\n")
            for name in ("postinst", "prerm"):
                (root / name).chmod(0o755)
            failures: list = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(
                any("does not delegate" in failure for failure in failures), failures
            )
            self.assertEqual(
                [failure for failure in failures if "prerm" in failure], [])

    def test_the_guards_and_the_launchd_plist_are_required_payload(self) -> None:
        required = verify_release_package.REQUIRED_PAYLOAD_FILES
        self.assertIn("usr/libexec/networkmanager-install-guard", required)
        self.assertIn("usr/libexec/networkmanager-maintenance", required)
        # The removal guard is required to be *absent*, not merely unlisted: it is
        # a fail-closed gate on a path that no longer has anything to refuse.
        self.assertNotIn("usr/libexec/networkmanager-removal-guard", required)
        self.assertIn(
            "networkmanager-removal-guard",
            verify_release_package.FORBIDDEN_LEGACY_PAYLOAD_BASENAMES,
        )
        self.assertIn(
            "Library/LaunchDaemons/me.nixuge.networkmanager.maintenance.plist", required
        )
        # The guards are verified as Mach-O in the payload now, not in DEBIAN/.
        self.assertIn(
            "usr/libexec/networkmanager-install-guard",
            verify_release_package.BINARY_PAYLOAD_FILES,
        )
        # The daemon joins the install guard: neither may link libroothide,
        # because neither runs with a bootstrap or a .jbroot beside it.
        self.assertEqual(
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
            ("networkmanager-install-guard", "networkmanager-maintenance"),
        )
        # Same membership, different question, and the lists must stay separate.
        # LC_DYLD_INFO_ONLY is pinned for the two injected bundles, where a
        # floating-Xcode chained-fixups build once crashed on device. These two are
        # exec'd rather than injected, and chained fixups are known to run in that
        # position on the reporting iOS 15.1.1 device: both guards shipped them
        # then, and it is their output that redesigned this release.
        self.assertEqual(
            verify_release_package.CHAINED_FIXUPS_ALLOWED_TOOLS,
            ("networkmanager-install-guard", "networkmanager-maintenance"),
        )
        self.assertIsNot(
            verify_release_package.CHAINED_FIXUPS_ALLOWED_TOOLS,
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
            "the two lists answer different questions and must not be aliased",
        )
        for bundle in ("NetworkManager", "NetworkManagerPrefs"):
            self.assertNotIn(
                bundle, verify_release_package.CHAINED_FIXUPS_ALLOWED_TOOLS)
        # Absence of the library is asserted for those binaries, not merely
        # tolerated, and the daemon's whole dependency set is pinned so any
        # unreviewed addition fails too.
        verifier = (REPO / "scripts/verify_release_package.py").read_text()
        self.assertIn(
            "links the roothide runtime, which cannot be loaded from its install location",
            verifier)
        self.assertIn(
            "ROOTHIDE_RELEASE_DEPENDENCIES[MAINTENANCE_HELPER_NAME]", verifier)
        self.assertNotIn(
            verify_release_package.ROOTHIDE_DYLIB,
            verify_release_package.ROOTHIDE_RELEASE_DEPENDENCIES[
                "networkmanager-maintenance"],
        )


class PreferenceCellClassGateTests(unittest.TestCase):
    """The artifact check for the crash that every other gate let through.

    A specifier built in code must be handed a Class for PSCellClassKey. Handing it
    the class *name* compiles, links, signs, and passed source verification, the
    diagnostic-string scan, the build-log gate and both Mach-O lanes -- the shipped
    deb was green on all of them and Settings died on entry to the pane.

    So the gate has to read the built binary, and it has to read the right section:
    the name legitimately appears in __objc_classname for any class the bundle
    defines, and only its presence in __cstring means an NSString was built out of
    it. Fixtures are synthesised Mach-O images, so both answers are exercised
    without a device or a macOS host.
    """

    def _check(self, image: bytes) -> Tuple[List[str], Dict[str, object]]:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / verify_release_package.PREFERENCE_BUNDLE_BINARY_RELATIVE
            binary.parent.mkdir(parents=True)
            binary.write_bytes(image)
            failures: List[str] = []
            evidence = verify_release_package.verify_preference_cell_classes(
                Path(directory), failures
            )
        return failures, evidence

    def test_the_gate_accepts_class_metadata_alone(self) -> None:
        """Every build defines these classes, so metadata alone must stay clean."""
        names = verify_release_package.PREFERENCE_CELL_CLASS_NAMES
        failures, evidence = self._check(machofixtures.preference_bundle_binary(
            names, ["some unrelated literal", "GROUP_BAND_SELECTION"]))
        self.assertEqual(failures, [])
        self.assertEqual(evidence["cell_classes_as_string_literals"], [])
        self.assertEqual(sorted(evidence["cell_classes_in_objc_metadata"]), sorted(names))

    def test_the_gate_rejects_a_cell_class_name_as_a_string_literal(self) -> None:
        """Red case: exactly the shape of the crashing build."""
        names = verify_release_package.PREFERENCE_CELL_CLASS_NAMES
        failures, evidence = self._check(machofixtures.preference_bundle_binary(
            names, ["CCNMStatusCell", "CCNMBandSelectionCell"]))
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("crashes Preferences", failures[0])
        self.assertEqual(
            evidence["cell_classes_as_string_literals"],
            ["CCNMStatusCell", "CCNMBandSelectionCell"],
        )

    def test_every_slice_is_inspected(self) -> None:
        """arm64 and arm64e are compiled separately, so one clean slice proves nothing."""
        names = verify_release_package.PREFERENCE_CELL_CLASS_NAMES
        clean = machofixtures.preference_bundle_binary(names, ["nothing to see"], slices=1)
        dirty = machofixtures.preference_bundle_binary(
            names, ["CCNMBandSelectionCell"], slices=1)
        failures, evidence = self._check(machofixtures.fat_macho([clean, dirty]))
        self.assertEqual(evidence["slices"], 2)
        self.assertEqual(evidence["cell_classes_as_string_literals"],
                         ["CCNMBandSelectionCell"])
        self.assertEqual(len(failures), 1, failures)

    def test_a_binary_without_the_classes_is_reported_not_passed(self) -> None:
        """Guard against the check silently reading the wrong file and finding nothing.

        A clean result and an unread binary look identical from the outside, which
        is how a gate rots into decoration.
        """
        failures, evidence = self._check(
            machofixtures.preference_bundle_binary([], ["unrelated"]))
        self.assertEqual(evidence["cell_classes_in_objc_metadata"], [])
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("defines none of its cell classes", failures[0])

    def test_a_missing_or_non_macho_binary_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            failures: List[str] = []
            verify_release_package.verify_preference_cell_classes(
                Path(directory), failures)
            self.assertEqual(len(failures), 1, failures)
            self.assertIn("missing from the payload", failures[0])
        failures, _ = self._check(b"#!/bin/sh\nexit 0\n")
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("not a Mach-O image", failures[0])

    def test_a_truncated_fat_header_does_not_read_as_clean(self) -> None:
        """Malformed input must fail loudly rather than yield an empty literal list."""
        names = verify_release_package.PREFERENCE_CELL_CLASS_NAMES
        image = machofixtures.preference_bundle_binary(names, ["CCNMStatusCell"])
        failures, _ = self._check(image[:6])
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("not a Mach-O image", failures[0])

    def test_the_gate_runs_on_any_host_not_only_macos(self) -> None:
        """It parses sections directly instead of shelling out to otool, so it runs in
        the host-tests job as well as the two macOS packaging jobs."""
        verifier_source = (REPO / "scripts/verify_release_package.py").read_text()
        _, _, after = verifier_source.partition('report["preference_cell_classes"]')
        self.assertNotIn("macho_requested", after.split("\n\n", 1)[0])
        self.assertIn("verify_preference_cell_classes(", verifier_source)

    def test_the_watched_names_are_classes_the_bundle_actually_has(self) -> None:
        """The two halves of the fix must not drift apart: a name that no longer
        exists would make the gate quietly stop protecting that cell."""
        cells = (REPO / "networkmanagerprefs/CCNMPreferencesCells.h").read_text()
        for name in verify_release_package.PREFERENCE_CELL_CLASS_NAMES:
            self.assertIn("@interface " + name, cells, name)


class LaunchdPlistLaneTests(unittest.TestCase):
    """What prefix belongs inside the plist, per lane.

    roothide: none. Its launchctl is a redirected binary that rewrites every
    absolute path in the file as jbroot(path) before launchd sees it, guarding
    re-entry only with a __Patched flag it sets itself, so a plist that already
    carries the jailbreak root gets a second one. The reporting device showed
    exactly that doubled path.

    rootless: /var/jb, because nothing there rewrites anything.

    The repo template carries @PLIST_PREFIX@ where the prefix belongs, which is
    invalid on both lanes on purpose. The template used to carry @JBROOT@, and
    that made a skipped before-package patch invisible on roothide while only
    rootless failed -- the asymmetry that let a wrong roothide contract look
    verified.
    """

    RELATIVE = verify_release_package.LAUNCHD_PLIST_RELATIVE
    SENTINEL = verify_release_package.TEMPLATE_SENTINEL

    def staged(self, prefix: str) -> dict:
        return {
            "Label": verify_release_package.LAUNCHD_LABEL,
            "ProgramArguments": [
                prefix + verify_release_package.MAINTENANCE_PROGRAM_RELATIVE,
                "--daemon",
            ],
            "KeepAlive": {
                "PathState": {
                    prefix + verify_release_package.MAINTENANCE_BASELINE_RELATIVE: True
                }
            },
            "UserName": "root",
            "EnvironmentVariables": {"DISABLE_TWEAKS": "1"},
            "ProcessType": "Background",
            "ThrottleInterval": 30,
        }

    def write(self, root: Path, payload: dict, fmt=plistlib.FMT_XML) -> None:
        target = root / self.RELATIVE
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(plistlib.dumps(payload, fmt=fmt))

    def check(self, lane: str, payload: dict, fmt=plistlib.FMT_XML) -> list:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, payload, fmt)
            failures: list = []
            verify_release_package.verify_launchd_plist(root, lane, failures)
            return failures

    def test_each_lane_accepts_its_own_prefix(self) -> None:
        self.assertEqual(self.check("roothide", self.staged("")), [])
        self.assertEqual(self.check("rootless", self.staged("/var/jb")), [])

    def test_an_unpatched_plist_fails_both_lanes(self) -> None:
        # The point of a sentinel that is valid nowhere: a patcher that never ran
        # is caught in both lanes, not just the one whose prefix it resembles.
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                failures = self.check(lane, self.staged(self.SENTINEL))
                self.assertTrue(
                    any(self.SENTINEL in failure for failure in failures), failures)

    def test_a_jbroot_placeholder_is_still_refused(self) -> None:
        # No device-side step substitutes this any more, and launchctl would
        # happily prepend the jailbreak root to it and store the result.
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                failures = self.check(lane, self.staged("@JBROOT@"))
                self.assertTrue(
                    any("@JBROOT@" in failure for failure in failures), failures)

    def test_a_rootless_prefixed_plist_fails_the_roothide_lane(self) -> None:
        failures = self.check("roothide", self.staged("/var/jb"))
        self.assertTrue(any("/var/jb" in failure for failure in failures), failures)

    def test_a_jbroot_absolute_path_fails_the_roothide_lane(self) -> None:
        # The shape the reporting device shipped: a real jailbreak root written
        # into the plist at package time, which launchctl then doubles.
        jbroot = "/var/containers/Bundle/Application/.jbroot-D6B5C1F194F5F1C3"
        failures = self.check("roothide", self.staged(jbroot))
        self.assertTrue(any(jbroot in failure for failure in failures), failures)

    def test_a_binary_plist_is_accepted_because_theos_binarizes_it(self) -> None:
        # Theos converts every staged plist to binary1 in internal-package, which
        # runs after before-package, so a binary plist is what actually ships. An
        # XML requirement here failed a completely correct package.
        self.assertEqual(self.check("roothide", self.staged(""),
                                    plistlib.FMT_BINARY), [])
        self.assertEqual(self.check("rootless", self.staged("/var/jb"),
                                    plistlib.FMT_BINARY), [])

    def test_an_unresolved_token_is_caught_in_either_format(self) -> None:
        # The byte scan runs before parsing and independently of the two path
        # checks, so a token in a key those checks do not reach is still caught.
        for token in (self.SENTINEL, "@JBROOT@"):
            for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                with self.subTest(token=token, fmt=fmt):
                    payload = self.staged("")
                    payload["WorkingDirectory"] = token + "/usr/libexec"
                    failures = self.check("roothide", payload, fmt)
                    self.assertTrue(
                        any(token in failure for failure in failures), failures)

    def test_the_reviewed_contract_fields_are_enforced(self) -> None:
        payload = self.staged("")
        payload["RunAtLoad"] = True
        self.assertTrue(
            any("RunAtLoad" in failure for failure in self.check("roothide", payload))
        )

        payload = self.staged("")
        payload["KeepAlive"]["SuccessfulExit"] = False
        self.assertTrue(
            any("SuccessfulExit" in failure for failure in self.check("roothide", payload))
        )

        payload = self.staged("")
        payload["UserName"] = "mobile"
        self.assertTrue(
            any("UserName" in failure for failure in self.check("roothide", payload))
        )

    def test_a_missing_plist_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            failures: list = []
            verify_release_package.verify_launchd_plist(
                Path(directory), "roothide", failures)
        self.assertTrue(any("missing" in failure for failure in failures), failures)

    def test_the_patcher_output_satisfies_this_gate_for_both_lanes(self) -> None:
        # End to end against the real staged template, so the two modules cannot
        # drift apart on what a correct plist looks like.
        spec = importlib.util.spec_from_file_location(
            "patch_maintenance_launchd", SCRIPTS / "patch-maintenance-launchd.py")
        patcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(patcher)
        template = (REPO / "layout" / self.RELATIVE).read_bytes()
        for lane in ("roothide", "rootless"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / self.RELATIVE
                target.parent.mkdir(parents=True)
                # Theos stages this as a binary plist.
                target.write_bytes(
                    plistlib.dumps(plistlib.loads(template), fmt=plistlib.FMT_BINARY))
                patcher.patch_launchd_plist(root, patcher.plist_prefix(lane))
                failures: list = []
                verify_release_package.verify_launchd_plist(root, lane, failures)
                self.assertEqual(failures, [], (lane, failures))


class PackageLaneMetadataTests(unittest.TestCase):
    def test_package_lane_metadata_is_distinct_but_name_is_shared(self) -> None:
        self.assertEqual(
            verify_release_package.EXPECTED_ARCHITECTURE,
            {"rootless": "iphoneos-arm64", "roothide": "iphoneos-arm64e"},
        )
        self.assertEqual(verify_release_package.PACKAGE_NAME, "NetworkManagerReborn")
        self.assertEqual(
            verify_release_package.ROOTHIDE_DYLIB,
            "@loader_path/.jbroot/usr/lib/libroothide.dylib",
        )
        self.assertEqual(
            verify_release_package.ROOTHIDE_BASELINE_DEPENDENCIES["NetworkManagerPrefs"],
            {
                "/usr/lib/libobjc.A.dylib",
                "/System/Library/Frameworks/Foundation.framework/Foundation",
                "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
                "/System/Library/Frameworks/UIKit.framework/UIKit",
                "@loader_path/.jbroot/usr/lib/libroothide.dylib",
                "/usr/lib/libSystem.B.dylib",
            },
        )
        self.assertEqual(verify_release_package.EXPECTED_MIN_OS, {"arm64": "14.0", "arm64e": "14.0"})
        self.assertIn("LC_DYLD_INFO_ONLY", verify_release_package.ROOTHIDE_RELEASE_LOAD_COMMANDS)
        self.assertNotIn("LC_DYLD_CHAINED_FIXUPS", verify_release_package.ROOTHIDE_RELEASE_LOAD_COMMANDS)
        self.assertNotIn("LC_VERSION_MIN_IPHONEOS", verify_release_package.ROOTHIDE_RELEASE_LOAD_COMMANDS)
        self.assertIn(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            verify_release_package.ROOTHIDE_RELEASE_DEPENDENCIES["NetworkManagerPrefs"],
        )


if __name__ == "__main__":
    unittest.main()
