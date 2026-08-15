# Device probe result: iPhone14,3 / iOS 15.1.1 (19B81)

## Result

The read-only `CoreTelephonyClient` path works from the NetworkManager preference bundle on the target rootHide device:

- `getSubscriptionInfoWithError:` returned two contexts.
- Slot 1: `isSimPresent=true`, `isSimGood=true`.
- Slot 2: `isSimPresent=false`, despite `isSimGood=true`; all future reads/writes must require both flags and operate only on slot 1.
- `getBandInfo:error:` returned `activeBands` and `supportedBands` dictionaries for both contexts.

`activeBands` is an allowed/enabled band set, not the modem's current serving band. It is broader than this hardware's `supportedBands`, so UI choices and writes must be intersected with `supportedBands`.

## Slot 1 supported bands

- LTE: 1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 30, 34, 38, 39, 40, 41, 42, 46, 48, 66
- NR: 1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 30, 38, 40, 41, 48, 66, 77, 78, 79
- UTRAN: 1, 2, 4, 5, 6, 8
- GSM: 1, 2, 7, 9
- CDMAHybrid: 1, 2, 3, 12
- TDSCDMA: none

## Confirmed RAT keys

- `kCTRegistrationRadioAccessTechnologyLTE`
- `kCTRegistrationRadioAccessTechnologyNR`
- `kCTRegistrationRadioAccessTechnologyUTRAN`
- `kCTRegistrationRadioAccessTechnologyGSM`
- `kCTRegistrationRadioAccessTechnologyCDMAHybrid`
- `kCTRegistrationRadioAccessTechnologyTDSCDMA`

## Implications for a write experiment

The object/selector contract and read authorization are confirmed, but write authorization, persistence, and modem behavior are not. A setter test must be a separate guarded build and must:

1. Refuse absent or unhealthy SIM contexts; target slot 1 only.
2. Snapshot the complete original `activeBands` dictionary in memory and on disk before any write.
3. First build a `CTBandInfo` payload from an exact deep copy of the original dictionary without changing any RAT key or Band value. Any later mutation experiment must change only one RAT key and use only values in that slot's `supportedBands`.
4. After every pre-write check passes, durably create a write-intent record tied to the snapshot; post-relaunch restore must refuse to write without a matching intent.
5. Call `setActiveBandInfo:bands:error:` and inspect `NSError **`.
6. Immediately call `getBandInfo:error:` and require exact full-dictionary read-back for the same-value probe.
7. Expose one-tap restore and restore the full original snapshot, not a hard-coded default.
8. Arm an independent timeout before the write; on timeout or failed read-back, restore the snapshot.
9. Keep the existing RAT-selection path unchanged and do not integrate the setter into a Control Center tap until recovery behavior is proven.
10. Treat emergency calling and no-service behavior as unverified. Initial testing must not occur when the phone is the only emergency-communication device.

## Next safest experiment

Only after the same-value authorization probe succeeds on-device, a minimal LTE-only, slot-1 setter probe with a very short rollback timer and a user-selected supported LTE band is safer than a combined LTE+NR production UI. It must intersect the requested value with the live slot-1 `supportedBands`, then test one mutation, read-back, and restoration before any persistent lock feature is designed.
