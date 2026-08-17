# NetworkManagerReborn

NetworkManagerReborn continues NoisyFlake's original [NetworkManager](https://github.com/NoisyFlake/NetworkManager), with earlier maintenance by Nixuge and current maintenance at [doimty/NetworkManagerReborn](https://github.com/doimty/NetworkManagerReborn).

## 1.5.0 scope

Version 1.5.0 replaces legacy RAT cycling with a reversible n78 preference:

- When NR is used, the allowed NR list is changed to exactly n78.
- LTE and every other non-NR band list remain unchanged.
- LTE fallback remains available when n78 is not serving.
- Requested policy, verified applied policy, and fresh serving RAT/Band are displayed independently.
- A retained baseline and package removal guard prevent uninstall or downgrade from stranding the modem on the modified NR list.

This is not a hard n78 lock. Carrier policy, coverage, idle state, thermal state, and modem selection can still move service to LTE.

The first acceptance target is intentionally restricted to `iPhone14,3` running iOS 15.1.1 (`19B81`) with one present and good SIM in slot 1. Other devices and builds fail closed.

## Release status

The 1.5.0 source is under validation. Rootless and roothide packages are not release-ready until pinned Xcode 15.4 cloud builds and the device acceptance checklist in [the release plan](docs/formal-release-1.5.0-plan.md) pass.

Host checks:

```sh
python3 -m unittest discover -s tests -v
python3 scripts/verify_release_source.py --repo .
```
