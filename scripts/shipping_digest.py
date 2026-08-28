#!/usr/bin/env python3
"""Compute the shipping-source digest used by the delivered-version ledger.

The digest covers every tracked path that can change the bytes of the built
package, and excludes only what provably cannot: prose, the host test suites, and
the verifiers that read a build rather than produce one. Inclusion is the default,
so a new source directory is covered without anyone remembering to add it.

Exclusions are matched by shape rather than by listing individual files, because a
list is exactly what goes stale. Prose is any ``*.md``; tests are any path with a
``tests/`` component, which also covers the nested ``livecc/tests``.

The scope errs toward over-inclusion. The livecc prototype's own packaging files
do not reach the main package, but its ``Sources`` are compiled into it, so the
directory stays in. A wrong inclusion costs an unnecessary version bump; a wrong
exclusion lets a delivered version silently cover changed bytes.

Usage:
    shipping_digest.py                # the working tree
    shipping_digest.py <rev>          # a commit, read from git history
    shipping_digest.py --list [<rev>] # the paths that feed the digest
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional


REPO = Path(__file__).resolve().parents[1]

# Directory prefixes that cannot alter a package byte: editor settings, prose, and
# the verification scripts, which inspect a finished build.
NON_SHIPPING_PREFIXES = (
    ".vscode/",
    "docs/",
    "scripts/",
)
# Path components that mark a test tree wherever it appears.
NON_SHIPPING_COMPONENTS = ("tests",)
# Basenames that are never compiled or packaged.
NON_SHIPPING_BASENAMES = (".gitignore",)
# Suffixes that are prose.
NON_SHIPPING_SUFFIXES = (".md",)


def is_shipping(path: str) -> bool:
    if path.startswith(NON_SHIPPING_PREFIXES):
        return False
    if path.endswith(NON_SHIPPING_SUFFIXES):
        return False
    parts = path.split("/")
    if parts[-1] in NON_SHIPPING_BASENAMES:
        return False
    if any(part in NON_SHIPPING_COMPONENTS for part in parts[:-1]):
        return False
    return True


def _git(args: List[str]) -> str:
    completed = subprocess.run(
        ["git", "-C", str(REPO)] + args,
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )
    return completed.stdout


def _git_bytes(args: List[str]) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(REPO)] + args,
        capture_output=True,
        timeout=120,
        check=True,
    )
    return completed.stdout


def shipping_paths(rev: Optional[str] = None) -> List[str]:
    if rev is None:
        listing = _git(["ls-files", "-z"])
    else:
        listing = _git(["ls-tree", "-r", "--name-only", "-z", rev])
    paths = [entry for entry in listing.split("\0") if entry]
    return sorted(path for path in paths if is_shipping(path))


def shipping_files(rev: Optional[str] = None) -> Dict[str, bytes]:
    """Path to content for the shipping source.

    Without a rev this reads the working tree, so uncommitted edits are visible;
    a commit comparison alone would call a dirty tree clean.
    """
    contents: Dict[str, bytes] = {}
    for path in shipping_paths(rev):
        if rev is None:
            candidate = REPO / path
            if not candidate.is_file():
                # A tracked path deleted in the working tree is a real difference,
                # recorded as such rather than skipped.
                contents[path] = b"\0<missing>"
                continue
            contents[path] = candidate.read_bytes()
        else:
            contents[path] = _git_bytes(["cat-file", "blob", f"{rev}:{path}"])
    return contents


def digest(files: Dict[str, bytes]) -> str:
    accumulator = hashlib.sha256()
    for path in sorted(files):
        accumulator.update(path.encode("utf-8"))
        accumulator.update(b"\0")
        accumulator.update(hashlib.sha256(files[path]).hexdigest().encode("ascii"))
        accumulator.update(b"\n")
    return accumulator.hexdigest()


def main(argv: List[str]) -> int:
    listing = False
    if argv and argv[0] == "--list":
        listing = True
        argv = argv[1:]
    rev = argv[0] if argv else None
    if listing:
        for path in shipping_paths(rev):
            print(path)
        return 0
    print(digest(shipping_files(rev)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
