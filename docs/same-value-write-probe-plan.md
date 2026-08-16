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
- An in-process 20-second watchdog creates a fresh CoreTelephony client and fresh slot-1 subscription context before attempting the same snapshot restore. Its telemetry is written to a separate plist so it cannot race the main result dictionary. A synchronized restore-claim flag prevents the watchdog and the normal completion path from both restoring.
- A separate Restore Saved Band Snapshot button is available after app relaunch and uses an independent manual-restore lock. It refuses to overlap the first 20 seconds of a live test, a test setter, or an automatic restore, but remains available after that watchdog window even if one of those synchronous operations is stuck. Starting manual recovery invalidates any not-yet-invoked test setter, so a delayed preflight cannot resume and write after recovery. It writes telemetry to a separate manual-restore plist. Pressing it after the window while a setter or automatic restore is visibly hung can still create one intentional concurrent request; the button is an explicit emergency recovery action.
- The recovery snapshot and its matching write-intent record are created with `O_EXCL`, durably synced, read back, and never overwritten. A second experiment is refused while either file exists. The intent repeats the snapshot UUID, creation time, and complete active-band dictionary; removal intents additionally bind the complete supported-band dictionary, the removed band, and the full requested dictionary, which is regenerated and revalidated against the snapshot. Manual restore refuses to call the setter unless both records match. Therefore a normal failure before write-intent creation cannot produce a later write through the manual-restore path.
- Clear Saved Probe State is the supported way to remove those records. It refuses unless the live slot-1 active bands already equal the snapshot, so the recovery records can only be deleted once they are provably unnecessary. It never calls the setter. Reinstalling the package does not delete them, because they live in the user preferences domain.
- The snapshot records slot 1's subscription UUID, and all restore paths refuse a changed UUID.
- `CTBandInfo.activeBands` must exactly equal the intended dictionary before any setter runs: the deep-copied original for same-value and restore writes, and the validated single-removal dictionary for the removal write.
- CoreTelephony Objective-C exceptions are converted to structured failures, and the test/recovery operation locks are released after an exception. A crash between setter and restore remains a residual risk because this probe has no independent daemon. The watchdog is in-process and cannot survive a Preferences process crash. A crash in the tiny interval after durable write-intent creation but before the setter enters can make a later manual restore perform an unnecessary write of the original set; this is the unavoidable fail-safe side of preserving post-crash recovery.
- Unlike stage 1, the stage 2 request differs from the prior value, so a crash before restore can leave one cold LTE band disabled until the manual restore runs. Because that band cannot carry a primary registration, the expected worst case is no observable service change.
- Device testing must not be performed while this phone is the only available emergency-communication device.
