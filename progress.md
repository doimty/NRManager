# Serving Cell Probe Repair

A/B implementation baseline: `8ccdd37654ea8746aa2e98167cae1159d8e16b9a`

## Hypothesis

- CoreTelephony read-only telemetry is viable when selectors receive their actual iOS 15 argument type.
- Cell Monitor constants must be resolved by their C source names and treated as optional runtime evidence.
- Target-device discovery must preserve raw runtime classes, keys, values, and parse status instead of assuming the schema.
- The target iPhone14,3 / iOS 15.1.1 sample used `PID` and `UARFCN`; this is target-specific evidence, not an iOS-wide schema claim.
- A single NSA snapshot can miss a demand-activated NR secondary cell, so the read-only probe needs a short bounded sampling window.
- The target run returned ten distinct `CTCellInfo` objects with one canonical payload, so a same-run A/B must compare one refresh followed by repeated copies against refresh-before-each-copy.
- Async results are usable only after a completed wait; timeout, API error, missing slot, and persistence failure are independent failures.

## Success

- Public NR frequency range keeps the raw value and decodes only known `0`, `4`, `8`, and `12` values.
- Descriptor-only selectors receive a `CTServiceDescriptor` built from the slot-1 subscription context.
- Missing Cell Monitor symbols cannot cause nil-key dictionary access.
- The probe plist contains typed raw `legacyInfo` evidence plus optional parsed fields.
- Parsed output normalizes physical-cell ID and frequency while retaining each value's source key.
- Two five-sample phases preserve independent raw evidence: Phase A performs one refresh, while Phase B refreshes before every copy.
- Every attempted refresh and copy records bounded wait/timing/error evidence with phase and sample identity; every omitted planned operation has an explicit count, sample index, and reason.
- Attempted, callback-completed, API-succeeded, and parsed copy counts remain distinct. Only 6/6 successful refresh callbacks and 10/10 successful, non-nil, parsed copies count as complete. A nonzero parsed subset is partial; zero parsed copies is failed.
- `nrServingCellObserved` remains false unless a sampled serving entry itself reports an exact Cell Monitor NR/NRNSA RAT. The companion status is tri-state: `observed`, `notObservedComplete`, or `indeterminatePartial`.
- A/B payload output is descriptive only. It may report normalized serving payload equality or change, but never claims that Phase B is fresher or that refresh caused a change.
- Refresh/copy/RAT-selection timeouts are explicit and never reported as fresh success.
- Missing slot 1 or a failed plist write produces a failed UI result.
- All host tests pass, both architectures compile, and no new modem/RAT/band write path exists.

## Independent Failure Signals

- Any private selector is invoked with an object type contradicted by the iOS 15 runtime headers.
- Any unresolved symbol is used as a dictionary key.
- Any callback state is consumed after a timed-out wait.
- Any missing RAT field, `currentRat`, `activeBands`, or `supportedBands` must not cause an NR serving-cell inference or allow an incomplete window to be reported as a complete negative.
- Raw runtime data is discarded because it does not match the expected dictionary schema.
- The UI reports success when slot 1, any of the six required refreshes, all ten Cell Monitor samples, or the output plist is unavailable.
- A timed-out refresh/copy is followed by another private API request while its late callback may still be outstanding.
- A callback mutates report state directly, outlives stack-owned state, or is consumed more than once.
- Concurrent serving-cell and Band operations can run in the same Preferences process.

## Ablations

- Unknown NR range (`1`) stays unknown; known Sub-6 (`4`) decodes as FR1.
- Missing Cell Monitor constants yield a `missingSymbols` list while raw evidence remains available.
- Refresh timeout prevents the result from being marked fresh and prevents stale parsing.
- A non-dictionary `legacyInfo` element is archived with its class and description.
- An iOS 15 LTE dictionary with only `PID`/`UARFCN` still yields normalized `physicalCellId`/`frequency` fields.
- An NRNSA device snapshot containing only an LTE serving entry keeps `nrServingCellObserved=false`.
- A nil serving RAT cannot become an NR match through a struct-return message to `nil`.
- One successful copy followed by a timeout classifies as partial, preserves both samples, and does not report overall success.
- Refresh policy planning yields one refresh for five Phase A copies and five refreshes for five Phase B copies.
- A Phase A API error may leave Phase B independently observable, while any timeout aborts the whole A/B to prevent overlapping late callbacks.

## Evidence Plan

1. Red/green host tests for each behavior slice.
2. Full Python test suite with bytecode generation disabled.
3. Theos arm64 + arm64e compile and package smoke check.
4. Diff audit for write selectors, generated artifacts, whitespace, and ABI warnings.
5. Cloud build and device LTE/NSA/SA validation only after the local repair is complete.

## Progress

- [x] Review baseline and lock findings.
- [x] Correct NR frequency range decoding and preserve the `id *` out value.
- [x] Correct descriptor construction and selector arguments.
- [x] Make Cell Monitor symbol resolution nil-safe.
- [x] Preserve typed raw runtime evidence.
- [x] Make async timeout and persistence outcomes fail explicitly.
- [x] Run full host tests and clean arm64/arm64e package builds.
- [x] Complete the initial parser diff review; no actionable P0/P1 was found.
- [x] Add parser compatibility for the target device's observed raw `PID`/`UARFCN`/`DeploymentType` schema without weakening evidence; patched target output is device-verified.
- [x] Replace the single Cell Monitor copy with a bounded 10-sample read-only window and per-sample evidence.
- [x] Re-run the independent sampling review after fixing partial-result classification; no actionable P0/P1/P2 remained.
- [x] Build the fixed commit in the pinned Xcode 15.4 cloud workflow and verify both artifacts.
- [x] Validate `cellmonprobe2` on the target: 20/20 symbols resolved, 10/10 samples completed, and normalized PID/UARFCN/numeric DeploymentType output matched the raw evidence.
- [x] Add red tests for two-phase refresh planning, per-attempt evidence, strict completion, and timeout/exception abort behavior.
- [x] Implement the read-only 5+5 A/B and bump the diagnostic package to `cellmonprobe3`.
- [x] Add one-shot strong callback holders, strict four-stage counts, exact not-attempted evidence, tri-state NR output, descriptive payload comparison, and mutual exclusion with Band operations.
- [x] Run focused/full tests, both local package schemes, and a write-path diff audit.
- [x] Complete the A/B design review and incorporate its P0/P1/P2 requirements.
- [x] Resolve the independent final-review findings: duplicate slot-1 iteration, RAT-selection timeout overlap, and missing critical-symbol false completeness.
- [x] Build and verify cloud artifacts with the pinned Xcode 15.4 workflow.
- [x] Validate `cellmonprobe3` on the target: complete 6-refresh/10-copy A/B, explicit NR n78 serving entries, and no timeout, exception, parse, symbol, or safety-latch failure.

## Adaptive Sampler Refactor (2026-08-17)

### Hypothesis

- The successful target trace is enough to retire the diagnostic fixed-order A/B from the product path: each useful sample should use one bounded `refreshCellMonitor` + settle + `copyCellInfo` attempt.
- A bounded adaptive window can stop after an explicit NR serving payload is confirmed twice consecutively, while a non-NR result requires the full window before it can be classified as a complete negative observation.
- Moving Cell Monitor symbol resolution, typed raw parsing, asynchronous attempt ownership, and sampling aggregation behind one module interface will reduce controller/UI risk without changing the evidence contract.

### Success And Failure Signals

- Success: one sampler call returns a schema-versioned report with a maximum of 10 planned refresh/copy pairs, exact attempted/completed/API-success/parsed counts, typed raw evidence, explicit omitted-operation indexes and reasons, and exact serving-entry NR classification.
- Success: two consecutive parsed samples containing explicit Cell Monitor NR/NRNSA serving entries stop the window early with `explicitNRConfirmed`; otherwise all 10 parsed pairs are required for `windowExhausted` and a complete negative observation.
- Failure: timeout or invocation exception aborts the run and arms the existing unsafe-outstanding latch until its late callback resolves; ordinary callback/parse failures remain recorded and may continue within the fixed global bound.
- Failure: any early stop caused by LTE payload stability, `currentRat`, `activeBands`, `supportedBands`, or missing RAT data would turn an incomplete window into a false negative.
- Failure: extraction changes any Band/RAT/modem setter path, loses raw runtime types, drops ABI guards, or permits UI/controller code to issue refresh/copy directly.

### Ablations And Evidence Plan

- NR on samples 0 and 1 stops after two pairs; NR interrupted by LTE resets confirmation; LTE-only runs consume all 10 pairs.
- A recoverable refresh failure omits that pair's copy with an explicit reason and continues; a timeout or invocation exception omits every later planned operation and stops.
- Missing critical classification symbols or structurally unclassifiable entries preserve raw evidence but prevent parsed success and complete-negative classification. A serving entry with missing or non-string RAT still consumes the full window, but keeps the result indeterminate rather than producing `notObservedComplete`; missing RAT on non-serving entries does not invalidate the window.
- Host C tests exercise the adaptive stop reducer and completion classifier; Python source tests enforce module ownership, schema/evidence keys, no write selector, and Makefile inclusion.
- Verification requires focused/full host tests, host header compilation, rootless and roothide compile/package smoke checks, `git diff --check`, and a source audit for forbidden setters.

### Progress

- [x] Lock the existing branch, source, target evidence, and dirty-worktree baseline.
- [x] Add red tests for adaptive stop/completion behavior and independent module ownership.
- [x] Extract the Cell Monitor parser, async attempts, and adaptive aggregation into the sampler module.
- [x] Replace controller-owned fixed A/B orchestration with one sampler call and update the UI/result schema.
- [x] Run focused/full host tests and local rootless/roothide compile checks.
- [x] Audit the diff for write-path changes, generated artifacts, warnings, and documentation drift.
- [x] Resolve independent final-review findings, if any.
- [x] Build the committed sampler in the pinned cloud environment and verify the release artifacts.
- [x] Validate the schema-v4 adaptive result from the target device.

## Verification Evidence

- Adaptive sampler final source checks on 2026-08-17: focused serving-cell suite `15/15`; full host suite `92/92`; `git diff --check` clean. Production-source scans found no old fixed A/B identifiers, no direct refresh/copy invocation in the controller, no Band/setter selector in the sampler, and no `currentRat`/`activeBands`/`supportedBands` sampler inference.
- Final local compile/package smoke checks passed for rootless with explicit Theos iPhoneOS 16.5 SDK and for roothide. Package SHA256 values: rootless debug smoke package `3dd22311dec06b1d0a4c803c3dd0cb882886b16f75266928c7f372fa05fd8b52`; roothide debug smoke package `5f2408bd0787019dfb5a8c7a330256bf3a16e1f73bf970c4d47184328e19ff95`. Both package variants contain `arm64 + arm64e` slices and `LC_DYLD_INFO_ONLY` in both binaries; packaged plists parse and expose `Sample Serving Cell` with no A/B label or legacy operation string.
- Independent current-worktree review found no P0/P1 and one P2: structurally unclassifiable entries, including serving entries without a classifiable RAT, could count toward a complete negative. The parser now rejects non-dictionary entries, entries without a string Cell Monitor cell type, and serving entries without a string RAT from the clean-window count while preserving typed raw evidence. The sampler still exhausts the window for these recoverable parse failures. Focused re-review marked the finding resolved and reported no new P0/P1/P2.
- Committed source `1ab1162782050fc5cfef38b1a4bed57478b23dfa` built successfully in GitHub Actions run `31992579209` from branch `diagnostic/serving-cell-ios15`. The nonempty log confirms macOS 14, Xcode 15.4 (`15F31d`), Apple clang 15.0.0, ld `1053.12`, and the Xcode iPhoneOS 17.5 SDK. It contains no compiler/linker error and no `incompatible arm64e` warning.
- Cloud package SHA256 values: rootless `b7e59bff6e8447d98255817de46a9f0c4d15e3e2e0c42163c4fbbb6ef6a1f1b6`; roothide `ee6d44bba637df7f353319cec3fca8a2c0742f50203131a2701f66d7dce25f0b`. Both contain `arm64 + arm64e`, valid package plists, `Sample Serving Cell`, adaptive-operation markers, malformed-entry evidence fields, and no legacy A/B operation marker.
- The roothide artifact is the target delivery candidate. Both of its arm64e slices are `ARM64 E USR00`, target iOS 14.0 with SDK 17.5, use `LC_DYLD_INFO_ONLY`, and link `@loader_path/.jbroot/usr/lib/libroothide.dylib`. Per-architecture load-command sequences and linked-library lists match the device-verified `cellmonprobe3` artifact from run `31979975939`; the normalized 31-line warning set also matches that baseline exactly.
- Target-device schema-v4 evidence SHA256 `ee7b1353eca0b142424eba549307781fb1a845c250d8b4d533b7fbb2d10e57e3` parsed as a valid 74,128-byte plist with no malformed dictionary or duplicate key. The corrected verifier passed 65/65 checks: 2/2 refresh/copy/callback/API/parse successes, `explicitNRConfirmed`, complete status, exact 16-operation omission ledger for samples 2...9, no timeout/exception/failure/missing symbol, and no structurally invalid entry.
- Both explicit serving entries are identical n78 evidence: exact Cell Monitor NR RAT, Band 78, bandwidth 100, NRARFCN 633984, GSCN 7853, PID/physicalCellId 622, Cell ID 19866992645, TAC 4849750, MCC/MNC 460/1. NRARFCN and GSCN independently resolve to 3509.760 MHz. The result is not inferred from active/supported bands or coarse RAT state.
- Residual evidence limitation: schema v4 records slot/subscription/SIM state but not hardware model, system version, or build. The plist is valid target-run evidence in the controlled device context, but it cannot independently prove `iPhone14,3 / 15.1.1 / 19B81` without that external context.
- The local linker emitted the known `incompatible arm64e ABI compiler` warning (plus roothide's existing deprecated `-undefined dynamic_lookup` warning). Those local packages remain compile evidence only and are superseded for delivery by the verified cloud roothide artifact above.

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`:
  92 tests passed for `cellmonprobe3`; the focused serving-cell suite passed 15/15.
- The host-compiled support test executes the 1+5 refresh policy, strict 6/6 refresh plus
  10/10 copy completion rule, complete/partial/failed states, wait outcomes, and nil/LTE/NR
  RAT classification rather than relying only on source-text assertions.
- The A/B source records two 5-sample phases and separately tracks planned, attempted,
  callback-completed, API-succeeded, parsed, and not-attempted operations. Each attempt has
  one-shot strong callback state, wall-clock correlation, monotonic timing/latency, wait result,
  status, typed payload/error/exception evidence, and phase/sample identity. RAT selection uses
  the same one-shot holder and unsafe-outstanding latch as Cell Monitor. Any private async timeout
  or invocation exception aborts all later CoreTelephony calls; ordinary callback/parse failures
  preserve evidence and continue where later samples are independent. Phase B uses a 0.5-second pre-refresh delay
  and a 0.5-second settle delay; actual monotonic timings are retained because fixed A-then-B
  ordering and refresh latency prevent a causal freshness claim.
- Static method-scope audit found zero band/RAT/modem setter calls in
  `showServingCellProbe:`; its only file write persists the diagnostic plist. The first matching
  slot-1 context stops subscription enumeration, so duplicate runtime contexts cannot exceed the
  global 6-refresh/10-copy bound. A process-local gate excludes re-entry and overlap with Band
  write/recovery/manual-restore operations, including late callbacks after timeout.
- Missing `kCTCellMonitorCellType`, `kCTCellMonitorCellTypeServing`, or
  `kCTCellMonitorCellRadioAccessTechnology` preserves typed raw evidence but makes every sample a
  parse failure, leaving comparison ineligible and NR status `indeterminatePartial`.
- Fresh local rootless and roothide `cellmonprobe3` packages both compiled and packaged.
  The Linux toolchain again emitted `incompatible arm64e ABI compiler`, so these packages
  remain compile-only smoke artifacts and must not be delivered.
- Target `cellmonprobe2` evidence SHA256
  `23a8488b021a3e9121e76a5d3c4ba02d68f902397bc90fbab257b23630d64c9d`:
  sampling was complete (10 requested/completed/successful); all 20 symbols resolved
  with no missing symbols; numeric `DeploymentType=2`, `physicalCellId=191` from
  `kCTCellMonitorPID`, and `frequency=1600` from `kCTCellMonitorUARFCN` matched raw
  evidence. `currentRat` reported NR NSA while all ten serving entries reported LTE,
  so `nrServingCellObserved=false`; n78 was not inferred from active/supported bands.
- The ten copies returned ten distinct `CTCellInfo` object addresses but one canonical
  payload over 9.567 seconds. An older run 6233 seconds earlier had a different Cell
  ID/PID, proving the data is not frozen across runs, but within-window freshness
  remains unresolved between stable radio state and a repeatedly copied cache.
- `git diff --check`: passed; no added serving-probe line calls a band, RAT, or
  modem setter.
- Fresh rootless and roothide package builds both compiled and packaged after the
  final partial-result fix. The Linux toolchain emits `incompatible arm64e ABI compiler`
  for its arm64e slices, so neither local package is the final arm64e delivery source.
- Pinned cloud run `31957880916` built source commit
  `8d5d3e20b9499ee7ce039a04d5dd23252a138d6a` successfully on `macos-14` with
  Xcode 15.4 (`15F31d`), Apple clang 15.0.0, ld 1053.12, and the Xcode iPhoneOS
  17.5 SDK selected. The rootless step explicitly used the Theos
  `iPhoneOS16.5.sdk` bundle (whose Mach-O metadata records SDK 16.4); roothide
  used the Xcode system SDK 17.5.
- Cloud logs contain no `incompatible arm64e`, compiler error, or link failure.
  Both roothide binaries are arm64+arm64e, arm64e is `ARM64 E USR00`, both slices
  use `LC_DYLD_INFO_ONLY`, and both binaries load
  `@loader_path/.jbroot/usr/lib/libroothide.dylib`.
- Cloud artifacts: rootless ID `9266453088`, package SHA256
  `d42ac01202d3a4c509728dcabf239738c30ebfcab9d40bb57429c55a094c7686`;
  roothide ID `9266453177`, package SHA256
  `86bce24e0048ae2cdb640acc52af4fb872576613dfffaf8825a93d1c08d331db`.
- Target `cellmonprobe3` evidence SHA256
  `323e9df9617a88196e4e0a93f33eb11b819f37a6025c8099f38d51bc70a57bc8`:
  schema v3 completed all 6 refreshes and 10 copies/parses with no failure. Phase A's
  five payloads and Phase B sample 0 were the same LTE B3/UARFCN 1600 serving cell;
  Phase B samples 1-4 explicitly reported NR Band 78, NRARFCN 627264, GSCN 7783.
  NR samples changed from PID/physicalCellId 179 and Cell ID 19865165826 to PID/physicalCellId 37 and
  Cell ID 19879297025, while channel and TAC stayed fixed, capturing an n78 cell
  transition rather than an object-address-only change.
- The trace proves explicit n78 serving telemetry is available without a modem/Band
  write and strongly associates repeated refresh with exposing the NR snapshot.
  Fixed A-then-B ordering remains time-confounded, so strict refresh causality would
  require a counterbalanced or randomized follow-up; that caveat does not weaken the
  observed n78 serving evidence.
- The six tracked `tests/__pycache__/*.pyc` files introduced by the probe commit
  were removed, and `.gitignore` now prevents future bytecode from being tracked.
- `getPublicNrFrequencyRangeSync:` is guarded and called as `unsigned int(id *)`;
  its out object is archived as typed raw evidence rather than treated as an
  `NSError **`.

## 2026-08-17 LTE B1 release-gate correction

- Baseline remains `272b1ae56b919de53bad723ff81b62e1deb6b972` on
  `diagnostic/lte-b1-lock-ios15`; the LTE B1 implementation is still uncommitted.
- The pre-fix host suite passed 112 tests, but two independent read-only reviews did
  not both return GO, so no commit, cloud build, or package delivery was started.
- Review triage found the removed n78 write UI to be intentional scope, not a
  regression: this single-purpose package exposes B1 instead, while legacy n78
  helpers and recovery validators remain covered.
- The sampler unsafe-outstanding flag is being strengthened to a counted latch so
  overlapping future attempts cannot let one late callback clear another attempt's
  fail-closed gate.
- A real recovery-lifecycle gap remains: successful B1 automatic restore removes
  only the setter marker, and a failure after snapshot creation but before the
  setter can leave orphan recovery state. Release success now requires exact
  cleanup of all B1 records after verified restore, plus exact cleanup of records
  created by an attempt whose setter is provably never called.
- Independent failure signals: no recovery record may be removed after a setter
  call, timeout, exception, unresolved async callback, or unverified restore; a
  changed/foreign record must fail cleanup and remain preserved.
- Evidence plan: add red model/static tests for counted outstanding attempts and
  both cleanup authorizations, apply the minimal implementation, run the full host
  suite and diff checks, then repeat both release-gate reviews before any build.

## 2026-08-17 LTE B1 current-tree closure

- The counted Cell Monitor unsafe-outstanding latch, full-window LTE B3/B1 sampler,
  exact LTE `[1]` payload, setter/restore interlocks, and complete recovery-record
  cleanup are implemented in the uncommitted working tree.
- All three exposed write flows now retire snapshot, intent, and setter records only
  through the same durable verified-restore cleanup handoff. Failures before the
  setter use that handoff only while the exact records still match and the setter is
  provably uncalled; timeout, exception, changed-record, and incomplete-observation
  paths preserve evidence and remain fail-closed.
- Manual recovery now retires an exact validated earlier-boot restore marker when a
  fresh live read already equals the snapshot, without issuing another modem setter.
- Markerless legacy n78 snapshot+intent state is clearable only when the old n78
  result binds the same generation and subscription; exact original, supported,
  requested, immediate-read-back, observation-end, and restore-read-back
  dictionaries; coherent request/original/effect flags; a complete nested restore
  phase with both markers retired; strictly ordered timestamps; and final pass
  state, followed by another exact live-snapshot read. All contradictory, stale,
  malformed, or other markerless states remain blocked.
- Fresh host verification is 132/132 tests passing, and `git diff --check` is clean.
  Local rootless and roothide package builds both compile successfully as smoke
  evidence. Both local arm64e links still emit `incompatible arm64e ABI compiler`,
  so neither local package is deliverable.
- A fresh independent safety/standards review of the final tree returned GO. A
  subsequent spec review found that the first markerless-n78 migration validator
  over-relied on booleans; the exact dictionary, nested restore-phase, and timestamp
  bindings above were added, and a focused current-tree re-review then returned GO.
  No independent review has a remaining P0/P1/P2.
- No commit, push, cloud build, or package delivery has been performed. The next
  release gate is an explicit commit/push followed by the pinned macOS 14 / Xcode
  15.4 / iPhoneOS 17.5 cloud build and artifact inspection.
