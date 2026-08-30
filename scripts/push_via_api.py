#!/usr/bin/env python3
"""Push the current HEAD commit through the GitHub Git Data API.

Direct HTTPS git transport to github.com is failing on this host while
api.github.com is reachable. This recreates the exact same commit object
server-side: identical tree, parent, message, author and committer (including
timestamps), so the resulting SHA must match the local one. If it does not,
the script refuses to move the ref.
"""

import base64
import json
import subprocess
import sys

REPO = "doimty/NRManager"
BRANCH = "prototype/livecc-readonly"


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.rstrip("\n")


def commit_message(rev):
    """Exact message bytes as stored in the commit object.

    `git log --pretty=%B` appends its own newline, and stripping trailing
    newlines instead drops the one the object really has. Either way the
    recreated commit hashes differently, which is how this was caught: the API
    commit differed from the local one by a single byte.
    """
    raw = subprocess.run(
        ["git", "cat-file", "commit", rev], capture_output=True, check=True
    ).stdout
    _, separator, message = raw.partition(b"\n\n")
    if not separator:
        raise SystemExit(f"could not parse commit object for {rev}")
    return message.decode()


def api(path, payload=None, method=None):
    command = ["gh", "api", path]
    if method:
        command += ["--method", method]
    if payload is not None:
        command += ["--input", "-"]
    completed = subprocess.run(
        command,
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True,
        text=True,
        timeout=180,
    )
    if completed.returncode != 0:
        raise SystemExit(f"api {path} failed: {completed.stderr.strip()}")
    return json.loads(completed.stdout)


def main():
    head = git("rev-parse", "HEAD")
    parent = git("rev-parse", "HEAD^")
    local_tree = git("rev-parse", "HEAD^{tree}")
    parent_tree = git("rev-parse", f"{parent}^{{tree}}")
    message = commit_message("HEAD")
    fields = dict(
        zip(
            ("an", "ae", "ad", "cn", "ce", "cd"),
            git(
                "log", "-1", "--pretty=format:%an%n%ae%n%aI%n%cn%n%ce%n%cI"
            ).split("\n"),
        )
    )

    remote = api(f"repos/{REPO}/git/refs/heads/{BRANCH}")["object"]["sha"]
    if remote == head:
        print("already pushed")
        return
    if remote != parent:
        raise SystemExit(
            f"refusing to push: remote is {remote}, expected parent {parent}"
        )

    changes = git(
        "diff-tree", "--no-commit-id", "-r", "--name-status", head
    ).split("\n")
    entries = []
    for line in changes:
        status, path = line.split("\t", 1)
        if status == "D":
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            continue
        mode = git("ls-tree", head, "--", path).split()[0]
        content = subprocess.run(
            ["git", "cat-file", "blob", f"{head}:{path}"],
            capture_output=True,
            check=True,
        ).stdout
        blob = api(
            f"repos/{REPO}/git/blobs",
            {"content": base64.b64encode(content).decode(), "encoding": "base64"},
        )
        entries.append(
            {"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]}
        )
        print(f"blob {blob['sha'][:12]} {mode} {path}")

    tree = api(
        f"repos/{REPO}/git/trees",
        {"base_tree": parent_tree, "tree": entries},
    )
    if tree["sha"] != local_tree:
        raise SystemExit(
            f"tree mismatch: remote {tree['sha']} != local {local_tree}"
        )
    print(f"tree {tree['sha']} matches local")

    commit = api(
        f"repos/{REPO}/git/commits",
        {
            "message": message,
            "tree": tree["sha"],
            "parents": [parent],
            "author": {
                "name": fields["an"],
                "email": fields["ae"],
                "date": fields["ad"],
            },
            "committer": {
                "name": fields["cn"],
                "email": fields["ce"],
                "date": fields["cd"],
            },
        },
    )
    if commit["sha"] != head:
        raise SystemExit(
            f"commit mismatch: remote {commit['sha']} != local {head}; ref untouched"
        )
    print(f"commit {commit['sha']} matches local")

    api(
        f"repos/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": commit["sha"], "force": False},
        method="PATCH",
    )
    print(f"ref {BRANCH} -> {commit['sha']}")


if __name__ == "__main__":
    sys.exit(main())
