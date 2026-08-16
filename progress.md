# Serving Cell Probe Repair

Baseline: `33e50597ce124bca4a2440ba3bb4800b586730be`

## Hypothesis

- CoreTelephony read-only telemetry is viable when selectors receive their actual iOS 15 argument type.
- Cell Monitor constants must be resolved by their C source names and treated as optional runtime evidence.
- Target-device discovery must preserve raw runtime classes, keys, values, and parse status instead of assuming the schema.
- Async results are usable only after a completed wait; timeout, API error, missing slot, and persistence failure are independent failures.

## Success

- Public NR frequency range keeps the raw value and decodes only known `0`, `4`, `8`, and `12` values.
- Descriptor-only selectors receive a `CTServiceDescriptor` built from the slot-1 subscription context.
- Missing Cell Monitor symbols cannot cause nil-key dictionary access.
- The probe plist contains typed raw `legacyInfo` evidence plus optional parsed fields.
- Refresh/copy/RAT-selection timeouts are explicit and never reported as fresh success.
- Missing slot 1 or a failed plist write produces a failed UI result.
- All host tests pass, both architectures compile, and no new modem/RAT/band write path exists.

## Independent Failure Signals

- Any private selector is invoked with an object type contradicted by the iOS 15 runtime headers.
- Any unresolved symbol is used as a dictionary key.
- Any callback state is consumed after a timed-out wait.
- Raw runtime data is discarded because it does not match the expected dictionary schema.
- The UI reports success when slot 1, Cell Monitor data, or the output plist is unavailable.

## Ablations

- Unknown NR range (`1`) stays unknown; known Sub-6 (`4`) decodes as FR1.
- Missing Cell Monitor constants yield a `missingSymbols` list while raw evidence remains available.
- Refresh timeout prevents the result from being marked fresh and prevents stale parsing.
- A non-dictionary `legacyInfo` element is archived with its class and description.

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
- [x] Complete the independent final diff review; no actionable P0/P1 was found.

## Verification Evidence

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -s tests -p 'test_*.py'`:
  86 tests passed.
- `git diff --check`: passed; no added serving-probe line calls a band, RAT, or
  modem setter.
- Fresh arm64 package build: passed; both `NetworkManager` and
  `NetworkManagerPrefs` objects contain arm64 only.
- Fresh arm64e package build: compiled and packaged, but the local toolchain still
  emits `incompatible arm64e ABI compiler`; this artifact is not deliverable.
- The six tracked `tests/__pycache__/*.pyc` files introduced by the probe commit
  were removed, and `.gitignore` now prevents future bytecode from being tracked.
- `getPublicNrFrequencyRangeSync:` is guarded and called as `unsigned int(id *)`;
  its out object is archived as typed raw evidence rather than treated as an
  `NSError **`.
