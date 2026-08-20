#!/usr/bin/env python3
"""Finalise the staged package for one install scheme.

Two jobs, both scheme-dependent.

1. The maintenance launchd plist gets its install prefix. launchd itself is not
   subject to any path redirection, so the plist must hold a real absolute path.
   On rootless that path is known at package time. On roothide the jailbreak root
   is only known on the device, so the plist keeps roothide's @JBROOT@
   placeholder and the shell postinst substitutes it there.

2. postinst and prerm are rendered from the shell templates.

Two different prefixes are involved and conflating them is the trap:

  plist prefix   what launchd will execute, so it must be a real absolute path
  script prefix  how the maintainer script itself reaches those files

On roothide the script prefix is empty. The shell that dpkg runs maintainer
scripts with does have the bootstrap injection, so it sees the jailbreak root
mapped at "/" and bare paths resolve inside it. roothide's own packages rely on
exactly that; Bootstrap-basebin/bootstrapd/layout/DEBIAN/postinst reads:

    plutil -xml /basebin/LaunchDaemons/com.roothide.bootstrap.bootstrapd.plist
    sed -i "s|@JBROOT@|$(jbroot)|g" /basebin/LaunchDaemons/...

Note the bare /basebin path being edited while $(jbroot) supplies the absolute
path written into the file. That is the same split used here.
"""
import argparse
import plistlib
import stat
from pathlib import Path


LABEL = "me.nixuge.networkmanager.maintenance"
PLIST_RELATIVE = Path("Library/LaunchDaemons") / f"{LABEL}.plist"
PROGRAM_RELATIVE = "/usr/libexec/networkmanager-maintenance"
BASELINE_RELATIVE = (
    "/var/mobile/Library/Preferences/"
    "me.nixuge.networkmanager.n78-policy.baseline.plist"
)
ROOTHIDE_PLACEHOLDER = "@JBROOT@"
ROOTLESS_PREFIX = "/var/jb"
MAINTAINER_SCRIPTS = ("postinst", "prerm")


def plist_prefix(scheme: str) -> str:
    """Prefix launchd will see. Resolved on device for roothide."""
    return ROOTLESS_PREFIX if scheme == "rootless" else ROOTHIDE_PLACEHOLDER


def script_prefix(scheme: str) -> str:
    """Prefix the maintainer script uses to reach installed files."""
    # Empty on roothide: the maintainer-script shell is redirected, so a bare
    # path already resolves inside the jailbreak root. Prepending the jbroot
    # would produce a doubled path.
    return ROOTLESS_PREFIX if scheme == "rootless" else ""


def patch_launchd_plist(staging: Path, prefix: str) -> Path:
    path = staging / PLIST_RELATIVE
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if payload.get("Label") != LABEL:
        raise SystemExit(f"invalid launchd label in {path}")

    payload["ProgramArguments"] = [prefix + PROGRAM_RELATIVE, "--daemon"]
    payload["KeepAlive"] = {
        "PathState": {prefix + BASELINE_RELATIVE: True},
    }
    # XML, because the roothide substitution is textual. A binary plist would
    # leave the placeholder unmatched and point the daemon at a literal
    # @JBROOT@ path, with nothing in the install log to show it.
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return path


def render_maintainer_scripts(staging: Path, source: Path, scheme: str) -> list:
    control = staging / "DEBIAN"
    control.mkdir(parents=True, exist_ok=True)
    prefix = script_prefix(scheme)
    needs_jbroot = "" if scheme == "rootless" else "1"
    written = []
    for name in MAINTAINER_SCRIPTS:
        template = source / f"{name}.sh.in"
        text = template.read_text()
        if "@PREFIX@" not in text:
            raise SystemExit(f"{template} is missing @PREFIX@")
        text = text.replace("@PREFIX@", prefix)
        text = text.replace("@NEEDS_JBROOT@", needs_jbroot)
        target = control / name
        target.write_text(text)
        target.chmod(0o755)
        mode = stat.S_IMODE(target.stat().st_mode)
        if mode != 0o755:
            raise SystemExit(f"{target} has mode {mode:o}, expected 755")
        written.append(target)
    return written


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheme", choices=("rootless", "roothide"), required=True)
    parser.add_argument("--staging-dir", type=Path, required=True)
    parser.add_argument(
        "--source-dir", type=Path,
        default=Path(__file__).resolve().parent.parent / "package-actions")
    args = parser.parse_args()

    patch_launchd_plist(args.staging_dir, plist_prefix(args.scheme))
    render_maintainer_scripts(args.staging_dir, args.source_dir, args.scheme)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
