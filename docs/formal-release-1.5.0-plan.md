# NetworkManagerReborn 1.5.0 formal release plan

**Branch:** `release/1.5.0`
**Baseline:** `2947f98ffb2665b000afab2c4db3ae843866d4da`
**Historical first acceptance device:** iPhone14,3 / iOS 15.1.1 (19B81), slot 1, one present and good SIM. This is evidence for the first end-to-end test, not the current compatibility allowlist.

## Release goal

Ship a small, truthful n78 preference product instead of a collection of modem diagnostics.

The formal user contract is:

> When NR is used, allow only n78. Keep the complete LTE fallback policy unchanged. Show requested policy, verified applied policy, and actual serving RAT/Band as separate states. Never claim continuous n78 service.

This is an n78 preference, not a hard n78 lock. Carrier policy, coverage, idle state, thermal state, and modem selection may still move service to LTE.

## Source boundary

- Start from the device-working Xcode 15.4 baseline `2947f98`.
- Do not merge the diagnostic history ending at `f516867`.
- Port only reviewed production modules and tests.
- Keep diagnostic plans, result exporters, evidence screenshots, same-value write, cold-band removal, LTE B1, and 60-second experiments out of the release branch.
- PullOver-X is GPL-3.0. Use its information hierarchy as a visual reference, but implement all cells and controllers independently.

## Version and package identity

- Release version: `1.5.0`.
- Tag after final acceptance: `1.5.0`.
- Package ID remains `me.nixuge.networkmanager`.
- Use neutral package metadata for both schemes: `NetworkManagerReborn`, not `NetworkManagerReborn Roothide` in the rootless package.
- Publish rootless and roothide as separate artifacts from the same source commit. Only publish a scheme after its own device acceptance.

## Product state model

Keep these domains independent:

### RequestedMode

- `systemDefault`
- `n78Preferred`

This is user intent only.

### AppliedPolicy

- `unknown`
- `applying`
- `verifiedSystemDefault`
- `verifiedN78Only`
- `diverged`
- `recoveryRequired`

A verified n78 policy contains the subscription UUID, operation generation, exact NR `[78]`, proof that every non-NR array stayed byte-identical, and a read-back timestamp.

### ServingState

- `nrN78`
- `nrOther`
- `lteBand`
- `other`
- `unknown`

Serving state comes only from fresh Cell Monitor evidence and carries a timestamp. It is never inferred from requested mode or BandInfo.

### RecoveryState

- `clean`
- `enablePending`
- `enabledWithBaseline`
- `restorePending`
- `rebootRequired`
- `recoveryFailed`

The exact pre-policy BandInfo snapshot remains durable for the full time n78 preference is enabled.

## Safe n78 policy lifecycle

### Enable

1. Acquire the cross-process modem lock.
2. Refuse an existing transition/recovery record, ambiguous SIM topology, UUID drift, malformed BandInfo, or missing n78 in both active and supported NR arrays.
3. Durably save the complete original six-RAT dictionary and exact subscription identity.
4. Durably save write intent and in-flight state.
5. Freshly reread BandInfo.
6. Build a deep copy that changes only the NR array to exact `[78]`; preserve LTE and all other RAT arrays byte-identically.
7. Write once.
8. Poll bounded read-back and require the complete dictionary to match exactly.
9. Persist `RequestedMode=n78Preferred` and `AppliedPolicy=verifiedN78Only` only after verification.
10. Retire transition markers but retain the original policy baseline for disable/uninstall recovery.

Do not issue a RAT-selection write in 1.5.0. Target evidence shows its read-back can become `Unknown`, so it cannot currently support a reversible formal contract.

### Disable

1. Acquire the same lock and validate the persistent policy baseline and subscription UUID.
2. Freshly read current BandInfo.
3. Restore the exact saved original NR array while preserving the current non-NR arrays.
4. Write once and require exact full read-back.
5. Remove policy baseline and transition records only after verification.

### Failure rules

- Setter timeout, exception, over-deadline return, UUID mismatch, invalid read-back, or uncertain async state forbids a second same-boot write.
- Preserve all evidence and require reboot/manual recovery.
- Control Center changes are blocked while transition or recovery state exists.
- Changed, missing, or foreign records fail closed.

### Uninstall and downgrade

This is a P0 release requirement. The package must not be removable while an n78 policy baseline is active unless the original NR list has been restored and verified. Implement a packaged restore helper or an equivalent pre-removal handshake; a settings warning alone is insufficient.

## Settings interface

Use the PullOver-X information hierarchy, independently implemented with Auto Layout, system colors, Dynamic Type, and dark-mode support.

### Header

- Existing NetworkManager icon, 46 pt.
- Title: `NetworkManagerReborn`.
- Subtitle: `5G n78 偏好与真实驻网状态`.
- Compact 88 pt header cell; no decorative banner card.

### Group 1: 5G n78 偏好

- Toggle: `启用 n78 偏好`.
- Footer: `启用后，NR 仅允许 n78；LTE 频段保持不变并可在无 5G 时回落。`.
- Transition state row: `正在应用` / `已验证` / `需要恢复`.

### Group 2: 当前状态

- `请求策略`
- `已应用策略`
- `当前驻网`
- `数据线路`
- `更新时间`
- Command: `刷新驻网状态`

Examples must be truthful:

- `请求：n78 偏好`
- `策略：NR 仅允许 n78，LTE 未修改`
- `驻网：NR n78 · 3408.96 MHz`
- `驻网：LTE B3（n78 当前未驻留）`
- `驻网：未知（数据已过期）`

### Group 3: 恢复与维护

- Hidden when recovery state is clean.
- Show `恢复原始频段配置` only with a valid recoverable baseline.
- Show exact reboot requirement when a setter outcome is uncertain.
- No ordinary-user blind `Clear State` button.
- No same-value, removal, B1, or diagnostic write actions.

### Group 4: 关于

Implement PullOver-style blue link cells with a Safari glyph and optional subtitle.

- `原作者项目`
  - Subtitle: `NetworkManager by NoisyFlake`
  - URL: `https://github.com/NoisyFlake/NetworkManager`
- `当前维护源码`
  - Subtitle: `NetworkManagerReborn by doimty`
  - URL: `https://github.com/doimty/NetworkManagerReborn`
- `版本`
  - `1.5.0`

Credit NoisyFlake and Nixuge in the footer/release notes. Do not copy PullOver-X GPL source.

## Localization

- Add `zh-Hans.lproj/NetworkManagerPrefs.strings`.
- Add `en.lproj/NetworkManagerPrefs.strings` as the fallback table.
- Localize header, group labels, footers, status text, recovery alerts, buttons, and repository links.
- Keep machine values such as `NR n78`, `LTE B3`, frequencies, hashes, and version strings unlocalized.
- Do not hardcode user-visible Chinese in controller logic; use localized keys.

## Module boundaries

### CCNMN78PolicyController

Owns policy record, exact payload construction, cross-process lock, setter/read-back, timeout classification, enable/disable, boot reconciliation, and recovery.

### CCNMServingStatusProvider

Wraps the reviewed serving-cell sampler behind a small typed summary. Full schema-v4 dictionaries are available only for support export, not as the UI contract.

### CCNMSettingsController

Renders localized policy/status/recovery sections and repository links. It never writes modem state directly.

### CCNetworkManager

Reads shared policy state and invokes the policy controller. It must not treat local `selectedNetwork` as modem truth. Formal short tap toggles `systemDefault` and `n78Preferred`; legacy RAT cycling is not in the 1.5.0 formal scope.

## Test gates

Before implementation, add red tests for:

- exact NR `[78]` payload and byte-identical non-NR arrays;
- enable/disable state transitions;
- durable baseline retained while enabled;
- crash points before and after each durable record/write/read-back;
- timeout/exception no-second-write rule;
- UUID and SIM-topology drift;
- stale/foreign/missing records;
- LTE fallback reported truthfully;
- requested/applied/serving states never conflated;
- diagnostic actions and forbidden strings absent from formal source/package. The scan selects files by extension, so any change to a shipped file's shape must be reflected there: the maintainer scripts moved from `postinst.m`/`prerm.m` to `postinst.sh.in`/`prerm.sh.in`, which silently removed them from the scan until `.in`/`.sh` were added;
- Chinese and English localization key parity;
- original/current repository URLs present exactly once;
- uninstall/downgrade cannot strand NR `[78]`.

## Reproducible build

Create separate macOS 14 jobs for rootless and roothide.

Pin and print:

- Xcode 15.4 (`15F31d`)
- Apple clang 15.0.0
- ld 1053.12
- Xcode iPhoneOS 17.5 SDK
- roothide Theos commit `88506b2c22e9e07dd4ed055f23c9e398a117a2c7`
- Theos SDK repository commit `0222fd5413cf4b9af096f37b4621afa2688572f7`
- CCSupport commit `ec20c982b3f74f2f0500a83761363384e92a0ca3`
- GitHub Actions by immutable commit SHA

Rootless alone uses the pinned Theos iPhoneOS16.5 SDK. Roothide must use the Xcode 17.5 system SDK with no explicit `SYSROOT`.

CI must fail on:

- empty logs;
- any compiler/linker/fatal error;
- `incompatible arm64e`;
- missing or multiple packages per lane;
- plist parse failure;
- package metadata mismatch;
- forbidden diagnostic UI/string;
- source or dependency SHA drift;
- missing architecture/load-command/dependency evidence.

## Artifact gates

For each accepted artifact record source SHA, run ID, artifact ID, size, SHA256, control fields, file manifest, plist parse, and signature parse.

Roothide requires both bundles, both policy guards, and the maintenance helper to have:

- arm64 + arm64e;
- arm64e subtype `ARM64 E USR00`;
- minimum iOS 14.0 and SDK 17.5;
- `LC_DYLD_INFO_ONLY` and `LC_CODE_SIGNATURE`;
- no `LC_DYLD_CHAINED_FIXUPS`;
- `@loader_path/.jbroot/usr/lib/libroothide.dylib` where the binary uses roothide APIs. The two policy guards deliberately do not link it: `roothideinit.dylib` derives the jbroot from its own load path and asserts on `@loader_path/.jbroot`, which does not exist beside an installed helper, so linking it would abort at load time. They therefore carry `LC_DYLD_CHAINED_FIXUPS` and are exempt from the prohibition above.
- normalized load-command and dependency sets matching device-working run `30166854314`, with the formal Settings bundle's explicit public CoreGraphics dependency recorded;
- ldid-readable signatures. Apple `codesign --verify` is report-only because ldid signatures are not Apple CodeSign objects.

Rootless requires both bundles, both policy guards, and the maintenance helper to have arm64 + arm64e, arm64e `ARM64 E USR00`, exact minOS 14.0, the pinned SDK, `LC_CODE_SIGNATURE`, and either supported dyld fixup format. The roothide-only chained-fixup prohibition does not apply to the rootless lane.

`DEBIAN/postinst` and `DEBIAN/prerm` are verified as the inverse: they must be `#!/bin/sh` text, mode 755, free of unrendered `@PREFIX@` / `@LAUNCHD_PREFIX@` / `@NEEDS_JBROOT@` placeholders, and must delegate to their guard. A Mach-O maintainer script is a hard failure. On roothide a compiled maintainer script runs without the `bootstrap.dylib` injection: it can stat and read inside the jailbreak root but gets `EPERM` on every write and every child exec, and does not see the root mapped at `/`. That is the defect this shape exists to prevent, so the gate is stated as a prohibition rather than a preference.

The staged launchd plist is verified per lane, not merely parsed. **Roothide must hold the program and baseline paths bare, with no prefix at all**; rootless must hold `/var/jb`. Neither lane may contain `@PLIST_PREFIX@` or `@JBROOT@` as plain bytes.

The roothide prefix is empty because its `launchctl` rewrites the plist on load: `_patch_plist` replaces every absolute path in the launchd-recognised keys with `jbroot(path)`, writes the result back to disk, and guards re-entry only with its own `__Patched` marker without inspecting whether the value already carries a jailbreak root. A staged jbroot-absolute path therefore becomes `<jbroot>/<jbroot>/usr/libexec/networkmanager-maintenance`, which then fails in `dyld` because `@loader_path` resolves into a directory that does not exist. Independently: the jbroot identifier changes every time the device is re-jailbroken, so any baked-in absolute path expires at the next boot into a new bootstrap. Bare paths plus load-time prefixing is the only form that survives both.

The container format is recorded as evidence but not constrained, because Theos converts every staged plist to `binary1` in its `internal-package` step, which runs after `before-package`: an XML requirement here failed a package that was completely correct. This gate exists because the repository template carries a sentinel where the prefix belongs, and a `before-package` step that silently does not run ships a permanently unresolvable path — nothing on the device substitutes anything into that file any more. The sentinel is `@PLIST_PREFIX@`, invalid on both lanes by design. It was previously `@JBROOT@`, which left a skipped patcher looking accidentally correct on roothide and broken only on rootless, and that asymmetry is exactly what let a wrong roothide contract pass as verified. Every per-stage check passes in that state, which is why the end-to-end test carries an explicit negative control that stages with the patch step skipped and requires both lanes to fail, naming the sentinel in both. That test also reproduces the Theos binarization step, so a format assumption cannot pass locally and fail in the cloud again.

The shell suite still reruns itself in full against a BSD-flavoured `grep`, but the requirement has inverted: the maintainer scripts must not invoke `plutil`, `sed` or `grep` at all. All three were ways to ship a broken package while reporting success — `plutil` is not present on every bootstrap, the two `grep` flavours disagree about binary files and *no match was the success branch*, and `sed` on a binary plist expands a length-prefixed string and leaves the trailer's offset table stale, which launchd cannot parse. The assertion uses word boundaries: a substring test for `sed ` also matches the middle of `used `, and once did.

## Device acceptance

Build and test `1.5.0-rc1` before the final tag.

Required target checks:

1. Upgrade from 1.4.3.
2. Settings opens with complete Simplified Chinese UI and both repository links.
3. Enable n78 preference; exact BandInfo read-back is verified.
4. Actual n78 serving is displayed when present.
5. LTE fallback is displayed truthfully when n78 is not serving.
6. Respring and reboot preserve policy state without an extra write.
7. Disable restores the exact original NR list.
8. Process death at each transition checkpoint remains recoverable.
9. Timeout/exception requires reboot and preserves evidence.
10. Uninstall/downgrade restores the original NR list.
11. No crash logs, black screen, or stale Control Center label.

Rootless needs separate device acceptance before its package is published.

## Release sequence

1. Implement domain model and tests.
2. Implement policy/recovery module.
3. Implement truthful serving summary.
4. Implement PullOver-inspired localized Settings UI.
5. Implement reproducible CI and artifact verifier.
6. Independent standards/spec/safety review.
7. Build `1.5.0-rc1` from a clean commit.
8. Complete device acceptance and recovery tests.
9. Build final artifact from the accepted source commit.
10. Create immutable annotated tag `1.5.0`, publish checksums/provenance/release notes, and retain 1.4.3 for rollback.

## Current release decision

`NO-GO` for distribution. The working tree now contains the production policy/recovery lifecycle, bounded setter handling, truthful serving provider, localized interface, compiled removal/install guards, host tests, and pinned CI/package gates. Local rootless compilation is smoke evidence only and carries the known incompatible-arm64e warning. A clean reviewed commit, pinned cloud artifacts, target-device transition/recovery/uninstall acceptance, and separate rootless acceptance remain mandatory before release or tag creation.
