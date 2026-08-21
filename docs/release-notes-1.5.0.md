# NetworkManagerReborn 1.5.0 release notes

Status: release candidate source, not yet approved for distribution.

## Product changes

- Replaced local Control Center RAT cycling with a single reversible n78 preference.
- Enabling changes only the NR allowed-band array to exact `[78]`; all non-NR arrays, including LTE, remain unchanged.
- Added separate requested-policy, verified-applied-policy, and fresh serving-network states.
- Added adaptive Cell Monitor sampling for truthful NR n78, other NR, LTE, other, or stale/unknown serving status.
- Added an independently implemented, localized Simplified Chinese and English Settings interface.
- Kept links and credit for NoisyFlake's original project, Nixuge's continuation, and doimty's maintained source.

## Safety and recovery

- Retains the complete original six-RAT baseline while n78 preference is enabled.
- Uses durable intent and in-flight records, exact subscription identity, a cross-process lock, and full read-back verification.
- A 20-second setter deadline returns control while retaining the lock until a late private call resolves; uncertain outcomes forbid another same-boot write.
- Disabling restores the exact original NR list while preserving current non-NR arrays.
- Shell `postinst` and `prerm` do the privileged work, and compiled policy guards decide the verdict: restore runs before removal, or before a downgrade below 1.5.0, and a durable removal marker closes the post-`prerm` race.
- Maintenance-daemon registration reports its outcome honestly, and now reports success too: loaded, or not started because `launchctl` could not run, declined by launchd, or not loadable at all. Previously a clean install printed no launchd line at all, so success was inferable only from the absence of warnings, and a user had to ask what the silence meant. Where the daemon did not start, the install says to reinstall the package rather than promising that a reboot will start it: nothing in the jailbreak loads this directory at boot, and re-jailbreaking relocates the tree to a new jailbreak root. This holds for the roothide family generally, including Dopamine's roothide fork, whose launchd hook injects only `<jbroot>/basebin/LaunchDaemons` and leaves `<jbroot>/Library/LaunchDaemons` to `launchctl`.
- Malformed, missing, foreign, or inconsistent evidence fails closed. There is no ordinary-user clear-state action.

## Compatibility

The first accepted target is restricted to:

- iPhone14,3
- iOS 15.1.1 (19B81)
- exactly one present and good SIM in slot 1

This feature is an n78 preference, not a guarantee of continuous 5G or n78 service. LTE fallback is expected and is not reported as policy failure.

## Remaining release gates

- Independent source/spec/safety review with no unresolved P0 or P1 findings.
- Pinned macOS 14 / Xcode 15.4 rootless and roothide cloud builds.
- Mach-O, dependency, signature, package-control, warning, and checksum verification for both bundles, both policy guards, and the maintenance helper in each lane, plus the shell-shape gate on `DEBIAN/postinst` and `DEBIAN/prerm` and a per-lane gate on the staged launchd plist.
- Target-device enable, LTE fallback, reboot, disable, crash-recovery, timeout, uninstall, and downgrade acceptance.
