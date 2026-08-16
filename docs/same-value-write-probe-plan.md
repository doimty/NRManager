# iOS 15 Band write probes

Target: iPhone14,3, iOS 15.1.1 (19B81), rootHide/arm64e, physical SIM in slot 1.

## Stage 1 result (device-confirmed 2026-08-16)

The same-value write completed with `passed=true`: the setter returned no error in 5.5 ms, the immediate read-back equalled the original six-technology dictionary, the automatic restore verified, and an independent post-relaunch manual restore also verified against the durable write-intent record. The watchdog never fired.

This proved write authorization and setter ABI. It did not prove that a changed set is actually applied, because request and prior value were identical.

A second device fact from the read-only probe: `activeBands` is a permissive allowed set, not the hardware capability set. Slot 1 reported 41 LTE entries in `activeBands` against 26 in `supportedBands`, and 6 TDSCDMA entries against an empty supported list. Any future band-limiting feature must intersect with `supportedBands`.

## Stage 2 question

Does a *changed* active-band dictionary actually take effect, or does CommCenter silently ignore the write?

## Stage 2 hypothesis

Writing the original slot-1 dictionary minus exactly one cold LTE band will read back with that band absent. The independent failure signal is a read-back that still equals the original set: setter success with no state change means the write is advisory only.

## Why this specific band

The removal target is LTE band 48 (US CBRS, 3.55-3.7 GHz), falling back to LTE band 46 (unlicensed LAA) when 48 is not present. Neither can carry a primary registration on this network: band 48 is a US-only shared-spectrum allocation, and band 46 is LAA, usable only as a secondary carrier-aggregation leg. Removing one of them cannot drop service even if every recovery path fails. Band 3/8/41 style primary bands are never touched.

NR band 48 is a different key and is explicitly left byte-identical; only the LTE key changes.

## Stage 2 success

- Device, slot, UUID, ABI, snapshot, and pre-write equality gates all pass as in stage 1.
- The payload is validated to be exactly the original LTE list minus one allowed cold band, with every other technology array byte-identical. Candidate selection requires the band to be present in both the freshly read `activeBands` and `supportedBands` LTE arrays, and both dictionaries must still match on the final pre-write reread.
- The setter returns no error.
- The immediate read-back either equals the request (`effectApplied=true`, the write is real) or equals the original set (`effectApplied=false`, the write is advisory). Both are informative outcomes; neither is a crash.
- The original snapshot is restored and read back equal.

## Stage 2 independent failure signals

- Read-back matches neither the request nor the original snapshot: partial or unexpected modem state, reported as a failure with a full per-technology difference dump.
- No allowed cold band is currently active, so no write is attempted.
- Any device/slot/UUID/ABI/snapshot/payload gate rejects before the setter.
- The restore errors or does not read back exactly.

## Guardrails

- No user-selected Band numbers exist in this build. The only writable change is removing one hard-coded cold LTE band from the live set.
- Slot 2 is never written; the build is fail-closed on any device/build other than the confirmed `iPhone14,3 / 15.1.1 / 19B81` target.
- The existing Control Center RAT path remains untouched.
- The setter is synchronous. A 20-second in-process watchdog therefore never issues a concurrent restore. It only marks the operation state uncertain, records `requiresDeviceReboot=true` in a separate timeout plist, and stops all further writes in the current boot session. This replaces the earlier watchdog-restore design, which could have produced two overlapping setter calls against the same subscription.
- Recovery after a timeout is gated on a device reboot, not on restarting Preferences. A durable setter-in-flight marker binds the process id, the kernel boot time, the operation generation, the slot, the subscription UUID, and the snapshot/write-intent timestamps. While that marker belongs to the same boot, both Restore Saved Band Snapshot and Clear Saved Probe State refuse to act, so relaunching Preferences cannot bypass the ban. After a reboot the marker's boot time no longer matches, and manual restore is allowed.
- Every setter path and both cleanup paths take an exclusive cross-process `flock` on a dedicated recovery lock file. A second Preferences instance cannot restore or clear while the first still owns the lock.
- Manual restore requires a valid marker: no marker means no crash or timeout write is outstanding, so no recovery setter is authorized. It also rereads live bands first and skips the setter entirely when live already equals the snapshot.
- The recovery snapshot, the write-intent record, and the setter-in-flight marker are created with `O_EXCL`, durably synced, read back, and never overwritten. A second experiment is refused while any of them exists. The intent repeats the snapshot UUID, creation time, and complete active-band dictionary; removal intents additionally bind the complete supported-band dictionary, the removed band, and the full requested dictionary, which is regenerated and revalidated against the snapshot.
- The marker is only deleted after a verified restore. On the normal path that means the automatic restore read back exactly equal; on the recovery path it means the manual restore read back exactly equal. Any unverified outcome preserves the snapshot, the intent, and the marker.
- Cleanup order is snapshot, then intent, then marker. An interrupted cleanup therefore fails closed: the leftover files cannot authorize a restore on their own.
- Clear Saved Probe State is the supported way to remove those records. It refuses unless live slot-1 active bands already equal the snapshot, refuses while a same-boot marker exists, and never calls the setter. Reinstalling the package does not delete them, because they live in the user preferences domain.
- The snapshot records slot 1's subscription UUID, and all restore paths refuse a changed UUID.
- `CTBandInfo.activeBands` must exactly equal the intended dictionary before any setter runs: the deep-copied original for same-value and restore writes, and the validated single-removal dictionary for the removal write.
- CoreTelephony Objective-C exceptions are converted to structured failures, and locks plus in-process flags are released on every exit path. A crash between setter and restore remains a residual risk because this probe has no independent daemon; the durable marker exists precisely so that post-reboot recovery is still possible.
- Residual risk that cannot be removed in this design: if the synchronous recovery setter itself hangs forever, this build will not force a second concurrent write. The trade-off is deliberate. Concurrent writes to the same subscription are considered more dangerous than a stuck recovery attempt, which a reboot clears.
- Unlike stage 1, the stage 2 request differs from the prior value, so a crash before restore can leave one cold LTE band disabled until the post-reboot manual restore runs. Because that band cannot carry a primary registration, the expected worst case is no observable service change.
- Device testing must not be performed while this phone is the only available emergency-communication device.
