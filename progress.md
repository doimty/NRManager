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
- Any missing RAT field, `currentRat`, `activeBands`, or `supportedBands` causes an NR serving-cell inference.
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
- [ ] Build and verify cloud artifacts with the pinned Xcode 15.4 workflow.

## Verification Evidence

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
- A follow-up read-only A/B remains necessary to distinguish within-window payload
  freshness: one initial refresh plus repeated copies versus refresh-before-each-copy.
  Capturing an explicit NR serving entry under confirmed sustained traffic also remains open.
- The six tracked `tests/__pycache__/*.pyc` files introduced by the probe commit
  were removed, and `.gitignore` now prevents future bytecode from being tracked.
- `getPublicNrFrequencyRangeSync:` is guarded and called as `unsigned int(id *)`;
  its out object is archived as typed raw evidence rather than treated as an
  `NSError **`.
