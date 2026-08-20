# Automatic Maintenance Execution Owner

## Decision

Automatic n78 preference maintenance will be owned by a dedicated root launch daemon. SpringBoard and the Settings process remain clients of read-only status and explicit user commands; neither process runs an automatic modem setter.

The daemon is policy-scoped rather than permanently resident. Its launchd `KeepAlive/PathState` condition follows the durable n78 policy baseline path. It may start while recovery evidence exists, but it remains read-only unless the policy state is a complete, verified `enabledWithBaseline` state.

## Why this owner

- A SpringBoard writer expands the crash and modem-write blast radius into the system UI process.
- A Settings writer exists only while Settings is open and cannot maintain policy.
- A purely on-demand XPC service cannot detect an n78-to-other-NR transition without a client already sampling.
- A globally permanent daemon consumes resources even when the policy is disabled.
- A policy-scoped daemon can observe RAT notifications and perform low-frequency serving-cell verification only while durable policy evidence exists.

## Process boundary

- Install executable under `/usr/libexec` inside the active jailbreak root.
- Install one launchd plist under `/Library/LaunchDaemons` inside the active jailbreak root.
- Run as root with `ProcessType=Background`, `Umask=077`, and `DISABLE_TWEAKS=1`.
- Do not expose TCP, UDP, Bonjour, an unauthenticated UNIX socket, or writable command files.
- Do not write logs to `/tmp`. Publish bounded structured status through an atomic root-owned/mobile-readable plist.
- Resolve the private CoreTelephony symbols used by the maintenance refresh and fail closed before capability evaluation if the ABI does not match. The capability query validates the read-only `getBandInfo:error:` shape; a capability ABI failure never arms maintenance.

## Lifecycle

1. Policy disabled and no recovery evidence: daemon is not resident.
2. Baseline appears during explicit enable: launchd may start the daemon, but state is transitional so the daemon only observes records and waits.
3. State becomes verified `enabledWithBaseline`: daemon begins read-only serving-cell sampling.
4. State becomes restore-pending, uncertain, invalid, or recovery-required: daemon stops sampling and never issues a setter.
5. Baseline is retired after verified restore: `PathState` becomes false and the daemon exits.
6. Package removal first stops and verifies the launchd job, then runs the existing verified restore path. This prevents the observer from racing policy restoration; dpkg removes the plist and executable only after `prerm` succeeds.

## Observation policy

- RAT-change notification requests a debounced refresh.
- A bounded periodic refresh is also required because n78-to-other-NR can keep the same RAT.
- The period is not a public preference until device power and modem behavior are measured.
- Each refresh uses the reviewed responsive serving sampler.
- Two independent matching clean refresh summaries are required before a drop generation exists.
- Unknown, stale, incomplete, unsafe, or lock-contended summaries reset the candidate drop and never request a correction.

## Durable maintenance record

The daemon will persist a separate maintenance record containing:

- schema and owner
- policy generation and baseline creation identity
- device/system/SIM capability fingerprint, including the real slot-1 subscription UUID
- current supported/active NR arrays, exact supported RAT key shape, and n78 presence
- previous and current clean serving evidence
- drop generation and exact RAT+band identity
- whether the one correction attempt for that drop was consumed
- verification-pending state
- monotonic and wall-clock evidence needed to reject reboot-stale cooldowns
- cooldown deadline and last decision

This record never replaces the transaction baseline and never contains a portable raw modem payload.

## Correction gate

A future one-shot correction may run only when all of these are true:

- policy state is exact verified n78-preferred with the matching baseline
- maintenance record and current device/SIM/capability identity agree
- two independent clean summaries identify the same non-target RAT+band
- target n78 remains supported by the current profile and current capability
- no policy operation, removal guard, shared modem lock holder, or unsafe callback exists
- no attempt has been consumed for this drop generation
- cooldown has expired

The daemon persists attempt intent before calling the setter. Timeout, exception, late callback, invalid read-back, identity drift, or persistence failure consumes the attempt and enters recovery-required. There is no same-drop retry loop.

## Packaging validation required before activation

- Confirm `KeepAlive/PathState` behavior on iOS 15.1.1 and the target roothide bootstrap.
- Confirm daemon ownership/mode and `DISABLE_TWEAKS` at runtime.
- Confirm enable, disable, upgrade, downgrade, uninstall, reboot, and crash lifecycle.
- Measure idle memory, wakeups, sampler duration, and battery impact before choosing a periodic interval.

The source/package contract is already enforced: rootless staging emits `/var/jb/usr/libexec/networkmanager-maintenance` and `/var/jb/var/mobile/...baseline.plist`; roothide staging retains `@JBROOT@`, and the shell `postinst` substitutes the live `$(jbroot)` into the plist with `plutil -xml` plus `sed`, the way roothide's own bootstrapd package does. It then hands the resolved prefixes to the guard through `NETWORKMANAGER_INSTALL_PREFIX` and `NETWORKMANAGER_LAUNCHD_PREFIX`, and the guard verifies the result rather than writing it.

Two properties of that substitution are load-bearing, because both failure modes would otherwise report success:

- **The plist must be confirmed XML before `sed` touches it, but only once a substitution is known to be needed.** `grep -a` matches `@JBROOT@` inside a binary plist too, so a failed or missing `plutil` would let a textual rewrite expand 8 bytes to a longer path inside a length-prefixed string and leave the trailer's offset table stale. launchd could then not parse the file at all, while every later check passed because the placeholder really was gone. A plist left unsubstituted is recoverable by reinstalling; a corrupted one reported as written is not, so this refuses instead. The order of the two questions is itself load-bearing: Theos converts every staged plist to `binary1` in its `internal-package` step, which runs *after* `before-package`, so both lanes ship a binary plist regardless of what the packaging script wrote. Asking about the format first therefore warned about the rootless plist, which has its prefix baked in at package time and needs no rewrite at all. The placeholder check comes first, and the format is only questioned when a rewrite is genuinely required. For the same reason the package verifier records the plist format as evidence but does not require XML; what it requires is that `@JBROOT@` survive in the roothide package as plain bytes, which is the property the on-device `sed` actually depends on.
- **`jbroot`'s output is validated before it is used as a prefix.** It is an external input that ends up inside the plist. Empty, multi-line, relative, or non-directory values are rejected with the reason named in the install log; a trailing separator is normalised rather than rejected, so the daemon path does not gain a doubled slash. `prerm` applies the same validation for the fail-closed reason: a relative prefix resolves against a working directory dpkg does not guarantee, and any binary reached that way would be answering the removal question the gate exists to answer.

`grep`'s three-valued exit status is treated as three-valued at both ends of the substitution. Used as a boolean, an unreadable plist or an absent `grep` is indistinguishable from "no placeholder left", which is the success case.

Those two prefixes answer different questions and must not be conflated. The install prefix is what a maintainer-script child prepends to reach an installed file, and on roothide it is empty because that process already resolves bare paths inside the jailbreak root. The launchd prefix is what has to appear inside the plist, and it is never empty because launchd is not subject to the redirection. The policy reader/controller use the same convention, so launchd and the daemon observe the same baseline.

## Current boundary

The read-only monitor builds as `/usr/libexec/networkmanager-maintenance` relative to the active jailbreak root. It requires `--daemon`, reads the existing validated policy summary, samples only under the exact stable-enabled predicate, retains two independent summaries, and evaluates the shared pure decision module. Its entry source contains no enable, disable, recover, durable-record writer, or active-band setter call.

A root launchd plist is now packaged with one `KeepAlive/PathState` baseline condition. The shell `postinst` substitutes the jailbreak root into it, then the install guard validates the contract and bootstraps the job after removal-guard cleanup; `prerm` stops and verifies it before any restore work. A failure to register is a warning, not an install failure: the daemon owns no policy or modem state, and a correct plist on disk is what makes the job loadable at the next boot. Baseline retirement explicitly stops the daemon run loop because `PathState` alone does not terminate an already-running process. The read-only daemon persists its maintenance record and bounded status plist after each refresh. `CorrectOnce` remains disconnected from every setter, so this activation adds observation only.

Registration reports four outcomes, and the distinction between the last three is a reporting requirement rather than a control-flow convenience:

- `Active` — the job is loaded and running now.
- `Deferred` — the plist is validated and on disk but `launchctl` could not be run at all, so launchd has not yet seen the job. The next boot is a genuine prediction, and the install log says so.
- `Rejected` — `launchctl` ran and launchd declined to load the job. The durable half of the work is still intact, so this is not a permanent failure, but launchd has already refused once and the message must not borrow the deferred wording and promise the next boot will work.
- `Failed` — the plist itself could not be validated, so the job will not load now or later.

`Failed` is therefore reachable only from the prepare step. Reusing it for post-`launchctl` problems told the user the daemon would never run while a correct plist sat on disk, and collapsed "launchctl is missing" together with "launchd looked at the job and said no", which have different remedies. The `switch` in the install guard is exhaustive with no `default`, so the compiler rejects an unhandled outcome; that was verified by deleting a case and observing the build fail.
