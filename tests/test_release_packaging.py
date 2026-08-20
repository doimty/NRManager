#!/usr/bin/env python3
"""Host-side tests for formal 1.5.0 release packaging and CI policy."""

from __future__ import annotations

import importlib.util
import plistlib
import re
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

import verify_build_log  # noqa: E402
import verify_release_package  # noqa: E402
import verify_release_source  # noqa: E402


class ReleaseMetadataTests(unittest.TestCase):
    def test_control_is_neutral_1_5_0_metadata(self) -> None:
        fields = verify_release_source.read_control(REPO / "control")
        self.assertEqual(fields["package"], "me.nixuge.networkmanager")
        self.assertEqual(fields["name"], "NetworkManagerReborn")
        self.assertEqual(fields["version"], "1.5.0")
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
        removal = (
            "#!/bin/sh\n"
            "GUARD=\"/usr/libexec/networkmanager-removal-guard\"\n"
            "\"$GUARD\" \"$@\"\n"
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
            (root / "prerm").write_text(
                "#!/bin/sh\nnetworkmanager-removal-guard \"$@\"\n"
            )
            for name in ("postinst", "prerm"):
                (root / name).chmod(0o755)
            failures: list = []
            verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertTrue(
                any("@PREFIX@ placeholder" in failure for failure in failures), failures
            )

    def test_a_script_that_does_not_delegate_is_rejected(self) -> None:
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

    def test_the_guards_and_the_launchd_plist_are_required_payload(self) -> None:
        required = verify_release_package.REQUIRED_PAYLOAD_FILES
        self.assertIn("usr/libexec/networkmanager-install-guard", required)
        self.assertIn("usr/libexec/networkmanager-removal-guard", required)
        self.assertIn("usr/libexec/networkmanager-maintenance", required)
        self.assertIn(
            "Library/LaunchDaemons/me.nixuge.networkmanager.maintenance.plist", required
        )
        # The guards are verified as Mach-O in the payload now, not in DEBIAN/.
        self.assertIn(
            "usr/libexec/networkmanager-install-guard",
            verify_release_package.BINARY_PAYLOAD_FILES,
        )
        self.assertEqual(
            verify_release_package.UNLINKED_ROOTHIDE_TOOLS,
            ("networkmanager-install-guard", "networkmanager-removal-guard"),
        )


class LaunchdPlistLaneTests(unittest.TestCase):
    """The repo template already contains @JBROOT@.

    That makes a skipped before-package patch invisible on roothide and fatal on
    rootless: rootless has no jbroot and its postinst has nothing to substitute,
    so a literal @JBROOT@ path would ship and the daemon would never start.
    """

    RELATIVE = verify_release_package.LAUNCHD_PLIST_RELATIVE

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
        self.assertEqual(self.check("roothide", self.staged("@JBROOT@")), [])
        self.assertEqual(self.check("rootless", self.staged("/var/jb")), [])

    def test_an_unpatched_plist_fails_the_rootless_lane(self) -> None:
        failures = self.check("rootless", self.staged("@JBROOT@"))
        self.assertTrue(any("@JBROOT@" in failure for failure in failures), failures)

    def test_a_rootless_prefixed_plist_fails_the_roothide_lane(self) -> None:
        failures = self.check("roothide", self.staged("/var/jb"))
        self.assertTrue(any("/var/jb" in failure for failure in failures), failures)

    def test_a_binary_roothide_plist_is_rejected(self) -> None:
        failures = self.check("roothide", self.staged("@JBROOT@"), plistlib.FMT_BINARY)
        self.assertTrue(any("must be XML" in failure for failure in failures), failures)

    def test_the_reviewed_contract_fields_are_enforced(self) -> None:
        payload = self.staged("@JBROOT@")
        payload["RunAtLoad"] = True
        self.assertTrue(
            any("RunAtLoad" in failure for failure in self.check("roothide", payload))
        )

        payload = self.staged("@JBROOT@")
        payload["KeepAlive"]["SuccessfulExit"] = False
        self.assertTrue(
            any("SuccessfulExit" in failure for failure in self.check("roothide", payload))
        )

        payload = self.staged("@JBROOT@")
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
