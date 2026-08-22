# Automatic n78 Preference Maintenance

## Scope

This is an opt-in n78 preference maintenance mode, not a guaranteed band lock. The serving-cell sampler observes actual serving RAT and band. The policy controller owns any active-band write. The two modules do not infer one domain from the other.

## Domains

- `PolicyIntent`: the portable user intent, such as preferring n78.
- `DeviceTransactionBaseline`: non-portable rollback evidence for the device and SIM transaction that changed modem configuration.
- `ServingEvidence`: fresh Cell Monitor evidence of the actual serving RAT and band.
- `CorrectionAttempt`: one bounded write and complete read-back verification.
- `RecoveryRequired`: fail-closed state after an uncertain setter, identity drift, capability drift, or invalid read-back.

## Correction contract

1. Require two consecutive clean serving samples that identify the same non-target RAT+band before classifying a drop.
2. Unknown, stale, incomplete, conflicting, or retrying samples never trigger a write.
3. Re-read the current device identity (`hw.machine`, product version, build), the exact slot-1 SIM UUID, current supported bands, current active bands, policy state, and shared modem lock before a correction.
4. Require `getBandInfo:error:` to pass its runtime ABI check, require the exact supported RAT key shape, require n78 in the current supported NR set, and require the current active policy NR set to be exactly `[78]`.
5. Permit at most one correction attempt for a confirmed drop. A failed or uncertain attempt stops automatic maintenance.
6. After a successful setter, wait for a bounded read-only verification window. Do not issue another setter from that window.
7. Use the existing late-callback unsafe latch and cross-process lock. A timeout or exception forbids a second same-boot write.
8. Preserve the first `DeviceTransactionBaseline` for the entire policy lifetime. Correction attempts append evidence and never replace that baseline.
9. If the device, system build, SIM identity, supported RAT shape, or owned-band set changes, do not replay the old payload. Recompute policy from portable intent or require manual recovery.

## Backup contract

A transaction baseline is not a portable backup. New baselines retain device model, system version/build, complete supported-band evidence, and `modifiedBandKeys`. Restore requires the same hardware model and NR bands the current modem still declares; a baseline written before that evidence existed is still restorable, but only when its saved NR bands pass the same capability check. A portable migration record may carry policy intent and profile identity, but never raw modem BandInfo.

## Current implementation checkpoint

- Responsive serving-cell sampling is already shared by the stable provider and isolated LiveCC namespace.
- The stable package still has no automatic correction trigger.
- Capability-bound transaction baseline metadata and restore compatibility checking are implemented.
- `CCNMAutomaticMaintenanceDecision` is a pure C decision layer compiled into both the Control Center and settings bundles. It requires two matching clean samples, permits one correction decision, and blocks on unsafe, incompatible, busy, cooldown, verification-pending, or exhausted states.
- The read-only daemon now refreshes the live capability snapshot through the existing serving provider. It records the exact subscription UUID, supported/active NR arrays, supported RAT key shape, and n78 presence in the maintenance record and status plist.
- A policy-scoped root launchd job owns automatic observation. Its single `KeepAlive/PathState` condition uses the same jailbroken-root baseline path as the policy reader. The shell `postinst` hands the live jailbreak root to the guards and bootstraps the job after safe guard cleanup; `prerm` stops it before restore; baseline retirement makes the already-running daemon exit. Registration failure warns rather than failing the install, because band policy changes do not need the daemon. It does not promise a boot-time retry: nothing in the jailbreak loads this directory at startup and a re-jailbreak relocates the tree to a new jailbreak root, so reinstalling the package is the retry.
- `capabilityCompatible` is fail-closed: it requires a successful BandInfo read, n78 in the supported set, the exact active NR set `[78]`, a baseline with capability evidence, matching device/system/SIM identity, matching RAT shape, and retention of every baseline-owned supported NR band.
- `CorrectOnce` is still not connected to a setter call. The daemon only persists evidence and evaluates the pure decision layer.
- Carrier profiles and multi-device writes remain read-only design work until device/SIM/profile evidence is collected.

## Explicit non-goals

- No claim of continuous n78 service.
- No periodic blind re-write loop.
- No RAT-selection write without a verified read-back contract.
- No restoration of a baseline from another device, SIM, or incompatible system.
