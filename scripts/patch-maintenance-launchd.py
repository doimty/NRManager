#!/usr/bin/env python3
"""Finalise the staged package for one install scheme.

Two jobs, both scheme-dependent.

1. The maintenance launchd plist gets its install prefix.
2. postinst and prerm are rendered from the shell templates.

The prefix that belongs in a roothide plist is *empty*, and getting this
backwards was the original defect. It is not a guess: roothide's launchctl is a
redirected binary that rewrites the plist before handing it to launchd.
`_patch_plist` in <jbroot>/usr/bin/launchctl walks Program,
ProgramArguments[0], RootDirectory, WorkingDirectory, Standard{In,Out,Error}Path,
WatchPaths, QueueDirectories, KeepAlive/PathState keys, Sockets and LaunchEvents,
and for every value starting with '/' does:

    if (patched) p = rootfs(p);            // only if it set __Patched itself
    xpc_dictionary_set_string(d, k, jbroot(p));

then stores __Patched=true back into the file. The only opt-out is a value
already prefixed with "/rootfs/". Re-entry is guarded solely by that __Patched
marker; the value is never inspected for a jbroot component it already carries.

So a roothide plist holding a jbroot-absolute path gets a second jbroot
prepended, and the reporting device showed exactly that:

    program = <jbroot>/<jbroot>/usr/libexec/networkmanager-maintenance

which then failed in dyld, because @loader_path resolved into a directory that
does not exist, so libroothide.dylib could not be found beside it. One
mechanism, both symptoms.

The earlier version of this file cited
Bootstrap-basebin/bootstrapd/layout/DEBIAN/postinst as precedent for an @JBROOT@
placeholder plus a sed in postinst. That precedent does not transfer: basebin
daemons are loaded by bootstrapd through the native API, not by the patched
launchctl, so they genuinely need a pre-expanded path. Ordinary packages must
not pre-expand. The two ordinary daemons shipped in the bootstrap tarball agree.
us.diatr.shshd.plist names /bin/sh and /usr/libexec/shshd-wrapper, and
com.apple.atrun.plist names /usr/libexec/atrun, with no jbroot and no
placeholder anywhere.

A second, independent reason the bare form is the only correct one: the jbroot
identifier changes every time the device is re-jailbroken. Observed directly
while diagnosing this -- .jbroot-D6B5C1F194F5F1C3 became
.jbroot-FD0B70513C6A9312 across one reboot. Any absolute path baked into the
package therefore expires at the next boot into a new bootstrap, and the daemon
would simply stop being found. Bare paths plus load-time prefixing survives
both this and the doubling above.

Two different prefixes are still involved, and conflating them remains the trap:

  plist prefix   what launchctl and launchd will resolve. Empty on roothide,
                 where launchctl supplies the root; /var/jb on rootless, where
                 nothing rewrites anything.
  script prefix  how the maintainer script itself reaches those files.

On roothide both happen to be empty, for unrelated reasons: the plist prefix
because launchctl prepends the root, the script prefix because the shell dpkg
runs maintainer scripts with has the bootstrap injection and sees the jailbreak
root mapped at "/". They stay separate values so a future change to one cannot
silently move the other.
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
# What the repo template carries where a prefix belongs. Deliberately invalid on
# both lanes, so a patcher that never ran is caught in both. The previous
# template held @JBROOT@, which meant a skipped patcher produced an accidentally
# correct roothide package and only rootless failed; that asymmetry is what let a
# wrong roothide contract look verified.
TEMPLATE_SENTINEL = "@PLIST_PREFIX@"
MAINTAINER_SCRIPTS = ("postinst", "prerm")


def plist_prefix(scheme: str) -> str:
    """Prefix that belongs inside the plist.

    Empty on roothide: launchctl prepends the jailbreak root to every absolute
    path in the file before launchd sees it, so anything written here would be
    doubled. See the module docstring for the disassembly this rests on.
    """
    return ROOTLESS_PREFIX if scheme == "rootless" else ""


def script_prefix(scheme: str) -> str:
    """Prefix the maintainer script uses to reach installed files."""
    # Empty on roothide: the maintainer-script shell is redirected, so a bare
    # path already resolves inside the jailbreak root. Prepending the jbroot
    # would produce a doubled path.
    #
    # Equal to plist_prefix() on both lanes today. That is a coincidence of two
    # separate facts, not a shared cause, so the two stay distinct.
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
    # Both path-bearing keys are rewritten wholesale rather than substituted, so
    # nothing unresolved can reach the device. Assert it: no on-device step
    # rewrites the plist any more, and launchctl would happily prepend the jbroot
    # to a placeholder and store the result.
    residue = plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=False)
    for token in (TEMPLATE_SENTINEL, ROOTHIDE_PLACEHOLDER):
        if token.encode() in residue:
            raise SystemExit(f"{path} still contains {token} after patching")
    # XML for legibility in the staged tree. Theos converts every staged plist to
    # binary1 in its FINALPACKAGE internal-package step, which runs after
    # before-package, so the format written here is not the format that ships.
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return path


def render_maintainer_scripts(staging: Path, source: Path, scheme: str) -> list:
    control = staging / "DEBIAN"
    control.mkdir(parents=True, exist_ok=True)
    prefix = script_prefix(scheme)
    launchd_prefix = plist_prefix(scheme)
    needs_jbroot = "" if scheme == "rootless" else "1"
    written = []
    for name in MAINTAINER_SCRIPTS:
        template = source / f"{name}.sh.in"
        text = template.read_text()
        for placeholder in ("@PREFIX@", "@LAUNCHD_PREFIX@"):
            if placeholder not in text:
                raise SystemExit(f"{template} is missing {placeholder}")
        text = text.replace("@PREFIX@", prefix)
        # A package-time constant, because it no longer depends on anything the
        # device knows. It was derived from the live jbroot while the plist held
        # an absolute path; now that the plist holds a bare one, the value is a
        # property of the lane alone.
        text = text.replace("@LAUNCHD_PREFIX@", launchd_prefix)
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
