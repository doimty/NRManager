# iOS 15 Band Probe

Target device: iPhone 13 Pro Max (`iPhone14,3`), iOS 15.1.1 (`19B81`), rootHide/arm64e.

## Hypothesis

The Preferences process can use the iOS 15 `CoreTelephonyClient` XPC client to read a `CTBandInfo` object for each returned subscription context.

## Success criteria

- `getSubscriptionInfoWithError:` returns at least one context.
- `getBandInfo:error:` returns active and supported band dictionaries per SIM slot.
- No modem-setting selector is present in the built probe.
- The cloud roothide artifact is built on macOS 14 with Xcode 15.4 and the iPhoneOS 17.5 system SDK, without an incompatible arm64e ABI warning.

## Independent failure signals

- A required class or selector is absent on iOS 15.1.1.
- CoreTelephony XPC returns an error or no subscriptions.
- Preferences crashes or hangs while querying.
- Build logs contain an incompatible arm64e ABI warning.

## Scope

This package is read-only. It does not call `setActiveBandInfo:bands:error:`, `_CTServerConnectionSetBandInfo`, or any baseband setter. A write experiment requires a separate design with snapshot/read-back verification, automatic rollback, no-service recovery, dual-SIM isolation, and emergency-call protection.
