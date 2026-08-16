# Serving Cell Probe Repair

Baseline: `33e50597ce124bca4a2440ba3bb4800b586730be`

## Hypothesis

- CoreTelephony read-only telemetry is viable when selectors receive their actual iOS 15 argument type.
- Cell Monitor constants must be resolved by their C source names and treated as optional runtime evidence.
- Target-device discovery must preserve raw runtime classes, keys, values, and parse status instead of assuming the schema.
- The target iPhone14,3 / iOS 15.1.1 sample used `PID` and `UARFCN`; this is target-specific evidence, not an iOS-wide schema claim.
- A single NSA snapshot can miss a demand-activated NR secondary cell, so the read-only probe needs a short bounded sampling window.
- Async results are usable only after a completed wait; timeout, API error, missing slot, and persistence failure are independent failures.

## Success

- Public NR frequency range keeps the raw value and decodes only known `0`, `4`, `8`, and `12` values.
- Descriptor-only selectors receive a `CTServiceDescriptor` built from the slot-1 subscription context.
- Missing Cell Monitor symbols cannot cause nil-key dictionary access.
- The probe plist contains typed raw `legacyInfo` evidence plus optional parsed fields.
- Parsed output normalizes physical-cell ID and frequency while retaining each value's source key.
- Ten one-second Cell Monitor samples preserve independent raw evidence and aggregate only explicit serving-cell observations.
- Only 10/10 successfully parsed samples count as complete; any nonzero subset is an explicit partial result and does not produce a success UI.
- `nrServingCellObserved` remains false unless a sampled serving entry itself reports an NR RAT.
- Refresh/copy/RAT-selection timeouts are explicit and never reported as fresh success.
- Missing slot 1 or a failed plist write produces a failed UI result.
- All host tests pass, both architectures compile, and no new modem/RAT/band write path exists.

## Independent Failure Signals

- Any private selector is invoked with an object type contradicted by the iOS 15 runtime headers.
- Any unresolved symbol is used as a dictionary key.
- Any callback state is consumed after a timed-out wait.
- Any missing RAT field, `currentRat`, `activeBands`, or `supportedBands` causes an NR serving-cell inference.
- Raw runtime data is discarded because it does not match the expected dictionary schema.
- The UI reports success when slot 1, all ten Cell Monitor samples, or the output plist is unavailable.

## Ablations

- Unknown NR range (`1`) stays unknown; known Sub-6 (`4`) decodes as FR1.
- Missing Cell Monitor constants yield a `missingSymbols` list while raw evidence remains available.
- Refresh timeout prevents the result from being marked fresh and prevents stale parsing.
- A non-dictionary `legacyInfo` element is archived with its class and description.
- An iOS 15 LTE dictionary with only `PID`/`UARFCN` still yields normalized `physicalCellId`/`frequency` fields.
- An NRNSA device snapshot containing only an LTE serving entry keeps `nrServingCellObserved=false`.
- A nil serving RAT cannot become an NR match through a struct-return message to `nil`.
- One successful copy followed by a timeout classifies as partial, preserves both samples, and does not report overall success.

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
- [x] Add parser compatibility for the target device's observed raw `PID`/`UARFCN`/`DeploymentType` schema without weakening evidence; patched target output remains pending.
- [x] Replace the single Cell Monitor copy with a bounded 10-sample read-only window and per-sample evidence.
- [x] Re-run the independent sampling review after fixing partial-result classification; no actionable P0/P1/P2 remained.
- [ ] Build the fixed commit in the pinned Xcode 15.4 cloud workflow and verify both artifacts.

## Verification Evidence

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -s tests -p 'test_*.py'`:
  88 tests passed after the final partial-result fix.
- The host-compiled support test executes complete/partial/failed sampling states and nil/LTE/NR RAT classification rather than relying only on source-text assertions.
- Target-device evidence from the previous package: `currentRat` reported NR NSA
  while Cell Monitor returned only an LTE serving cell. The raw entry used `PID`,
  `UARFCN`, and numeric `DeploymentType`; no NR serving entry was present, so n78
  was not inferred from RAT state or allowed/supported bands. This proves the raw
  input shape only; `cellmonprobe2` symbol resolution and normalized output still
  require a new target-device run.
- `git diff --check`: passed; no added serving-probe line calls a band, RAT, or
  modem setter.
- Fresh rootless and roothide package builds both compiled and packaged after the
  final partial-result fix. The Linux toolchain emits `incompatible arm64e ABI compiler`
  for its arm64e slices, so neither local package is the final arm64e delivery source.
- The six tracked `tests/__pycache__/*.pyc` files introduced by the probe commit
  were removed, and `.gitignore` now prevents future bytecode from being tracked.
- `getPublicNrFrequencyRangeSync:` is guarded and called as `unsigned int(id *)`;
  its out object is archived as typed raw evidence rather than treated as an
  `NSError **`.
