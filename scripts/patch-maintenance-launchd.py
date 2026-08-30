#!/usr/bin/env python3
"""Finalise the staged package for one install scheme.

Two jobs, both scheme-dependent.

1. The maintenance launchd plist gets its install prefix.
2. postinst and prerm are rendered from the shell templates, which includes the
   launchd label, plist path and baseline path they need in order to run
   launchctl themselves. That last part is not cosmetic: the compiled guards
   cannot exec anything on roothide, because the bootstrap injection that grants
   the exemption is not applied to them. The reporting device returned EPERM from
   posix_spawn for the real <jbroot>/usr/bin/launchctl while the shell in the
   same dpkg run exec'd both `jbroot` and the guard without trouble.

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

The earlier version of this file cited a basebin daemon's own DEBIAN/postinst as
precedent for an @JBROOT@ placeholder plus a sed in postinst. That precedent does
not transfer: basebin daemons are loaded by the jailbreak itself through the
native API, not by the patched launchctl, so they genuinely need a pre-expanded
path. Ordinary packages must not pre-expand. The two ordinary daemons shipped in
the bootstrap tarball agree. us.diatr.shshd.plist names /bin/sh and
/usr/libexec/shshd-wrapper, and com.apple.atrun.plist names /usr/libexec/atrun,
with no jbroot and no placeholder anywhere.

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


LABEL = "com.doimty.nrmanager.maintenance"
PLIST_RELATIVE = Path("Library/LaunchDaemons") / f"{LABEL}.plist"
PROGRAM_RELATIVE = "/usr/libexec/networkmanager-maintenance"
BASELINE_RELATIVE = (
    "/var/mobile/Library/Preferences/"
    "com.doimty.nrmanager.n78-policy.baseline.plist"
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
# One copy of the launchctl exec logic, substituted into both scripts. Two
# hand-maintained copies in two maintainer scripts is how the halves drift apart,
# and this logic is the part that had to move out of the compiled guards.
LAUNCHCTL_INCLUDE = "launchctl.sh.inc"
# The shell's copy of the durable policy record paths, and the presence check and
# cleanup built on them. Only prerm needs it.
POLICY_RECORD_INCLUDE = "policy-records.sh.inc"

# There is deliberately no carrier-reset include and no version floor any more.
#
# 1.6.0 rendered a `killall -9 CommCenter` adapter into prerm and used a dpkg
# version comparison against a floor to decide when to run it. The premise was
# that killing CommCenter makes the modem reload carrier defaults; the target
# device disproved it, and the false success authorised deleting the baseline that
# holds the only copy of the user's original band configuration. Both the adapter
# and the floor that gated it are gone, along with the dpkg child process and the
# fail-open branch that once reset on every ordinary upgrade.
#
# Do not reintroduce either. Undoing a narrowed modem needs a reverse
# setActiveBandInfo: write against CoreTelephony, which only the Settings bundle
# can perform, so a maintainer script has no mechanism to offer.

# Placeholders each rendered script must contain, so a template that stops using
# one is caught at package time rather than by a silently skipped substitution.
#
# The launchd identifiers are rendered rather than written into the templates by
# hand: the shell half now runs launchctl itself, and a label copied by hand
# could drift from the one inside the plist. The drift would not be caught by the
# contract check either -- launchctl would load the plist and the verification
# would then ask about a job nobody registered.
COMMON_PLACEHOLDERS = ("@PREFIX@", "@LAUNCHD_PREFIX@", "@NEEDS_JBROOT@",
                       "@LAUNCHD_LABEL@", "@LAUNCHCTL_SUPPORT@")
REQUIRED_PLACEHOLDERS = {
    # Only postinst loads the job, so only postinst needs the plist it loads.
    # prerm boots the job out, which needs the label alone.
    "postinst": COMMON_PLACEHOLDERS + ("@LAUNCHD_PLIST@",),
    # Only prerm inspects and discards policy records. Installing does not retire
    # a band configuration, so postinst has no business carrying the paths -- and
    # deleting a baseline there would destroy the way back from the policy the
    # user just installed.
    "prerm": COMMON_PLACEHOLDERS + ("@POLICY_RECORD_SUPPORT@",),
}
# Retired, and still scanned for. @BASELINE@ was how postinst decided whether to
# kickstart the job. The kickstart is gone, so neither script carries the token
# and nothing substitutes it -- which is exactly why it stays in the residue
# check: a reintroduced @BASELINE@ would now ship as a literal inside a path.
# The value itself still exists as a constant here, because the plist's KeepAlive
# PathState names it and that is what starts the job now.
#
# @CARRIER_RESET_SUPPORT@ and @CARRIER_RESET_FLOOR@ join it for a different
# reason: 1.6.0 substituted both, and a template that still carries one must fail
# packaging rather than ship the token as literal shell.
RETIRED_PLACEHOLDERS = ("@BASELINE@", "@CARRIER_RESET_SUPPORT@", "@CARRIER_RESET_FLOOR@")
# Every placeholder either script may carry, used for the post-render residue
# check. Built from the same tables so a new placeholder cannot be added to one
# without the check learning about it.
ALL_PLACEHOLDERS = tuple(sorted(set(
    [token for tokens in REQUIRED_PLACEHOLDERS.values() for token in tokens]
    + list(RETIRED_PLACEHOLDERS))))


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
    launchctl_support = (source / LAUNCHCTL_INCLUDE).read_text().rstrip("\n")
    policy_record_support = (source / POLICY_RECORD_INCLUDE).read_text().rstrip("\n")
    written = []
    for name in MAINTAINER_SCRIPTS:
        template = source / f"{name}.sh.in"
        text = template.read_text()
        for placeholder in REQUIRED_PLACEHOLDERS[name]:
            if placeholder not in text:
                raise SystemExit(f"{template} is missing {placeholder}")
        text = text.replace("@PREFIX@", prefix)
        # A package-time constant, because it no longer depends on anything the
        # device knows. It was derived from the live jbroot while the plist held
        # an absolute path; now that the plist holds a bare one, the value is a
        # property of the lane alone.
        text = text.replace("@LAUNCHD_PREFIX@", launchd_prefix)
        text = text.replace("@NEEDS_JBROOT@", needs_jbroot)
        # Same values the plist was patched with, from the same constants, so the
        # script and the file it loads cannot disagree. The path carries the
        # launchd prefix because launchctl is what resolves it.
        text = text.replace("@LAUNCHD_LABEL@", LABEL)
        text = text.replace("@LAUNCHD_PLIST@",
                            launchd_prefix + "/" + PLIST_RELATIVE.as_posix())
        # Substituted last, so their own text is never scanned for placeholders
        # they do not carry and cannot accidentally supply one. Both are
        # unconditional replaces: the token is absent from the script that does
        # not want the block, so the substitution is a no-op there rather than a
        # second place that has to know which script gets which include.
        text = text.replace("@LAUNCHCTL_SUPPORT@", launchctl_support)
        text = text.replace("@POLICY_RECORD_SUPPORT@", policy_record_support)
        # Nothing unresolved may ship. These scripts run as root during dpkg, and
        # a skipped substitution would leave a literal @TOKEN@ in a path or a
        # launchctl target, where it would be a silent no-op at best.
        residue = [token for token in ALL_PLACEHOLDERS if token in text]
        if residue:
            raise SystemExit(
                f"{name} still contains {', '.join(sorted(residue))} after rendering")
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
