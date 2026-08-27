# NR band selection (1.6.0) — implementation plan

> **1.6.1 note.** The selection feature described here is unchanged and still
> current. What changed after this plan was written is the *undo* path: 1.6.0 also
> shipped a `killall -9 CommCenter` "carrier defaults reload" in place of the
> reverse `setActiveBandInfo:` write, and the target device disproved it -- the
> bands stayed narrowed. Because that path read a process exit status as proof of
> success, it then deleted the baseline, which is the only copy of the pre-enable
> configuration. 1.6.1 retires the reload, revives the reverse write, and gates
> baseline retirement on a modem read-back. See `docs/carrier-reset-recovery-plan.md`
> for the disproven plan and the two rules that came out of it. Nothing in the
> selection design below depends on which undo mechanism is in place.

Status: **all work items landed; pinned cloud build passed, hardware verification pending.** Commits `5472aaa` (payload, records, summary, daemon, decision module) and `efc0669` (removal cleanup) implement work items 1–11, 16 and 17; commit `54ce741` plus the evidence-only follow-up `e233deb` implement items 12–15, which makes the feature reachable by a user for the first time — before it, `CCNMWriteSelectedNRBands` had no caller in the shipped bundle and every install read the default `@[ @78 ]`. Item 13 landed in a materially different form than planned, described at the item. Release run `32688526055` built and verified both lanes from the final source SHA; nothing here is device-verified. See "Implementation status".

Supersedes nothing in 1.5.0; 1.5.0 remains the shipping line. Its dual-SIM write path is confirmed working on the reporting device; three of the four retest steps are still unreported. See "Sequencing".

Scope decision: **NR only.** LTE and the other four RAT arrays stay untouchable in this version. Restricting NR is safe because LTE remains the fallback, which is the entire safety argument the 1.5.0 feature rests on. Opening LTE removes that fallback and needs a runtime confirm-or-auto-rollback mechanism that does not exist yet; that is a separate version.

Second scope decision, from grilling this plan: **no new policy operation.** The write path, the record shapes and the state machine are untouched. What changes is which NR array the existing enable path writes, and where that array comes from.

## Implementation status

Nothing below is a device-verified claim. The source and host evidence is supplemented by pinned cloud run `32688526055`; no package has been installed on hardware.

Landed in `5472aaa`, 353 host tests green:

- Selection layer in both mirrors: `CCNMCanonicalNRSelection`, `CCNMSelectableNRDomain`, `CCNMValidateSelectedNRPayload`, `CCNMValidateSelectedNRIntentPayload` / `…Local`, `CCNMBuildSelectedNRPayload`.
- Preference accessors `CCNMReadSelectedNRBands` / `CCNMWriteSelectedNRBands` on `CCNMN78SelectedBandsPath()`, deliberately outside `CCNMN78PolicyPaths()`.
- `CCNMValidateStateRecord` requires a canonical selection for a settled enabled record only.
- `CCNMSummaryFromState` publishes `targetNRBands` in both mirrors.
- Daemon `CCNMActiveNRBandsMatchTarget`, baseline-supported check, and `CCNMCopyTargetNRBands`.
- Decision module generalised to a target set (work item 10, which this plan originally missed).

Landed in `efc0669`, 355 host tests green:

- `prerm` discards the stored selection on `remove` (work item 16, also missed by this plan).

Landed in the pane change set, 388 host tests green (`tests/test_band_selection_pane.py`, 32 tests):

- Work items 12–15: the child pane, its cell, its localisation, and the source-level assertion the test section listed as waiting on item 12.
- Shared exported selection helpers, including `CCNMCanonicalNRSelection`, `CCNMSelectableNRBandDomain` and `CCNMValidateNRBandSelectionAgainstDomain`, so the pane shares the write path's canonicalisation, domain and validation implementation instead of computing a lookalike intersection. `CCNMHasStoredSelectedNRBands` distinguishes the shipped default from an explicit pending choice.
- The pane accepts only fresh capability evidence, shows the applied target while the policy is enabled, localises validation failures, rechecks delayed warning confirmations, and rebuilds its model after a save. The shipped default is not labelled as an explicit user save.
- New header `CCNMNRBandSupport.h`: static band-number facts only, deliberately separate from `CCNMServingStatusSupport.h`, which converts a measured channel number.
- `Root.plist` is now 23 specifiers, not 21: a group plus a `PSLinkCell` whose `detail` is the pane.

**Work item 13 did not land as written; see the item for what replaced it and why.**

Outstanding: nothing in this plan's work-item list. The pinned cloud build is complete; remaining work is the device retest under "Tests" and "Sequencing". The two open questions at the end of this section are still open.

### Facts established while implementing, which the plan had as assumptions

- **No migration is needed, now confirmed rather than predicted.** `git show HEAD~2:networkmanagerprefs/CCNMN78PolicyController.m` has `@"targetNRBands": @[ @78 ]` at line 2407, in the enable proof shipped as 1.5.0 by commit `47e1e72`. Every stable enabled 1.5.0 install already carries a valid selection, so `CCNMValidateStateRecord` gained no backward-compatibility branch.
- **The recorded target is read out of the verified read-back, not out of the requested selection**, and canonicalised again on the way in. This was not in the plan and matters more than it looks: the record is the daemon's only statement of what the modem should be doing, so populating it from an unverified source would let a failed write leave behind a target the modem never accepted.
- **Order sensitivity is already safe on the read side.** `CCNMServingNormalizedBandArray` in `CCNMServingStatusProvider.m` sorts before publishing, and the policy summary is canonical ascending, so the daemon's whole-array equality has sorted input on both sides. The plan flagged ordering as the highest-risk detail; on the provider path it was already handled, and the remaining risk is confined to the write/read-back pair described under work item 3.
- **`CCNMValidateStateRecord`'s narrow condition was the right call and is now load-bearing.** Confirmed against `CCNMFinishSystemDefaultState`, which writes a disable checkpoint carrying `requestedMode = n78Preferred` with `appliedPolicy = applying` and no `targetNRBands`.
- **A downgrade to 1.5.0 with a non-78 selection is fail-safe, not corrupt.** The old daemon's hardcoded gate simply fails to match and reports `StopIncompatible`; it does not write.
- **`enum`, not `static const size_t`, for the daemon's target-buffer bound.** `static const size_t` makes `int targetBands[N]` a folded VLA in ObjC and trips `-Wgnu-folding-constant`, which is an error under `-Werror`.
- **ObjC syntax checks on this host need an explicit sysroot.** `/root/.openclaw/workspace/toolchains/theos/sdks/iPhoneOS16.5.sdk`; without `-isysroot` clang cannot find `Foundation/Foundation.h`. `prerm.m` must additionally be checked with `-DCCNM_MAINTAINER_SCRIPT=1`, which is how it is really compiled.
- **The CI test gate needs no registration for new test files.** `.github/workflows/livecc-prototype.yml` asserts a floor (279 root / 12 livecc) against `unittest discover`, so added files are picked up automatically. The floor is deliberately allowed to drift below the real count, and `tests/test_ci_test_gates.py` pins that direction, so it must not be bumped to match 355.
- **A ban assertion on this pane has to read comment-stripped source.** The pane, the cell and `CCNMNRBandSupport.h` all carry comments that name the very tokens the tests forbid, because the comment's job is to record why the token is absent. The first run of `tests/test_band_selection_pane.py` failed three times on its own explanations: `NRARFCN` in two files and `UITableViewCellAccessoryCheckmark` in the cell. `code_only` is copied from `tests/test_serving_status_provider.py`, which had already solved this; a Makefile variant strips `#` lines so a commented-out source file cannot read as compiled. Each of the four ban assertions was then re-verified by injecting the real token or comment and watching it fail.

### Open questions, neither of which blocks the UI

- `CCNMBuildIntentRecord` (`CCNMN78PolicyController.m:1241`) calls `CCNMBuildSelectedNRPayload`, which applies the whole-domain and live-equal refusals during intent construction. The decision recorded below is that those two refusals belong to preflight, against a fresh read. Whether this call is genuinely redundant with `CCNMValidateSelectedNRIntentPayload`, or is a second gate in a place that cannot justify one, is unresolved.
- Provider ordering is safe today by inspection, not by assertion. There is no test pinning that `CCNMServingNormalizedBandArray` sorts, so a future edit could remove the sort and only multi-band installs would notice.

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

No policy-record schema bump. No migration code for `baseline`, `intent`,
`inFlight` or `state`; those records remain at their existing shape and there is
no new policy operation. The separate read-only automatic-maintenance observation
record is a different owner and schema: 1.6.2 uses `schemaVersion: 2` to stop
encoding a read-only drop observation as post-setter verification. That schema
change does not alter policy evidence or the modem write contract.

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

Surviving the off state is what keeps it out of `CCNMN78PolicyPaths()`, and that is also why it needs an explicit owner at removal — see work item 16.

## Work items

Payload and validation — **all landed in `5472aaa`**:

1. [x] `CCNMValidateN78OnlyPayload` → take the selection as a parameter: identical key sets, every non-NR array exactly equal, NR array exactly equal to the selection. Two mirrored copies: `CCNMN78PolicyController.m:684` and `CCNMN78PolicyReader.m:621`. *Landed as `CCNMValidateSelectedNRPayload` in both mirrors.*
2. [x] `CCNMBuildN78Payload` → build from a selection. Checks: non-empty, unique, positive, every selected band present in both fresh active NR and fresh supported NR, not equal to the whole domain, not equal to the live array. Replaces the current `containsObject:@78` pair and the `isEqualToArray:@[ @78 ]` no-op guard (`CCNMN78PolicyController.m:705-730`). *Landed as `CCNMBuildSelectedNRPayload`. Controller-only: the reader never builds a payload, it only validates one.*
3. [x] Write the NR array in ascending numeric order, always.

   This is the highest-risk detail in the change, and it is not merely cosmetic. `CCNMWaitForReadBack` accepts only `CCNMDictionariesEqual(active, expected)`, which is whole-dictionary equality and therefore `NSArray` equality, which is order-sensitive. A single-element `@[ @78 ]` has no ordering question, so 1.5.0 never exercised this. With two or more bands, if the modem normalises the stored array and we wrote a different order, read-back mismatches and the operation is reported as `diverged` / `readBackMismatch` even though the write succeeded — a false alarm that pushes the user toward recovery.

   Ascending is the only order that is safe under both plausible modem behaviours (echo-as-written, or normalise), and every NR array in the captured device evidence is ascending, including the `257…261` tail. Order must be canonicalised in the payload builder, not at the UI layer, so tap order can never reach the modem.

   Residual risk that ordering does not cover: the modem could accept the write but return a different *set*, for example silently dropping a band. Every offered band was in the original active list and in fresh supported, so this is not expected, but it is unproven for multi-band writes. It would not be silent — the existing read-back mismatch path reports it and the baseline is retained.
4. [x] `CCNMValidateIntentRecord` enable payload check (`CCNMN78PolicyController.m:1132`, `CCNMN78PolicyReader.m:565`) → derive the expected NR set from the intent's own `requestedActiveBands`, assert it is a non-empty subset of `preWriteActiveBands[NR]` intersected with `preWriteSupportedBands[NR]`, and assert non-NR arrays unchanged. No separate selection field needed; the intent already carries the full requested dictionary, which is also why crash recovery needs no new data. With the toggle round-trip, pre-write active NR at enable time is always the original list, so no `baselineActiveBands` cross-check is required here. *Landed as `CCNMValidateSelectedNRIntentPayload` / `…Local`.*
5. [x] `CCNMValidateStateRecord` → validate `proof.targetNRBands` as above.
6. [x] Expose the recorded target set through the policy summary. `CCNMSummaryFromState` drops the proof dictionary entirely today (`CCNMN78PolicyController.m:1259`, mirrored at `CCNMN78PolicyReader.m:737`), so neither the daemon nor the settings pane can see the selection. Both mirrors gain one field. Without this, the daemon work items below have nothing to compare against and the pane cannot show what is currently applied. *Landed at `CCNMN78PolicyController.m:1476` and `CCNMN78PolicyReader.m:874`, published only for a settled enabled state.*

Daemon — **all landed in `5472aaa`**:

7. [x] `maintenance-daemon/main.m:63` compares live active NR against `@[ @78 ]`. Change to compare against the recorded `proof.targetNRBands`. *Landed as `CCNMActiveNRBandsMatchTarget`.*
8. [x] `maintenance-daemon/main.m:102` requires `savedNR` to contain 78. Change to: every recorded target band must be present in the baseline's supported NR.
9. [x] Stop consuming `CCNMServingSummaryCapabilityN78Supported/ActiveKey` in the decision path; the generic `ActiveNRBands` / `SupportedNRBands` arrays it already receives are sufficient. Leave the two booleans in the summary for the UI rather than redefining their meaning. *The booleans now appear in `main.m` only where the durable record is built, as factual telemetry.*
10. [x] **Generalise the decision module itself.** *Missing from the original plan and found during review.* `CCNMAutomaticMaintenanceInput.targetBand` was a single `int` compared for equality, so a chosen set such as `{41, 78}` resting on 41 would have been judged a deviation and would have spent the boot's one correction attempt on an already-correct state. Replaced with `targetBands` + `targetBandCount` and set membership in `CCNMSampleIsTarget`. `CCNMTargetSelectionIsUsable` refuses an absent, empty or malformed selection as `StopIncompatible`, ranked **above** `VerificationPending`: refusing to act is always available, acting on an unknown target never is. The buffer bound is `enum { CCNMMaintenanceMaximumTargetBands = 128 }` for the `-Wgnu-folding-constant` reason noted above; 128 is fail-closed headroom against the reference device's 46 active NR bands.

Serving status and UI — **all landed; item 13 in a different form than planned**:

11. [x] `CCNMServingStatusProvider` is not changed. An earlier draft of this plan had it classify "NR on a selected band" vs "NR outside the selection"; that would make the provider depend on durable policy state, which it does not read today and should not start reading — it is deliberately a capability/serving reporter, and the daemon links the reader precisely to keep these concerns apart. The provider already emits the serving band number alongside the RAT, so membership-in-selection is computed by whoever holds the selection: the daemon and the settings pane. `CCNMServingStateNRN78` keeps both its wire value and its current meaning, serving band is 78; it becomes a special case of a general question rather than the question itself. Two of its three consumers (`livecc/Sources/NetworkManagerLiveModule.m:34`, `maintenance-daemon/main.m:124`) already treat it identically to `NROther`; only `CCNMRootListController.m:318` distinguishes it, and that is a label.
12. [x] New child pane: a `PSListController` subclass rendering one row per selectable band with a checkmark accessory, reading live BandInfo through the reader and the applied set from the policy summary. It writes only the pending preference; it performs no modem write. Custom cells already exist in `CCNMPreferencesCells.m`.

    Two constraints found while reviewing the landed code, both of which shape the pane rather than decorate it:

    - **The domain is a runtime read, so the pane cannot be static `Root.plist` rows.** `Root.plist` currently holds 21 specifiers and no band entry. The selectable set is fresh active NR ∩ fresh supported NR, which is only knowable at display time, so the rows must be constructed in code.
    - **The pane must be unavailable, and visibly so, while the feature is on.** `performEnable` hard-refuses when a baseline exists, so a selection edited in the on state cannot be applied. Grey the rows out and say the switch must be turned off first, rather than accepting taps and failing at apply time.

    *Landed as `CCNMBandSelectionListController`, with these differences from the sketch above:*

    - *The checkmark is a glyph driven by a specifier property, not `UITableViewCellAccessoryCheckmark` and not `PSTableCell`'s `-setChecked:`. The accessory type is reset when Preferences hands back a recycled cell, and `-setChecked:` is radio-group machinery, which is the wrong shape for multi-select. A checkmark surviving onto the wrong row would be a false claim about what a later enable will write.*
    - *Unavailability is one enum decided in a single pass before any specifier exists, with three distinct causes — policy on, recovery needed, no capability evidence — so each row renders a decision instead of re-deriving it. A policy problem outranks missing evidence, because it is the more actionable statement.*
    - *The pane never samples. `CCNMServingStatusProvider`'s sampler is an async private-API call behind a cross-process lock with an unsafe-outstanding latch, already owned and refreshed by the parent pane. A second owner buys nothing and could leave the latch set, which blocks the write path the user is walking towards.*
    - *The whole model is rebuilt in `-viewWillAppear:`, discarding unsaved checkmarks. Keeping them would mean showing a selection checked against a domain that may no longer exist.*
    - *A stored band that is not in the current domain is dropped from the working selection and named in the group footer, rather than silently vanishing — that is the exact state work item 16 exists to prevent, and it is still reachable when the SIM changes.*
13. [x] ~~Each row shows the band's frequency, not just its number. A bare list of integers is not actionable for a user; the sampler already computes NRARFCN/GSCN → MHz.~~

    **This item was wrong and did not land as written.** The sampler converts a *measured* NRARFCN or GSCN, which exists only for a cell the modem is currently reporting. A band number alone does not determine a frequency; that needs the 3GPP band table (TS 38.101-1 Table 5.2-1 for FR1, TS 38.101-2 Table 5.2-1 for FR2), which this project has never transcribed. Showing a made-up MHz figure for 18 other bands would have been worse than showing none.

    What a band number *does* determine is its frequency range, because 3GPP allocates the numbers themselves by range. So each row shows Sub-6 GHz or mmWave, and the one band actually being served additionally shows its real measured frequency. That distinction carries the consequence the user cannot otherwise see: a selection of nothing but mmWave leaves them with essentially no 5G coverage, and a bare `n260` gives no hint of that. `CCNMNRBandSupport.h` holds the classifier as `static inline` C with a compiled test harness, since its whole job is a numeric judgement; its band ceiling is pinned by test to the policy mirrors' own `CCNMMaximumBandIdentifier`, so it cannot offer a band the write path would reject.
14. [x] Mark the band currently being camped on, and warn before applying a selection that excludes it. *Landed, and the serving band is adopted only from a fresh, successful, non-stale NR sample — nil for LTE and for any failed read, because a guessed serving band would produce a warning about nothing. A second warning covers the mmWave-only case above. Both are warnings, not refusals: LTE is untouched either way, so the user is told and then allowed to proceed.*
15. [x] Localised strings for both `en.lproj` and `zh-Hans.lproj`. *34 keys each. Tests pin that every key the pane asks for exists in both, that validation failures are localised before reaching the UI, that `%@` counts agree between locales (a mismatch crashes `-stringWithFormat:` rather than degrading), and that both locales still contain the sentence saying a save writes nothing to the modem.*

Packaging — **landed in `efc0669`**:

16. [x] **Discard the stored selection when the install is retired.** *Missing from the original plan.* `CCNMN78SelectedBandsPath()` is the first durable file the policy owns that the policy records do not retire — it has to outlive the off state, so it cannot join `CCNMN78PolicyPaths()` — and dpkg will not remove it either, since it lives under `/var/mobile/Library/Preferences` and was never package payload. Left behind, a stored band the current SIM no longer offers makes the toggle refuse while nothing in Settings names the stored value, so remove-and-reinstall silently inherits the same selection and fails the same way. 1.5.0 had no preference file, so this was a regression introduced by this work.

    Every allowed verdict in `prerm.m` now returns through `CCNMAllowRemoval(action)`, which discards on `remove` only; `upgrade`, `failed-upgrade` and `deconfigure` hand the same records to a successor or leave the package unpacked. The single funnel is the point — the guard has five separate paths that authorize removal and a sixth added later would otherwise skip the cleanup. `prerm` rather than a new `postrm`: `postrm` is dpkg's hook for this, but a new maintainer script on the removal path must resolve the install prefix itself and can block a removal outright, which is a failure mode this project has already shipped once. The price is that an aborted removal loses the selection, which resets to the shipped default. Never a block, and `ENOENT` is success: failing to unlink a preference file leaves the modem untouched, so refusing removal over it would turn a stale plist into an unremovable package.

Known-orphan recovery:

17. [x] Unchanged, and must stay pinned to its reviewed `[78]` evidence, single SIM, and slot 1. The existing test asserting the literal `@"targetNRBands": @[ @78 ]` in that path (`tests/test_known_orphaned_n78_recovery.py:434`) stays as-is and is the guard against this generalisation leaking into it.

## Tests

Behaviour — landed, `tests/test_nr_band_selection.py` (318 lines) and `tests/test_automatic_maintenance_decision.py` (23 harness assertions, up from 14):

- [x] Selection outside the narrowing domain is refused, including a band present in supported but absent from the original active list, and a band present in the original active list but absent from fresh supported.
- [x] Empty, whole-domain, live-equal, duplicated, non-integer, and non-positive selections refused.
- [x] A disable checkpoint (`requestedMode = n78Preferred`, `appliedPolicy = applying`, `recoveryState = restorePending`, proof without `targetNRBands`) still validates, and a subsequent enable is not blocked by it. This is the regression guard for the stranding hazard described under "Records".
- [x] A stable enabled record (`verifiedN78Only`) missing `targetNRBands`, or holding an empty / duplicated / non-positive array, is rejected.
- [x] Order-independent: two applies differing only in tap order produce identical records and an identical written array, ascending.
- [x] Daemon compares against the recorded target set, not a literal 78; plus subset membership, out-of-set correction, RAT still mattering, four malformed selections, and refusal outranking pending verification.
- [ ] Restore after a multi-band enable returns the original table. *Not expressible as a host test; belongs to device retest.*
- [ ] Off-then-on with a changed selection produces a baseline whose `activeBands` equals the first baseline's, which is the by-construction form of the capture-once invariant. *Device retest.*
- [ ] Crash between intent and read-back recovers to baseline for a multi-band selection. *Device retest.*

Source-level, in the style already used in this repo:

- [x] No shipped path may compare an NR array against a literal `@[ @78 ]` outside the known-orphan replay. This is the assertion that flushes out remaining hardcoded sites; per the slot-1 cleanup, write it before hunting for call sites rather than after. *Landed: `containsObject:@78`, `isEqualToArray:@[ @78 ]` and `? @[ @78 ] :` are forbidden, and `@"targetNRBands": @[ @78 ]` is pinned to exactly one occurrence.*
- [x] Every durable path the policy names must be either retired with the policy records or discarded on removal. *Landed with work item 16. Written against the set of `CCNMPolicyRoot()` paths rather than the one filename that broke the rule, because the next preference file added will land in the same gap and the symptom is invisible until a user reinstalls. It also asserts each path is reachable through exactly one named accessor, so an inline literal cannot defeat the audit, and that the removal funnel itself touches no policy state.*
- [x] The band-selection pane must not call any policy write entry point from a row-selection handler, only from the apply action. *Landed. Written against every policy write entry point and every known modem setter, per method body, with a guard test asserting the body extractor actually found the methods so the scoping assertions cannot pass on an empty string. The preference write is additionally pinned to exactly one call site.*
- [x] The pane must not build a domain from stale capability evidence, display a pending preference as an applied target, or retain stale dropped-band state after saving. *Landed with the pane review hardening: capability timestamp gate, applied-target branch, explicit-default tracking, and full model rebuild after write.*
- [x] The four operation-domain literals must stay exactly `enable`, `disable`, `recover`, `knownOrphanRecovery`, so a future in-place edit path cannot be added without deliberately touching this assertion.

No registration step is needed for new test files: the CI gate asserts a floor against `unittest discover`, and `tests/test_ci_test_gates.py` pins that the floor stays at or below the real count. Do not raise the 279 literal to match the current 355.

## Sequencing

The dual-SIM write path on `58b81c9` is confirmed working on the reporting device, which closes step 1 of the 1.5.0 retest (enable reaching the setter with a successful read-back) and unblocks this work. Three steps remain unreported and are **not** assumed: disable retiring the record while status persists, same-boot re-enable not inheriting a consumed attempt, and restore returning the original six-RAT table.

Restore is untouched by this plan and was verified on the single-SIM reference device in 1.5.0, so it does not block implementation. It does become more load-bearing than before: under the toggle round-trip, restore runs on every edit rather than only at uninstall, so the fourth retest step is worth closing early.

The pinned cloud build is complete in run `32688526055`: `macos-14`, Xcode 15.4 (`15F31d`), clang 15.0.0, ld 1053.12, and iPhoneOS 17.5 for roothide; both package lanes passed source/package verification with zero `incompatible arm64e` diagnostics. The roothide injected bundles have `LC_DYLD_INFO_ONLY` and its three exec'd tools have `LC_DYLD_CHAINED_FIXUPS`. The remaining gate is device validation of the retest items above.
