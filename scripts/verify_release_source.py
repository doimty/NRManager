#!/usr/bin/env python3
"""Verify release metadata, source plists, and absence of diagnostic UI/actions."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


PACKAGE_ID = "com.doimty.nrmanager"
PACKAGE_NAME = "NR Manager"
RELEASE_VERSION = "1.7.4"

# These names belong to the discarded diagnostic UI and write experiments. n78,
# BandInfo, and serving-state terms are intentionally not blocked: they are part
# of the formal product contract and may appear in production implementation.
FORBIDDEN_DIAGNOSTIC_PATTERNS: Sequence[Tuple[str, re.Pattern]] = (
    (
        "diagnostic UI or result string",
        re.compile(
            r"\b(?:Band Diagnostics|Serving Cell Telemetry|Write Authorization Experiment|"
            r"Cold Band Removal Experiment|LTE B3 to B1 Experiment|NR n78-Only Experiment|"
            r"Same-Value Band Write|Cold LTE Band Removal|NR n78 Only for 60 Seconds|"
            r"Clear Saved Probe State|Query Active / Supported Bands|Band probe|"
            r"Cell monitor probe|Target-only diagnostic)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "diagnostic action",
        re.compile(
            r"\b(?:showBandProbe|showServingCellProbe|confirmSameValueBandWrite|"
            r"confirmColdBandRemovalWrite|confirmLTEB1BandWrite|confirmNR78BandWrite|"
            r"confirmRestoreBandSnapshot|confirmClearProbeState)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "diagnostic operation",
        re.compile(
            r"\b(?:same_value(?:_write|_automatic_restore)?|cold_band_removal(?:_[a-z0-9_]+)?|"
            r"nr78_only(?:_[a-z0-9_]+)?|lte_b1_only(?:_[a-z0-9_]+)?)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "diagnostic persistence path",
        re.compile(r"(?:bandprobe|cellmonitor\.probe|bandwrite\.)", re.IGNORECASE),
    ),
)

# .in and .sh are here because the maintainer scripts became shell templates.
# They used to be postinst.m / prerm.m, which .m already covered, so dropping
# them would have quietly removed two device-shipped files from this gate.
TEXT_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".in",
    ".m",
    ".mm",
    ".mk",
    ".plist",
    ".sh",
    ".strings",
    ".swift",
    ".x",
    ".xml",
    ".yaml",
    ".yml",
}
SKIP_PARTS = {".git", ".theos", "build", "packages", "scripts", "tests", "docs", "theos"}


def parse_debian_fields(text: str) -> Dict[str, str]:
    """Parse the small RFC822-like subset used by Debian control files."""

    fields: Dict[str, str] = {}
    current = ""
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        if not raw_line.strip():
            continue
        if raw_line[0] in " \t":
            if not current:
                raise ValueError("continuation without a field at line %d" % line_number)
            fields[current] += "\n" + raw_line.strip()
            continue
        if ":" not in raw_line:
            raise ValueError("malformed field at line %d" % line_number)
        key, value = raw_line.split(":", 1)
        key = key.strip().lower()
        if not key or key in fields:
            raise ValueError("duplicate or empty field at line %d" % line_number)
        current = key
        fields[current] = value.strip()
    return fields


def read_control(path: Path) -> Dict[str, str]:
    return parse_debian_fields(path.read_text(encoding="utf-8"))


def validate_control_fields(fields: Dict[str, str]) -> List[str]:
    failures: List[str] = []
    expected = {
        "package": PACKAGE_ID,
        "name": PACKAGE_NAME,
        "version": RELEASE_VERSION,
    }
    for key, value in expected.items():
        if fields.get(key) != value:
            failures.append("control %s must be %r (got %r)" % (key, value, fields.get(key)))
    if fields.get("architecture") not in {"iphoneos-arm64", "iphoneos-arm64e"}:
        failures.append("control architecture must be an iPhone arm64 architecture")
    description = fields.get("description", "")
    if not description.strip():
        failures.append("control description is empty")
    if re.search(r"\broothide\b", description, re.IGNORECASE):
        failures.append("control description must be neutral and must not mention roothide")
    for key in ("maintainer", "author", "section", "depends"):
        if not fields.get(key, "").strip():
            failures.append("control field %s is missing or empty" % key)
    return failures


def _included(path: Path, repo: Path) -> bool:
    try:
        relative = path.relative_to(repo)
    except ValueError:
        return False
    return not any(part in SKIP_PARTS for part in relative.parts)


def iter_source_text_files(repo: Path) -> Iterable[Path]:
    for path in repo.rglob("*"):
        if not path.is_file() or not _included(path, repo):
            continue
        if path.name == "control" or path.suffix.lower() in TEXT_SUFFIXES:
            yield path


def scan_forbidden_strings(repo: Path) -> List[Dict[str, object]]:
    findings: List[Dict[str, object]] = []
    for path in iter_source_text_files(repo):
        try:
            raw = path.read_bytes()
        except OSError as error:
            findings.append({"file": str(path), "error": str(error)})
            continue
        if b"\x00" in raw:
            continue
        text = raw.decode("utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), 1):
            for label, pattern in FORBIDDEN_DIAGNOSTIC_PATTERNS:
                if pattern.search(line):
                    findings.append(
                        {
                            "file": str(path.relative_to(repo)),
                            "line": line_number,
                            "category": label,
                            "text": line.strip(),
                        }
                    )
    return findings


def validate_plists(repo: Path) -> List[str]:
    failures: List[str] = []
    required = {
        Path("Resources/Info.plist"): (PACKAGE_ID, "NRManager"),
        Path("nrmanagerprefs/Resources/Info.plist"): (
            "com.doimty.nrmanager.prefs",
            "NRManagerPrefs",
        ),
    }
    for relative, (bundle_id, executable) in required.items():
        path = repo / relative
        if not path.is_file():
            failures.append("missing source plist: %s" % relative)
            continue
        try:
            data = plistlib.loads(path.read_bytes())
        except Exception as error:  # plistlib raises several platform-specific types
            failures.append("could not parse %s: %s" % (relative, error))
            continue
        if data.get("CFBundleIdentifier") != bundle_id:
            failures.append("%s has unexpected CFBundleIdentifier" % relative)
        if data.get("CFBundleExecutable") != executable:
            failures.append("%s has unexpected CFBundleExecutable" % relative)

    for path in repo.rglob("*.plist"):
        if not _included(path, repo):
            continue
        try:
            plistlib.loads(path.read_bytes())
        except Exception as error:
            failures.append("could not parse %s: %s" % (path.relative_to(repo), error))
    return failures


def validate_source(repo: Path) -> Dict[str, object]:
    failures: List[str] = []
    control_path = repo / "control"
    if not control_path.is_file():
        failures.append("missing control file")
        fields: Dict[str, str] = {}
    else:
        try:
            fields = read_control(control_path)
            failures.extend(validate_control_fields(fields))
        except (OSError, ValueError) as error:
            fields = {}
            failures.append("could not parse control: %s" % error)

    failures.extend(validate_plists(repo))
    forbidden = scan_forbidden_strings(repo)
    if forbidden:
        failures.append("forbidden diagnostic strings/actions found (%d finding(s))" % len(forbidden))
    return {
        "status": "passed" if not failures else "failed",
        "control": fields,
        "failures": failures,
        "forbidden": forbidden,
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    result = validate_source(repo)
    serialized = json.dumps(result, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized, encoding="utf-8")
    print(serialized, end="")
    if result["status"] != "passed":
        for failure in result["failures"]:
            print("ERROR: %s" % failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
