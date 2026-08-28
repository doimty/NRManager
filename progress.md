# 1.5.0 implementation progress

Baseline: `2947f98ffb2665b000afab2c4db3ae843866d4da`
Branch: `prototype/livecc-readonly`
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
- Device acceptance found that a Settings refresh followed by respring displayed the correct band, proving the cache data was correct but CCUIKit retained the old `iconGlyph`. Provider now posts a Darwin notification after an atomic cache write; CC reloads a newer cache across process boundaries and calls `refreshState` plus selector-guarded iOS 15 `contentViewController reconfigureView`, so the glyph updates without respring. The callback runs on main, observer lifetime is balanced, and no notification loop is introduced.
- A subsequent package attempt exposed the critical CC ownership bug: CCUIKit invokes `setSelected:` during module initialization/state synchronization, so the old implementation could create a baseline and enter n78 policy recovery even when the user never tapped the tile. The CC module is now strictly read-only: `setSelected:` ignores the requested value and refreshes presentation only; the entire CC source contains no enable/disable/recover writer references. Settings is the sole policy-write owner; CC selected color still mirrors requested policy and glyph text remains serving truth.
- Device crash evidence rejected the first glyph-reload implementation: three SpringBoard SIGABRT logs share NetworkManager UUID `0F600183-5784-37B6-9A5E-4289140F02C5`; image offset `0x4520` symbolicates to `-[CCNetworkManager refreshModulePresentation] + 0x20`, immediately after the unguarded `contentViewController` getter send. iOS 15.1.1 `CCUIToggleModule` does not expose that getter.
- A runtime `_viewController`/`reconfigureView` fallback was also rejected before delivery: it remained private ABI and could recurse when CCUIKit synchronization calls the read-only `setSelected:`. The stability fix removes all `contentViewController`, runtime-ivar, and `reconfigureView` access. `refreshModulePresentation` uses public `refreshState` only, and `setSelected:` is a true no-op. Crash regression tests forbid every private glyph-refresh token. Known tradeoff: dynamic serving text may remain cached until the module/SpringBoard reloads; solving that requires a separate custom-content-controller prototype, not production private calls.

## Control Center tile migrated to a self-refreshing content module

- Reported symptoms: the tile's toggle did nothing when tapped, and the serving band lagged badly compared with the standalone `livecc` prototype ("the separate one at least refreshes live").
- Root cause of both, confirmed by reading the headers rather than inferring: `CCUIToggleModule` declares no tap callback at all, so `setSelected:` is simultaneously the user-tap entry point and the framework's initialization/synchronization entry point, and its `iconGlyph`/`selectedIconGlyph` are `readonly`, so the only way to publish a new glyph is to ask the framework to re-read them. The read-only decision was therefore structurally forced, and refresh could only ever be a side effect of drawing.
- `CCUIButtonModuleViewController` resolves both: `glyphImage` is writable, `buttonTapped:forEvent:` is a real user-interaction callback the framework does not invoke during state synchronization, and being a `UIViewController` it has genuine visibility lifecycle. The class is exported by the ControlCenterUIKit private framework (present in the iPhoneOS16.5 SDK tbd `objc-classes` list) but absent from the vendored headers, so the bundle declares the members it uses in `include/NetworkManagerControlCenterUIKitPrivate.h`. The prototype already loaded this class on the target device without a SpringBoard crash, which retires the runtime-resolution risk for the roothide lane.
- The private declarations must live in one self-contained local header, not in angle-bracket imports of `<ControlCenterUIKit/...>`. The vendored headers form a Clang module with an umbrella header, while the pinned CCSupport templates install a second overlapping copy into `$(THEOS)/include`, so a framework import resolves differently depending on which copy Clang finds first. The first cloud attempt (run `32467857111`) failed in both lanes for exactly this reason: duplicate protocol definitions for `CCUIContentModuleContentViewController` and `CCUIContentModule`, ambiguous protocol references, an incomplete umbrella, and finally `could not build module 'ControlCenterUIKit'`, all promoted to errors by `-Werror`. Reproduced locally by materializing the pinned CCSupport headers into `$(THEOS)/include`; the local header form then compiles clean for arm64 and arm64e in the same environment. A regression test forbids framework imports in the bundle and forbids a local directory named `ControlCenterUIKit`.
- `CCNetworkManager` is now an `NSObject <CCUIContentModule>` that vends `CCNetworkManagerViewController`. The view controller owns a visible-session refresh loop: `controlCenterWillPresent`/`viewWillAppear:` start it, `controlCenterDidDismiss`/`viewDidDisappear:` stop it, a 15 s timer refreshes while on screen, radio-technology notifications are debounced 0.25 s, a 2 s floor bounds request rate, and a generation counter prevents a superseded round from publishing. Off-screen the timers are invalidated and observers removed, so an unseen tile never samples.
- The pre-existing guard chain is preserved verbatim: no sample starts while the policy is transitioning, while recovery is pending, or while a setter is outstanding. Settings remains the sole policy writer. A tap only forces an immediate sample; it does not call `super`, so the framework's own selection handling cannot flip displayed state without a policy change behind it. `selected` mirrors requested policy for display only.
- The three-SIGABRT crash class is now impossible by construction rather than by avoidance: the module owns and implements `contentViewController` instead of sending it to a framework object. A regression test asserts the identifier appears exactly once, as the implementation, and forbids `_viewController`, `reconfigureView`, and `refreshState`.
- Evidence: 267/267 host tests pass with 3 Foundation-dependent skips. `CCNetworkManager.x` passes `-Wall -Werror` syntax checks for both arm64 and arm64e against the iPhoneOS16.5 SDK. A full local aggregate `make` for `arm64 arm64e` compiles, links, and signs every target with the pinned CCSupport headers present in `$(THEOS)/include`, which is the condition that broke the first cloud attempt. The linked bundle binary is `arm64 arm64e`, defines `CCNetworkManager` and `CCNetworkManagerViewController`, and contains no `CCUIToggleModule`, `iconGlyph`, `refreshState`, `reconfigureView`, or policy-writer symbol. Local packages remain compile evidence only; delivery requires the pinned macOS-14/Xcode-15.4/iPhoneOS-17.5 cloud build.
- Still open: on-device acceptance of the auto-refresh cadence, and the product decision on whether a tap should additionally write n78 policy. The current tap semantics are strictly safer than the shipped behaviour, which was a tile that looked tappable and did nothing.

## Remaining gates

- Perform read-only target Control Center serving-label acceptance. Do not immediately re-enable n78 merely to retest the policy path.
- Exercise real-device dpkg guard unwind, uninstall, and downgrade separately after the restored device state is preserved. Rootless requires separate acceptance.
- Do not create a public tag/release from this device-specific recovery branch.

## Responsive serving-status sampling plan

- Baseline: LiveCC 0.0.3 is device-accepted for layout, tint, stability, and the existing read-only refresh path. Shared provider source still calls the diagnostic adaptive sampler: NR can stop after two explicit samples, while LTE requires all ten clean samples.
- Performance hypothesis: the deterministic sleeps dominate. With 0.5 seconds settle before every copy plus 0.5 seconds between samples, a clean LTE result has 9.5 seconds of scheduled delay before CoreTelephony callback latency; the LiveCC RAT notification adds a separate 2-second debounce.
- Success: add a separate responsive UI policy which confirms two consecutive clean serving cells with the same normalized RAT+Band, keeps the 0.5-second post-refresh settle, removes only the redundant inter-sample delay, and uses a 0.25-second RAT notification debounce. Expected scheduled delay is at most 1.0 seconds for a stable serving cell and at most 1.25 seconds after a RAT notification, excluding measured callbacks.
- Independent failure signals: a single sample must never complete; a changed, missing, or unclassifiable serving identity must reset confirmation; timeout and invocation exception must retain current unsafe-outstanding behavior; the diagnostic adaptive/full-window APIs and their evidence semantics must remain unchanged.
- Rollout: exercise the shared source through the isolated LiveCC package first. Only after target timing and truthfulness acceptance should the same reviewed provider/sampler change be applied to the stable main-package branch.
- Implementation checkpoint: responsive confirmation and diagnostic NR-negative status are independent. Provider accepts only a complete `responsiveStableServing` report with a valid `confirmedServingCell` and second-copy timestamp; it never falls back to earlier observed cells. Winning-tier selection is NR > LTE > other, rejects invalid/conflicting cells without falling through, and treats NR and NRNSA as distinct identities. LiveCC generation/suppression state prevents superseded completions and Darwin cache notifications from repainting a pre-handover result.
- Current evidence: focused responsive red test failed on all three baseline symptoms and is green after the change; LiveCC 12/12, root 100/100, source verifier, Python compile, `git diff --check`, local rootless compile/package, and local roothide compile/package smoke checks pass. Local roothide remains non-deliverable; pinned cloud and target timing/NSA/handover acceptance are pending.
- The first 0.0.4 cloud artifact was withdrawn before acceptance after a final mixed-version review. LiveCC and the stable installed package must not share the serving cache/notification namespace while their ordering semantics differ. Version 0.0.5 uses an isolated LiveCC cache, notification, and publication lock; serializes revision read-increment-write; never publishes lock-contention as a false-safe state; and clears pending/debounce state across visibility sessions.

## Automatic n78 preference maintenance, first safe slice

- The product goal is an opt-in n78 preference maintenance mode, not a guaranteed band lock. Serving evidence, allowed-band policy, and recovery state remain separate domains.
- Added `docs/automatic-n78-preference-maintenance.md` as the source of truth for two-step correction, one-attempt/cooldown behavior, unsafe-latch handling, non-portable transaction baselines, and portable policy intent.
- Transaction baselines now retain device model, system version/build, complete `supportedBands`, and `modifiedBandKeys` alongside the original active-band snapshot. Legacy baselines remain readable through the existing accepted-target gate.
- Restore now validates an enriched baseline against the current device/system identity, RAT-key shape, supported capability, and owned fields before any modem setter. Drift fails closed into recovery-required state.
- Added `CCNMAutomaticMaintenanceDecision.[ch]`, a side-effect-free state machine shared by the Control Center and settings bundles. Executable host tests cover unknown/stale/flapping evidence, stable n78, LTE/other-NR drops, unsafe and incompatible states, verification, one-attempt exhaustion, cooldown, busy state, and disabled policy.
- The current schema now requires `modifiedBandKeys` to be exactly the NR RAT key. Records cannot claim ownership of unrelated RAT arrays while the restore payload only restores NR.
- Automatic correction is not wired to a background writer. SpringBoard remains read-only; the next slice needs a non-SpringBoard owner plus durable attempt/cooldown evidence before a one-shot setter path can be enabled.
- Final evidence for this slice: 103/103 host tests pass; Python compilation, release source verification, and `git diff --check` pass; local rootless arm64/arm64e package compilation succeeds. The local arm64e linker emits the known incompatible-ABI warning, so the generated debug package is compile evidence only and must not be delivered.
- An independent review attempt timed out without findings and is not counted as approval. The primary review verified identity population on every restore path and tightened `modifiedBandKeys` from “contains NR” to exactly the NR key.
- Execution ownership is now fixed in `docs/automatic-maintenance-execution-owner.md`: a root, policy-scoped launch daemon guarded by launchd `KeepAlive/PathState`. SpringBoard and Settings remain non-automatic writers. The daemon is read-only unless the exact verified enabled state and matching baseline exist; a future correction persists attempt intent before any setter and never retries the same drop.
- Added a manually invoked, read-only `networkmanager-maintenance --daemon` skeleton under `/usr/libexec`. It reuses the validated policy reader and responsive provider, requires the exact stable-enabled state, keeps two independent serving summaries, and evaluates the shared decision module. Its entry source has hard gates against policy write APIs and durable-record writers.
- The monitor tool compiles for arm64/arm64e, but no launchd plist or package lifecycle activation exists, so it cannot start automatically. It has no setter path and persists no maintenance state.
- Evidence after this slice: 110/110 host tests, Python compilation, release source verification, and `git diff --check` pass; the full local package including the monitor tool compiles successfully. Local arm64e warnings remain compile-only evidence.
- iOS 15.1.1/roothide `PathState`, rewritten executable path, lifecycle, wakeups, and battery behavior still require controlled device validation before activation.

## Read-only policy record parser extracted

- `CCNMN78PolicyReader.m`/`.h` contain a self-contained copy of all read-only policy state functions (validation, loading, summary building, boot identity, band dictionary, record validation).
- The reader exports `CCNMReadN78PolicyState()` with the same contract as the full controller, but contains no writer code: no `CCNMAcquirePolicyLock`, `CCNMCreateDurableRecord`, `CCNMBeginSetter`, `CCNMCallSetter`, `CCNMSetterUncertainLatch`, or any enable/disable/recover/recovery function.
- The daemon `maintenance-daemon/main.m` now imports `CCNMN78PolicyReader.h` and the Makefile links `CCNMN78PolicyReader.m` instead of `CCNMN78PolicyController.m`.
- The daemon has zero compile-time reachable writer code. Any future accidental writer call in the daemon will fail at link time.
- Full host suite is now 117/117; new focused tests verify the daemon imports the reader (not the controller), the reader contains no forbidden writer tokens, and the reader header exports the correct read-only API.

## Durable maintenance record and status plist

- `CCNMAutomaticMaintenanceRecord.m`/`.h` define the record schema (version, owner, boot identity, device/system/SIM fingerprint, previous/current sample, drop generation, attempt consumption, cooldown, last decision) and the status plist (bounded external-observation format).
- The daemon now persists both the record (`CCNMAWriteRecord`) and the status (`CCNMAWriteStatus`) after every refresh, including when the policy is disabled.
- The record carries forward drop state across restarts on the same boot. A new boot session resets the drop state. Identity drift (different device model, system version, or build) is detectable via `CCNMARecordMatchesCurrentIdentity`.
- The daemon imports `CCNMAutomaticMaintenanceRecord.h` and the Makefile links the new module. The record module contains no writer code (no setter, no lock, no durable policy write).
- New focused suite `tests/test_automatic_maintenance_record.py` (7 tests: record building, validation, status construction, decision names, identity drift, Makefile linkage, source code integrity).

## P1 identity and capability gate

- Hypothesis: `baselineValid` alone is insufficient. A daemon can only evaluate automatic maintenance when the live slot-1 SIM UUID, device model, system product version/build, supported RAT shape, supported NR bands, and active NR policy domain are freshly observed and consistent with the retained baseline.
- Implemented a read-only `getBandInfo:error:` query in `CCNMServingStatusProvider.m` with runtime ABI validation. The provider now publishes capability read success, supported/active NR arrays, exact supported RAT keys, n78 presence, capability sample time, and the real subscription UUID.
- Replaced the daemon's `input.capabilityCompatible = [latestPolicy[@"baselineValid"] boolValue]` placeholder with a fail-closed baseline comparison. It requires both live supported and active n78, exact device/system/SIM identity, matching supported RAT shape, a baseline-owned NR set still supported, and a valid baseline capability snapshot.
- Extended the maintenance record/status schema with the capability snapshot. Drop state is carried only when boot, device, system, SIM, and capability values all match; identity or capability drift starts a fresh generation and cannot replay the old evidence.
- Success criteria: no baseline-only capability decision, missing UUID/capability cannot produce compatibility, and no setter/writer symbol enters the daemon or provider. Independent failure signals: ABI mismatch, malformed BandInfo, missing n78, missing UUID, baseline shape drift, or unsupported baseline-owned NR band.
- Focused host checks pass for the serving provider, daemon read-only contract, and record source contract. Foundation-dependent Objective-C execution remains skipped on Linux pending Apple SDK/cloud build.
- Local Theos compile caught and fixed Objective-C-only issues missed by host tests: missing `@` dictionary keys, a stale unimplemented method declaration, nested nullability in the reader header, reader static helper forward declarations, unused orphan-only reader helpers, record-local serving keys, and missing shared support constant linkage.
- Extracted shared policy/serving/error constants into `networkmanagerprefs/CCNMN78PolicySupport.m`, linked by the Control Center bundle, PreferenceBundle, read-only daemon, and both maintainer-script tools. The complete aggregate `make` now compiles, links, merges, and signs all targets for arm64/arm64e. Local arm64e ABI warnings remain compile-only evidence and block delivery.
- Current host evidence: 118/118 tests pass with 3 Foundation-dependent tests skipped, Python compilation and `git diff --check` pass. No writer symbols are present in the daemon, provider, record, or reader source paths.

## 2026-08-22 write path: replace the device allowlist with runtime capability evidence

The n78 write path required `iPhone14,3` / iOS 15.1.1 (`19B81`) at six call sites through
one `CCNMValidateTarget`. That single gate answered for two unrelated data flows, which
made "can this run on other phones" unanswerable without reading all six sites.

Split first (`d1ea1bb`), then loosened:

- `CCNMValidateSelfSourcedWriteTarget` — `performEnable`, `performRestoreOperation:`.
  These write only values the device produced: enable resends live BandInfo with the NR
  array narrowed, restore resends a baseline the device wrote about itself.
- `CCNMValidateHistoricalReplayTarget` — the three known-orphan paths. These carry a
  reviewed historical BandInfo table.

Both now reduce to `CCNMValidateTargetIdentity`: model, version and build must be
readable, because `CCNMBuildBaselineRecord` refuses a baseline with empty identity and an
enable that cannot record a baseline must not reach the setter. Neither compares against a
model name.

What replaced the allowlist, per path:

- Enable: `CCNMBuildN78Payload` requires 78 in both fresh `activeBands[NR]` and
  `supportedBands[NR]`, refuses when active is already exactly `[78]`, and
  `CCNMValidateN78OnlyPayload` requires every non-NR RAT array to be byte-identical.
- Known-orphan replay: `CCNMKnownOrphanBandInfoMatches` demands an exact dictionary match
  of the reviewed active and supported tables plus the reviewed subscription UUID and clean
  durable state. n78 being common is not sufficient and never was the gate.
- Restore: `CCNMValidateBaselineCompatibility` keeps `deviceModel`, drops the
  `systemVersion`/`systemBuild` equality, and checks the saved NR capability snapshot
  against the current supported NR evidence.

Two corrections found while implementing:

1. Requiring the OS build to match would have stranded any device that updates iOS while
   the policy is enabled — the baseline is the only way back, so an update would have
   turned a reversible change into a permanent one. Build is now recorded evidence, not a
   gate.
2. A first attempt rejected baselines lacking the capability snapshot (added in `156ec8a`;
   `47e1e72` baselines have only `activeBands`). Same stranding bug from the other side.
   Those baselines now restore when their saved NR bands pass the capability check, which
   is the evidence they can still offer.

The check is scoped to NR because `CCNMBuildRestorePayload` replays exactly one array: live
values for every RAT except NR, saved values for NR. The other arrays were just read from
this modem, so they cannot be unsupported.

A post-implementation device-shaped regression was then found in the compatibility check:
`activeBands[NR]` is not guaranteed to be a subset of `supportedBands[NR]`. The reviewed
historical fixture contains active NR bands 257-261 absent from its supported NR list, while
its restore read-back was verified equal. The check now validates the saved capability snapshot
(`supportedBands[NR]`) and replays the exact saved active NR list, without applying the invalid
active-subset assumption. Compatibility failures now use `baselineIncompatible`, rather than
reporting as the unrelated `uuidDrift` subscription error.

`CCNMValidateBaselineCompatibility` exists in both the controller and the reader (the
daemon links the reader). Both were changed identically; a test diffs the two bodies by
asserting the same content in each. Keyed subscripts are nil-guarded because the reader
copy is exported and the bundle loads into SpringBoard.

`tests/test_write_path_target_gates.py` (12 tests) pins which caller uses which gate, that
enable and restore share one gate, that no `iPhone14,3`/`19B81` literal remains in the
controller, that the OS-build equality stays absent, that the NR capability check runs for
every baseline before the evidence branch, and that pre-snapshot baselines stay restorable.

Verification: 297 host tests pass (3 skipped), livecc 12 pass, `verify_release_source`
passed with no forbidden strings, `clang -fsyntax-only -fobjc-arc -target arm64-apple-ios14.0`
clean for the controller, reader and serving provider. Device verification of a write on a
non-reference handset remains outstanding.

Unchanged and still true: setting NR to `[78]` is an allowed-band preference, not a serving
guarantee; the reference device still falls back to LTE B3. The setter keeps its 20 s
watchdog, and a timeout still defers restore past a reboot.

## 2026-08-22 Control Center: replace policy switch with read-only Live Band tile

- The formal Control Center module no longer reads n78 policy state, mirrors policy
  `selected`, observes policy-change notifications, or carries the policy writer
  controller. It now uses the standalone LiveCC state machine: `Live Band` title,
  read-only `selected = NO`, current LTE/NR text, searching glyph while a sample is
  pending, RAT debounce, pending/superseded refresh generations, and completion
  summaries supplied directly by the provider.
- Follow-up diagnosis found that the previous formal bundle was still not equivalent
  to standalone LiveCC: it retained the normal policy cache/lock namespace and a second
  hand-copied controller with glyph caching. The formal target now compiles the
  standalone `livecc/Sources/NetworkManagerLiveModule.m` directly with class-name
  aliases, the standalone `CCNMLiveServingPaths.m`, the
  `CCNMLiveServingStatusProvider`/`CCNMLiveCellMonitorAsyncState` namespace flags, and
  the same private-framework linkage split. The path shim selects `NetworkManager.bundle`
  for the formal target, so its isolated cache/lock resolve relative to the actual
  loaded bundle.
- This removes the formal bundle's `CCNMN78PolicyReader.m`/policy-support linkage,
  `drawnGlyphKey` image cache, extra `viewDidAppear` refresh, and common-mode timer
  differences. Settings continues to compile the full writer controller separately.
- Verification after the exact-source replacement: 291 host tests passed (3 skipped),
  38 focused LiveCC/serving/policy tests passed, `verify_release_source`, Python
  compilation, and diff checks passed. The first pinned cloud run `32561009570`
  compiled both lanes and passed host gates/rootless, but roothide package verification
  correctly rejected the temporary Makefile delta: the bundle was missing the pinned
  `@loader_path/.jbroot/usr/lib/libroothide.dylib` dependency and added CoreGraphics /
  QuartzCore. The formal wrapper now macro-substitutes the standalone `CGRectIntegral`
  call with an equivalent local helper, removes QuartzCore from the formal framework
  list, and restores the roothide library link. Local roothide package
  `1.5.0-2+debug` now has the isolated livecc symbols/cache and exactly the expected
  roothide runtime dependency, with no policy writer symbols. Local arm64e ABI warnings
  remain expected compile-only evidence. Follow-up pinned cloud run `32561680422`
  then passed host gates and both rootless/roothide package verification. The roothide
  artifact is ready for delivery after the final hash check.

## 2026-08-22 Control Center long-press and enabled-color correction

- 老大澄清：正式 Control Center 按钮不能移除，只需要取消长按展开反馈。上一轮 `1fc1b6a` 的移除方案作废，正式 bundle 恢复保留；独立 LiveCC 仍是独立包，不与正式 bundle 合并安装路径。
- 顶层 Makefile 恢复构建 `NetworkManager.bundle`，正式包继续保留 Control Center 按钮；Settings、maintenance-daemon、package-actions 也继续完整构建。
- 复用同一份 LiveCC 控制器源码，但新增 `shouldBeginTransitionToExpandedContentModule` 返回 `NO`，长按不会再展开一个与紧凑磁贴相同的频段预览。没有 runtime 手势 hook，也不影响普通点击刷新。
- 正式 bundle 只读读取自身 path shim 指向的 policy state plist，用 `requestedMode == n78Preferred` 同步 `selected`；不链接完整 policy reader/support，不调用任何 setter。启用态 selected glyph 使用原来的橙色 `#FF9500`，普通 glyph 白色；同时显式设置 `selectedGlyphImage`，避免白色 selected 背景上继续显示白字。
- 当前验证：全套主机 290 passed、3 skipped；定向 77 passed；standalone LiveCC 12 passed；`verify_release_source`、py_compile、diff check 通过；serial roothide/rootless local aggregate builds 和 standalone LiveCC build 完成。commit `ca62113`，固定云端 run `32577478710` 全部成功；roothide/rootless 包内 verification-report 均 `passed`，正式 bundle 为 arm64+arm64e、roothide `LC_DYLD_INFO_ONLY`、依赖基线不变，`incompatible arm64e` 为 0。roothide SHA256 `ec971267aa07af989f02450242fe1a3dba2bccb29943b47f798ed627402081ab`，314356 bytes；rootless SHA256 `7e547f6f05086157f111afca882f76d8b95edd6fc5ffaf2713a319700ce3bc44`，297320 bytes。

## 2026-08-22 修复 SIM 2 写入门禁误拒绝

- 真机截图确认：设备报告的是 `SIM 2`，但写入失败文本仍是旧的 `slot 1` 硬编码；失败发生在 modem setter 之前，错误码是 `unsafeSubscription`，所以没有发生任何 modem 写入。
- 普通写入路径现在选择“恰好一个 present/good 且有稳定 UUID 的正整数 slot”，不再要求 slot 1。首次 enable 将实际 `slotID` 与 UUID 写入 baseline、intent、in-flight 和 state proof；后续 fresh guard、setter 前 revalidation、read-back 和 restore 全部同时绑定这两个身份字段。slot/UUID 任一变化仍 fail-closed，双卡、缺 UUID、非正 slot 仍拒绝。
- reader 和 maintenance daemon 同步验证实际 slot。serving summary 输出真实 slot，maintenance record 的 identity/drop state 也绑定真实 slot，避免 SIM 1/SIM 2 切换后错误继承自动维护状态。已知历史孤儿恢复继续固定 reviewed UUID + slot 1，不被普通路径泛化。
- 回归覆盖 slot 1/slot 2 单卡成功模型、双卡/缺 UUID/非法 slot 拒绝、UUID+slot 原子 revalidation、四类 durable record 链接、reader/daemon 镜像和历史孤儿 slot 1 pin。
- 追加修正：disabled 一轮没有选定 subscription，无 slot/UUID 可绑定，record builder 现在正确地拒绍凭空写 slot 1，但那会把上一代 record 留在盘上。daemon 在 disabled 分支显式 `CCNMADeleteRecord()` 退役记录，只保留 status，避免同一 boot 内 disable 再 enable 继承已消耗的 attempt。删除条件故意窄于“record 为 nil”：enabled 下身份读不到时必须保留旧记录，否则会把已用完的尝试洗成可用。
- 当前验证：host 全套 302 passed、3 skipped；新增定向 12/12；`verify_release_source` passed；本地 rootless aggregate 构建完成（仅编译证据，不交付）。
- 云端固定环境 run `32581725415`（commit `3ecc200`）三 job 全部 success：Host release gates、Package roothide、Package rootless。两 lane 的 verification-report 与 source-verification 均 `status: passed`，failures/forbidden 为空。
- 工具链已固定并核对：Xcode 15.4 (`15F31d`)、Apple clang 15.0.0 (clang-1500.3.9.4)、ld 1053.12、system SDK 17.5、min iOS 14.0；两 lane 日志 `incompatible arm64e` 计数均为 0。
- roothide 五个二进制均 arm64+arm64e；两个注入 bundle 保持 `LC_DYLD_INFO_ONLY`，三个 exec 工具（install-guard / removal-guard / maintenance）为 `LC_DYLD_CHAINED_FIXUPS`，符合已审定基线；daemon 与两个 guard 不链 libroothide；launchd plist program 为裸路径 `/usr/libexec/networkmanager-maintenance`。
- 产物：roothide `me.nixuge.networkmanager_1.5.0_iphoneos-arm64e.deb`，SHA256 `0e0faeb0154b19b0c0b6efe3133b707dc809acaf5175eecb31d8b8a29ee02fc2`，318732 bytes；rootless `me.nixuge.networkmanager_1.5.0_iphoneos-arm64.deb`，SHA256 `b30e3af17ecaa11ecfe7629a7da6b7e5d73efc7493cfacf7e3c918444491094a`，300398 bytes。
- 剩余缺口：SIM 2 真机端到端复测（enable / read-back / disable 后的 record 退役 / 重新 enable 不继承旧 attempt）尚未完成。
- 第三轮复审发现最后一处 slot 1 默认值：`performRestoreOperation:` 的 verified-restore-cleanup 分支用 `state[@"slotID"] ?: @1` 写 cleanup proof。该分支专门处理早于本次改动的 checkpoint，那些记录本来就没有 slot 字段，回退到 1 等于把未曾观测到的 slot 写进持久证据。分支内已经跑过 `CCNMSafeTargetContext` 重验证，改为采用 `details[@"targetSlotID"]`，并先用 `CCNMValidSlotID` 校验再入字典字面量（nil 入字面量会在 Preferences 内抛异常），不合法时以 `unsafeSubscription` fail-closed。
- 同时新增两条测试：一条锁定该分支必须用重验证结果且带校验；一条在 controller / reader / daemon / automatic record 四个文件上禁止任何 `slotID"] ?: @1` 形式的默认值，防止同类写法重新渗入。红/绿已验：把旧写法改回去 → 2 项失败；恢复 → 全绿。
- 补充验证：host 全套 304 passed、3 skipped；定向 14/14；`clang -fsyntax-only -fobjc-arc -target arm64-apple-ios14.0` 对 controller 干净；`verify_release_source` passed；`py_compile`、`git diff --check` 干净。
- 固定云端验证：commit `3bca7d2`，run `32612884590` 三 job 全 success（Host release gates / Package rootless / Package roothide）。两 lane provenance 均回报 `source_sha=3bca7d2d0f7f24670c6930ff9787608c0bf88a68`。
- 两 lane 包校验 `status: passed`，`failures` / `forbidden_diagnostics` 为空；`incompatible arm64e` 计数 0；Xcode 15.4 (`15F31d`)、Apple clang 15.0.0 (clang-1500.3.9.4)、ld 1053.12、system SDK 17.5、min iOS 14.0。
- roothide 五个二进制均 arm64+arm64e；两个注入 bundle 保持 `LC_DYLD_INFO_ONLY` 并依赖 libroothide，三个 exec 工具为 `LC_DYLD_CHAINED_FIXUPS` 且不链 libroothide；launchd plist program 为裸路径 `/usr/libexec/networkmanager-maintenance`，`jbroot_present` 与 `plist_prefix_present` 均 false。rootless lane program 为 `/var/jb/usr/libexec/networkmanager-maintenance`。
- 产物：roothide SHA256 `ed7f32c67de1737d35ecf54d84f21ec4e3b6cb6a3d7b943ba8996b9681c1436c`，317930 bytes；rootless SHA256 `901ccc0a8d8d3c68a2634ac98acd7c5f1ec7251a29abf879ebc974b6ba128285`，300086 bytes。roothide 已交付，待真机 SIM 2 复测。

## 2026-08-23 写入拒绝文案改为上报实测布局

- 真机回测（截图）：装上 `3bca7d2` 后仍报 `unsafeSubscription`，但弹窗已包含「本机实测：iPhone15,3 / iOS 16.5.0（20F66）」这一行。该行来自 `measuredDeviceDescription:`，引入于 `d60bd6b`，而 `d60bd6b` 是 `e19749f`（slot 修复）的祖先提交，因此它不能单独证明新包已装。**无法从这张截图判定装的是旧包还是新包**，因为两个版本的拒绝文案只差 `slot 1` / `positive slot` 一个词，而弹窗里那句英文已被截断换行，看不到尾巴。这本身就是诊断缺陷。
- 修正：`CCNMSafeTargetContext` 的两处拒绝文案不再复述规则，而是上报实测到的东西。新增 `CCNMSubscriptionLayoutSummary()` 渲染逐 slot 的 `present/absent`、`good/notGood`、`hasUUID/noUUID`（**只报 UUID 有无，不打印值**）。
- 同时拆分两类本来共用一句话的拒绝：`presentCount != 1` 报「需要恰好一张在位 SIM，实测 N 张」；单卡但不可写报「唯一在位 SIM 不可写」。这两种对用户意义不同，合成一句会把双卡用户引到不存在的 slot 问题上。
- drift 文案同样拆成四种：记录的 slot 本身非法（优先判，因为它也会违反等价比较）、slot 与 UUID 同时变、卡换了槽、卡被换了。
- 新增两条测试：`test_refusal_names_the_observed_layout_not_just_the_rule`（禁止旧句，要求引用 layout summary 与 `presentCount`，并断言 summary 不出现 `UUIDString`）与 `test_drift_refusal_distinguishes_a_moved_sim_from_a_swapped_one`（禁止旧句，要求四种文案，并断言 `!requiredSlotValid` 分支先于 drift 分支）。
- 验证：host 全套 306 passed / 3 skipped；定向 16/16；`clang -fsyntax-only -fobjc-arc -Wall -Wformat -target arm64-apple-ios14.0` 对 controller 干净（含格式字符串检查）；`verify_release_source` passed；`py_compile`、`git diff --check` 干净；本地 rootless aggregate `build_rc=0`、`error:` 计数 0（仅编译证据）。
- 固定云端：commit `a6acd0b`（`a6acd0b5056f1afa41e1429bc2d60efad59d9031`），run `32614300326` 三 job 全 success；两 lane provenance 均回报同一 `source_sha`。两 lane 包校验 `status: passed`，`failures` / `forbidden_diagnostics` / `legacy_assets` 均为空，`build_log.failures` 为空（即 `verify_build_log.py` 的 `incompatible arm64e` 模式零命中）。
- 工具链：Xcode 15.4 (`15F31d`)、Apple clang 15.0.0 (clang-1500.3.9.4)、min iOS 14.0；roothide 走系统 SDK 17.5，rootless 走 Theos SDK 16.4（与上一轮一致）。roothide 两个注入 bundle 保持 `LC_DYLD_INFO_ONLY` 并依赖 libroothide，三个 exec 工具 `LC_DYLD_CHAINED_FIXUPS` 且不链 libroothide；plist program 为裸路径。
- 产物：roothide SHA256 `a1bf442a4e889426cd8cf29f294f30dc48cfad5bbcdd348d4d2ad897f7810f41`，319706 bytes；rootless SHA256 `cf9df53e43ec57a08f4a9580bd6ad4fd308ab5a4928d8e5f396bc212d11aec8d`，302746 bytes。roothide 已交付。
- 待定决策（需要老大拍板，未实施）：写入路径是否允许双卡在位时按数据线选定目标。读取路径（`CCNMServingTargetContext`）已有三级选择：`currentDataSubscription` → 唯一 `userDataPreferred` → 唯一可用卡，歧义时拒绝。写入路径没有这一层，仍要求整机恰好一张在位 SIM。若要放宽，必须明确：仅当 CoreTelephony 明确报出当前数据订阅时允许，且遵循 controller 自己的 client（避开跳 lock domain）。
## 2026-08-23 写入目标改为「按数据卡选、按记录认」（双卡放宽）

- 需求确认：老大要「按当前的数据卡来做」。原实现要求整机恰好一张在位 SIM，双卡直接拒绝，这就是真机上 `A modem write needs exactly one present SIM, but 2 are present` 的来源。
- 关键区分（本轮全部设计的地基）：**数据线路是运行时可变的**，实测同一台机 10:46 数据在 SIM 2（NR n1）、11:30 在 SIM 1（NR n78）。所以数据卡只能用来「选目标」，绝不能用来「认目标」。绑定身份必须是订阅 UUID + 卡槽。
- `CCNMSafeTargetContext` 新增显式模式参数 `CCNMTargetResolution`，不再从「记录字段是否为 nil」推断意图：
  - `CCNMTargetResolutionFirstEnable`：仅首次 enable。单卡直接用那张；双卡用 CoreTelephony 自己报出的当前数据订阅。查询不可用 / 报错 / 报出的线不可写 → 一律拒绝，不猜。
  - `CCNMTargetResolutionRecorded`：所有后续校验、read-back、restore、recover。只按 UUID（或旧记录的裸 slot）查找，**永不重选**，也不看数据线。
  - `CCNMTargetResolutionRecordedSoleSIM`：known-orphan 回放专用，额外坚持整机单卡，因为它的评审证据来自单卡参考机。
- 为什么必须显式传模式而不是看 nil：早于身份字段的旧记录什么都没记，如果用「没记录 ⇒ 可自由选择」的推断，一次旧 checkpoint 对账就会在双卡机上重新挑一条线。现在旧记录在双卡机上明确拒绝并如实说明「记录未指明订阅且当前 2 张卡在位，无法确定它当初写的是哪条线」。
- 反向也锁死：持有记录的调用方传 FirstEnable 会被拒（`A recorded write target cannot be reselected.`）。
- 数据线探针 `CCNMCurrentDataLineUUID` 走 controller 自己的 client（不跨 provider 的 modem lock 域），`getCurrentDataSubscriptionContextSync:` 声明为 `@optional` 并经 `CCNMValidateObjectErrorABI` 校验。与读取路径的关键差异：**写入路径不做静默降级**，四条无答案路径全部返回 nil + 具体原因，不回落 `userDataPreferred`，也不回落「唯一可用卡」。
- 双卡下若数据线是不可写的那张（无 UUID / notGood / slot ≤ 0），拒绝而不是落到另一张。落过去等于把偏好悄悄写到用户没问的那条线上。
- 新增歧义防护：两条可写线报同一 slot 或同一 UUID 时拒绝，否则后面所有查表都会静默取其中一条。
- 布局摘要改为整表扫完之后再渲染一次（函数内只允许出现一次 `CCNMSubscriptionLayoutSummary(`），此前若在循环内渲染，关于第二张卡的拒绝可能只描述第一张。
- 拒绝文案区分「卡还在但身份变了（被换）」与「记录的线根本不在（被拔/坏）」，只有后者能靠插回原卡解决。UUID 仍只报有无。
- transient `details` 新增 `targetSelection` / `presentSubscriptionCount` / `writableSubscriptionCount` / `targetWasRecorded`，durable record 结构未动（避免 `CCNMRecordsRemainExact` 让老记录失效）。
- 测试：`tests/test_write_path_subscription_slot.py` 的行为模型重写为镜像新逻辑，并补 8 条源码级断言。其中三条是防回归的结构约束：所有 `CCNMSafeTargetContext` 调用点必须显式带模式且只有一个 FirstEnable；函数内 `CCNMCurrentDataLineUUID(` 只能出现一次且必须排在 recorded 拒绝分支之后；`presentCount != 1` 的每一处拒绝都必须同时出现 `CCNMTargetResolutionRecordedSoleSIM`。新增 `calls_to()` 辅助按分号跨行重组调用，避免换行绕过断言。
- 已知残留风险（如实记录）：双卡下 iOS 事后把数据线挪到另一张时，n78 仍 pin 在原订阅上，失效但无害，disable/restore 仍可用；真正新增的风险是用户拔掉或换掉被改过的那张卡 → 「孤儿 baseline」概率上升，恢复需插回原卡。
- 验证：host 全套 320 passed / 3 skipped；定向 30/30；`clang -fsyntax-only -fobjc-arc -Wall -Wformat -target arm64-apple-ios14.0 -isysroot iPhoneOS16.5.sdk` 对 controller 与 provider 均干净；`verify_release_source` `status: passed`（`failures` / `forbidden` 空）；`py_compile`、`git diff --check` 干净；本地 rootless aggregate `build_rc=0`、`error:` 计数 0（仅编译证据，不交付）。
- 文档同步：README 第 20 行的 `slot 1 has the single present/good SIM` 已改（上一轮误报为已改，实为未改）；release notes 的 Compatibility 段改写为三条目标来源规则 + 双卡行为与残留风险说明。

## 2026-08-24 NR band selection pane review hardening

- Worktree `/root/.openclaw/workspace/worktrees/NetworkManagerReborn-release-1.5.0`, branch `feature/nr-band-selection-1.6.0`; no device claim is made.
- Review findings fixed: the pane now rejects capability evidence older than 30 seconds (capability timestamp is independent from serving-cell freshness), recovery states take precedence over `requestedMode`, validation and write-failure messages stay localized, unavailable text is not duplicated, custom cells own their accessibility height, and post-confirmation policy state plus captured selection are rechecked before the preference write.
- The pane now uses the stable policy summary `targetNRBands` for displayed checkmarks while the policy is enabled; it uses the pending preference only in clean system-default state. An absent pending file is tracked as the shipped default rather than called an explicit save. Saving rebuilds the whole model and clears stale dropped-band footers.
- Hypothesis: all user-visible selection state must be derived from fresh capability evidence and the correct durable/applied owner, while a pane save must remain preference-only and never become a modem write. Independent failure signals were stale timestamps accepted, recovery guidance saying only “turn off”, raw English validation text, duplicate unavailable paragraphs, applied target omitted, or stale footer after save.
- Evidence so far: pane tests 32/32; full host suite 388 passed with 3 Foundation-dependent skips; `verify_release_source.py` passed with empty `failures`/`forbidden`; `py_compile` and `git diff --check` passed; seven Objective-C syntax checks returned rc=0; local rootless aggregate `make package SYSROOT=.../iPhoneOS16.5.sdk` returned 0 and compiled/linked the new pane in both slices. The local arm64e ABI warnings are expected compile-only evidence and not deliverable. The only syntax diagnostic beyond those linker warnings remains the existing vendored `roothide/stub.h` unused-parameter warning in the policy controller.
Cloud gate complete: release run `32688526055`, final source SHA `e233deb986b79807f8760d1d4a7dde536c1c6ced`, host/rootless/roothide all green. Rootless artifact SHA256 `0fab5b78b39e0dfa51c0c194cc26bf2b4b9aff5517319378126f4754d3619f33`; roothide artifact SHA256 `46275ea0ae8ae305eb9b1230d09c584885686fe234af4d9fddc2ff294c0ec8fb`. Both reports and source verification passed, logs have zero `incompatible arm64e`, and both provenance files record Xcode 15.4 (`15F31d`), clang 15.0.0, ld 1053.12; roothide reports SDK 17.5 and the expected bundle/tool load-command split.
- Remaining gate: device validation of multi-band restore, off/on baseline capture, and crash-between-intent/read-back behavior.

## 2026-08-24 Settings crashed on entering the band pane: PSCellClassKey held a name, not a Class

- Reported from the device: entering the new NR band selection pane aborted `Preferences`. Incident `CEBF0CDF-141C-4E8B-B123-D47CB8599F46`, `iPhone14,3`, iOS 15.1.1, crashing frame `-[PSListController tableView:cellForRowAtIndexPath:] + 592` into `___forwarding___`. The delivered package was roothide SHA256 `46275ea0ae8ae305eb9b1230d09c584885686fe234af4d9fddc2ff294c0ec8fb` from run `32688526055`. That build was green on every gate this repo has.
- Root cause: the pane's three code-built specifiers set `PSCellClassKey` to `@"CCNMStatusCell"` / `@"CCNMBandSelectionCell"`. `PSCellClassKey` requires a `Class`. `Root.plist` may name a cell class as a string only because Preferences' plist loader replaces it with `NSClassFromString` before the specifier exists (`Preferences.m` `__SpecifiersFromPlist`, which also removes the key when the lookup fails, so the contract is a Class either way). Nothing converts a specifier built in code: `+[PSTableCell cellClassForSpecifier:]` returns the property verbatim, and both `PSListController` and `PSListControllerDefaultAppearanceProvider` then send the class method `+isSubclassOfClass:` to it. `NSString` does not answer it, so the first row layout throws `NSInvalidArgumentException` and Settings aborts. `-[PSTableCell reuseIdentifierForSpecifier:]` is a second independent path to the same crash.
- Evidence, from decompiled iOS 18.2 Preferences sources cross-checked with `gh search code` (30 hits, all `+ (Class)cellClassForSpecifier:`, no counter-example): the theos header only declares `NSString *const PSCellClassKey; // @"cellClass"`, which is exactly why the wrong type looked right at the call site.
- Fix: one file-local helper `CCNMSetCellClass(PSSpecifier *, Class)` is now the only writer of `PSCellClassKey` in the pane, so the parameter type carries the contract. `PSHeaderCellClassGroupKey` and `PSFooterCellClassGroupKey` deliberately stay strings, since the framework resolves those two with `NSClassFromString` itself; a test pins that distinction so the next reader does not "fix" them too. `detail` and `pane` likewise remain strings.
- Scope check: the bug was only reachable in the pane. `CCNMRootListController` never writes `PSCellClassKey` in code, and every other property the pane sets is a string, number, or the framework's own type.
- New artifact gate, because no existing gate could see this. `verify_release_package.py` now parses the preference bundle's Mach-O sections and refuses a package that carries a cell class name in `__TEXT,__cstring`, which is where an `NSString` literal's bytes live. The name legitimately appears in `__TEXT,__objc_classname` for every class the bundle defines, so the section is the whole signal and a plain `strings` scan would flag every build. It also fails when none of the classes appear at all, so "read the wrong file" cannot look like "clean". Pure section parsing, so it runs in the host-tests job too, not only the two macOS lanes.
- Verified against the real binaries: the shipped crashing deb reports `cell_classes_as_string_literals = [CCNMStatusCell, CCNMBandSelectionCell]` and fails; the rebuilt bundle reports `[]` and passes, with all four classes present in `__objc_classname` in both slices.
- Test fixtures moved to `tests/machofixtures.py`. `test_package_end_to_end` previously staged a four-byte fat magic, which was enough for `is_macho_file` but became "not a Mach-O image" once a second consumer read real sections; the shared fixture is now structurally valid for both. The end-to-end test asserts a package whose bundle names a cell class as a string fails as a whole, not merely that the checking function returns a failure, since the previous release proved a check that is not reached is worth nothing.
- Hypothesis: a specifier property whose required type is not visible at the call site must be constrained by the artifact, not by review. Independent failure signals: the gate passing on the known-crashing deb, the gate failing on a correct build, a fixture that reads as clean because its offsets are wrong, or the check being registered but never reached by `verify_package`.
- Evidence: pane tests 34/34 with the new assertion verified red against the shipped source and green after the fix; full host suite 399 passed with 3 Foundation-dependent skips; `verify_release_source.py` passed with empty `failures`/`forbidden`; local `make` for the preference bundle links both slices with no errors and the rebuilt binary carries no cell-class string literal. Device validation of the pane is still outstanding.
- Cloud gate: run `32700801939`, source SHA `b4737fb46286083f7e4b9400034729963afa2d35`, all three jobs green. Both lanes report `status: passed` with empty `failures`, and the new gate's evidence reads `cell_classes_as_string_literals: []` with all four classes present in `__objc_classname` across both slices. Zero `incompatible arm64e`; Xcode 15.4 (`15F31d`), clang 15.0.0, ld 1053.12, system SDK 17.5. roothide SHA256 `61a9e3a0daeaf65e6784cbe063df9534afd9d48c3fa6f2fa15e457c7432ded8f` (344718 B); rootless SHA256 `ad71862da8748ac38fac96bb3f8693254e3afebc944c116654d1c519366bd5e3`. The delivered deb was re-extracted and re-checked independently of the CI report, and its `__cstring` was confirmed to still contain the pane's own literals, because a green CI report does not establish that the file in hand is that artifact.
- **Device confirmed the pane opens.** Settings no longer aborts on entry, which closes the crash this section is about. The screenshot also exercises several paths that host tests can only assert structurally: `CCNMBandSelectionCell` renders its own subtitle and its own checkmark glyph (`n78` marked while `PSTableCell`'s radio-group machinery is unused), `-detailForBand:` shows the measured serving frequency for the served band only (`3408.960 MHz` on `n78`, bare `Sub-6 GHz` on every other row), the Chinese table resolves for every key on screen, and the save row is correctly disabled because `canSave` requires a change against the saved selection. Band rows are enabled, so `availability` is `CCNMBandSelectionAvailable`, meaning the pane correctly reads the policy as being in clean system-default state.
- Remaining device gates, unchanged by this fix: multi-band restore, off/on baseline capture, and crash-between-intent/read-back behaviour. A save followed by enabling the switch has not been exercised yet.

## 2026-08-24 The save row could never be re-enabled: two independent stale-state bugs

- Reported from the device with the pane now opening: tapping other bands appeared to do nothing durable, and 保存选择 stayed disabled. The screenshot settles which half was broken. `n41` carries a checkmark next to `n78`, so `-toggleBandSelection:` dispatched, mutated `workingSelection`, and its own `-reloadSpecifier:` on the tapped row worked. The save row is still grey and the status row still reads the value it had when the pane was built. The selection was registered; only the two rows that report it were never updated.
- Root cause A, the identifier. `-[PSSpecifier setIdentifier:]` was being used to label every code-built specifier in the pane. `-[PSSpecifier identifier]` reads `propertyForKey:@"id"` and falls back to `@"label"`, then `@"key"`, then `-name`, and `PSSpecifier` declares no identifier storage of its own, so that property is the entire mechanism. Preferences' own code-built specifier, `+[PSSpecifier deleteButtonSpecifierWithName:target:action:]`, sets the ID with `setProperty:forKey:@"id"` and never calls the setter. With the property unwritten the getter answers a localized display name, so `-specifierForID:` cannot match the ID the caller asked for and every refresh keyed on that lookup silently does nothing.
- Root cause B, the model replacement. `_specifiersByID` and the group index array are rebuilt only by `-[PSListController prepareSpecifiersMetadata]`, reachable from exactly three places: `-viewDidLoad`, `-setSpecifiers:` and `-reloadSpecifiers`. The pane assigned `_specifiers` directly on every appearance and after every save, so neither structure was ever rebuilt. An ID lookup therefore answers with an object from an earlier build, and `-reloadSpecifier:` locates rows with `-indexOfObject:` while `PSSpecifier` does not override `-isEqual:`, making that a pointer comparison that fails. Writing to an orphan and reloading nothing is the observed no-op.
- The two are independent. Fixing only A leaves the lookup returning a stale object; fixing only B leaves the ID unmatched. Both were present.
- Latent second-order bug from B, worse than a missed refresh: `PSListController` computes section row counts from `_groups`, which `-createGroupIndices` rebuilds on the same path that was being bypassed. This pane's row count varies with the capability evidence, so a domain that changed size between appearances would have been read against stale group indices.
- Fix: a file-local `CCNMSetSpecifierID(PSSpecifier *, NSString *)` is now the only writer of `PSIDKey`, applied to the status, band, save, unavailable and group specifiers, including groups from `+groupSpecifierWithID:` which routes through the same empty setter. Model replacement goes through `-setSpecifiers:` via one `-commitRebuiltSpecifiers`; the sole remaining direct assignment is the `-specifiers` getter, which `PSListController` calls from inside its own `-viewDidLoad` before it runs `-prepareSpecifiersMetadata`, so using the setter there would re-enter the getter. `-refreshStatusAndSaveRows` no longer looks anything up: the pane holds weak references to the two rows it built, so a replaced model yields nil and skips the refresh rather than editing an object the table no longer shows. `-specifierForID:` no longer appears in the pane at all.
- Two defects found while confirming the above and folded in. The status row reported an untouched factory default as "not saved yet", pointing at a button that is correctly disabled because there is nothing to save; there are three states, so `BAND_STATUS_DEFAULT_FORMAT` was added to both localizations. And the comment justifying the re-check in `-saveBandSelection:` claimed a disabled `PSButtonCell` can still dispatch its action; `-[PSTableCell setCellEnabled:]` clears `userInteractionEnabled`, so it cannot. The guard stays, because the state it reads can change after the row was rendered, but the retracted reason is gone and a test pins its absence.
- Hypothesis: UI state that is written but not rendered is a refresh-path bug, and a refresh path that depends on framework-maintained indirection must not be used unless this project can show the framework maintains it on the path taken. Independent failure signals: an ID written through the property yet still unmatched, a rebuild through `-setSpecifiers:` that still leaves `_groups` stale, the held references resolving to an object the table does not show, or the new assertions passing against the shipped source.
- Evidence: pane tests 40/40, full host suite 405 passed with 3 Foundation-dependent skips, `verify_release_source.py` passed with empty `failures`/`forbidden`. Each of the six new assertions was verified red by reinjecting the specific defect it guards, one at a time against an untouched copy, and green after restoring: reverting one ID to `.identifier =`, assigning `_specifiers` directly in `-rebuildFromWorld`, refreshing through `-specifierForID:`, dropping the group ID write, collapsing the status text back to two states, and reinstating the retracted comment. Local `make` links both slices clean. Device validation of the three outcomes is outstanding: checkmark appears, status text tracks it, and 保存选择 becomes enabled.

## 2026-08-24 The save row could enable itself with no input: two different spaces were compared

- Found while investigating a device report that backgrounding Settings and re-entering the pane made it saveable. This is a separate defect from that report, confirmed by reading the code rather than inferred from it, and it is a data-integrity bug rather than a cosmetic one.
- `-reloadModel` seeds `workingSelection` with the stored selection narrowed to the current domain, and separately kept the raw stored array. `-workingSelectionDiffersFromSaved` compared those two, which are not in the same space: a stored band that has dropped out of the domain can never be in `workingSelection`, so the two arrays differ on arrival and the save row enables itself on a pane the user only looked at. Pressing it then rewrites the preference without the dropped bands, so an untouched pane can silently narrow a saved selection.
- The domain is the live active list narrowed by supported, so it shrinks on its own when the modem's active set changes. That is why re-entering the pane, which re-reads the domain, could flip the row on. Reachability requires a stored selection with at least one in-domain and one out-of-domain band; with the shipped single-band default the narrowed set is either equal or empty, and empty is refused by validation. So this is reachable only after a first successful multi-band save, which is why it did not show up before now.
- Fix: `savedSelection` is replaced by `baselineSelection`, defined as what the pane actually offered on this appearance, which is the same narrowed set `workingSelection` starts from. Both sides of the comparison are now canonical and confined to the current domain, so the question it answers is only "did the user change something here". The dropped bands remain reported in the group footer, whose text already states they will not be saved again, so a save that omits them is disclosed rather than silent.
- Hypothesis: an "is this edited" test must compare two values from the same space, and for this pane that space is the domain-narrowed set, not the durable record. Independent failure signals: the baseline seeded from the raw stored array, either operand re-sorted at the comparison (which would mean it is some other array), or the dropped-band footer disappearing while the narrowing stays.
- Evidence: pane tests 41/41, full host suite 406 passed with 3 Foundation-dependent skips, `verify_release_source.py` passed with empty `failures`/`forbidden`, local `make` links both slices clean. The new assertion was verified red twice against copies of the fixed file, once with the baseline seeded from `stored` (the shipped defect) and once with an operand re-sorted, and green after each restore.
- Not fixed here, still open: the reported trigger itself. Whether backgrounding Settings changes which rows are enabled, and what the reported garbled text is, are unresolved; the localization path cannot affect `-canSave`, so the two symptoms share only an upstream cause of Settings reloading the bundle. A screenshot of the garbled state was requested.

## Removal is no longer gated on a probe that cannot answer

- Device report: `dpkg` removal exited 73 with `removal blocked; the live band configuration could not be proven clean (error=The operation couldn't be completed. Permission denied)`, and the abort-remove rerun of `postinst` then reported `The installed launchd plist does not point at this install`. Two defects, one report.
- Root cause of the removal block: `CCNMEvaluateKnownOrphanEligibilityWithHeldLock` returns `conclusive = matched || observedValidBandInfo`, and `prerm` treated `!conclusive` as fatal. The probe reaches CoreTelephony, so it cannot succeed from a maintainer script: the guard links no libroothide and is exec'd through a bare path, so it receives neither roothide's path redirection nor its exemptions, both of which arrive through `basebin/bootstrap.dylib` via `DYLD_INSERT_LIBRARIES`. This is the same process-scoped restriction that already removed `posix_spawn` from this binary.
- The failure was localized by the shape of the message rather than by guessing. Every `CCNMCreateClient` failure path emits a fixed English literal (`CoreTelephonyClient is unavailable.` and the ABI-validation strings); the reported text is an `NSError.localizedDescription` for EACCES. So `dlopen`, `NSClassFromString`, `initWithQueue:`, and all three ABI validations passed, and the refusal came from the XPC call itself. The policy lock is separately excluded: its failure text is `Could not open the policy lock: ...`.
- A check that can only return "inconclusive" is an unconditional deny, not a safety mechanism, and it made the package impossible to remove on any device. `prerm` now warns and falls through to the durable records. The probe keeps its ability to convict: `eligible` is a positive detection and still blocks, and the call is unchanged, so an entitled or rootless guard starts working again with no further edit.
- Residual risk, stated rather than waived: on a device whose records are clean while the modem is secretly narrowed, removal now proceeds. It is bounded by what this package can narrow — `CCNMBuildBaselineRecord` refuses a baseline whose owned-band set is not exactly the NR key, so every other RAT array including the full LTE list is written back byte-identical. The worst case is an NR subset with LTE intact, which the reporting device has already shown keeps service, and a reinstall can still restore it.
- Second change on the same path: when the records say this package still owns a modified modem and the probe could not answer, `prerm` refuses and names the Settings restore instead of attempting `CCNMRecoverN78Preference`. The restore needs the access the probe just failed to get, and attempting it is not side-effect free — every failure path inside the recovery routine durably marks recoveryRequired/rebootRequired, and that marker keeps the removal guard armed, turning every later install into a half-configured package whose Settings UI can no longer perform the recovery the error demands. That is the trap the `upgrade` exemption already exists to avoid. Settings is confirmed working on the reporting device, so it is the owner named.
- Launchd contract defect: the plist ships bare on roothide because `launchctl` prepends the root on load, but `_patch_plist` writes the rewritten values back to disk and stamps `__Patched`. After the first successful load the file no longer holds what shipped, so any `postinst` run that does not unpack — plain `dpkg --configure`, and the abort-remove rerun after a blocked `prerm` — compared the rewritten file against the shipped spelling and reported a violation against a plist that was correct and already loaded. `CCNMVerifyMaintenanceLaunchdContract` now also accepts the install-prefix spelling, gated on `__Patched` being a true boolean, which is launchctl's own marker and is never written by this package. Both comparisons stay exact, so the doubled path this project shipped once and a prefix left from a previous jailbreak root both still fail; the latter correctly needs a reinstall rather than a load. On rootless both prefixes are `/var/jb`, so the two spellings coincide and nothing widens.
- Hypothesis: a gate must be able to return both verdicts, and a file that a foreign component rewrites in place has more than one correct spelling. Independent failure signals: an inconclusive probe still refusing, the unreachable-modem path reaching the restore call, the rewritten spelling accepted without the `__Patched` evidence, or either comparison relaxed to a suffix/containment test.
- Evidence: 409 host tests pass with 3 Foundation-dependent skips, `verify_release_source.py` passed with empty `failures`/`forbidden`, `git diff --check` clean, and both guards link for arm64 and arm64e locally (local arm64e ABI warning only, non-deliverable). Three new assertions were each verified red against copies of the fixed files — inconclusive restored to fatal, the unreachable-modem refusal deleted, the `__Patched` gate dropped, and an exact comparison relaxed to `hasSuffix:` — and green after each restore.
- Not fixed here: the guards still have no entitlements, so the live probe remains unavailable in dpkg context by construction rather than by accident. Whether an entitled guard is even possible on this jailbreak is unexamined. Device verification of both changes is pending, as is the band-selection pane acceptance that this report interrupted.

## 2026-08-27 1.6.2 review follow-up: recovery reachability and truthful state wiring

- Baseline: branch `feature/nr-band-selection-1.6.0`, source `fa8b305cad2fe3761b8c1257d75773e515c10e42`, clean worktree. Scope is the three P1 findings from the `94cc264...fa8b305` review; carrier-reset execution stays retired and the full-dictionary modem read-back remains the only write-success criterion.
- Hypothesis 1: a verified restore-cleanup checkpoint is safe to expose as an explicit recovery action after the baseline has been retired, because the action revalidates the recorded subscription and live complete BandInfo and performs no second setter call. Success means Settings can reach that owner with truthful cleanup-only wording. Independent failure signals are a button still gated solely by `baselineValid`, any cleanup path reaching `CCNMCallSetter`, or the UI claiming it will replay a baseline that no longer exists.
- Hypothesis 2: the maintenance decision is only bounded if a validated record from the same boot, policy generation, baseline, device, SIM and capability snapshot feeds its drop, verification, attempt and cooldown state back into the next decision. Success means one confirmed non-target drop creates one generation and the following identical refresh is truthfully `dropRecorded`, not another `correctOnce` and not `verificationPending` before any setter exists. Independent failure signals are carrying state across a new policy/baseline, trusting malformed record fields, claiming verification without a write, or `dropGeneration` increasing on repeated identical refreshes. Schema 2 deliberately rejects the schema-1 false-pending records created by the read-only prototype.
- Hypothesis 3: the durable applied-policy record proves a past write, while fresh `capabilityActiveNRBands` proves the current modem configuration. Success means Settings distinguishes current exact match, live drift and unavailable/stale live evidence without mutating policy-owner state. Independent failure signals are treating serving RAT/band as allowed-band evidence, rendering a mismatch as currently applied, or naming bands from malformed evidence.
- Ablations to pin before implementation: remove the cleanup summary key and the action must disappear; omit record feedback and the repeated-drop test must increment again; remove the live active-array comparison and the drift display test must fall back to the verified wording.
- Evidence plan: focused red/green tests for reverse restore, daemon wiring/record state and Settings copy; complete host suite; `scripts/verify_release_source.py`; Objective-C syntax/build gate where the host toolchain permits; `git diff --check`. No package, commit, push or device-success claim in this phase.
- Implementation result: the reader and controller expose a typed cleanup-checkpoint capability only for an earlier-boot, fully verified restore checkpoint with no baseline or transition files. Settings renders a cleanup-only action and warning that performs no second setter. The daemon feeds back only schema-2 records matching the exact boot/policy/baseline/device/SIM/capability context, discards a decision if that context changes before persistence, and records a first read-only candidate as `dropRecorded` rather than falsely claiming verification. The applied-policy row compares the durable target with fresh complete allowed-band evidence only when the sampled subscription UUID matches the policy UUID; it distinguishes current match, live drift and last-verified history.
- Final evidence: 422 host tests passed with 3 Foundation-dependent skips; focused red/green suites passed; `scripts/verify_release_source.py` returned `status: passed` with empty `failures` and `forbidden`; `py_compile` and `git diff --check` passed. A clean local aggregate `make all` against Theos iPhoneOS16.5 SDK compiled and linked every arm64/arm64e target, including the Settings bundle and maintenance daemon. The only linker diagnostics were the known local `incompatible arm64e ABI compiler` warnings, so these binaries remain compile evidence and are not deliverable.
- Residual gates: no device claim; cleanup-checkpoint UI, live drift rendering and daemon record rollover still need hardware validation. The review's narrow external TOCTOU window between final modem read-back and baseline deletion remains P2. No package, commit, push or cloud build was created.

## 2026-08-28 1.6.3: a version number that has left the building cannot be reused

- Defect: 1.6.2 was delivered twice with different contents. `fa8b305` was built, verified and handed to the user; `fe581b8` then closed the three review findings from the `94cc264...fa8b305` review, was built and verified under the same version number, and was never sent. Both packages report `1.6.2`, so the About row in Settings shows the same string for either one.
- Why that matters here specifically: all three of those fixes are device-verification items — the cleanup-checkpoint recovery entry, the live-drift wording, and the schema-2 record rollover. With one version number covering two different binaries, a device report cannot be attributed to a build, which makes the verification unfalsifiable rather than merely inconvenient.
- Why no gate caught it: every existing version check compares the three in-repo literals (`control`, `networkmanagerprefs/Resources/Root.plist`, `scripts/verify_release_source.py:RELEASE_VERSION`) against each other. They agreed both times. Self-consistency and unusedness are different properties, and only the first one was ever asserted.
- Fix, two parts. `docs/delivered-packages.json` records what has actually been handed over (version, source sha, run id, roothide sha256, size); a build that was made but not delivered is deliberately absent, which is why `fe581b8` is not in it. `tests/test_delivered_version_ledger.py` then asserts the release version is not in that ledger, is strictly above every delivered version, and still agrees with all three literals. Reusing a delivered number now requires editing the ledger, which is a reviewable act rather than an oversight.
- Hypothesis: the version gate must answer "has this number already shipped", not only "do the copies of it match". Independent failure signals, each verified red against the fixed tree and green after restore: the version returned to the delivered 1.6.2 (2 failures — delivered, and not moving forward), lowered to an unlisted-but-older 1.6.0 (1 — not moving forward), either `control` or `Root.plist` left behind alone (1 each — literals disagree), the ledger emptied (1 — an empty ledger silently disables the gate), and 1.6.2 listed twice (1 — the defect recorded instead of caught).
- Stated limitation, not waived: a delivery that is never added to the ledger leaves the gate inert for that number. The ledger starts at 1.6.1 because those are the packages whose bytes are still on hand to hash; earlier releases are not reconstructed from memory. The forward-progress assertion is what covers the unlisted older numbers.
- Evidence: 426 host tests pass with 3 Foundation-dependent skips (422 before, plus the 4 new ones, and `unittest discover` picks up the new module); `scripts/verify_release_source.py` returns `status: passed` with `version: 1.6.3` and empty `failures`/`forbidden`; `py_compile` and `git diff --check` clean. Byte-compiled caches were cleared before each mutation round, because a stale `scripts/__pycache__/verify_release_source.cpython-312.pyc` made one restored baseline read as still-failing.
- Not done in this entry: commit, push, cloud build, delivery. The three P1 fixes in `fe581b8` remain device-unverified; 1.6.3 is the build that will carry them to hardware.
