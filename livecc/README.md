# NetworkManager Live CC Prototype

This is an isolated, non-deliverable prototype for a read-only live serving-band
Control Center module. It does not replace or extend `NetworkManager.bundle`.

Prototype question: can a standalone `CCUIContentModule` own a
`CCUIButtonModuleViewController`, refresh serving-band state while Control Center
is visible, and update `glyphImage` directly without any toggle or policy-writing
path?

Current verdict: host contracts and a pinned-SDK rootless compile pass. Runtime
loading, glyph rendering, notifications, and lifecycle behavior remain unverified
on a device, so this is not a delivery candidate.

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
