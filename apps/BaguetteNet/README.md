# BaguetteNet

The macOS **host app + NetworkExtension content-filter system extension**
that throttles a single simulator's network (bandwidth / latency / packet
loss) without touching the rest of the Mac. This is the *activator bundle*
the [network-speed-control design](../../docs/design/network-speed-control.md)
calls for — a bare CLI can't activate a System Extension, only a bundled
app can.

Scaffolded with **Tuist** (the `Project.swift` is the source of truth; the
`.xcodeproj` / `.xcworkspace` are generated and git-ignored).

## Layout

```
apps/BaguetteNet/
├── Project.swift                 # Tuist: 4 targets (Kit / App / Extension / Tests)
├── Shared/                       # BaguetteNetKit — pure, unit-tested core
│   ├── NetworkProfile.swift      #   the three fields + presets
│   ├── ThrottleEngine.swift      #   verdict math (allow / drop / pause) + PacketLossGate
│   └── ProfileStore.swift        #   app-group handoff (app writes, extension reads)
├── App/Sources/                  # BaguetteNet — SwiftUI host
│   ├── BaguetteNetApp.swift
│   ├── ContentView.swift         #   preset pills + 3 sliders + match keys
│   └── NetworkExtensionController.swift   # OSSystemExtensionManager + NEFilterManager
├── Extension/Sources/            # BaguetteNetExtension — the .systemextension
│   ├── main.swift                #   NEProvider.startSystemExtensionMode()
│   ├── FilterDataProvider.swift  #   NEFilterDataProvider → ThrottleEngine verdicts
│   └── SourceApp.swift           #   audit-token → signing id (macOS source-app match)
└── Tests/                        # BaguetteNetKitTests — Swift Testing, 10 tests
```

The decision logic (what to allow / drop / pause-for-how-long) is **pure**
and lives in `Shared/`, fully unit-tested. The `NEFilter*` /
`OSSystemExtensionManager` / Security calls are the thin, integration-only
edges.

## Build & test

```bash
cd apps/BaguetteNet
tuist generate                 # produces the .xcworkspace

# Unit tests — no signing needed (framework + test bundle only):
xcodebuild test -workspace BaguetteNet.xcworkspace -scheme BaguetteNetKit \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Running the real throttle (needs a dev team)

The `content-filter-provider` entitlement is **not** ad-hoc-signable, and a
System Extension can only be activated by a signed, bundled app. So:

1. Set your Team ID in `Project.swift` (`DEVELOPMENT_TEAM`) and regenerate.
2. One-time on the dev machine, to allow a dev-signed sysext outside
   `/Applications`:
   ```bash
   systemextensionsctl developer on
   ```
3. Build & run the `BaguetteNet` scheme. Click **Activate Extension** and
   approve it in System Settings → Login Items & Extensions → Network
   Extensions.
4. Pick a preset (or set the three sliders), set **Target** match keys
   (substrings of the source app's signing id — the
   `SimDevice` / simulator-runtime identifier is the open spike), and
   **Apply throttle**. **Clear** removes it.

## Status

This is a working scaffold: it generates, compiles (app + extension), and
the pure core is green (10/10). The simulator-flow `sourceAppIdentifier`
match (what string a simulator app's flows actually carry on the host) is
the empirical spike flagged in the design doc — `SourceApp` resolves a
signing id; confirming the exact match key for simulator traffic is the
next step before this throttles a real simulator end-to-end.
