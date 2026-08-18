# 1.5.0 implementation progress

Baseline: `2947f98ffb2665b000afab2c4db3ae843866d4da`
Branch: `fix/settings-ios15-table-getter`
Target: iPhone14,3 / iOS 15.1.1 (19B81), slot 1, one present and good SIM

## Completed in working tree

- Formal n78 policy state model with exact six-RAT validation, durable baseline, intent/in-flight records, UUID/SIM checks, cross-process flock, bounded setter wait, late-setter lock retention, full read-back, and reboot-required uncertainty.
- All four shipped Mach-O targets use iOS 14.0 minimum; package verification requires both arm64 and arm64e slices to report minOS 14.0.
- Truthful serving-cell provider backed by the reviewed adaptive Cell Monitor sampler, with NR-ARFCN-to-frequency conversion, LTE fallback classification, freshness expiry, and a shared modem lock.
- Control Center short-tap behavior now reads shared policy state and calls formal enable/disable; legacy RAT cycling and `selectedNetwork` persistence are removed. Darwin policy-change notifications refresh a tile living in another process, with a local pending icon state.
- Independently implemented Auto Layout Settings cells, English/Simplified Chinese localization, compact header, policy/applied/serving/recovery rows, repository links, and recovery confirmation.
- Compiled `prerm` and `postinst` maintainer guards. `prerm` restores and verifies before remove/upgrade/downgrade, then arms a durable removal guard that closes the post-script enable race. `postinst` clears it only after a safe state check.
- Release source, package, build-log, Mach-O, maintainer-script, and forbidden-string verifier updates.

## Evidence in this checkpoint

- `python3 -m unittest discover -v tests`: 61/61 passed.
- `python3 -m py_compile scripts/*.py`: passed.
- `python3 scripts/verify_release_source.py --repo .`: passed.
- First cloud run `32052865548`: host gates passed; both package lanes stopped before build because `ld -version_details` now emits JSON (`"version": "1053.12"`). Workflow matching now accepts the pinned JSON form while retaining legacy output compatibility.
- Second cloud run `32053525066`: host gates, pinned Xcode/SDK/dependencies, and both package builds passed. Final source re-verification incorrectly traversed the newly cloned `theos/` dependency and rejected its template plist placeholders. The verifier now excludes the external dependency tree.
- Third cloud run `32054864964`: host gates and both package builds passed. Raw Mach-O evidence proved roothide uses the required `LC_DYLD_INFO_ONLY`, no chained fixups, exact minOS 14.0/SDK 17.5, and ldid-readable signatures. Verifier false positives came from lane-crossed rootless fixup rules, whitespace-sensitive arm64e header parsing, treating ldid as Apple CodeSign, and the formal Settings bundle's intentional public CoreGraphics dependency. Those rules are now lane-aware and evidence-backed.
- Artifact downloads from run `32055654251` independently confirmed both verification reports passed, but exposed two evidence-format defects: SHA256SUMS used the wrong package-relative path, and provenance recorded only `{` for ld. Both generation paths now use the package subdirectory and extract/record exact ld 1053.12; rerun pending.
- Local rootless and roothide packages compiled and passed Linux structural verification: 13-file payloads, 5 parsed plists, compiled `postinst` + `prerm`, zero legacy social assets, zero forbidden strings. These are compile/package evidence only, not deliverables. The build-log gate correctly rejects all local incompatible-arm64e warnings; local roothide also uses the non-accepted local SDK/linker dependency shape, so only the pinned cloud lane can satisfy Mach-O acceptance.

## Review result

- Independent spec/safety review found no P0 and identified bounded-readback/CC pending-state improvements; those were implemented. Two proposed changes were rejected with rationale because they would weaken the shared modem interlock or invalidate legitimate post-restore crash cleanup.
- Independent standards review found three P1 issues: arm64e minOS drift, `prerm` exiting while a timed-out setter retained the lock, and an incorrect maintainer-script mode range check. All were fixed and the same reviewer confirmed no P0/P1 remained. Its final P2 exact-minOS gate was also fixed.

## Target Settings crash diagnosis and fix

- The first roothide RC crashed immediately when opening its Settings page. Device report `Preferences-2026-08-18-074050`, SHA256 `dc2411ddf2ffedf98f66e7fb7ce75dc4a0ecd7411775dff31348c61138737196`, is an uncaught Objective-C `doesNotRecognizeSelector:` exception on the main thread.
- Exact arm64e symbolization of package SHA256 `7d4b38de36f78ba1bf1ccdd90fa790fe0aa997b2046165d01994e68b3cf276d0` maps the four package frames to `viewDidLoad + 0x74`, `refreshPolicyState + 0x30`, `applyPolicySummary: + 0x2d4`, and `rebuildRecoverySection + 0x38c`.
- The failing call is the final `self.tableView` getter in `rebuildRecoverySection`. The iOS 15.1.1 `PSListController` runtime exposes `table`, not `tableView`; the newer Theos header incorrectly made the unavailable getter compile. The controller now reloads through `[self.table reloadData]`.
- Specifier loading also takes a defensive `mutableCopy` before removing hidden recovery rows, so runtime array mutability is no longer assumed.
- A dedicated iOS 15 compatibility regression failed before the getter fix and passes after it. Full host suite is now 62/62; Python compile, source verifier, and `git diff --check` pass. Local rootless and roothide compile smoke checks pass, but local arm64e warnings remain non-deliverable.

## Control Center real-time refresh fix

- Device testing showed that the new CC tile could write policy state but did not always refresh its selected state immediately. The formal module was calling the private/legacy `reconfigureView` path, while the target `CCUIToggleModule` contract exposes `refreshState` as the public switch-state refresh API.
- The CC Darwin-notification callback, blocked-operation paths, setter completion, and immediate post-request path now call `refreshState`; the obsolete `reconfigureView` category declaration was removed. A static regression failed before the change and passes after it.
- Full host suite is now 63/63; source verifier, Python compile, and `git diff --check` pass. Cloud/device retest is still required.

## Control Center glyph state fix

- Device testing found a second UI defect: the CC glyph was hardcoded to `n78`, so it still displayed n78 after the policy was disabled and the device was serving LTE B3.
- `iconGlyph` now derives the label from requested policy: `n78` when n78 is requested, `Auto` when system default is requested, and matching `...`/`!` forms during transition or recovery. A pending target property keeps the transition glyph truthful before the durable state write completes.
- Full host suite is now 64/64; source verifier, Python compile, and `git diff --check` pass. Cloud/device retest is still required.

## Known-device orphaned n78 one-time recovery

- Target device returned a reviewed post-B1 plist (`me.nixuge.networkmanager.bandwrite.lte-b1---85c15892-4f2f-4c28-a44f-09d5f1ff8ec4.xml`, SHA256 `9e6230dfae679537b5b827518975e7675abf864cd403e96f97f11de63316ac76`) whose live active NR array is exactly `[78]` while the durable n78 policy state is clean `systemDefault` with no baseline, intent, in-flight, or removal guard. The modem is orphaned: the package cannot restore it through the normal recovery path because that path requires policy evidence that does not exist.
- Added a dedicated one-time recovery instead of a general import channel. Fixed compiled-in evidence identity only: SHA256 of the reviewed plist, target `iPhone14,3`/`15.1.1`/`19B81`, target UUID `00000000-0000-0000-0000-000000000001`, the exact six-key historical `originalActiveBands`, the orphan live dict (same with NR `[78]`), and the exact six-key historical `supportedBandsAtSelection`. No plist is read at runtime; no arbitrary snapshot import exists.
- Read-only eligibility API `CCNMReadKnownOrphanedN78RecoveryEligibility()` and dedicated `CCNMRecoverKnownOrphanedN78WithCompletion`. Eligibility rechecks the target, exactly one present/good SIM in slot 1 with the fixed UUID, absent-or-exact-clean durable state, no records, exact live active (orphan shape, all five non-NR arrays ordered-equal historical), and exact live supported dictionary.
- `performKnownOrphanedN78Recovery` runs inside one held policy lock: eligibility recheck, historical baseline creation (with `recoverySource`/`evidenceSHA256`), adoption of a stable `verifiedN78Only`/`enabledWithBaseline` state with normal proof fields plus provenance, then the existing restore core. The restore core was refactored to accept an already-held lock descriptor (`int *`) plus an `requireKnownOrphanFinalGuard` flag; no lock is released between adoption and setter, and a timed-out setter still transfers that same descriptor to the late-return latch. Immediately before the setter the complete historical predicate is rerun and any drift fails closed without a modem write.
- Crash safety: every durable checkpoint (baseline, adopted state, intent, pending, in-flight) is fail-closed for ordinary enable/disable; the existing reboot recovery path still restores from the durable baseline and now carries the same provenance into the final clean state. Success leaves only a clean state with recovery provenance; the eligibility probe rejects it, so the action is one-time.
- Settings: a separate hidden `PSButtonCell` group appears only after the eligibility probe succeeds, gated by a destructive confirmation alert; it never routes through the ordinary toggle or Control Center. Probe generations prevent stale asynchronous results from changing visibility. `prerm` now probes the live orphan condition before accepting even an existing removal guard. Eligible orphans are blocked until the user confirms recovery in Settings; inconclusive probes also block removal. The maintainer script never invokes the one-time modem write automatically.
- Evidence: new focused model/static suite `tests/test_known_orphaned_n78_recovery.py` (22 tests: exact eligibility, one-field rejections for identity/SIM/live/supported/durable, tracked sanitized evidence fixture, absent-or-clean state, lock continuity, provenance-bound resume guards, final-guard drift without setter, crash checkpoints, timeout lock transfer, read-back mismatch, UI visibility/confirmation, prerm ordering, and no arbitrary import). Full host suite is now 87/87; `py_compile`, release-source verifier, and `git diff --check` pass. Local rootless compile/package smoke passed (only the known local arm64e ABI warning, non-deliverable).
- Final source branch/commit: `recovery/known-orphaned-n78-20260818`, `52d1d05f478385df7fbc12f72f0b912d9a05f30f`. Final independent review found no unresolved P0/P1/P2.
- Pinned cloud run `32106118565` passed host/rootless/roothide jobs with Xcode 15.4 (`15F31d`), clang 15.0.0, ld 1053.12, and system SDK 17.5. Logs contain no compiler/linker/fatal or incompatible-arm64e diagnostics. Delivered roothide package SHA256 `672b6e6a8c9b284dab35bebfcb28d388ef8a2d151d622e34429c1b283fd85697`; both product binaries are arm64+arm64e, minOS 14.0, SDK 17.5, and `LC_DYLD_INFO_ONLY`; maintainer scripts are mode 755 and self-contained.
- Target device completed the confirmation-gated recovery. The accepted screenshot shows requested `systemDefault`, applied `verifiedSystemDefault`, serving LTE B3, and no one-time recovery section. Exact full BandInfo read-back and verified cleanup therefore completed; the one-time action is retired.

## Control Center live serving-band label

- On-device CC inspection after recovery still showed the policy name `Auto` instead of the true serving band because `iconGlyph` only read policy state and never the serving summary.
- Root causes: CC bundle Makefile did not compile `CCNMServingStatusProvider.m`/`CCNMServingCellSampler.m`, and the module had no async refresh lifecycle.
- `CCNetworkManager.x` now imports the provider, keeps a per-module `servingSummary`/`servingRefreshInProgress`/cooldown, and requests a bounded async Cell-Monitor refresh on first draw. Policy transitions/recovery/outstanding-setter still show `n78…/Auto…/!` and block refresh; stable fresh LTE shows `B3`, fresh NR shows `n78`/`n79`, loading shows `...`, unknown/stale shows `?`. `selectedColor`/`isSelected` remain policy truth. The refresh path never writes the modem and shares the policy lock.
- New focused suite `tests/test_control_center_serving_label.py` (5 tests) went red before the fix and green after; old glyph contract was updated for the new stable-state text.
- First CC package upgrade was safely blocked before unpack: both old and fallback new `prerm` received `Permission denied` from the CoreTelephony live probe in dpkg context and exited 73. No product or modem state changed. A separately approved SHA-bound hotfix atomically replaced the installed `prerm` and preserved its backup; an active removal guard was then cleared successfully through the installed `postinst configure` safety path.
- The next upgrade still blocked because the actual verified clean state predates final provenance persistence: it has exact `systemDefault`/`verifiedSystemDefault`/`clean`, slot UUID `000...001`, `verifiedAt`, `restoredBaselineCreatedAt`, and the complete exact historical six-RAT read-back, but no `recoverySource/evidenceSHA256`. The compatibility gate now accepts either fixed provenance or this exact legacy verified shape; any UUID, timestamp, band, uncertainty, provenance-half, guard, baseline, or transition mismatch remains fail-closed.
- Added a shared non-policy serving cache (`me.nixuge.networkmanager.serving-status.plist`) written only by the reviewed Provider summary, so Settings and CC can reuse a fresh typed result across processes. CC now drops a stuck serving refresh after 20 seconds to `?` and permits retry instead of displaying `...` indefinitely. No cache path is used for policy truth or modem writes.
- Device acceptance found that a Settings refresh followed by respring displayed the correct band, proving the cache data was correct but CCUIKit retained the old `iconGlyph`. Provider now posts a Darwin notification after an atomic cache write; CC reloads a newer cache across process boundaries and calls `refreshState` plus selector-guarded iOS 15 `contentViewController reconfigureView`, so the glyph updates without respring. The callback runs on main, observer lifetime is balanced, and no notification loop or modem write path is introduced.
- Full host suite 96/96; Python compile, source verifier, `git diff --check`, local rootless compile/package smoke, and focused independent review pass with no unresolved P0/P1/P2. Branch `fix/cc-serving-band-label`; final cloud build and device acceptance still required.

## Remaining gates

- Perform read-only target Control Center serving-label acceptance. Do not immediately re-enable n78 merely to retest the policy path.
- Exercise real-device dpkg guard unwind, uninstall, and downgrade separately after the restored device state is preserved. Rootless requires separate acceptance.
- Do not create a public tag/release from this device-specific recovery branch.
