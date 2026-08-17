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
- Compiled `prerm` and `postinst` guards restore before removal, upgrade, or downgrade and close the post-`prerm` race with a durable removal marker.
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
- Mach-O, dependency, signature, package-control, warning, and checksum verification for both bundles and both maintainer binaries in each lane.
- Target-device enable, LTE fallback, reboot, disable, crash-recovery, timeout, uninstall, and downgrade acceptance.
