# NR band selection (1.6.0) — implementation plan

Status: plan only. No code written yet. Supersedes nothing in 1.5.0; 1.5.0 remains the shipping line. Its dual-SIM write path is confirmed working on the reporting device; three of the four retest steps are still unreported. See "Sequencing".

Scope decision: **NR only.** LTE and the other four RAT arrays stay untouchable in this version. Restricting NR is safe because LTE remains the fallback, which is the entire safety argument the 1.5.0 feature rests on. Opening LTE removes that fallback and needs a runtime confirm-or-auto-rollback mechanism that does not exist yet; that is a separate version.

Second scope decision, from grilling this plan: **no new policy operation.** The write path, the record shapes and the state machine are untouched. What changes is which NR array the existing enable path writes, and where that array comes from.

## What the user gets

The existing switch keeps its meaning: on = a pinned NR set is applied, off = the original six-RAT table is restored. A new child pane lists the NR bands available on this modem and lets the user check the ones to keep. Applying happens through the existing switch, so there is exactly one way to write to the modem.

Turning the switch on with no prior selection applies `[78]`, which is byte-for-byte the current 1.5.0 behaviour. Existing users see no change until they open the pane.

Changing a selection while enabled means switching off, editing, switching on. See "Editing a selection" below for why that is the design rather than a limitation.

## Why this is a generalisation, not a rewrite

Five properties of the 1.5.0 design already anticipate a set instead of a constant:

- The setter always writes the complete six-RAT dictionary. NR is one key in it; nothing about the write is n78-specific.
- `baseline.activeBands` stores the complete original table, and `baseline.modifiedBandKeys` is already a *set* pinned to exactly `[CCNMNRKey]`. Owning "the NR key" is the invariant, not owning "band 78".
- Restore replays `baseline.activeBands[NR]` exactly and keeps live non-NR arrays (`CCNMValidateRestorePayloadLocal`). It never inspects which NR bands were pinned, so **restore needs no change at all.**
- Disable removes the baseline record after a verified restore, and enable refuses to run while one exists. That pairing is what makes editing expressible as an off/on round-trip with no new operation.
- The state proof field is already named `targetNRBands` and already holds an array (`@[ @78 ]`). Every *stable enabled* install therefore already carries the correct field with the correct value.

The last point removes the migration entirely. See "Records" below.

## The one safety rule that must not be relaxed

**A selection may only narrow, never expand.** 1.5.0 only ever removes entries from a list iOS had already accepted. That is what makes the operation defensible without per-carrier knowledge. Adding a band iOS had not enabled is a different operation with no evidence behind it, and it cannot be validated locally, because whether it is safe depends on the carrier's deployment.

### The domain is an intersection, not the original active list

The legal domain is fresh active NR ∩ fresh supported NR. Neither side alone is right, and this is not a theoretical refinement — the reference-device evidence in the tree makes it concrete. `CCNMKnownOrphanHistoricalOriginalBands()` has **46** NR entries while `CCNMKnownOrphanHistoricalSupportedBands()` has **19**; on that device supported NR is a strict subset of active NR, so the intersection is exactly those 19. The code documents in `CCNMValidateBaselineCompatibility` that an active list is *not required* to be a subset of supported ("Do not require saved active NR to be a subset of supported NR."), so the intersection must be computed rather than assumed to equal either side.

So:

- Offering the active list alone would list 46 bands on that device, 27 of which the modem does not report as supported, and would let the user pin a band that can never carry traffic.
- Offering the supported list alone would offer bands iOS never had enabled, which is the expansion this section forbids.

That asymmetry does not conflict with `CCNMBaselineNRBandsFitCurrentCapability`, which does require a subset relation but between *saved supported* and *current supported* — it never inspects an active list, so it places no constraint on the domain.

The intersection is both safe and meaningful. It also matches what the shipped code already does for one band: `CCNMBuildN78Payload` requires 78 in *both* fresh active and fresh supported.

Because editing is a toggle round-trip, an enable always starts from the off state, where live active NR *is* the original list. So the domain is always computed from the fresh pre-write read and never needs to consult a stored baseline. The settings pane shows the same intersection; while the feature is on, it must label the checkmarks as the applied set and read the domain from the baseline, since live active NR is then the narrowed set.

## Other decisions taken

- **Empty selection is refused in this version.** `NR = []` means "no 5G at all". It is arguably the safest possible selection, but it is a different feature with a different name and it makes the switch's on/off semantics ambiguous. Non-empty subset only. A deliberate "disable 5G" affordance can come later.
- **A selection equal to the whole domain is refused**, pointing at the switch instead. Pinning everything iOS already allowed is what "off" means; performing it as a modem write would spend a write, a crash window and a baseline for no change in behaviour.
- **A selection equal to the live NR array is refused as a no-op.** This generalises the current `isEqualToArray:@[ @78 ]` guard, which exists for the same reason. With the whole-domain rule above it is nearly the same check at enable time; both are kept because the payload builder is also reachable from the intent validators, where live and domain are not necessarily equal.
- **A crashed enable recovers to the baseline.** Unchanged from today. The practical effect for an edit is that a crash mid-apply leaves the feature off; the stored selection survives in preferences, so it can be retried.
- **Each apply is a real modem write.** It carries the same 20-second setter deadline and the same uncertain-outcome handling as today's toggle, so the pane must gate its apply action on `mayWrite` exactly as the switch does at `CCNMRootListController.m:278`.
- **One write per apply, not one per checkbox.** The pane accumulates a pending selection in memory. Tapping a band must not touch the modem. Per-tap writes would burn the same-boot write budget and multiply the crash window by the number of taps.
- **Symbols and filenames keep their `CCNMN78Policy*` names.** Renaming touches every file in the bundle, the daemon, both guards and every test for no behavioural gain, and the diff would bury the real change. Only user-visible strings change.
- **`requestedMode` keeps the on-disk value `n78Preferred`.** It becomes a slightly misnamed identifier for "an NR subset is pinned". Renaming it would invalidate every existing state record and force a migration branch, and backward-compatibility branches are this project's demonstrated test blind spot. One shape with a stale name beats two shapes.
- **Version 1.6.0.** Feature addition on a shipped line.

## Records

No schema bump. No migration code. No `schemaVersion: 2`. No new operation.

| Record | Change |
| --- | --- |
| `baseline` | none |
| `intent` | none |
| `inFlight` | none |
| `state` | `proof.targetNRBands` becomes authoritative user data instead of a derived constant, and gets validated |

`CCNMValidateStateRecord` currently does not inspect the proof dictionary at all. It must now require `proof.targetNRBands` to be a non-empty array of unique positive integers, **but only for a stable enabled record** — that is, when `requestedMode == n78Preferred` *and* `appliedPolicy == verifiedN78Only`. The daemon compares live NR against the recorded selection, and only a verified-enabled record has a selection in effect.

The obvious wider condition (`requestedMode != systemDefault`) is wrong and would strand users. `CCNMFinishSystemDefaultState` writes a disable checkpoint that carries the pre-disable `requestedMode` (`n78Preferred`) with `appliedPolicy = applying` / `recoveryState = restorePending`, and its proof deliberately contains no `targetNRBands` (`CCNMN78PolicyController.m:2445`). Under the wider rule, any crash mid-disable would leave a state record that fails validation, and `performEnable` refuses outright when `stateExists && !CCNMValidateStateRecord` — turning a recoverable state into an unusable one. Transitional records must stay valid without the field.

Hazard to respect: any in-memory normalisation of a loaded record must not leak into the writer paths. `CCNMReplaceExpectedRecord` compares an expected dictionary against what is on disk; handing it a normalised copy would fail the exact-compare. The plan avoids normalisation entirely, which is the main reason to keep the old mode string.

## Editing a selection: toggle round-trip, not a new operation

An earlier draft of this plan added a fourth operation, `reselect`, to change the selection in place while enabled. **Dropped.** Editing means: turn the switch off, change the checkmarks, turn it back on.

The reason is not effort. `performEnable` hard-refuses when a baseline exists (`CCNMN78PolicyController.m:2657`), so `reselect` cannot reuse it; it would be a fourth write path with its own preflight, its own branch in both mirrored intent validators, its own entry in four operation-domain literals, and its own crash-recovery semantics. Every one of those is a place for the multi-band change to diverge from the paths that have device evidence.

The round-trip is better on the invariant that matters. `performRestoreOperation` removes the baseline record after a verified restore (`CCNMN78PolicyController.m:2469`), and the restore replays `baseline.activeBands` exactly. So the next enable reads a fresh active table that is byte-identical to the old baseline's, and captures a new baseline equal to the old one. **The "baseline is captured once from the true original" invariant therefore holds by construction, not by a new rule that a future edit could break.** With `reselect` it would have depended on a hand-written guard plus a test.

Cost: two modem writes per edit instead of one, and the phone passes through the full original band list in between. That intermediate state is exactly the "off" state, which is the safe one, so the extra exposure is a second ordinary crash window, not a new failure mode. If the re-enable fails, the user is left with the feature off, which is also safe.

This also matches what was actually asked for: switch on, pick bands, apply. In-place editing while enabled was never part of the request.

Where the pending selection lives: ordinary plugin preferences, the same place the switch already reads from, so it survives the off state. It is untrusted input and is revalidated against the domain at write time, so a tampered preference can still only pick a subset of what iOS already allowed. That is the same trust level as the existing switch.

## Work items

Payload and validation:

1. `CCNMValidateN78OnlyPayload` → take the selection as a parameter: identical key sets, every non-NR array exactly equal, NR array exactly equal to the selection. Two mirrored copies: `CCNMN78PolicyController.m:684` and `CCNMN78PolicyReader.m:621`.
2. `CCNMBuildN78Payload` → build from a selection. Checks: non-empty, unique, positive, every selected band present in both fresh active NR and fresh supported NR, not equal to the whole domain, not equal to the live array. Replaces the current `containsObject:@78` pair and the `isEqualToArray:@[ @78 ]` no-op guard (`CCNMN78PolicyController.m:705-730`).
3. Write the NR array in ascending numeric order, always.

   This is the highest-risk detail in the change, and it is not merely cosmetic. `CCNMWaitForReadBack` accepts only `CCNMDictionariesEqual(active, expected)`, which is whole-dictionary equality and therefore `NSArray` equality, which is order-sensitive. A single-element `@[ @78 ]` has no ordering question, so 1.5.0 never exercised this. With two or more bands, if the modem normalises the stored array and we wrote a different order, read-back mismatches and the operation is reported as `diverged` / `readBackMismatch` even though the write succeeded — a false alarm that pushes the user toward recovery.

   Ascending is the only order that is safe under both plausible modem behaviours (echo-as-written, or normalise), and every NR array in the captured device evidence is ascending, including the `257…261` tail. Order must be canonicalised in the payload builder, not at the UI layer, so tap order can never reach the modem.

   Residual risk that ordering does not cover: the modem could accept the write but return a different *set*, for example silently dropping a band. Every offered band was in the original active list and in fresh supported, so this is not expected, but it is unproven for multi-band writes. It would not be silent — the existing read-back mismatch path reports it and the baseline is retained.
4. `CCNMValidateIntentRecord` enable payload check (`CCNMN78PolicyController.m:1132`, `CCNMN78PolicyReader.m:565`) → derive the expected NR set from the intent's own `requestedActiveBands`, assert it is a non-empty subset of `preWriteActiveBands[NR]` intersected with `preWriteSupportedBands[NR]`, and assert non-NR arrays unchanged. No separate selection field needed; the intent already carries the full requested dictionary, which is also why crash recovery needs no new data. With the toggle round-trip, pre-write active NR at enable time is always the original list, so no `baselineActiveBands` cross-check is required here.
5. `CCNMValidateStateRecord` → validate `proof.targetNRBands` as above.
6. Expose the recorded target set through the policy summary. `CCNMSummaryFromState` drops the proof dictionary entirely today (`CCNMN78PolicyController.m:1259`, mirrored at `CCNMN78PolicyReader.m:737`), so neither the daemon nor the settings pane can see the selection. Both mirrors gain one field. Without this, the daemon work items below have nothing to compare against and the pane cannot show what is currently applied.

Daemon:

7. `maintenance-daemon/main.m:63` compares live active NR against `@[ @78 ]`. Change to compare against the recorded `proof.targetNRBands`.
8. `maintenance-daemon/main.m:102` requires `savedNR` to contain 78. Change to: every recorded target band must be present in the baseline's supported NR.
9. Stop consuming `CCNMServingSummaryCapabilityN78Supported/ActiveKey` in the decision path; the generic `ActiveNRBands` / `SupportedNRBands` arrays it already receives are sufficient. Leave the two booleans in the summary for the UI rather than redefining their meaning.

Serving status and UI:

10. `CCNMServingStatusProvider` is not changed. An earlier draft of this plan had it classify "NR on a selected band" vs "NR outside the selection"; that would make the provider depend on durable policy state, which it does not read today and should not start reading — it is deliberately a capability/serving reporter, and the daemon links the reader precisely to keep these concerns apart. The provider already emits the serving band number alongside the RAT, so membership-in-selection is computed by whoever holds the selection: the daemon and the settings pane. `CCNMServingStateNRN78` keeps both its wire value and its current meaning, serving band is 78; it becomes a special case of a general question rather than the question itself. Two of its three consumers (`livecc/Sources/NetworkManagerLiveModule.m:34`, `maintenance-daemon/main.m:124`) already treat it identically to `NROther`; only `CCNMRootListController.m:318` distinguishes it, and that is a label.
11. New child pane: a `PSListController` subclass rendering one row per selectable band with a checkmark accessory, reading live BandInfo through the reader and the applied set from the policy summary. It writes only the pending preference; it performs no modem write. Custom cells already exist in `CCNMPreferencesCells.m`.
12. Each row shows the band's frequency, not just its number. A bare list of integers is not actionable for a user; the sampler already computes NRARFCN/GSCN → MHz.
13. Mark the band currently being camped on, and warn before applying a selection that excludes it.
14. Localised strings for both `en.lproj` and `zh-Hans.lproj`.

Known-orphan recovery:

15. Unchanged, and must stay pinned to its reviewed `[78]` evidence, single SIM, and slot 1. The existing test asserting the literal `@"targetNRBands": @[ @78 ]` in that path (`tests/test_known_orphaned_n78_recovery.py:434`) stays as-is and is the guard against this generalisation leaking into it.

## Tests

Behaviour:

- Selection outside the narrowing domain is refused, including a band present in supported but absent from the original active list, and a band present in the original active list but absent from fresh supported.
- Empty, whole-domain, live-equal, duplicated, non-integer, and non-positive selections refused.
- A disable checkpoint (`requestedMode = n78Preferred`, `appliedPolicy = applying`, `recoveryState = restorePending`, proof without `targetNRBands`) still validates, and a subsequent enable is not blocked by it. This is the regression guard for the stranding hazard described under "Records".
- A stable enabled record (`verifiedN78Only`) missing `targetNRBands`, or holding an empty / duplicated / non-positive array, is rejected.
- Order-independent: two applies differing only in tap order produce identical records and an identical written array, ascending.
- Restore after a multi-band enable returns the original table.
- Off-then-on with a changed selection produces a baseline whose `activeBands` equals the first baseline's, which is the by-construction form of the capture-once invariant.
- Crash between intent and read-back recovers to baseline for a multi-band selection.
- Daemon compares against the recorded target set, not a literal 78.

Source-level, in the style already used in this repo:

- No shipped path may compare an NR array against a literal `@[ @78 ]` outside the known-orphan replay. This is the assertion that flushes out remaining hardcoded sites; per the slot-1 cleanup, write it before hunting for call sites rather than after.
- The band-selection pane must not call any policy write entry point from a row-selection handler, only from the apply action.
- The four operation-domain literals must stay exactly `enable`, `disable`, `recover`, `knownOrphanRecovery`, so a future in-place edit path cannot be added without deliberately touching this assertion.

## Sequencing

The dual-SIM write path on `58b81c9` is confirmed working on the reporting device, which closes step 1 of the 1.5.0 retest (enable reaching the setter with a successful read-back) and unblocks this work. Three steps remain unreported and are **not** assumed: disable retiring the record while status persists, same-boot re-enable not inheriting a consumed attempt, and restore returning the original six-RAT table.

Restore is untouched by this plan and was verified on the single-SIM reference device in 1.5.0, so it does not block implementation. It does become more load-bearing than before: under the toggle round-trip, restore runs on every edit rather than only at uninstall, so the fourth retest step is worth closing early.
