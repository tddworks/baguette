---
description: How describe-ui talks to the simulator's AX server from outside Simulator.app — the AXPTranslator bridge-token dispatcher, the per-call token dance, and the UIKit-point-to-native-panel-point rotation. Read before touching accessibility.
---

# Accessibility — design

## Path

```
CLI / WS  →  Simulator.accessibility()  →  Accessibility     
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
  identity transform; the observed display geometry rotates the guest frames later.
- `-accessibilityTranslationRootParentWithToken:` — `nil`.

`@objc dynamic` and `NSObject` subclassing are mandatory because
AXP invokes the delegate via ObjC dispatch.

### Per-call dance

```
1. simctl [--set path] spawn UDID HingeControl frontmost → live PID
2. translation = SimDevice.sendAccessibilityRequestAsync(
                     requestType: 1, parameters: {pid})
3. Token = UUID().uuidString
4. dispatcher.register(device: simDevice, token, deadline)
5. translation.bridgeDelegateToken = token   ← critical, see below
6. root = translator.macPlatformElementFromTranslation:translation
7. root.translation.bridgeDelegateToken = token
8. walk root.accessibilityChildren, stamping the token onto each
   child's `translation` sub-property
9. dispatcher.unregister(token)
```

Step 5 is the single most important thing. The translator stores
the token internally, but it re-reads `bridgeDelegateToken` from
**every translation object** it touches — if a child object was
returned by AXP without our token stamped on it, the next sub-XPC
silently fails.

### Fresh guest frontmost discovery

On iOS 26.5 the CoreSimulatorBridge frontmost request
(`-frontmostApplicationWithDisplayId:bridgeDelegateToken:`) can return an
empty `AXPTranslatorResponse` even while its application-by-PID requests
work, and `describe-ui` answered `null` for a visibly running app. Each
query therefore asks the guest window server for the current frontmost PID
in a fresh `HingeControl frontmost` process: inside the guest, the AX
translator routes requests to its own `processTranslatorRequest:`, and no
HID framework is loaded or input service registered. The implementation
follows [idb's guest runtime](https://github.com/facebook/idb/blob/1c5c81f6cbe3a31986eda66349fd22a2f9b47858/SimulatorFrameworkBridge/Runtime/AccessibilityRuntime.m#L831)
and ships its MIT notice (`LICENSE.idb`) next to the helper.

The guest exits within four seconds of reaching `main`, on an independent
watchdog. Its main queue stays live while the query runs off-main: blocking
main delays `_enableAccessibilityBridgeRuntime` callbacks by three seconds on
iOS 26.5. The host allows ten seconds for `simctl` startup, the guest query,
exit and pipe drain; other `simctl` queries keep their five-second budget.
The host reads stdout and stderr separately and decodes only the final
stdout line, which the helper starts with a newline so an injected dylib's
partial diagnostics cannot run into it. An invalid final line fails the
query; an earlier PID is never reused, and there is no cached-PID path.
The application lookup goes to the selected SimDevice directly because the
host translator's PID convenience method sends an empty bridge token, which
cannot tell concurrent devices apart. The tree's deadline starts after
discovery completes.

## Coordinates

With the identity delegate, `AXPTranslator` reports `accessibilityFrame`
in **UIKit screen points** of the guest. The application root is neither
a host window nor a source of display scale: a hosted app can report a
partial window, so its bounds must not define the screen. The native
panel size comes from the bound framebuffer port and the connected
screen's `Preferred UI Scale`, and
`SimulatorKit.SimDeviceScreen.screenProperties` reports the **observed**
interface orientation (an app can refuse a requested rotation).

For a native panel W×H, a UIKit point `(x, y)` maps to the HID point:

| Orientation | Native point |
|---|---|
| portrait | `(x, y)` |
| landscape-left | `(y, H - x)` |
| landscape-right | `(W - y, x)` |
| portrait-upside-down | `(W - x, H - y)` |

Rectangle edges use the same transform (`AXFrameTransform.map`) and point
queries invert it before calling AXP (`AXFrameTransform.unmap`). Each outer
result carries `screen: {width, height, orientation, target}`; descendants
carry native `frame`s. The geometry is read before and after the AX query
and a changed orientation, panel identity or size rejects the result. That
detects transitions the host can observe; it does not make the guest tree an
atomic snapshot. Missing or unknown geometry throws instead of guessing a
phone size.

The four mappings were established with a full-screen UIKit probe on an
iPad mini (A17 Pro) simulator: raw PNGs stayed 1488×2266 pixels and HID
normalised coordinates stayed in the native 744×1133 point space in every
orientation, and taps at AX-reported centres hit their off-centre targets
in all four directions. The previous root-width scale missed every
non-portrait target. Compatibility-hosted applications may add another
guest transform; that case is not covered by this probe and must never be
inferred by scaling an application root to the panel.

## Adding a field

The mapping from `AXPMacPlatformElement` properties to `AXNode` fields
lives in the adapter's walk; a property that returns a
non-string/bool/CGRect type needs a typed
`class_getMethodImplementation` cast like the frame reader does.

## References

- [Silbercue/SilbercueSwift `AXPBridge.swift`](https://github.com/Silbercue/SilbercueSwift/blob/main/SilbercueSwiftMCP/Sources/SilbercueSwiftCore/AXPBridge.swift)
  — the source of the dispatcher pattern.
- [cameroncooke/AXe](https://github.com/cameroncooke/AXe) — the
  reference implementation for the AXPTranslator path on iOS 26.
- [idb#767](https://github.com/facebook/idb/issues/767) — AXP dropping
  children of `role=group` containers.
