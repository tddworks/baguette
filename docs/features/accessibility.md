# Accessibility tree

Read the on-screen UI tree (labels, frames, traits, identifiers) of a
booted simulator without taking a screenshot or running a test bundle.
Two entry points share one dispatch path:

- `baguette describe-ui --udid <UDID> [--x <px> --y <px>] [--output <path>]` — CLI.
- Wire JSON `{ "type": "describe_ui", "x"?: <px>, "y"?: <px> }` on
  `baguette serve`'s `/simulators/:udid/stream` WebSocket. Reply
  arrives on the same socket as
  `{ "type": "describe_ui_result", "ok": true, "tree": { … } }`.

This is the structured-context counterpart to `screenshot.jpg` —
where the screenshot tells an agent *what it looks like*, the AX
tree tells it *what's actually there*: button labels, frame
rectangles in device points, accessibility identifiers, and the
parent / child structure underneath.

## Wire JSON — request

```json
{ "type": "describe_ui" }
{ "type": "describe_ui", "x": 172, "y": 880 }
```

- No `x` / `y` → full tree of the frontmost application.
- Both `x` and `y` → hit-test: returns the topmost AX node whose
  `frame` contains the point. Coordinates are **device points**,
  same units as the gesture wire (`tap`, `swipe`, `width`,
  `height`).

## Wire JSON — reply

```json
{
  "type": "describe_ui_result",
  "ok": true,
  "tree": {
    "role": "AXButton",
    "subrole": null,
    "label": "Safari",
    "value": null,
    "identifier": "Safari",
    "title": null,
    "help": "Double tap to open",
    "frame": { "x": 136, "y": 844.33, "width": 72, "height": 72 },
    "enabled": true,
    "focused": false,
    "hidden": false,
    "children": []
  }
}
```

`ok: false` with an `error` string when AX isn't available
(framework missing, simulator not booted, no frontmost app, XPC
timeout). The CLI exits non-zero in those cases; the WS message
keeps the socket open and lets the caller try again.

A node's `frame` is in device points, **letterbox-corrected** for
devices whose host-window aspect doesn't match their screen
(simulator window centres the device vertically — we re-add that
offset). Pipe `frame.x + frame.width / 2`, `frame.y + frame.height / 2`
straight back into a `tap` envelope and the touch lands.

## Dispatch path

```
CLI / WS  →  Simulator.accessibility()  →  Accessibility port
                                                    │
                                                    ▼
                                  AXPTranslatorAccessibility
                                  (Infrastructure/Accessibility/)
                                                    │
                            sets up TokenDispatcher │ as the translator's
                            bridgeTokenDelegate     │ (one-time, process-wide)
                                                    ▼
                          AXPTranslator (sharedInstance)
                                                    │
                            per-call: register UUID │ token → SimDevice;
                            translator's XPC requests│ flow back through
                            the dispatcher's block;  │ block invokes
                            SimDevice.sendAccessibilityRequestAsync
                                                    ▼
                                           in-simulator AX server
```

Cribbed from `cameroncooke/AXe` and
`Silbercue/SilbercueSwift`'s `AXPBridge.swift` — the only public
Swift implementations of the iOS-26 / Xcode 26 dispatcher pattern
we found.

### Why the dispatcher is the trick

`AXPTranslator` is a process-wide singleton in
`AccessibilityPlatformTranslation.framework`. Inside Simulator.app
its `bridgeTokenDelegate` is wired up by `SimulatorKit.SimAccessibilityManager`
when a display view is added per simulator. Out of Simulator.app —
which is where `baguette` runs — the delegate is `nil`, and every
`-frontmostApplicationWithDisplayId:bridgeDelegateToken:` call
returns `nil` because the translator has no idea where to send its
XPC requests.

The fix: install our own `bridgeTokenDelegate` (the
`TokenDispatcher` class). It implements three `@objc dynamic`
methods that AXPTranslator looks up:

- `-accessibilityTranslationDelegateBridgeCallbackWithToken:` —
  returns a **block** `(AXPTranslatorRequest) -> AXPTranslatorResponse`
  that routes the request to the right `SimDevice` via
  `-sendAccessibilityRequestAsync:completionQueue:completionHandler:`.
- `-accessibilityTranslationConvertPlatformFrameToSystem:withToken:` —
  identity transform; we re-project later when we have the AX root.
- `-accessibilityTranslationRootParentWithToken:` — `nil`.

`@objc dynamic` and `NSObject` subclassing are mandatory because
AXP invokes the delegate via ObjC dispatch.

### Per-call dance

```
1. Token = UUID().uuidString
2. dispatcher.register(device: simDevice, token, deadline)
3. translation = translator.frontmostApplicationWithDisplayId:0
                                          bridgeDelegateToken:token
4. translation.bridgeDelegateToken = token   ← critical, see below
5. root = translator.macPlatformElementFromTranslation:translation
6. root.translation.bridgeDelegateToken = token
7. walk root.accessibilityChildren, stamping the token onto each
   child's `translation` sub-property
8. dispatcher.unregister(token)
```

Step 4 is the single most important thing. The translator stores
the token internally, but it re-reads `bridgeDelegateToken` from
**every translation object** it touches — if a child object was
returned by AXP without our token stamped on it, the next sub-XPC
silently fails.

## Coordinates

`AXPTranslator` reports `accessibilityFrame` in **macOS host-window**
coordinates — i.e. where Simulator.app's window would put that
button on the host screen. To project to device points we read
`SimDevice.deviceType.mainScreenSize` (pixels) and
`mainScreenScale`, divide one by the other to get the logical
point size, and apply:

```
scale   = pointSize.width / rootFrame.width
yOffset = (pointSize.height - rootFrame.height * scale) / 2
out.x   = (mac.x - rootFrame.x) * scale
out.y   = (mac.y - rootFrame.y) * scale + yOffset
out.w   = mac.width  * scale
out.h   = mac.height * scale
```

Width-based uniform scale + vertical centring matches Simulator.app's
own letterbox behaviour for tall devices on a short window. The
output is in the same device-point space the gesture wire uses, so
`tap` / `swipe` envelopes can consume the frame directly.

## Adding a new field

The mapping from `AXPMacPlatformElement` properties to `AXNode`
fields lives in `AXPTranslatorAccessibility.walk(...)`. To add a new
column (e.g. `accessibilityTraits`):

1. **Domain.** Add the field to `AXNode` (`Sources/Baguette/Domain/Accessibility/AXNode.swift`)
   with a default value, and to its `dictionary` JSON projection.
2. **Tests.** Extend `AXNodeTests` to assert the JSON shape and the
   `nil`-handling semantics.
3. **Adapter.** Read the property in `walk(...)` via
   `Self.stringValue` / `Self.boolValue` / `Self.frame`. If the
   property returns a non-string/bool/CGRect type, write a typed
   `class_getMethodImplementation` cast like `Self.frame` does.
4. **Doc.** Add a row to the example response above and update the
   wire-protocol reference.

## Known limits

- **Tree is a snapshot.** No subscribe / change notifications.
  Callers re-issue `describe_ui` after each gesture.
- **Frontmost-app only.** SpringBoard idle returns `null` for some
  states. Active app is what you get; we don't expose system-level
  overlays (Control Centre, Notification Centre).
- **Group containers occasionally drop children.** Inherited from
  AXP's behaviour on `role=group`; the
  [idb#767](https://github.com/facebook/idb/issues/767) workaround
  is to prefer the `--x --y` hit-test path for elements that don't
  surface in the full tree.
- **Slider / progress values stringify NSNumber.** Anything that
  AXP returns as `NSNumber` for `accessibilityValue` (sliders, page
  pickers) lands in JSON as a stringified number. JSON consumers
  that want to discriminate semantics should check `role`.
- **One XPC handshake per call.** First call after process startup
  pays a ~hundreds-of-ms warm-up while the AX connection comes up;
  subsequent calls reuse it. No connection pool.

## Further reading

- `Sources/Baguette/Infrastructure/Accessibility/AXPTranslatorAccessibility.swift`
  — the dispatcher recipe with inline commentary.
- `Sources/Baguette/Domain/Accessibility/AXNode.swift` — the value
  type + `hitTest` recursion.
- [Silbercue/SilbercueSwift `AXPBridge.swift`](https://github.com/Silbercue/SilbercueSwift/blob/main/SilbercueSwiftMCP/Sources/SilbercueSwiftCore/AXPBridge.swift)
  — the source of the dispatcher pattern.
- [cameroncooke/AXe](https://github.com/cameroncooke/AXe) — the
  reference implementation for the AXPTranslator path on iOS 26.
