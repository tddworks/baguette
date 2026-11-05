---
description: The normative domain model baguette binds to — the tree from Simulators down, the words the CLI and the page use, every law and its one owner, and the bounded contexts; read before adding or changing a Domain type, an @Mockable abstraction or where a rule lives.
---

# baguette — the canonical model

> ONE tree. The CLI, `baguette input`, the `serve` page and its plugins all
> drive it; none of them adds a rule to it. A node is here because a user can
> name it (a verb, a flag, a card on the page), and a rule lives on **the node
> that holds the data it needs** (tell, don't ask).
>
> **Answers:** what is true — the nodes, the words, the laws and their owners.
> **Next:** [ARCHITECTURE.md](ARCHITECTURE.md) for how a tap travels through
> the layers, and each feature's `design.md` for the private-API research.

## 0 · How to read it

| Mark | Means |
|---|---|
| **◆** | a domain object or `@Mockable` role with commands — it can refuse |
| **◇** | a value — it answers, and cannot be told anything |
| **DERIVED** | computed from other nodes, never stored |

**The words are the ones the user types and sees**: the CLI verbs and flags,
the wire `type` names, the page's cards (*Defaults*, *Network*, *Location*),
and Apple's own where we have none (*cover*, *unfolded panel*, *Device Hub*).
Their exact syntax is in [commands.md](commands.md) and [wire.md](wire.md). An abstraction is named for the role it plays — `Input`,
`Screen`, `Hinge`, `Subprocess` — never for a pattern (`Port`, `Service`,
`Manager`, `Repository`); aggregate persistence takes the plural (`Simulators`,
`Chromes`). See [AGENTS.md](../AGENTS.md#naming-the-abstractions).

| A word | Means here, and only here |
|---|---|
| **device points** | the unit of every coordinate and of the `width` / `height` beside it; never normalized, never pixels |
| **display plane** | one of a device's screens as baguette drives it: `phone` or `carPlay` |
| **panel** | one of a foldable's own screens: the **cover** (`primary`) or the **unfolded** panel (`secondary`) |
| **lit panel** | the panel the hinge lights now; everything that touches or shows the phone plane follows it |
| **binding** | a display plane's framebuffer *and* digitizer, chosen together |
| **target** | a HID digitizer registration — a constant some create-service message registered, never a number computed |
| **injected** | a capability delivered by a dylib in the guest (`motion`, `network`, camera): only apps launched after it is armed see it |
| **heal** | reclaim the input surface Device Hub took: restart backboardd |

## 1 · The tree

```text
Simulators  ◆                               THE DEVICES — a device set (default or --device-set): `list`
└── Simulator  ◆                            ONE DEVICE — udid, name, state, runtime, device type
    │                                       boot() · shutdown(); canAcceptInput DERIVED (booted)
    ├── displays → Displays  ◆              ITS SCREENS
    │   ├── phone: Display  ◆              the device's own screen — follows the lit panel
    │   ├── panel(cover | unfolded)  ◆     one panel pinned, the hinge not asked (the 3D book)
    │   └── carPlay: Display  ◆            an attached CarPlay display; never enabled implicitly
    │       Display: resolve() → DisplayBinding ◇ · screen() → Screen ◆ · input() → Input ◆
    │                observedScreen() → AXScreen ◇ · input(expected:) for --expected-screen
    ├── input → Input  ◆                    GESTURES, in device points: tap · swipe · touch1 · touch2 ·
    │   │                                   button · key · scroll · twoFingerPath. `ok` = sent, not landed
    │   ├── Gesture  ◇ (GestureRegistry)    the wire dialect: one type per `type`, parse(dict) → execute(on:)
    │   ├── FoldableInput  ◆                a foldable's keys — hardware and keyboard — through DeviceKeys
    │   └── LitPanelInput  ◆                a socket that outlives a fold: each gesture to the lit panel,
    │                                       a touch on the panel it went down on until it lifts
    ├── hinge → Hinge  ◆                    THE FOLD — angle() · watch(onAngle:) · fold(to:over:)
    │   └── litPanel                        DERIVED — the angle's panel; no reading is folded (cover)
    ├── orientation → Orientation  ◆        portrait · landscape-left · landscape-right · upside-down
    ├── accessibility → Accessibility  ◆    WHAT IS ON SCREEN — describeAll() · describeAt(point:)
    │   └── AXNode  ◇                       role · label · value · identifier · frame (device points) ·
    │                                       children; the root carries AXScreen ◇ (size, orientation, panel)
    ├── logs → LogStream  ◆                 the unified log, filtered (LogFilter ◇)
    ├── THE CONDITIONS THE APP RUNS UNDER
    │   ├── location → Location  ◆          set(Coordinate ◇) · start(LocationRoute ◇) · clear()
    │   ├── motion → Motion  ◆              injected — publish(MotionIntent ◇) · clear()
    │   ├── network → Network  ◆            injected — apply(NetworkCondition ◇) · clear() · current()
    │   ├── interface → Interface  ◆        appearance · contrast · content size; unknown / unsupported
    │   ├── statusBar → StatusBar  ◆        override(StatusBarOverride ◇) · clear()
    │   └── shake → Shake  ◆
    ├── APPS AND THEIR DATA
    │   ├── apps → Apps  ◆                  install · launch · terminate · open(DeepLink ◇) ·
    │   │                                   deliver(RemoteNotification ◇) · installed
    │   ├── defaults → Defaults  ◆          read · write · delete — PreferenceEdit ◇ / PreferenceImport ◇
    │   │                                   apply with a Relaunch ◇ (never · always · whenNeeded)
    │   ├── pasteboard → Pasteboard  ◆      Paste ◇ (any unicode) · Copy ◇ (sim → host)
    │   └── photos → PhotoLibrary  ◆        MediaItem ◇
    ├── chrome(in: Chromes) → DeviceChromeAssets  ◇   the bezel, by device TYPE, per panel
    └── deviceModel(in: DeviceModels)  ◇    the 3D model, by device type first, then name

Chromes  ◆            bezels and profiles by device type — panels(forDeviceName:) says if it folds
DeviceModels  ◆       installed 3D models · DeviceRenderer ◆ · DeviceScene ◆ (the page's 3D book)
Stream  ◆             a framebuffer as MJPEG or AVCC — StreamFormat ◇ · StreamDisplayPlan ◇
CameraSessions  ◆     one virtual camera per server — Cameras ◆ · CameraSource ◇
Plugins  ◆            installed plugins — PluginManifest ◇ · PluginRoute ◇ · PluginGrants ◆
Bakery  ◇             trusted plugin sources — Checkout ◆ · InstallPlan ◇
Devices  ◆            physical-device twins — not wired: no companion app ships
```

## 2 · The commands, and the node each lands on

| The user does | The node is told | Notes |
|---|---|---|
| `boot` · `shutdown` | `simulator.boot()` · `shutdown()` | `boot` then heals if Device Hub attached |
| `heal` | `InputSurface.heal(on:)` | restarts backboardd; running apps die |
| `tap` · `swipe` · `pinch` · `pan` · `press` · `type` · `key` | `Gesture.execute(on: sim.input())` | one process per gesture; the input binds the lit panel once |
| `input` (stdin) · the stream WebSocket | `GestureDispatcher` → the plane's `Input` | many gestures; `--expected-screen` → `displays.phone.input(expected:)` |
| the Duo's 3D page | `sim.litPanelInput()` | the socket outlives a fold |
| `paste` · `clipboard …` | `Paste.execute(pasteboard:input:)` · `pasteboard` | the path around `type`'s US-ASCII limit |
| `hinge --pose` · `--angle` | `HingeCommand.parse` → `hinge.fold(to:over:)` | exit 3 when unconfirmed (`PoseDelivery`) |
| `orientation <value>` | `orientation.set(_:) → PoseDelivery` | on a foldable, through the hinge motor |
| `describe-ui [--x --y]` | `accessibility.describeAll()` · `describeAt(point:)` | |
| `screenshot` · `stream` · `record` | `StreamDisplayPlan.bind(to:)` → `Screen` | CarPlay fails closed, never the phone instead |
| `location set · start · walk · clear` | `location.set` · `start(route)` · `start(walk.route())` · `clear` | |
| `motion start · set · stop` | `motion.publish` · `clear` | injected |
| `network set · clear · status` | `network.apply` · `clear` · `current` | injected; `clear` reaches running apps |
| `interface appearance · contrast · text-size` | `interface` get / set | no value reads |
| `status-bar override · clear` | `statusBar.override` · `clear` | |
| `install` · `add-media` · `openurl` · `notify` | `apps.install` · `photos.add` · `apps.open(DeepLink)` · `RemoteNotification.deliver(to: apps)` | |
| `defaults write · delete · import` | `PreferenceEdit` / `PreferenceImport` `.apply(on: defaults, apps:)` | `--relaunch-if-needed` is `Relaunch.whenNeeded` |

## 3 · The laws, on the node that owns them

| Law | Owner |
|---|---|
| every coordinate is in device points, with the plane's `width` / `height` beside it; the adapter divides by size, the domain never normalizes | `Point` · `Size` · `IndigoHIDInput.sendMouse` |
| a display's screen and input come from one binding, so a framebuffer never pairs with another plane's digitizer | `Display` · `DisplayBinding` |
| a HID target is a registration, never computed from a screen id; an unregistered one kills backboardd. The phone plane uses its bound panel's `0x40000000 \| screenId`, else `0x32`; CarPlay its own `1` | `IndigoHIDTouchTarget` · `DisplayTouchTarget.resolve` |
| a read of the frontmost app asks the bridge first and runs the guest helper only when the bridge can't read it; no PID outlives its query | `AXFrontmostRead` |
| the sweep always looks where the walk can't see, and sweeps the gaps in full only when a scout finds something the walk didn't know | `AXSweep` |
| a probe override may name only a known target | `DisplayTouchTarget.parseOverride` |
| the external digitizer is never released | `InputTeardown.forPlane` |
| an unknown edge, modifier, phase or button is an error, never a fallback | `Field` · `Key.parseModifiers` · `Press.parse` |
| `type` / `key` are US-layout printable ASCII; anything else fails to parse and goes through `paste` | `KeyboardKey.decompose` · `TypeText.parse` |
| `siri` is not a button: every known path crashes backboardd | `DeviceButton` (left out on purpose) |
| no hinge reading means as booted: folded, the cover | `Hinge.litPanel` |
| 90° or more lights the unfolded panel | `HingeAngle.litPanel` |
| everything on the phone plane follows the lit panel; a socket that outlives a fold asks per gesture, and a touch stays on the digitizer it went down on until it lifts | `Displays.phone` · `LitPanelInput` |
| a foldable's keys — volume, power, action, and keyboard keys — go to the guest's buttons service, not Indigo | `FoldableInput` → `DeviceKeys` |
| a pose move that timed out is *unconfirmed*, not rejected: it may have landed | `PoseDelivery` |
| re-observe the screen before a `down` and a `move`, never before an `up` | `InputScreenGuard` |
| the external plane never falls back to a phone-sized surface; CarPlay never streams the phone | `FramebufferSurfacePick` · `StreamDisplayPlan.bind` |
| CarPlay is never enabled implicitly when `--require-existing-display` asks | `StreamDisplayPlan` |
| Device Hub can shadow the input surface; healing restarts backboardd and kills running apps | `InputSurface` · `DeviceHubAttachment` |
| an injected capability reaches only apps launched after arming; `DYLD_INSERT_LIBRARIES` is shared, so arming is read-modify-write by dylib name | `Motion` · `Network` · `InjectedDylibs` |
| injected dylibs install under per-hash paths, so dyld never serves a stale page | `InjectedDylibInstallPlan` |
| network conditioning is per simulator; `clear` reaches running apps | `Network` |
| `unknown` and `unsupported` are answers, not errors | `InterfaceReading` · `ContentSize` |
| a write to a running app's settings may not be seen: `whenNeeded` relaunches only for keys it doesn't watch, and relaunches when it can't say | `Relaunch` · `PreferenceEdit` |
| a preference's type is never coerced; a suite name can't smuggle a path or a flag | `PreferenceValue` · `PreferenceSuite` |
| a push payload is an object with `aps`, at most 4096 bytes; an explicit bundle id beats the payload's | `RemoteNotification` |
| an `http(s)` link opens in Safari, a custom scheme in its app | `DeepLink` |
| a coordinate out of range never constructs; a route needs two points; a bearing wraps onto 0–360 | `Coordinate` · `LocationRoute` · `Bearing` |
| a bezel is found by device type, never by UDID | `Chromes` |
| one virtual camera owner per server; a source is only ever downscaled | `CameraSessions` · `ScaleToFit` |
| a plugin route not in the table is denied; grants are per invocation | `PluginRoute` · `PluginGrants` |
| a bakery installs only its pinned commit | `BakeryUpdate` |

## 4 · What is deliberately NOT in the tree

| Absent | Why |
|---|---|
| `XxxPort` · `XxxService` · `XxxManager` · `XxxRepository` | pattern labels, not roles ([AGENTS.md](../AGENTS.md#naming-the-abstractions)) |
| a subclass or `if name == "iPhone Duo"` per device | what differs is data: the profile's panels, the chrome, the 3D model. A foldable is a device whose `Chromes` lists two panels |
| a `--display inner` / `--panel` on gestures | the hinge picks the lit panel; folding is how you choose it |
| a HID target from `IndigoHIDTargetForScreen` or any arithmetic | a trap: only registrations are safe |
| normalized coordinates in the domain | device points end to end; the adapter normalizes |
| a `siri` button | it crashes backboardd |
| a ViewModel, or rules in the page's JS | the page is a dumb sender; `KeyboardKey.from(wireCode:)` resolves keys in Swift |
| a second `Input` hierarchy for tests | `IndigoHIDInput` is the only adapter; tests use `MockInput` |

## 5 · The contexts

Each is a **fence**: inside it every word has one meaning, and its laws have
one owner. Across a fence only a reference passes (an id, a value of the
shared kernel) — never another context's aggregate, its storage or its
adapter. `Sources/Baguette/Domain/<Context>/`, its `Infrastructure/<Context>/`
and `Tests/BaguetteTests/<Context>/` share a name.

| Context | Owns the question | Its root |
|---|---|---|
| **Common** (shared kernel) | *in what units?* | ◇ `Point` `Size` `Rect` `GesturePhase` `HIDUsage` `DeviceEdge` `DeviceButton` |
| **Simulator** (core) | *which devices are there, and what are they made of?* | ◆ `Simulators` → `Simulator` → `Displays` · `InputSurface` · `SimulatorInjection` |
| **Screen** | *which framebuffer is this plane, which panel is it?* | ◆ `Screen` · ◇ `DisplayBinding` `ConnectedScreens` `IntegratedPanel` |
| **Input** (core) | *how does a gesture reach the device?* | ◆ `Input` · `Gesture` · `DeviceKeys` |
| **Hinge** | *how far open is the fold?* | ◆ `Hinge` · `HingeMotor` · ◇ `HingeAngle` `HingeCommand` |
| **Orientation** | *which way is it turned?* | ◆ `Orientation` |
| **Accessibility** | *what is on screen?* | ◆ `Accessibility` · ◇ `AXNode` `AXScreen` |
| **Chrome** · **Render** · **Capture** | *what does the device look like, and how is it framed?* | ◆ `Chromes` · `DeviceModels` · ◇ `CaptureSize` |
| **Stream** · **Recording** | *how do frames leave?* | ◆ `Stream` · `Reel` |
| **Location** · **Motion** · **Network** · **Interface** · **StatusBar** · **Shake** · **Camera** | *what conditions does the app run under?* | one ◆ role each |
| **Apps** · **Defaults** · **Pasteboard** · **Photos** | *which apps, and what data?* | one ◆ role each |
| **Logs** | *what is the device saying?* | ◆ `LogStream` · `Subprocess` |
| **Plugin** · **Bakery** | *what extends the page?* | ◆ `Plugins` · `Checkout` |
| **Device** | *a physical phone's twin* | ◆ `Devices` (not wired) |

## 6 · Where the code is still behind

The tree and laws above are the design; where the code disagrees, the code
moves, one change at a time.

| Node | The code today | Moves to |
|---|---|---|
| "no reading means folded" | written out as `angle()?.litPanel ?? .primary` at four call sites | `Hinge.litPanel` everywhere (#124); `Server.hingeJSON` keeps one read for both the degrees and the panel |
| "is this device a foldable" | answered three ways: `chromes.panels(…).contains(.secondary)`, `IntegratedPanels.several(in:)`, `observed.multiplePanels` | one question, one owner |
| the phone plane's target | picked by `DisplayTouchTarget.resolve` in `SimulatorKitDisplay.input()`, inline in `input(expected:)` | `DisplayTouchTarget.resolve` for both, and one place deciding `FoldableInput` |
| `Display.input()`'s doc | says the target is "derived from `connectedScreenId`, never a hard-coded CarPlay constant" | the registration law above (CarPlay is the constant `1`) |
| `IntegratedPanel` on the wire | `"primary"` / `"secondary"` spelled in `DeviceFrame` and twice in `Server` | one wire name on the value |
| `StreamFormat.makeStream` | Domain builds `MJPEGStream` / `AVCCStream` and takes `FrameSink`, all Infrastructure | the factory moves to Infrastructure; Domain keeps the format |
| `FoldableInput` | calls `log(…)` from the App layer | Domain logs nothing; the failure is its `Bool` |
| `boot` · `heal` · `input` | the App builds `SimctlInputSurface()` itself | `simulator.inputSurface()`, as for every other role |
| `GuestHingeMotor` | plays `HingeMotor` and `DeviceKeys` over one guest helper | a name for the helper's role, not "motor" |

## 7 · Open

- **Who owns "IndigoHID runs on the MainActor"?** Only `Server.streamWS`'s hop
  enforces it; no type states it.
- **argv in the Domain.** `LogFilter.argv`, `Coordinate.argument`,
  `PreferenceSuite.containerArguments` and friends are values that build a
  subprocess's arguments. Pure and tested — but is that business or technique?
- **An offline render's default pose.** `DeviceRenderPlan` takes a missing
  `--hinge-degrees` as 180° (flat). That is a picture's pose, not the device's
  hinge, so the folded rule doesn't apply — the doc should say so.
- **Hinge ↔ Orientation.** `Hinge` uses `DeviceOrientation`; `Orientation`
  answers `PoseDelivery`. One should own the vocabulary.
