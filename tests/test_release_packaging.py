#!/usr/bin/env python3
"""Host-side tests for formal 1.5.0 release packaging and CI policy."""

from __future__ import annotations

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

    def test_forbidden_diagnostic_scanner_detects_discarded_action(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Controller.m"
            source.write_text("- (void)confirmSameValueBandWrite:(id)sender {}\n", encoding="utf-8")
            findings = verify_release_source.scan_forbidden_strings(root)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["category"], "diagnostic action")


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

    def test_maintainer_guard_requires_executable_macho(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            guards = [root / name for name in ("postinst", "prerm")]
            for guard in guards:
                guard.write_bytes(b"#!/bin/sh\nexit 0\n")
                guard.chmod(0o755)
            failures = []
            evidence = verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertEqual(evidence["status"], "failed")
            self.assertTrue(any("signed Mach-O guard" in failure for failure in failures))

            for guard in guards:
                guard.write_bytes(b"\xca\xfe\xba\xbe" + b"\0" * 32)
            failures = []
            evidence = verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertEqual(evidence["status"], "passed")
            self.assertEqual(failures, [])

            guards[0].chmod(0o644)
            failures = []
            evidence = verify_release_package.verify_maintainer_scripts(root, failures)
            self.assertEqual(evidence["status"], "failed")
            self.assertTrue(any("exact mode 755" in failure for failure in failures))

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


if __name__ == "__main__":
    unittest.main()
