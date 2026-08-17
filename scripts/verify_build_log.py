#!/usr/bin/env python3
"""Fail a release build when its log is empty or contains a fatal diagnostic."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import List, Optional, Sequence, Tuple


ERROR_PATTERNS: Sequence[Tuple[str, re.Pattern]] = (
    ("incompatible arm64e", re.compile(r"\bincompatible\s+arm64e\b", re.IGNORECASE)),
    ("compiler fatal error", re.compile(r"\bfatal\s+error\s*:", re.IGNORECASE)),
    ("fatal tool error", re.compile(r"\bfatal:\s*", re.IGNORECASE)),
    ("compiler or linker error", re.compile(r"\berror:\s*", re.IGNORECASE)),
    ("undefined symbols", re.compile(r"\bundefined\s+symbols?\s+for\s+architecture\b", re.IGNORECASE)),
    ("duplicate symbol", re.compile(r"\bduplicate\s+symbols?\b", re.IGNORECASE)),
    ("linker command failed", re.compile(r"\blinker\s+command\s+failed\b", re.IGNORECASE)),
    ("make failure", re.compile(r"^make(?:\[[0-9]+\])?:\s*\*\*\*", re.IGNORECASE)),
)


def find_log_errors(text: str) -> List[Tuple[int, str, str]]:
    """Return (line number, category, line) tuples for release-blocking lines."""

    findings: List[Tuple[int, str, str]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        for category, pattern in ERROR_PATTERNS:
            if pattern.search(line):
                findings.append((line_number, category, line.rstrip()))
                break
    return findings


def verify_log(path: Path) -> List[str]:
    """Return human-readable failures; an empty list means the log passed."""

    if not path.is_file():
        return ["build log is missing: %s" % path]
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        return ["could not read build log %s: %s" % (path, error)]
    if not text.strip():
        return ["build log is empty: %s" % path]

    failures = []
    for line_number, category, line in find_log_errors(text):
        failures.append("%s:%d: %s: %s" % (path, line_number, category, line))
    return failures


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args(argv)

    failures = verify_log(args.log)
    if failures:
        for failure in failures:
            print("ERROR: %s" % failure, file=sys.stderr)
        return 1
    print("build log verified: %s (%d bytes)" % (args.log, args.log.stat().st_size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
