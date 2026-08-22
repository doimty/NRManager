# NetworkManagerReborn

NetworkManagerReborn continues NoisyFlake's original [NetworkManager](https://github.com/NoisyFlake/NetworkManager), with earlier maintenance by Nixuge and current maintenance at [doimty/NetworkManagerReborn](https://github.com/doimty/NetworkManagerReborn).

## 1.5.0 scope

Version 1.5.0 replaces legacy RAT cycling with a reversible n78 preference:

- When NR is used, the allowed NR list is changed to exactly n78.
- LTE and every other non-NR band list remain unchanged.
- LTE fallback remains available when n78 is not serving.
- Requested policy, verified applied policy, and fresh serving RAT/Band are kept as separate domains in Settings and maintenance.
- The formal package no longer ships a duplicate Control Center button; the standalone LiveCC package is the sole optional serving-band preview.
- A retained baseline and package removal guard prevent uninstall or downgrade from stranding the modem on the modified NR list.

This is not a hard n78 lock. Carrier policy, coverage, idle state, thermal state, and modem selection can still move service to LTE.

The first end-to-end acceptance was performed on `iPhone14,3` running iOS 15.1.1 (`19B81`), but that identity is recorded evidence rather than a compatibility allowlist. Enable runs on any device/build that passes the runtime contract: the private CoreTelephony ABI is valid, slot 1 has the single present/good SIM, complete fresh `activeBands` and `supportedBands` are readable, and both NR sets contain n78. Only the NR array changes; LTE and every other RAT remain unchanged. Restore is bound to the same hardware model and to the saved capability shape and owned NR capability evidence. The saved active NR list is replayed exactly; it is not required to be a subset of the current supported NR list because the device's BandInfo contract permits that shape. An iOS version/build update alone does not strand the baseline.

## Release status

The 1.5.0 source is under validation. Rootless and roothide packages are not release-ready until pinned Xcode 15.4 cloud builds and the device acceptance checklist in [the release plan](docs/formal-release-1.5.0-plan.md) pass. The formal package owns Settings and automatic maintenance; the optional standalone LiveCC package owns the Control Center preview.

Host checks:

```sh
python3 -m unittest discover -s tests -v
python3 scripts/verify_release_source.py --repo .
```
