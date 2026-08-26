# Carrier configuration reset rebuild

Status: **superseded and disproven.** Kept as the record of a wrong turn, because
the reasoning below is exactly what the device refuted and the refutation is the
load-bearing fact for 1.6.1.

What happened: this plan was implemented and shipped as 1.6.0. On the target
device the bands stayed narrowed after the two invocations, so the locked device
fact stated below is false. Worse, the plan's success criterion was the kill's
exit status, and 1.6.0 used that false success to authorise deleting the policy
records -- including the baseline, the only copy of the pre-enable band
configuration. The one path that could not restore was also the one that destroyed
the means of restoring.

1.6.1 retires the whole mechanism and revives the reverse `setActiveBandInfo:`
write this plan called unnecessary. Two rules come directly out of the failure:

- Success is a modem read-back. Never a process exit status.
- The baseline is retired only after that read-back matched.

The original text follows unchanged.

---

Original status: implementation in progress on `feature/nr-band-selection-1.6.0`, baseline `0baf98a`.

## Locked device fact

On the target device, the carrier BandInfo returns to the system-managed/default
configuration after running these two commands as separate invocations:

```sh
killall -9 CommCenter
killall -9 CommCenter
```

The second invocation is part of the observed recovery procedure. It must not be
collapsed into a single call or treated as an optional retry without evidence.

## Hypothesis

The modem configuration is reloaded by the launchd-supervised `CommCenter`
process. Repeatedly terminating that process causes the replacement process to
reload carrier defaults, so a reverse `setActiveBandInfo:` write is unnecessary
and adds risk without adding recovery capability.

## New interface

Create one internal carrier-reset module with a small interface:

- `CCNMResetCarrierConfigurationWithCompletion`
- structured result: both kill attempts, process-command errors, timeout/failure,
  and whether the operation completed its requested two-invocation sequence

The Settings controller owns policy state transitions and verification. The reset
module owns command path resolution, argument construction, two invocations,
bounded waiting, and failure classification. No caller constructs a shell
command or invokes `killall` directly.

The package removal path uses the shell because the compiled maintainer guard has
known process-scoped exec restrictions on the target jailbreak. It uses the same
literal two-invocation semantics and a bounded shell helper, but does not depend
on CoreTelephony or the policy controller.

## State model

Keep the existing write-side transaction safety for enabling a selected NR set:
preflight, intent/in-flight records, setter watchdog, and read-back.

Replace the restore side with a reset transition:

- `resetPending`: reset has started; policy writes are blocked.
- `systemDefault`: reset completed and verification/cleanup succeeded.
- `resetFailed`/`rebootRequired`: reset did not complete or verification could not
  finish; durable records are retained for a later reset.

The existing on-disk names remain temporarily where compatibility requires them,
but no baseline active-band dictionary is used as a reverse-write payload. Legacy
baseline/intent/in-flight/removal-guard files are treated as migration evidence,
not as data to replay into CoreTelephony.

## Success and independent failure signals

Settings reset succeeds only when:

1. both `killall -9 CommCenter` invocations were launched and returned within the
   total deadline;
2. the carrier reset module reports no command-resolution or execution error;
3. a fresh read-only serving/policy observation is available after the reset;
4. the plugin's narrowed target is no longer reported as the active policy, or the
   carrier process has not yet exposed a stable read-back and the operation is
   explicitly marked pending rather than falsely clean.

Independent failure signals:

- no `killall` executable can be resolved;
- either invocation cannot be started or exceeds its deadline;
- the second invocation is skipped;
- the reset result is complete but the post-reset read remains narrowed;
- a setter is still active/uncertain in this process;
- durable records cannot be atomically retired.

A reset failure must never call the reverse Band setter and must never erase the
records needed for a later retry.

The removal path has a weaker contract: it attempts the same reset with a bounded
best-effort helper, reports failure, and still returns success to dpkg. Package
removal must not depend on CoreTelephony access or on a policy removal guard.

## Ablation expectations

- One kill only: expected to leave the target process/configuration in the
  observed bad state on the target device; retain as a negative test/documented
  unsupported variant.
- Reversed-band or baseline setter: must be absent from reset call paths; source
  scan must fail if reset code imports or calls `setActiveBandInfo:`.
- First command failure: second command must not be silently reported as a full
  reset; the result must preserve the failed attempt and return a retryable error.
- Second command failure: state remains reset-pending/failed and durable evidence is
  retained.
- Hanging helper: Settings completion arrives by the total deadline; prerm exits
  by the shell watchdog with an explicit warning.

## Implementation order

1. Add the reset module and host-testable command/result seam.
2. Replace controller disable/recover execution with reset plus verification;
   remove reverse restore payload/setter calls from those paths.
3. Collapse the Settings recovery UI into one "reload carrier defaults" action and
   remove known-orphan UI/eligibility paths.
4. Replace prerm's CoreTelephony/restore/removal-guard decision tree with bounded
   double-kill best effort, while retaining selection-file cleanup.
5. Remove obsolete compatibility gates and historical tables after legacy-record
   migration behavior is covered.
6. Update reader mirror, tests, localizations, source verifier, packaging, and
   release documentation.
7. Run host tests, syntax/build checks, package verification, and then device-test
   enable -> double kill -> read-back -> uninstall separately.

## Verification boundary

The target command and privilege behavior are device facts. Host tests can verify
that the two invocations, timeout, ordering, and state transitions are preserved,
but cannot prove that a mobile process may kill `CommCenter` or that launchd
recreates it. Device evidence must include the command output/status, the two
observed process transitions, and post-reset BandInfo.
