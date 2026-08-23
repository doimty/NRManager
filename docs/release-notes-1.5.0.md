# NetworkManagerReborn 1.5.0 release notes

Status: release candidate source, not yet approved for distribution.

## Product changes

- Replaced local Control Center RAT cycling with a single reversible n78 preference.
- Enabling changes only the NR allowed-band array to exact `[78]`; all non-NR arrays, including LTE, remain unchanged.
- Added separate requested-policy, verified-applied-policy, and fresh serving-network states.
- Added adaptive Cell Monitor sampling for truthful NR n78, other NR, LTE, other, or stale/unknown serving status.
- Added an independently implemented, localized Simplified Chinese and English Settings interface.
- Kept the formal Live Band Control Center button, disabled its redundant long-press expansion, and restored the original orange selected glyph when n78 preference is enabled.
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

The first end-to-end acceptance target was:

- iPhone14,3
- iOS 15.1.1 (19B81)
- exactly one present and good SIM in slot 1

The write path no longer requires slot 1, and no longer requires that only one SIM be in the phone. It binds a modem write to one subscription identified by UUID plus slot, and it must be able to find that same subscription again on every later verification and restore. Where the target comes from depends on what is already recorded:

- A first enable on a phone holding one SIM uses that SIM.
- A first enable on a dual-SIM phone uses the line CoreTelephony itself reports as the current data line. If that query is unavailable, errors, or names a line that cannot take a write, the enable is refused rather than resolved by a guess.
- Every later verification, restore, and recovery looks up the recorded identity and never re-chooses. The data line moves at runtime, so consulting it there would abandon the subscription the policy was actually written to as soon as iOS switched lines.

Refusals report the observed layout per slot, and name whether a recorded SIM moved slots, was replaced, or is absent. A UUID is only ever reported as present or absent, never printed. Reading the serving cell carries no such restriction and works with two SIMs present.

On a dual-SIM phone the preference stays bound to the line it was enabled on. If iOS later moves the data line to the other SIM, the preference remains on the original one, where it has no effect until the data line moves back; disable and restore continue to work. Removing or replacing that SIM leaves the recorded baseline unrestorable until it is put back.

The model and OS identity are now recorded baseline evidence, not a compatibility allowlist. Enable and restore accept any device/build that passes the runtime contract: the private CoreTelephony ABI is valid, the target subscription resolves unambiguously in a positive slot by the rules above, complete fresh active/supported BandInfo is readable, and n78 exists in both NR sets. The payload changes only NR; LTE and all other RAT arrays remain unchanged. Restore additionally requires the same hardware model, capability shape, and owned NR capability evidence. The saved active NR list is replayed exactly and is not required to be a subset of the current supported NR list, because the device's BandInfo contract permits that shape; an iOS update alone does not block a rollback.

The dedicated known-orphan recovery remains stricter: it requires an exact match of the reviewed six-RAT active and supported dictionaries, subscription identity, clean durable state, and a phone holding a single SIM, because its reviewed evidence was captured on a single-SIM reference device. It is not a general fallback for arbitrary phones.

This feature is an n78 preference, not a guarantee of continuous 5G or n78 service. LTE fallback is expected and is not reported as policy failure.

## Remaining release gates

- Independent source/spec/safety review with no unresolved P0 or P1 findings.
- Pinned macOS 14 / Xcode 15.4 rootless and roothide cloud builds.
- Mach-O, dependency, signature, package-control, warning, and checksum verification for both bundles, both policy guards, and the maintenance helper in each lane, plus the shell-shape gate on `DEBIAN/postinst` and `DEBIAN/prerm` and a per-lane gate on the staged launchd plist.
- Target-device enable, LTE fallback, reboot, disable, crash-recovery, timeout, uninstall, and downgrade acceptance.
