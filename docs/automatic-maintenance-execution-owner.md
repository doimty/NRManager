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

The source/package contract is already enforced: rootless staging emits `/var/jb/usr/libexec/networkmanager-maintenance` and `/var/jb/var/mobile/...baseline.plist`; roothide staging emits the same two paths **bare**, with no prefix at all. The shell `postinst` does not touch the plist. It resolves the two prefixes and hands them to the guard through `NETWORKMANAGER_INSTALL_PREFIX` and `NETWORKMANAGER_LAUNCHD_PREFIX`, and the guard verifies the shipped plist rather than writing it.

The roothide prefix is empty because its `launchctl` is itself a redirected binary that rewrites the plist on load. `_patch_plist` in `<jbroot>/usr/bin/launchctl` walks `Program`, `ProgramArguments[0]`, `RootDirectory`, `WorkingDirectory`, `Standard{In,Out,Error}Path`, `WatchPaths`, `QueueDirectories`, `KeepAlive/PathState` keys, `Sockets` and `LaunchEvents`, replaces every value beginning with `/` with `jbroot(value)`, and stores `__Patched=true` back into the file. Re-entry is guarded solely by that marker; the value is never inspected for a jailbreak root it already carries, and the only opt-out is a value already prefixed with `/rootfs/`. A plist staged with a jbroot-absolute path therefore gets a second one. The reporting device showed exactly that, on disk, after `launchctl` had written it back:

```
ProgramArguments[0] = <jbroot>/<jbroot>/usr/libexec/networkmanager-maintenance
```

which then failed in `dyld`, because `@loader_path` resolved into a directory that does not exist so `libroothide.dylib` could not be found beside it. One mechanism, both symptoms.

The earlier design cited a basebin daemon's own `DEBIAN/postinst` as precedent for an `@JBROOT@` placeholder plus a `sed` in `postinst`. That precedent does not transfer: basebin daemons are loaded by the jailbreak itself through the native API, not by the patched `launchctl`, so they genuinely need a pre-expanded path. The two ordinary daemons shipped in the bootstrap tarball agree with the new contract — `us.diatr.shshd.plist` names `/bin/sh` and `/usr/libexec/shshd-wrapper`, `com.apple.atrun.plist` names `/usr/libexec/atrun`, with no jbroot and no placeholder anywhere.

Retiring the substitution removed three separate ways to ship a broken package, and it is worth recording why each was dangerous rather than merely redundant:

- **`plutil` is not present on every bootstrap.** The rewrite needed XML because a textual `sed` cannot match inside a binary plist, and Theos converts every staged plist to `binary1` in its `internal-package` step, which runs *after* `before-package`. So the conversion was mandatory on a tool that may be missing.
- **`grep`'s answer about binary files is flavour-dependent, and "no match" was the success branch.** GNU `grep -a` finds a placeholder inside a binary plist; the `grep` on the macOS runners reports no match for the same file and pattern. Its exit status is also three-valued, so used as a boolean an unreadable file or an absent `grep` was indistinguishable from "nothing left to substitute".
- **`sed` on a binary plist corrupts it while reporting success.** Expanding 8 bytes to a longer path inside a length-prefixed string leaves the trailer's offset table stale, so launchd cannot parse the file at all — and every later check passes, because the placeholder really is gone. Unsubstituted is recoverable by reinstalling; corrupt-and-report-success is not.

The repo template now carries `@PLIST_PREFIX@` where the prefix belongs, which is invalid on both lanes by design. It previously carried `@JBROOT@`, and that asymmetry is what let the wrong roothide contract look verified: a `before-package` step that silently did not run left roothide accidentally correct and only broke rootless. The package verifier records the plist format as evidence rather than requiring XML, and refuses either token as plain bytes in either lane.

`jbroot`'s output is still validated before use, for a reason that survives the change: it is an external input that becomes the guard's filesystem root. Empty, multi-line, relative, or non-directory values are rejected with the reason named in the install log; a trailing separator is normalised rather than rejected. `prerm` applies the same validation for the fail-closed reason — a relative prefix resolves against a working directory dpkg does not guarantee, and any binary reached that way would be answering the removal question the gate exists to answer.

Those two prefixes answer different questions and must not be conflated. They now disagree on exactly one point: whether empty is a valid answer.

- **Install prefix** — what a maintainer-script child prepends to open a file. The guard is not redirected: it links no `libroothide` and is `exec`'d through a bare path, so an empty prefix lands every read on the real root. Empty is therefore rejected, each candidate is probed against this package's own anchor file rather than trusted, and when nothing resolves the variable is left *unset* so the guard fails closed instead of reporting every policy record absent — which is indistinguishable from a clean band configuration.
- **Launchd prefix** — what must literally appear inside the plist. Empty is the correct roothide answer, so it is always exported, and set-ness is carried separately from the value.

The policy reader/controller use the same convention, so launchd and the daemon observe the same baseline.

## Current boundary

The read-only monitor builds as `/usr/libexec/networkmanager-maintenance` relative to the active jailbreak root. It requires `--daemon`, reads the existing validated policy summary, samples only under the exact stable-enabled predicate, retains two independent summaries, and evaluates the shared pure decision module. Its entry source contains no enable, disable, recover, durable-record writer, or active-band setter call.

A root launchd plist is now packaged with one `KeepAlive/PathState` baseline condition. The shell `postinst` hands the jailbreak root to the guards, the install guard validates the contract, and the shell bootstraps the job after removal-guard cleanup; `prerm` stops and verifies it before any restore work. A failure to register is a warning, not an install failure: the daemon owns no policy or modem state, so band policy changes keep working without it. What a failed registration does **not** buy is a free retry at the next boot — see below. Baseline retirement explicitly stops the daemon run loop because `PathState` alone does not terminate an already-running process. The read-only daemon persists its maintenance record and bounded status plist after each refresh. `CorrectOnce` remains disconnected from every setter, so this activation adds observation only.

### A reboot is not the recovery path

Early wording in this project promised that a job which failed to load would start "at the next boot". That was wrong on this platform, in two independent ways:

- Nothing in the jailbreak walks `<jbroot>/Library/LaunchDaemons` at startup. The two ordinary daemons shipped in the bootstrap tarball are loaded by their own `extrainst_` maintainer script (`shshd.extrainst_` calls `/bin/launchctl load -w`), and basebin's daemons are loaded by the jailbreak through the native API. For a package like this one, its own maintainer script is the only loader that exists.
- A plain reboot ends the jailbreak. Re-jailbreaking re-randomises the root, moving the tree to a fresh `/var/containers/Bundle/Application/.jbroot-<16 hex>`. The reporting device went through four distinct jailbreak roots in a single day, which is what exposed the wrong advice.

This is a property of the roothide family rather than of one jailbreak app, which matters because the reporting device runs Dopamine's roothide fork rather than roothide Bootstrap. Both ship byte-identical bootstrap tarballs, derive the root name from `arc4random`, and re-randomise it on every jailbreak by moving the tree. Dopamine states the loader contract outright: its launchd hook injects `<jbroot>/basebin/LaunchDaemons` into the `LaunchDaemons` and `Paths` keys, while the equivalent block for `<jbroot>/Library/LaunchDaemons` sits commented out with the annotation "should be loaded by procursus launchctl". That `launchctl` is the one this `postinst` invokes.

So the recovery for a registration failure is to install the package again, and every message says that instead.

Registration reports four outcomes, and the distinction between the last three is a reporting requirement rather than a control-flow convenience:

- `Active` — the job is loaded and running now.
- `Deferred` — the plist is validated and on disk but `launchctl` could not be run at all, so launchd has never seen the job. Reinstalling the package is the retry, and the install log says so rather than promising a boot will do it.
- `Rejected` — `launchctl` ran and launchd declined to load the job. The durable half of the work is still intact, so this is not permanent, but launchd has already refused once and the message must not borrow the deferred wording or promise that anything fixes itself unattended.
- `Failed` — the plist itself could not be validated, so the job will not load now or later.

`Failed` is therefore reachable only from the prepare step. Reusing it for post-`launchctl` problems told the user the daemon would never run while a correct plist sat on disk, and collapsed "launchctl is missing" together with "launchd looked at the job and said no", which have different remedies. The `switch` in the install guard is exhaustive with no `default`, so the compiler rejects an unhandled outcome; that was verified by deleting a case and observing the build fail.
