# LTE B1 serving-switch diagnostic plan

**Date:** 2026-08-17
**Branch:** `diagnostic/lte-b1-lock-ios15`
**Baseline:** `272b1ae56b919de53bad723ff81b62e1deb6b972`
**Target:** iPhone14,3 / iOS 15.1.1 (19B81), slot 1, exactly one present and good SIM

## Scope boundary

This single-purpose package intentionally replaces the completed n78 write action in Settings with the LTE B1 action. It does not expose both destructive experiments at once. The proven n78 payload helpers and legacy `nr78_only` recovery validators remain in place so an existing n78 recovery record is still accepted by manual restore and clear-state paths.

## Question

When the target is explicitly operating on LTE and Cell Monitor reports a stable LTE B3 serving cell, does replacing only the LTE allowed-band array with exact `[1]` make the modem actually serve on LTE B1 before the original six-RAT snapshot is restored?

This experiment distinguishes three facts that must not be conflated:

1. the requested LTE allowed-band dictionary,
2. the modem's `getBandInfo:` read-back,
3. the Cell Monitor serving entry.

## Fresh device evidence

The schema-v4 target report with SHA256 `ee7b1353eca0b142424eba549307781fb1a845c250d8b4d533b7fbb2d10e57e3` shows LTE B1 in both live lists:

- active LTE bands include `1` and `3`,
- supported LTE bands include `1` and `3`.

That report was captured while serving on NR n78. It proves B1 is eligible for a guarded payload but does not satisfy this experiment's LTE B3 precondition. The user must first select LTE in Control Center and the probe must independently observe LTE B3 before any write.

## Hypothesis

With RAT already on LTE and the full active-band dictionary changed only by replacing `kCTRegistrationRadioAccessTechnologyLTE` with exact `[1]`, the modem will expose the exact request through `getBandInfo:` and Cell Monitor will subsequently return at least two trailing consecutive serving entries with exact LTE RAT and Band 1.

## Success criteria

- Exact target device, OS/build, slot and single-SIM guards pass.
- Fresh active and supported LTE arrays both contain B1.
- A complete pre-write full-window Cell Monitor sample run ends with at least two consecutive exact LTE B3 serving samples; each counted sample contains LTE serving evidence and every LTE serving entry in that sample is B3.
- No recovery record exists and no private async attempt remains outstanding before the setter.
- Snapshot, write intent and setter-in-flight marker are exclusively and durably saved and bound to UUID, slot, boot, operation generation and exact dictionaries.
- The generated payload has the same six RAT keys; LTE is exactly `[1]`; every non-LTE array is byte-identical to the fresh original.
- A final pre-write active/supported reread still equals the snapshot.
- `CTBandInfo` preserves the exact payload before the setter.
- The setter returns normally within 20 seconds without error.
- Bounded read-back returns the exact B1 request.
- A complete post-write full-window Cell Monitor sample run ends with at least two consecutive exact LTE B1 serving samples; each counted sample contains LTE serving evidence and every LTE serving entry in that sample is B1. A simultaneous competing LTE band invalidates the sample, while NR coexistence does not.
- The original complete active-band dictionary is restored and verified by bounded read-back.
- After exact automatic restore read-back, snapshot, intent, setter-in-flight marker and restore-in-flight marker are all removed before the result can pass.
- A failure before the setter call removes only the exact recovery records created by that attempt, while the same exclusive lock is still held. Changed or foreign records are preserved and reported as a cleanup failure.
- Result evidence records `transactionCompletedSafely=true`, `b1ServingConfirmed=true`, and `recoveryPending=false` only after verified restoration and complete recovery-record cleanup.

## Independent failure signals

These are not merely the inverse of success:

- Pre-write Cell Monitor does not end on two exact LTE B3 samples. No setter is authorized.
- B1 is absent from either fresh active or supported LTE bands. No setter is authorized.
- The setter is ignored and read-back remains exactly original. Record a determinate no-effect outcome and restore/verify the snapshot.
- Read-back matches neither request nor original before its deadline. Preserve evidence and attempt restoration only if setter return is provably safe.
- Post-write Cell Monitor completes but does not end on two exact LTE B1 samples. This disproves serving-switch confirmation even if allowed-band read-back is `[1]`; restore normally.
- Post-write Cell Monitor is incomplete for any reason, including callback/API failure, parse failure, timeout, or invocation exception. Do not issue an automatic restore in the same boot. Preserve all recovery files, require a full reboot, then use the existing manual snapshot restore. A timeout or invocation exception additionally leaves the private async call fail-closed until its late callback resolves or the device reboots.
- Setter timeout, over-deadline return or exception. Do not issue a same-boot restore; require reboot and manual restore.
- Restore setter timeout, exception or mismatched read-back. Preserve recovery evidence and require reboot/manual recovery.
- Process death during the write/observation transaction leaves durable recovery records. It must never silently clear them.

## Ablation expectations

- **Payload-only read-back, no Cell Monitor:** may prove `[1]` was accepted but cannot prove serving B1. This is insufficient for the hypothesis.
- **Cell Monitor without forcing LTE first:** may observe NR fallback and cannot isolate LTE B1 behavior. The write must be blocked unless the pre-window ends on LTE B3.
- **Change LTE plus another RAT array:** destroys attribution and must fail payload validation before the setter.
- **Choose B1 from supported bands only:** could add a carrier-disallowed band. B1 must exist in both the fresh active and supported arrays.
- **Restore after an unresolved async timeout:** risks overlapping private telephony calls. Same-boot restore must be blocked in that state.

## Implementation shape

- Add exact B1 payload builder and validator beside the proven n78 helpers.
- Extend write-intent and in-flight operation validators for `lte_b1_only` only.
- Add a full-window sampler policy plus a helper that evaluates trailing consecutive exact RAT/Band samples without treating allowed-band state or coarse RAT state as serving evidence. The existing read-only and n78 paths retain their early-NR policy.
- Add one explicit destructive-confirmation Settings action and one result plist.
- Reuse the existing recovery lock, snapshot, intent, setter/restore markers, setter watchdog, bounded band read-back, automatic restore and post-reboot manual restore.
- Remove all B1 recovery records only after verified restoration. If the setter was definitely never called, remove only this attempt's exact records before releasing the lock.
- Keep the experiment target-only and diagnostic. Do not add a production Band picker.

## Evidence plan

1. Add executable payload-model tests for exact LTE `[1]` and non-LTE identity.
2. Add executable/report-model tests for trailing B3/B1 confirmation semantics.
3. Extend static recovery tests to cover the fourth changed-value operation and all setter call sites.
4. Run focused tests, then the complete host suite and `git diff --check`.
5. Run local rootless/roothide compile smoke checks only; do not deliver local arm64e output.
6. Commit and push the new diagnostic branch.
7. Trigger the pinned macOS 14 / Xcode 15.4 / iPhoneOS 17.5 cloud build.
8. Verify nonempty logs, exact commit, zero compiler/linker errors, zero `incompatible arm64e`, package metadata, arm64+arm64e slices, minimum OS, load commands and roothide dependencies.
9. Deliver only the verified cloud roothide package.
10. On-device, select LTE first, run the B1 experiment once, and return the result plist. Verify the full transaction and actual serving evidence before making a product claim.
