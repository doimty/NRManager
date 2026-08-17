#!/usr/bin/env python3
"""Verify a 1.5.0 rootless or roothide deb and emit release evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

try:
    from .verify_build_log import verify_log
    from .verify_release_source import (
        FORBIDDEN_DIAGNOSTIC_PATTERNS,
        PACKAGE_ID,
        PACKAGE_NAME,
        RELEASE_VERSION,
        parse_debian_fields,
        validate_control_fields,
    )
except ImportError:
    from verify_build_log import verify_log
    from verify_release_source import (
        FORBIDDEN_DIAGNOSTIC_PATTERNS,
        PACKAGE_ID,
        PACKAGE_NAME,
        RELEASE_VERSION,
        parse_debian_fields,
        validate_control_fields,
    )


EXPECTED_ARCHITECTURE = {
    "rootless": "iphoneos-arm64",
    "roothide": "iphoneos-arm64e",
}
EXPECTED_MIN_OS = {
    "arm64": "14.0",
    "arm64e": "14.0",
}
REQUIRED_DEPENDENCIES = {"mobilesubstrate", "com.opa334.ccsupport"}
ROOTHIDE_DYLIB = "@loader_path/.jbroot/usr/lib/libroothide.dylib"
# Device-working dependency/load-command shape from Xcode 15.4 baseline
# 2947f98 / run 30166854314, later reconfirmed by the accepted Cell Monitor build.
ROOTHIDE_BASELINE_LOAD_COMMANDS = {
    "LC_BUILD_VERSION",
    "LC_CODE_SIGNATURE",
    "LC_DATA_IN_CODE",
    "LC_DYLD_INFO_ONLY",
    "LC_DYSYMTAB",
    "LC_ENCRYPTION_INFO_64",
    "LC_FUNCTION_STARTS",
    "LC_ID_DYLIB",
    "LC_LOAD_DYLIB",
    "LC_SEGMENT_64",
    "LC_SOURCE_VERSION",
    "LC_SYMTAB",
    "LC_UUID",
    "LC_VERSION_MIN_IPHONEOS",
}
# Raising both slices to iOS 14 intentionally replaces the arm64
# LC_VERSION_MIN_IPHONEOS command with LC_BUILD_VERSION. Every other command
# remains pinned to the device-working baseline.
ROOTHIDE_RELEASE_LOAD_COMMANDS = ROOTHIDE_BASELINE_LOAD_COMMANDS - {"LC_VERSION_MIN_IPHONEOS"}
ROOTHIDE_BASELINE_DEPENDENCIES = {
    "NetworkManager": {
        "/usr/lib/libobjc.A.dylib",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
        ROOTHIDE_DYLIB,
        "/usr/lib/libSystem.B.dylib",
        "/System/Library/Frameworks/UIKit.framework/UIKit",
    },
    "NetworkManagerPrefs": {
        "/usr/lib/libobjc.A.dylib",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        ROOTHIDE_DYLIB,
        "/usr/lib/libSystem.B.dylib",
    },
}
# The formal Settings cells use UIKit layout/color APIs that Xcode 15.4
# records with a public CoreGraphics dependency. This is the only intentional
# additive dependency relative to the older device-working Settings binary.
ROOTHIDE_RELEASE_DEPENDENCIES = {
    name: set(dependencies) for name, dependencies in ROOTHIDE_BASELINE_DEPENDENCIES.items()
}
ROOTHIDE_RELEASE_DEPENDENCIES["NetworkManagerPrefs"].add(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
)

REQUIRED_PAYLOAD_FILES = {
    "Library/ControlCenter/Bundles/NetworkManager.bundle/Info.plist",
    "Library/ControlCenter/Bundles/NetworkManager.bundle/NetworkManager",
    "Library/ControlCenter/Bundles/NetworkManager.bundle/SettingsIcon@2x.png",
    "Library/ControlCenter/Bundles/NetworkManager.bundle/SettingsIcon@3x.png",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/Info.plist",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/NetworkManagerPrefs",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/Root.plist",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/defaults.plist",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/en.lproj/NetworkManagerPrefs.strings",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/zh-Hans.lproj/NetworkManagerPrefs.strings",
    "Library/PreferenceLoader/Preferences/NetworkManagerPrefs.plist",
}
BINARY_PAYLOAD_FILES = (
    "Library/ControlCenter/Bundles/NetworkManager.bundle/NetworkManager",
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/NetworkManagerPrefs",
)
REQUIRED_MAINTAINER_FILES = {"postinst", "prerm"}
MAINTAINER_BINARY_FILES = ("postinst", "prerm")
FORBIDDEN_LEGACY_PAYLOAD_BASENAMES = {
    "discord@2x.png",
    "discord@3x.png",
    "reddit@2x.png",
    "reddit@3x.png",
    "telegram@2x.png",
    "telegram@3x.png",
    "twitter@2x.png",
    "twitter@3x.png",
}
PLIST_IDENTITIES = {
    "Library/ControlCenter/Bundles/NetworkManager.bundle/Info.plist": (
        PACKAGE_ID,
        "NetworkManager",
    ),
    "Library/PreferenceBundles/NetworkManagerPrefs.bundle/Info.plist": (
        "me.nixuge.networkmanagerprefs",
        "NetworkManagerPrefs",
    ),
}


class CommandFailure(RuntimeError):
    pass


def run_command(command: Sequence[str], check: bool = True) -> Tuple[int, str]:
    try:
        completed = subprocess.run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            check=False,
        )
    except OSError as error:
        if check:
            raise CommandFailure("could not execute %s: %s" % (command[0], error))
        return 127, str(error)
    if check and completed.returncode != 0:
        raise CommandFailure(
            "command failed (%d): %s\n%s"
            % (completed.returncode, " ".join(command), completed.stdout.strip())
        )
    return completed.returncode, completed.stdout


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalized_field(value: str) -> str:
    return " ".join(value.split())


def dependency_names(value: str) -> set:
    names = set()
    for clause in value.split(","):
        first_alternative = clause.split("|", 1)[0].strip()
        match = re.match(r"([a-z0-9+.-]+)", first_alternative, re.IGNORECASE)
        if match:
            names.add(match.group(1).lower())
    return names


def payload_manifest(extract_root: Path) -> List[str]:
    paths: List[str] = []
    for parent, directory_names, file_names in os.walk(str(extract_root), followlinks=False):
        parent_path = Path(parent)
        for name in file_names:
            paths.append((parent_path / name).relative_to(extract_root).as_posix())
        for name in list(directory_names):
            candidate = parent_path / name
            if candidate.is_symlink():
                paths.append(candidate.relative_to(extract_root).as_posix())
                directory_names.remove(name)
    return sorted(paths)


def version_tuple(value: str) -> Tuple[int, ...]:
    parts = value.split(".")
    if not parts or any(not part.isdigit() for part in parts):
        raise ValueError("invalid version %r" % value)
    return tuple(int(part) for part in parts)


def version_at_least(actual: str, required: str) -> bool:
    actual_parts = version_tuple(actual)
    required_parts = version_tuple(required)
    width = max(len(actual_parts), len(required_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) >= required_parts + (0,) * (
        width - len(required_parts)
    )


def versions_equal(actual: str, expected: str) -> bool:
    actual_parts = version_tuple(actual)
    expected_parts = version_tuple(expected)
    width = max(len(actual_parts), len(expected_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) == expected_parts + (0,) * (
        width - len(expected_parts)
    )


def parse_build_versions(text: str) -> List[Tuple[str, str]]:
    """Parse minOS/SDK pairs from vtool output for one thin Mach-O slice."""

    result: List[Tuple[str, str]] = []
    minimum: Optional[str] = None
    for line in text.splitlines():
        minimum_match = re.match(r"\s*(?:minos|version)\s+([0-9]+(?:\.[0-9]+){1,2})\s*$", line)
        if minimum_match:
            minimum = minimum_match.group(1)
            continue
        sdk_match = re.match(r"\s*sdk\s+([0-9]+(?:\.[0-9]+){1,2})\s*$", line)
        if sdk_match and minimum is not None:
            result.append((minimum, sdk_match.group(1)))
            minimum = None
    return result


def parse_allowed_sdks(value: Optional[str]) -> List[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def scan_payload_for_diagnostics(extract_root: Path) -> List[Dict[str, object]]:
    findings: List[Dict[str, object]] = []
    strings_tool = shutil.which("strings")
    for relative in payload_manifest(extract_root):
        path = extract_root / relative
        if path.is_symlink() or not path.is_file():
            continue
        try:
            raw = path.read_bytes()
        except OSError as error:
            findings.append({"file": relative, "error": str(error)})
            continue
        text = raw.decode("utf-8", errors="ignore")
        if b"\x00" in raw and strings_tool:
            _, strings_output = run_command([strings_tool, "-a", str(path)], check=False)
            text += "\n" + strings_output
        for label, pattern in FORBIDDEN_DIAGNOSTIC_PATTERNS:
            match = pattern.search(text)
            if match:
                findings.append(
                    {
                        "file": relative,
                        "category": label,
                        "match": match.group(0),
                    }
                )
    return findings


def is_macho_file(path: Path) -> bool:
    try:
        magic = path.read_bytes()[:4]
    except OSError:
        return False
    return magic in {
        b"\xcf\xfa\xed\xfe",  # thin arm64 little-endian
        b"\xfe\xed\xfa\xcf",  # thin arm64 big-endian
        b"\xca\xfe\xba\xbe",  # fat Mach-O
        b"\xbe\xba\xfe\xca",  # fat Mach-O swapped
    }


def verify_maintainer_scripts(control_root: Path, failures: List[str]) -> Dict[str, object]:
    evidence: Dict[str, object] = {}
    failure_count_before = len(failures)
    files = sorted(path.name for path in control_root.iterdir() if path.is_file()) if control_root.is_dir() else []
    evidence["files"] = files
    missing = sorted(REQUIRED_MAINTAINER_FILES - set(files))
    if missing:
        failures.append("package control archive is missing: %s" % ", ".join(missing))
    for name in REQUIRED_MAINTAINER_FILES:
        path = control_root / name
        if not path.is_file():
            continue
        mode = path.stat().st_mode & 0o777
        if mode != 0o755:
            failures.append("maintainer script %s must have exact mode 755 (got %o)" % (name, mode))
        if not is_macho_file(path):
            failures.append("maintainer script %s must be a signed Mach-O guard" % name)
    evidence["status"] = "passed" if len(failures) == failure_count_before else "failed"
    return evidence


def verify_plists(payload_root: Path, manifest: Sequence[str], failures: List[str]) -> Dict[str, object]:
    evidence: Dict[str, object] = {}
    parsed = []
    for relative in manifest:
        if not relative.lower().endswith(".plist"):
            continue
        path = payload_root / relative
        try:
            data = plistlib.loads(path.read_bytes())
        except Exception as error:
            failures.append("plist parse failed for %s: %s" % (relative, error))
            continue
        parsed.append(relative)
        if relative in PLIST_IDENTITIES:
            expected_id, expected_executable = PLIST_IDENTITIES[relative]
            if data.get("CFBundleIdentifier") != expected_id:
                failures.append("%s has unexpected CFBundleIdentifier" % relative)
            if data.get("CFBundleExecutable") != expected_executable:
                failures.append("%s has unexpected CFBundleExecutable" % relative)
    evidence["parsed"] = sorted(parsed)
    evidence["count"] = len(parsed)
    if not parsed:
        failures.append("package contains no parseable plist files")
    return evidence


def has_arm64e_usr00_header(otool_output: str) -> bool:
    return re.search(r"ARM64\s+E\s+USR00", otool_output) is not None


def normalized_dependencies(otool_output: str, binary_name: Optional[str] = None) -> List[str]:
    result = []
    for line in otool_output.splitlines():
        if not line[:1].isspace():
            continue
        value = line.strip().split(" (", 1)[0]
        if not value:
            continue
        if binary_name and value.startswith("/Library/") and value.rsplit("/", 1)[-1] == binary_name:
            continue
        result.append(value)
    return sorted(set(result))


def verify_macho_binary(
    binary: Path,
    lane: str,
    allowed_sdks: Sequence[str],
    failures: List[str],
) -> Dict[str, object]:
    evidence: Dict[str, object] = {"path": str(binary)}

    return_code, lipo_info = run_command(["xcrun", "lipo", "-info", str(binary)], check=False)
    evidence["lipo"] = lipo_info.strip()
    if return_code != 0:
        failures.append("lipo could not inspect %s" % binary)
        return evidence
    architectures = set(re.findall(r"\barm64e?\b", lipo_info))
    evidence["architectures"] = sorted(architectures)
    if architectures != {"arm64", "arm64e"}:
        failures.append("%s must contain exactly arm64 and arm64e" % binary)
    verify_code, verify_output = run_command(
        ["xcrun", "lipo", str(binary), "-verify_arch", "arm64", "arm64e"], check=False
    )
    evidence["lipo_verify"] = verify_output.strip()
    if verify_code != 0:
        failures.append("lipo -verify_arch failed for %s" % binary)

    header_code, header_output = run_command(["xcrun", "otool", "-hv", str(binary)], check=False)
    evidence["mach_headers"] = header_output.strip().splitlines()
    if header_code != 0:
        failures.append("otool -hv failed for %s" % binary)
    elif not has_arm64e_usr00_header(header_output):
        failures.append("%s lacks arm64e subtype ARM64 E USR00" % binary)

    load_code, load_output = run_command(["xcrun", "otool", "-l", str(binary)], check=False)
    load_commands = sorted(set(re.findall(r"\bcmd (LC_[A-Z0-9_]+)", load_output)))
    evidence["load_commands"] = load_commands
    if load_code != 0:
        failures.append("otool -l failed for %s" % binary)
    else:
        if "LC_CODE_SIGNATURE" not in load_commands:
            failures.append("%s lacks LC_CODE_SIGNATURE" % binary)
        has_info_only = "LC_DYLD_INFO_ONLY" in load_commands
        has_chained_fixups = "LC_DYLD_CHAINED_FIXUPS" in load_commands
        if not has_info_only and not has_chained_fixups:
            failures.append("%s lacks both supported dyld fixup formats" % binary)
        if lane == "roothide" and has_chained_fixups:
            failures.append("%s contains forbidden LC_DYLD_CHAINED_FIXUPS" % binary)
        if lane == "roothide" and binary.name in ROOTHIDE_BASELINE_DEPENDENCIES and set(load_commands) != ROOTHIDE_RELEASE_LOAD_COMMANDS:
            failures.append(
                "%s load-command set differs from the device-verified roothide baseline" % binary
            )

    dependency_code, dependency_output = run_command(
        ["xcrun", "otool", "-L", str(binary)], check=False
    )
    dependencies = normalized_dependencies(dependency_output, binary.name)
    evidence["dependencies"] = dependencies
    if dependency_code != 0:
        failures.append("otool -L failed for %s" % binary)
    elif lane == "roothide":
        if ROOTHIDE_DYLIB not in dependencies:
            failures.append("%s lacks the pinned roothide runtime dependency" % binary)
        forbidden_private = [
            item
            for item in dependencies
            if "ControlCenterUIKit.framework" in item or "Preferences.framework" in item
        ]
        if forbidden_private:
            failures.append("%s leaks private-framework dependencies in roothide lane" % binary)
        expected_dependencies = ROOTHIDE_RELEASE_DEPENDENCIES.get(binary.name)
        if expected_dependencies is not None and set(dependencies) != expected_dependencies:
            missing = sorted(expected_dependencies - set(dependencies))
            added = sorted(set(dependencies) - expected_dependencies)
            failures.append(
                "%s dependency set differs from the device-verified roothide baseline (missing=%s, added=%s)"
                % (binary, missing, added)
            )
    elif ROOTHIDE_DYLIB in dependencies:
        failures.append("rootless binary unexpectedly links the roothide runtime: %s" % binary)

    build_evidence: Dict[str, object] = {}
    with tempfile.TemporaryDirectory(prefix="nmr-thin-") as temp_directory:
        for architecture in ("arm64", "arm64e"):
            thin_path = Path(temp_directory) / architecture
            thin_code, thin_output = run_command(
                ["xcrun", "lipo", str(binary), "-thin", architecture, "-output", str(thin_path)],
                check=False,
            )
            if thin_code != 0:
                failures.append("could not thin %s as %s: %s" % (binary, architecture, thin_output.strip()))
                continue
            vtool_code, vtool_output = run_command(
                ["xcrun", "vtool", "-show-build", str(thin_path)], check=False
            )
            pairs = parse_build_versions(vtool_output)
            build_evidence[architecture] = {
                "versions": [{"min_os": minimum, "sdk": sdk} for minimum, sdk in pairs],
                "raw": vtool_output.strip().splitlines(),
            }
            if vtool_code != 0 or not pairs:
                failures.append("vtool did not return minOS/SDK evidence for %s (%s)" % (binary, architecture))
                continue
            required_minimum = EXPECTED_MIN_OS[architecture]
            for minimum, sdk in pairs:
                try:
                    if not versions_equal(minimum, required_minimum):
                        failures.append(
                            "%s %s minOS %s must equal %s"
                            % (binary, architecture, minimum, required_minimum)
                        )
                except ValueError as error:
                    failures.append("invalid vtool version for %s: %s" % (binary, error))
                if allowed_sdks and sdk not in allowed_sdks:
                    failures.append(
                        "%s %s SDK %s is not one of %s"
                        % (binary, architecture, sdk, ", ".join(allowed_sdks))
                    )
    evidence["build_versions"] = build_evidence

    ldid_tool = shutil.which("ldid")
    if ldid_tool:
        ldid_code, ldid_output = run_command([ldid_tool, "-e", str(binary)], check=False)
        evidence["ldid_entitlements"] = ldid_output.strip().splitlines()
        if ldid_code != 0:
            failures.append("ldid could not parse the code signature for %s" % binary)
    else:
        failures.append("ldid is required to verify the code signature of %s" % binary)
    signature_code, signature_output = run_command(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(binary)],
        check=False,
    )
    evidence["codesign_verify"] = signature_output.strip().splitlines()
    if signature_code != 0:
        # ldid signatures are valid for jailbreak packaging but are not Apple
        # CodeSign objects, so macOS codesign reports this known diagnostic.
        known_ldid_diagnostic = re.search(
            r"code object is not signed at all", signature_output, re.IGNORECASE
        )
        evidence["codesign_known_ldid_diagnostic"] = bool(known_ldid_diagnostic)
        if not known_ldid_diagnostic:
            failures.append("codesign verification failed for %s" % binary)
    display_code, display_output = run_command(
        ["codesign", "--display", "--verbose=4", str(binary)], check=False
    )
    evidence["codesign_display"] = display_output.strip().splitlines()
    if display_code != 0:
        failures.append("codesign could not parse signature metadata for %s" % binary)
    return evidence


def verify_package(args: argparse.Namespace) -> Dict[str, object]:
    package = args.package.resolve()
    source_control = args.source_control.resolve()
    failures: List[str] = []
    report: Dict[str, object] = {
        "lane": args.lane,
        "source_sha": args.source_sha,
        "run_id": args.run_id,
        "package_path": str(package),
        "failures": failures,
    }

    if not package.is_file():
        failures.append("package is missing: %s" % package)
        report["status"] = "failed"
        return report
    report["size_bytes"] = package.stat().st_size
    report["sha256"] = sha256_file(package)
    if package.stat().st_size == 0:
        failures.append("package is empty")

    try:
        source_fields = parse_debian_fields(source_control.read_text(encoding="utf-8"))
        failures.extend(validate_control_fields(source_fields))
    except (OSError, ValueError) as error:
        source_fields = {}
        failures.append("could not parse source control: %s" % error)
    report["source_control"] = source_fields

    try:
        _, package_control_text = run_command(["dpkg-deb", "-f", str(package)])
        package_fields = parse_debian_fields(package_control_text)
    except (CommandFailure, ValueError) as error:
        package_fields = {}
        failures.append("could not parse package control: %s" % error)
    report["package_control"] = package_fields

    expected_fields = {
        "package": PACKAGE_ID,
        "name": PACKAGE_NAME,
        "version": RELEASE_VERSION,
        "architecture": EXPECTED_ARCHITECTURE[args.lane],
    }
    for key, expected in expected_fields.items():
        if package_fields.get(key) != expected:
            failures.append("package control %s must be %r (got %r)" % (key, expected, package_fields.get(key)))
    package_name = package_fields.get("name", "")
    package_description = package_fields.get("description", "")
    if re.search(r"\broothide\b", "%s %s" % (package_name, package_description), re.IGNORECASE):
        failures.append("package Name/Description must be neutral and must not mention roothide")
    source_description = source_fields.get("description", "")
    if source_description and normalized_field(package_description) != normalized_field(source_description):
        failures.append("package Description differs from the shared source control metadata")
    if source_fields.get("name") and package_name != source_fields.get("name"):
        failures.append("package Name differs from the shared source control metadata")
    missing_dependencies = REQUIRED_DEPENDENCIES - dependency_names(package_fields.get("depends", ""))
    if missing_dependencies:
        failures.append("package is missing dependencies: %s" % ", ".join(sorted(missing_dependencies)))

    build_log = args.build_log.resolve() if args.build_log else None
    if build_log:
        log_failures = verify_log(build_log)
        report["build_log"] = {
            "path": str(build_log),
            "size_bytes": build_log.stat().st_size if build_log.is_file() else 0,
            "failures": log_failures,
        }
        failures.extend(log_failures)

    with tempfile.TemporaryDirectory(prefix="nmr-package-") as temp_directory:
        extract_root = Path(temp_directory) / "extract"
        control_root = Path(temp_directory) / "control"
        extract_root.mkdir()
        control_root.mkdir()
        try:
            run_command(["dpkg-deb", "-x", str(package), str(extract_root)])
            run_command(["dpkg-deb", "-e", str(package), str(control_root)])
        except CommandFailure as error:
            failures.append("could not extract package: %s" % error)
            report["status"] = "failed"
            return report

        report["maintainer_scripts"] = verify_maintainer_scripts(control_root, failures)
        raw_manifest = payload_manifest(extract_root)
        report["raw_manifest"] = raw_manifest
        if args.lane == "rootless":
            outside_prefix = [path for path in raw_manifest if not path.startswith("var/jb/")]
            if outside_prefix:
                failures.append("rootless payload has files outside var/jb: %s" % ", ".join(outside_prefix))
            payload_root = extract_root / "var" / "jb"
        else:
            prefixed = [path for path in raw_manifest if path.startswith("var/jb/")]
            if prefixed:
                failures.append("roothide payload unexpectedly contains var/jb paths")
            payload_root = extract_root

        manifest = payload_manifest(payload_root) if payload_root.is_dir() else []
        report["manifest"] = manifest
        missing_files = sorted(REQUIRED_PAYLOAD_FILES - set(manifest))
        if missing_files:
            failures.append("package manifest is missing: %s" % ", ".join(missing_files))
        if not manifest:
            failures.append("package payload manifest is empty")
        legacy_assets = sorted(path for path in manifest if Path(path).name in FORBIDDEN_LEGACY_PAYLOAD_BASENAMES)
        report["legacy_assets"] = legacy_assets
        if legacy_assets:
            failures.append("package contains removed social-link assets: %s" % ", ".join(legacy_assets))
        report["plists"] = verify_plists(payload_root, manifest, failures)

        forbidden = scan_payload_for_diagnostics(extract_root)
        control_forbidden = scan_payload_for_diagnostics(control_root)
        report["forbidden_diagnostics"] = forbidden
        report["maintainer_forbidden_diagnostics"] = control_forbidden
        if forbidden or control_forbidden:
            failures.append("package contains forbidden diagnostic strings/actions")

        macho_requested = args.require_mach_o or sys.platform == "darwin"
        report["macho_requested"] = macho_requested
        if macho_requested and sys.platform != "darwin":
            failures.append("Mach-O verification was required but the host is not macOS")
        elif macho_requested:
            allowed_sdks = parse_allowed_sdks(args.expected_sdk)
            macho = []
            for relative in BINARY_PAYLOAD_FILES:
                binary = payload_root / relative
                if not binary.is_file():
                    failures.append("missing Mach-O binary: %s" % relative)
                    continue
                macho.append(verify_macho_binary(binary, args.lane, allowed_sdks, failures))
            for relative in MAINTAINER_BINARY_FILES:
                binary = control_root / relative
                if not binary.is_file():
                    failures.append("missing maintainer Mach-O binary: %s" % relative)
                    continue
                macho.append(verify_macho_binary(binary, args.lane, allowed_sdks, failures))
            report["macho"] = macho
        else:
            report["macho"] = {"status": "skipped", "reason": "non-macOS host"}

    report["status"] = "passed" if not failures else "failed"
    return report


def write_report(report: Dict[str, object], path: Optional[Path]) -> None:
    serialized = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(serialized, encoding="utf-8")
    print(serialized, end="")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--lane", required=True, choices=sorted(EXPECTED_ARCHITECTURE))
    parser.add_argument("--source-control", type=Path, default=Path("control"))
    parser.add_argument("--build-log", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--checksums", type=Path)
    parser.add_argument("--checksum-name", help="Path recorded for the package in SHA256SUMS")
    parser.add_argument("--source-sha", default=os.environ.get("GITHUB_SHA", "unknown"))
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "local"))
    parser.add_argument(
        "--expected-sdk",
        help="Comma-separated SDK versions accepted in every slice (for example 17.5)",
    )
    parser.add_argument("--require-mach-o", action="store_true")
    args = parser.parse_args(argv)

    report = verify_package(args)
    write_report(report, args.report)
    package = args.package.resolve()
    if args.checksums and package.is_file():
        checksum_name = args.checksum_name or package.name
        checksum_path = Path(checksum_name)
        if checksum_path.is_absolute() or ".." in checksum_path.parts:
            print("ERROR: checksum name must be a safe relative path", file=sys.stderr)
            return 1
        args.checksums.parent.mkdir(parents=True, exist_ok=True)
        args.checksums.write_text("%s  %s\n" % (sha256_file(package), checksum_name), encoding="utf-8")
    if report["status"] != "passed":
        for failure in report["failures"]:
            print("ERROR: %s" % failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
