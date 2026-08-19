#!/usr/bin/env python3
import argparse
import plistlib
from pathlib import Path


LABEL = "me.nixuge.networkmanager.maintenance"
PLIST_RELATIVE = Path("Library/LaunchDaemons") / f"{LABEL}.plist"
PROGRAM_RELATIVE = "/usr/libexec/networkmanager-maintenance"
BASELINE_RELATIVE = (
    "/var/mobile/Library/Preferences/"
    "me.nixuge.networkmanager.n78-policy.baseline.plist"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scheme", choices=("rootless", "roothide"), required=True)
    parser.add_argument("--staging-dir", type=Path, required=True)
    args = parser.parse_args()

    path = args.staging_dir / PLIST_RELATIVE
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if payload.get("Label") != LABEL:
        raise SystemExit(f"invalid launchd label in {path}")

    prefix = "/var/jb" if args.scheme == "rootless" else "@JBROOT@"
    payload["ProgramArguments"] = [prefix + PROGRAM_RELATIVE, "--daemon"]
    payload["KeepAlive"] = {
        "PathState": {prefix + BASELINE_RELATIVE: True},
    }
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
