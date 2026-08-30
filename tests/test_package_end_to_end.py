#!/usr/bin/env python3
"""End-to-end packaging gate: real template, real patcher, real .deb, real verifier.

Every other test in this suite checks one stage in isolation. This one wires the
actual stages together in the order the Makefile runs them, builds a .deb, and
runs the release verifier over it.

It exists because of a specific gap. The repo template at
layout/Library/LaunchDaemons/... carries @PLIST_PREFIX@ where a lane prefix
belongs, and no on-device step substitutes anything into that file any more, so a
`before-package` rule that silently does not run ships a permanently
unresolvable path. The sentinel is deliberately invalid on both lanes: it used to
be @JBROOT@, which meant a skipped patcher produced an accidentally correct
roothide package while only rootless broke, and that asymmetry is what let a
wrong roothide contract look verified. No single-stage test notices, because each
stage passes on its own.

The negative control is therefore the point of this file: staging with the patch
step skipped must fail verification in both lanes.

dpkg-deb is required. The host-tests job runs on ubuntu-24.04 where it is
present; the macOS packaging jobs are where the real Theos build happens and
this is skipped there.
"""

from __future__ import annotations

import argparse
import importlib.util
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

import verify_release_package as verifier  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import machofixtures  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "patch_maintenance_launchd", SCRIPTS / "patch-maintenance-launchd.py")
patcher = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(patcher)


# The payload binaries. otool-based Mach-O verification is a macOS-only stage and
# is not requested here, but the preference-bundle cell-class gate parses sections
# on every host, so a bare four-byte magic is not enough: an unreadable image is
# reported as such rather than passing quietly. These are therefore structurally
# valid images that define the real cell classes and contain no class-name string
# literals, which is what a correctly built bundle looks like.
FAKE_MACHO = machofixtures.preference_bundle_binary(
    verifier.PREFERENCE_CELL_CLASS_NAMES,
    ["an unrelated literal"],
)

BINARY_PAYLOAD = (
    "Library/ControlCenter/Bundles/NetworkManager.bundle/NetworkManager",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/NetworkManagerPrefs",
    verifier.INSTALL_GUARD_RELATIVE,
    verifier.MAINTENANCE_HELPER_RELATIVE,
)

TEXT_PAYLOAD = {
    "Library/ControlCenter/Bundles/NetworkManager.bundle/Info.plist":
        plistlib.dumps({"CFBundleIdentifier": "com.doimty.nrmanager",
                        "CFBundleExecutable": "NetworkManager"}),
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/Info.plist":
        plistlib.dumps({"CFBundleIdentifier": "com.doimty.nrmanager.prefs",
                        "CFBundleExecutable": "NetworkManagerPrefs"}),
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/Root.plist":
        plistlib.dumps({"items": []}),
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/defaults.plist":
        plistlib.dumps({"n78PreferenceEnabled": False}),
    "Library/PreferenceLoader/Preferences/NetworkManagerPrefs.plist":
        plistlib.dumps({"entry": {}}),
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/"
    "en.lproj/NetworkManagerPrefs.strings": b'"key" = "value";\n',
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/"
    "zh-Hans.lproj/NetworkManagerPrefs.strings": b'"key" = "value";\n',
    "Library/ControlCenter/Bundles/NetworkManager.bundle/SettingsIcon@2x.png":
        b"\x89PNG\r\n\x1a\n",
    "Library/ControlCenter/Bundles/NetworkManager.bundle/SettingsIcon@3x.png":
        b"\x89PNG\r\n\x1a\n",
}


@unittest.skipIf(shutil.which("dpkg-deb") is None, "dpkg-deb is not available")
class PackageEndToEndTests(unittest.TestCase):
    def stage(self, lane: str, root: Path, run_before_package: bool = True,
              preference_binary: bytes | None = None) -> Path:
        """Reproduce Theos staging for one lane, optionally skipping the patch step."""
        payload_root = root / "var" / "jb" if lane == "rootless" else root

        # Theos stages the layout tree as binary plists.
        template = plistlib.loads(
            (REPO / "layout" / verifier.LAUNCHD_PLIST_RELATIVE).read_bytes())
        target = payload_root / verifier.LAUNCHD_PLIST_RELATIVE
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(plistlib.dumps(template, fmt=plistlib.FMT_BINARY))

        for relative, data in TEXT_PAYLOAD.items():
            path = payload_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for relative in BINARY_PAYLOAD:
            path = payload_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if relative == verifier.PREFERENCE_BUNDLE_BINARY_RELATIVE and preference_binary:
                path.write_bytes(preference_binary)
            else:
                path.write_bytes(FAKE_MACHO)
            path.chmod(0o755)

        control = root / "DEBIAN"
        control.mkdir(parents=True, exist_ok=True)
        (control / "control").write_text((REPO / "control").read_text().replace(
            "Architecture: iphoneos-arm64",
            "Architecture: " + verifier.EXPECTED_ARCHITECTURE[lane]))

        if run_before_package:
            # Exactly what the top-level Makefile's before-package rule runs.
            patcher.patch_launchd_plist(payload_root, patcher.plist_prefix(lane))
            patcher.render_maintainer_scripts(root, REPO / "package-actions", lane)

        # Theos's own internal-package step, which runs *after* before-package and
        # converts every staged plist back to binary1
        # (theos/bin/convert_xml_plist.sh, gated on FINALPACKAGE). Omitting this
        # is what let an XML-requiring gate pass here and fail the real build: the
        # packaging script writes XML, Theos binarizes it, and the .deb ships
        # binary on both lanes either way.
        self.binarize_staged_plists(payload_root)
        return root

    @staticmethod
    def binarize_staged_plists(payload_root: Path) -> None:
        for path in payload_root.rglob("*.plist"):
            raw = path.read_bytes()
            if raw[:8] == b"bplist00":
                continue
            path.write_bytes(plistlib.dumps(plistlib.loads(raw),
                                            fmt=plistlib.FMT_BINARY))

    def verify(self, lane: str, run_before_package: bool = True,
               preference_binary: bytes | None = None) -> dict:
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            root = workspace / "stage"
            root.mkdir()
            self.stage(lane, root, run_before_package, preference_binary)
            package = workspace / ("nmr-%s.deb" % lane)
            subprocess.run(
                ["dpkg-deb", "-Znone", "--root-owner-group", "-b",
                 str(root), str(package)],
                check=True, capture_output=True)
            log = workspace / "build.log"
            log.write_text("clang -c ok\nld ok\n** BUILD SUCCEEDED **\n")
            return verifier.verify_package(argparse.Namespace(
                package=package, lane=lane, source_control=REPO / "control",
                build_log=log, report=None, checksums=None, checksum_name=None,
                source_sha="test", run_id="local", expected_sdk=None,
                require_mach_o=False))

    def test_a_correctly_staged_package_passes_for_both_lanes(self) -> None:
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                report = self.verify(lane)
                self.assertEqual(report["failures"], [], report["failures"])
                self.assertEqual(report["status"], "passed")
                self.assertEqual(report["maintainer_scripts"]["status"], "passed")
                self.assertEqual(report["launchd_plist"]["status"], "passed")
                # Binary is what actually ships, and it must not be a failure.
                self.assertFalse(report["launchd_plist"]["xml"])

    def test_a_bundle_naming_a_cell_class_as_a_string_fails_the_whole_package(self) -> None:
        """The crash that shipped: PSCellClassKey given a name instead of a Class.

        Asserted end to end rather than only against the checking function, because
        the previous release was green on every gate that was actually wired into
        this report. A check that exists but is not reached is worth nothing.
        """
        crashing = machofixtures.preference_bundle_binary(
            verifier.PREFERENCE_CELL_CLASS_NAMES,
            ["CCNMStatusCell", "CCNMBandSelectionCell"],
        )
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                report = self.verify(lane, preference_binary=crashing)
                self.assertEqual(report["status"], "failed")
                self.assertEqual(
                    report["preference_cell_classes"]["cell_classes_as_string_literals"],
                    ["CCNMStatusCell", "CCNMBandSelectionCell"],
                )
                self.assertTrue(
                    any("crashes Preferences" in failure for failure in report["failures"]),
                    report["failures"],
                )

    def test_no_unresolved_token_ships_in_either_lane(self) -> None:
        # Checked against the package as Theos really leaves it, not against the
        # XML the packaging script wrote. There is no device-side substitution
        # left, so a surviving token would be a permanent unresolvable path.
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                evidence = self.verify(lane)["launchd_plist"]
                self.assertFalse(evidence["plist_prefix_present"])
                self.assertFalse(evidence["jbroot_present"])

    def test_each_lane_ships_its_own_launchd_prefix(self) -> None:
        # roothide ships bare paths: its launchctl rewrites every absolute path in
        # the plist as jbroot(path) before launchd sees it, so a prefix here would
        # be doubled. That doubling is what the reporting device showed.
        self.assertEqual(
            self.verify("roothide")["launchd_plist"]["program"],
            verifier.MAINTENANCE_PROGRAM_RELATIVE)
        self.assertEqual(
            self.verify("rootless")["launchd_plist"]["program"],
            "/var/jb" + verifier.MAINTENANCE_PROGRAM_RELATIVE)

    def test_a_skipped_before_package_step_is_caught_in_both_lanes(self) -> None:
        # The negative control this file exists for.
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                report = self.verify(lane, run_before_package=False)
                self.assertEqual(report["status"], "failed")
                self.assertTrue(
                    any("missing: postinst" in failure or "postinst" in failure
                        for failure in report["failures"]), report["failures"])

    def test_an_unpatched_plist_names_the_sentinel_in_both_lanes(self) -> None:
        # The sentinel is invalid on both lanes on purpose. It used to be @JBROOT@,
        # which meant a skipped patcher produced an accidentally correct roothide
        # package and only rootless failed -- the asymmetry that let a wrong
        # roothide contract look verified.
        for lane in ("roothide", "rootless"):
            with self.subTest(lane=lane):
                failures = self.verify(lane, run_before_package=False)["failures"]
                self.assertTrue(
                    any(verifier.TEMPLATE_SENTINEL in failure
                        for failure in failures), failures)


if __name__ == "__main__":
    unittest.main()
