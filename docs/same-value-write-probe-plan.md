# iOS 15 same-value Band write probe

Target: iPhone14,3, iOS 15.1.1 (19B81), rootHide/arm64e, physical SIM in slot 1.

## Question

Does the NetworkManager preference bundle have authorization to invoke `CoreTelephonyClient -setActiveBandInfo:bands:error:` on slot 1, and does the call round-trip through CommCenter without changing the requested active-band dictionary?

## Hypothesis

Passing a `CTBandInfo` initialized from the exact dictionary just returned by `getBandInfo:error:` will be accepted and read back unchanged. This tests write authorization and object/selector ABI only. It does not prove that a reduced set becomes an enforced modem lock.

## Success

- The runtime target matches `iPhone14,3 / iOS 15.1.1 / 19B81`, exactly one present/good context exists for slot 1, and its subscription UUID remains stable through restore.
- A complete original active-band snapshot is durably written before the setter.
- After all pre-write checks pass, a matching write-intent record is durably written immediately before the setter.
- `setActiveBandInfo:bands:error:` returns no `NSError`.
- Immediate `getBandInfo:error:` returns an active-band dictionary equal to the original snapshot.
- The original snapshot is written once more and the final read-back is equal.
- A structured result plist captures every phase.

## Independent failure signals

- Slot 1 is absent/unhealthy or another present SIM is detected.
- A required class/selector is missing.
- Snapshot or write-intent persistence/validation fails.
- The setter returns an error.
- Read-back differs from the original snapshot.
- The final restore errors or does not read back exactly.

## Guardrails

- No user-selected or hard-coded Band numbers exist in this build.
- No active-band key/value is removed or changed.
- Slot 2 is never written; the build is fail-closed on any device/build other than the confirmed `iPhone14,3 / 15.1.1 / 19B81` target.
- The existing Control Center RAT path remains untouched.
- An in-process 20-second watchdog creates a fresh CoreTelephony client and fresh slot-1 subscription context before attempting the same snapshot restore. Its telemetry is written to a separate plist so it cannot race the main result dictionary. A synchronized restore-claim flag prevents the watchdog and the normal completion path from both restoring.
- A separate Restore Saved Band Snapshot button is available after app relaunch and uses an independent manual-restore lock. It refuses to overlap the first 20 seconds of a live test, a test setter, or an automatic restore, but remains available after that watchdog window even if one of those synchronous operations is stuck. Starting manual recovery invalidates any not-yet-invoked test setter, so a delayed preflight cannot resume and write after recovery. It writes telemetry to a separate manual-restore plist. Pressing it after the window while a setter or automatic restore is visibly hung can still create one intentional concurrent same-value request; the button is an explicit emergency recovery action.
- The recovery snapshot and its matching write-intent record are created with `O_EXCL`, durably synced, read back, and never overwritten. A second test is refused while either file exists. The intent repeats the snapshot UUID, creation time, and complete active-band dictionary, and manual restore refuses to call the setter unless both records match. Therefore a normal failure before write-intent creation cannot produce a later write through the manual-restore path.
- The snapshot records slot 1's subscription UUID, and all restore paths refuse a changed UUID.
- `CTBandInfo.activeBands` must exactly equal the deep-copied source dictionary before either the test write or a restore setter can run.
- CoreTelephony Objective-C exceptions are converted to structured failures, and the test/recovery operation locks are released after an exception. A crash between setter and restore remains a residual risk because this probe has no independent daemon. The watchdog is in-process and cannot survive a Preferences process crash. A crash in the tiny interval after durable write-intent creation but before the setter enters can make a later manual restore perform an unnecessary same-value write; this is the unavoidable fail-safe side of preserving post-crash recovery. The write value equals the prior value, which bounds but does not eliminate modem-side side effects such as a short re-registration.
- Initial device testing must not be performed while this phone is the only available emergency-communication device.
