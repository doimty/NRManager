# NR Manager Live Control Center Preview

This is an isolated, non-deliverable prototype for a read-only live serving-status
Control Center module. It does not replace or extend the production NR Manager bundle (`NRManager.bundle`).

This preview tests whether a standalone `CCUIContentModule` can own a
`CCUIButtonModuleViewController`, refresh serving-band state while Control Center
is visible, and update `glyphImage` directly without any toggle or policy-writing
path?

Current status: version 0.0.1 loaded on the target device without a SpringBoard
crash and refreshed serving bands quickly. Version 0.0.2 added a radio-search
SF Symbol and one pending RAT refresh; device feedback confirmed the symbol but
found its raw bounds offset and black tint inappropriate. Version 0.0.3 renders
the search symbol as white, always-original media centered in the same 70x70
canvas used by band text, and renders `B3`/`n78`/`n79` text in white. Version
0.0.4 adds the shared responsive serving sampler: two consecutive clean samples
with the same normalized RAT+Band complete in about one second of scheduled
settle time, while changed, ambiguous, or unusable samples reset confirmation.
NR has priority over LTE in NSA snapshots, but an unclassifiable or conflicting
winning tier cannot fall through to a lower RAT. Responsive LTE confirmation is
only UI convergence and does not claim the diagnostic full-window NR-negative
result. The confirmed cell and timestamp come from the second copy. This version
also reduces RAT-notification debounce from two seconds to 250 ms and suppresses
superseded completions/cache notifications. Diagnostic adaptive/full-window
sampler APIs remain unchanged. Version 0.0.5 isolates the prototype's cache and
Darwin notification namespace from the installed stable package, serializes
publication revisions with a dedicated advisory lock, refuses to publish a
false-safe summary on modem-lock contention, and clears pending refresh state
across visibility sessions. Each version still requires pinned roothide cloud
validation before device delivery.

Run the focused checks:

```sh
python3 -m unittest discover -v -s tests
```

Compile the rootless bundle with the pinned local SDK:

```sh
THEOS=/root/.openclaw/workspace/toolchains/theos make package \
  SYSROOT=/root/.openclaw/workspace/toolchains/theos/sdks/iPhoneOS16.5.sdk
```

Do not install or deliver packages produced by this directory. The prototype
must be reviewed and absorbed into a production design or deleted.
