# NR Manager

NR Manager is a Control Center module for selecting allowed NR bands and viewing the actual serving network. It narrows only the NR band list selected by the user, keeps LTE available as fallback, and publishes the source code at [NR Manager source repository](https://github.com/doimty/NetworkManagerReborn).

## What it does

- Select one or more NR bands that are already both enabled by iOS and supported by the modem.
- Apply the selection through the existing reversible policy switch.
- Leave LTE and every other non-NR band list unchanged.
- Show requested policy, verified applied policy, and fresh serving RAT/band as separate states.
- Retain the original complete configuration so disabling the policy, recovering from an interrupted operation, removing the package, or downgrading can restore it safely.
- Support dual-SIM devices by selecting the current data subscription on first enable and retaining that subscription identity for later verification and restore.

NR Manager is a band preference, not a hard 5G or NR lock. Carrier policy, coverage, idle state, thermal state, and modem selection can still move service to another selected band or to LTE. Selecting every currently available NR band is treated as the system-default state rather than as a modem write.

## Current status

Version 1.6.4 is under source validation. Rootless and roothide packages are not release-ready until the pinned Xcode 15.4 cloud builds and the device acceptance checklist pass. The formal package includes the Control Center module, Settings interface, and automatic maintenance. The standalone LiveCC target remains an isolated read-only prototype and is not a deliverable package.

The first end-to-end acceptance was performed on `iPhone14,3` running iOS 15.1.1 (`19B81`). That device is recorded evidence, not a compatibility allowlist. Runtime checks validate the private CoreTelephony ABI, the target subscription, fresh active and supported NR capabilities, and every modem write by complete read-back.

## Checks

```sh
python3 -m unittest discover -s tests -v
python3 scripts/verify_release_source.py --repo .
```
