# 1.5.0 implementation progress

Baseline: `2947f98ffb2665b000afab2c4db3ae843866d4da`
Branch: `release/1.5.0`
Target: iPhone14,3 / iOS 15.1.1 (19B81), slot 1, one present and good SIM

## Completed in working tree

- Formal n78 policy state model with exact six-RAT validation, durable baseline, intent/in-flight records, UUID/SIM checks, cross-process flock, bounded setter wait, late-setter lock retention, full read-back, and reboot-required uncertainty.
- All four shipped Mach-O targets use iOS 14.0 minimum; package verification requires both arm64 and arm64e slices to report minOS 14.0.
- Truthful serving-cell provider backed by the reviewed adaptive Cell Monitor sampler, with NR-ARFCN-to-frequency conversion, LTE fallback classification, freshness expiry, and a shared modem lock.
- Control Center short-tap behavior now reads shared policy state and calls formal enable/disable; legacy RAT cycling and `selectedNetwork` persistence are removed. Darwin policy-change notifications refresh a tile living in another process, with a local pending icon state.
- Independently implemented Auto Layout Settings cells, English/Simplified Chinese localization, compact header, policy/applied/serving/recovery rows, repository links, and recovery confirmation.
- Compiled `prerm` and `postinst` maintainer guards. `prerm` restores and verifies before remove/upgrade/downgrade, then arms a durable removal guard that closes the post-script enable race. `postinst` clears it only after a safe state check.
- Release source, package, build-log, Mach-O, maintainer-script, and forbidden-string verifier updates.

## Evidence in this checkpoint

- `python3 -m unittest discover -v tests`: 61/61 passed.
- `python3 -m py_compile scripts/*.py`: passed.
- `python3 scripts/verify_release_source.py --repo .`: passed.
- First cloud run `32052865548`: host gates passed; both package lanes stopped before build because `ld -version_details` now emits JSON (`"version": "1053.12"`). Workflow matching now accepts the pinned JSON form while retaining legacy output compatibility.
- Second cloud run `32053525066`: host gates, pinned Xcode/SDK/dependencies, and both package builds passed. Final source re-verification incorrectly traversed the newly cloned `theos/` dependency and rejected its template plist placeholders. The verifier now excludes the external dependency tree.
- Third cloud run `32054864964`: host gates and both package builds passed. Raw Mach-O evidence proved roothide uses the required `LC_DYLD_INFO_ONLY`, no chained fixups, exact minOS 14.0/SDK 17.5, and ldid-readable signatures. Verifier false positives came from lane-crossed rootless fixup rules, whitespace-sensitive arm64e header parsing, treating ldid as Apple CodeSign, and the formal Settings bundle's intentional public CoreGraphics dependency. Those rules are now lane-aware and evidence-backed.
- Artifact downloads from run `32055654251` independently confirmed both verification reports passed, but exposed two evidence-format defects: SHA256SUMS used the wrong package-relative path, and provenance recorded only `{` for ld. Both generation paths now use the package subdirectory and extract/record exact ld 1053.12; rerun pending.
- Local rootless and roothide packages compiled and passed Linux structural verification: 13-file payloads, 5 parsed plists, compiled `postinst` + `prerm`, zero legacy social assets, zero forbidden strings. These are compile/package evidence only, not deliverables. The build-log gate correctly rejects all local incompatible-arm64e warnings; local roothide also uses the non-accepted local SDK/linker dependency shape, so only the pinned cloud lane can satisfy Mach-O acceptance.

## Review result

- Independent spec/safety review found no P0 and identified bounded-readback/CC pending-state improvements; those were implemented. Two proposed changes were rejected with rationale because they would weaken the shared modem interlock or invalidate legitimate post-restore crash cleanup.
- Independent standards review found three P1 issues: arm64e minOS drift, `prerm` exiting while a timed-out setter retained the lock, and an incorrect maintainer-script mode range check. All were fixed and the same reviewer confirmed no P0/P1 remained. Its final P2 exact-minOS gate was also fixed.

## Remaining gates

- Commit only after owner review, then run pinned macOS 14/Xcode 15.4 rootless and roothide cloud builds. Reject empty/fatal logs, incompatible arm64e warnings, exact-minOS/load-command/dependency drift, and maintainer-script verification failures.
- Perform target-device RC acceptance for enable, actual NR n78, LTE fallback, reboot, disable, crash checkpoints, timeout, uninstall, and downgrade. Rootless requires separate acceptance.
- Do not create tag, publish, or deliver a package until those gates pass.
