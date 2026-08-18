# NetworkManager Live CC Prototype

This is an isolated, non-deliverable prototype for a read-only live serving-band
Control Center module. It does not replace or extend `NetworkManager.bundle`.

Prototype question: can a standalone `CCUIContentModule` own a
`CCUIButtonModuleViewController`, refresh serving-band state while Control Center
is visible, and update `glyphImage` directly without any toggle or policy-writing
path?

Current verdict: version 0.0.1 loaded on the target device without a SpringBoard
crash and refreshed serving bands quickly. Version 0.0.2 added a radio-search
SF Symbol and one pending RAT refresh; device feedback confirmed the symbol but
found its raw bounds offset and black tint inappropriate. Version 0.0.3 renders
the search symbol as white, always-original media centered in the same 70x70
canvas used by band text, and renders `B3`/`n78`/`n79` text in white. Each version
still requires pinned roothide cloud validation before device delivery.

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
