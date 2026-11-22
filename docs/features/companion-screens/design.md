---
description: Why companion screens work the way they do — the CarPlay HID service that must be created first, why its touch target is the constant 1 and never IndigoHIDTargetForScreen, how the rail probes, and why external displays go blank.
---

# Companion screens — design

## Path

- Page rail → `GET /devices/:udid/companion-screens.json` → `CompanionScreens`
  (CarPlay probe = the stream's own `Display.resolve()`; watch = one phone's
  side of `simctl list pairs -j`). `POST …/carplay-display` →
  `ExternalDisplays.enableCarPlay()`, which drives Simulator.app's
  I/O → External Displays menu.
- `?display=carplay` / `--display carplay` → `StreamDisplayPlan` → bind the
  best external framebuffer port.
- Gestures on the CarPlay plane → `DisplayTouchTarget` → `IndigoHIDInput`,
  whose `warmServices` creates pointer, mouse **and** CarPlay services
  (`IndigoHIDMessageToCreateCarPlayService`) before anything is sent.
- The page's `families/simulator/screens-rail.js` owns the rail and state card, not the streams —
  opening a pane calls back into `page/device-page.js`, which owns every
  `StreamSession` on the page.

## HID targets — the rule

**A HID target is only ever a constant some create-service message registered —
never a computed number.** `SimHIDVirtualServiceManager` keeps registered
services in a dictionary and **throws** on an unknown target, killing
`backboardd` and SpringBoard with it (it presents as the simulator
spontaneously rebooting). The guest names the valid set when it dies:
`(50, 13, 11, 53, 51, 302, 300, 1, 14, 60, 12, 100, 54, 1073741825, 301)` —
`50` = `0x32` phone, `53` = `0x35` pointer, `54` = `0x36` mouse, and the plain
`1` is CarPlay. `IndigoHIDTargetForScreen` is a trap (below). `0x32` is not a
digitizer but a **slot** filled for a built-in panel — last created wins —
which is why `IndigoHIDTouchTarget.panel(screenId:)` exists and is fed only
screen ids Connected Screens lists as Integrated. Only targets in that
published list are ever valid, which is what the `BAGUETTE_CARPLAY_TARGET`
probe override will accept (decimal or `0x`-prefixed; anything else is
ignored and the known-good constant is used). The override exists because
finding the right target is a search: the guest publishes the registered set
only when it rejects one, and rebuilding between candidates is far slower than
restarting with a different number.

## The external digitizer has to be built before it can be touched

Gestures on an external display used to restart the guest, reproducibly,
on a freshly created simulator. Two things were wrong at once, and this
is the half that had to be fixed first: **the digitizer being addressed
had never been built.** (The other half — the target itself — is
[below](#the-target-is-a-constant-not-a-computation).)

`IndigoHIDInput.warmServices` already created the pointer and mouse
services on every HID client; the CarPlay one was simply missing. So
touches were dispatched at a service that did not exist, and `backboardd`
died — SpringBoard and the CarPlay session with it.

### The recipe

SimulatorKit exports three service constructors, all producing the same
192-byte message and differing in two fields:

| Symbol | opcode `[0x30]` | `[0x40]` | `[0x44]` | args |
| --- | --- | --- | --- | --- |
| `IndigoHIDMessageToCreatePointerService` | 3 | `0x35` | — | none |
| `IndigoHIDMessageToCreateMouseService` | 5 | `0x36` | — | none |
| `IndigoHIDMessageToCreateCarPlayService` | 7 | 1 | flag | **1 byte** |
| `IndigoHIDMessageToRemoveCarPlayService` | 8 | — | — | none |

Common header: `calloc(1, 0xc0)`, `[0x18] = 0xa0`, `[0x1c] = 1`,
`[0x20] = 0x7fff0001`. Note `0x35` / `0x36` sit beside
`IndigoHIDTouchTarget.phone = 0x32` — these are routing targets, and each
must be **created before anything is sent to it**.

**The byte is `hasTouchScreen`**, not a screen index. Disassembling
Simulator.app's own call site names it:

```objc
id   config   = [self starkConfig];          // "Stark" — Apple's codename for CarPlay
BOOL hasTouch = [config hasTouchScreen];
msg = IndigoHIDMessageToCreateCarPlayService(hasTouch);
[self sendIndigoHIDData:msg];
```

baguette passes `true`: nothing reaches that path without wanting touch.
A knob-driven head unit would pass `false`.

`deinit` removes the service, so a display that goes away doesn't leave a
digitizer behind for the next session to inherit.

### The target is a constant, not a computation

Creating the service was necessary and not sufficient. The guest names
the real problem as it dies:

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'Encountered HID event with unexpected target 1073741826
         not in known targets: ( 50, 13, 11, 53, 51, 302, 300, 1, 14, 60, 12, 100, 54,
                                 1073741825, 301 )'
```

`SimHIDVirtualServiceManager` keeps registered services in a dictionary
and throws on anything else — which kills `backboardd` and SpringBoard
with it. Read the list: `50` is `0x32` (phone), `53` is `0x35`
(pointer), `54` is `0x36` (mouse), and the plain `1` sitting quietly in
the middle is the CarPlay service, registered moments earlier. Every
entry is a service something explicitly created.

baguette sent `1073741826` = `0x40000002`. That is
`IndigoHIDTargetForScreen(2)`, dutifully derived from the connected
screen id.

**`IndigoHIDTargetForScreen` is a trap.** It is a genuine SimulatorKit
export, it takes exactly the argument you have, and it returns
`0x40000000 | screenId` — a number that looks like a target and that no
service has registered. CarPlay's real target is a fixed plain `1`,
because the create message hardcodes `1` into its target slot at
`[0x40]` and the guest keys its registry on that raw value, unshifted
and unflagged — exactly as the pointer and mouse constructors hardcode
`0x35` and `0x36`. One service, one target, however many screens are
attached.

The other entry in that list worth naming is `1073741825`
(`0x40000001`): `1` wearing the `0x40000000` flag invented to match
`IndigoHIDTargetForScreen`. Something else registers it, so it never
crashed anything — it just delivered CarPlay's touches to the phone,
which is the harder failure to spot.

That "something else" has since been read out of `SimulatorHID`:
`createDigitizerForTargetID:withDisplayUID:isBuiltIn:` registers every
Integrated screen's `ScreenTouchService` under `0x40000000 | screenId`
— the mask bit is what the create message must carry — and `0x32` is a
second slot the same call fills for a *built-in* panel, last one
created wins. So `0x40000001` is the phone panel's own registration,
which is exactly why CarPlay's taps ended up on the phone. The
distinction only bites on a foldable, where two panels fight over the
slot; see [iphone-duo](../iphone-duo/README.md).

So `DisplayTouchTarget` addresses a registration for both planes and
computes nothing from a screen that is not Integrated. And
`warmServices` fails closed: if the CarPlay service cannot be created,
`ensureWarm` returns no client and every gesture is dropped, because
dispatching to an unregistered target is not a degraded mode — it is a
dead simulator.

### Why the target is resolved once

An earlier fix re-derived the target on every gesture, to stop a session
dispatching to a screen that had gone away. It is gone: a target is a
constant naming a registered service, so nothing about it can go stale,
and re-deriving it put a `simctl io enumerate` subprocess plus a
SimulatorKit port walk in front of every touch — including every move of
a drag. That is where "input is uber laggy" came from.

Dispatching to a display that has since detached is harmless now: the
service is still registered, so the event goes nowhere rather than
throwing. Only *unregistered* targets kill the guest, and a constant
cannot produce one.

The **watch** pane was never affected — a watch is a device of its own,
streamed on its own udid down the ordinary integrated digitizer path.

## What was actually wrong, in order

Three attempts missed before the fourth landed. Each failure narrowed it,
and each wrong answer is worth keeping because each one looked right.

| Target sent | Where it came from | What happened |
| --- | --- | --- |
| `0x40000002` | `IndigoHIDTargetForScreen(screenId)` | unregistered → guest throws → guest restarts |
| `0x40000001` | `1` plus an invented `0x40000000` flag | the phone panel's own digitizer (screen 1 under the mask bit) → CarPlay's taps drove the phone |
| **`1`** | what the create message actually registers | works |

Along the way two real bugs were fixed that were not this bug: a session
held one digitizer target for its whole life, and three fallbacks turned
"we don't know" into confident wrong answers — `?? cachedBinding()`,
`?? 0` for the screen id, and worst, `?? IndigoHIDTouchTarget.phone`,
which redirected an external plane's gestures onto the phone.

The lesson worth carrying: **`IndigoHIDTargetForScreen` is a trap.** It
is a real SimulatorKit export, it takes exactly the argument you have,
and it returns a plausible number that no service has registered.


## Why it is a rail and not a pane that's just there

The CarPlay pane used to mount on every page load. That was worse than
clutter: `?display=carplay` doesn't only *read* the CarPlay plane, it
asks the host to **attach one** (`ExternalDisplays.enableCarPlay()`,
which drives Simulator.app's I/O → External Displays menu). So opening
a device's tab to look at it changed the device.

Nothing is asked for now until you open a pane, and the rail only
offers a screen the host already reports as attached — so the enable
path is never reached by accident.

## The routes

`udidParam` reads the udid **positionally** — the second-to-last path
segment — so the attach route is `…/:udid/carplay-display` and not the
tidier-looking `…/:udid/companion-screens/carplay`. A route that buries
the udid deeper still compiles and still matches; it just answers
`unknown udid: companion-screens` forever. `Server.udid(inPath:)` is
that rule as a pure function, and the route paths are pinned against it
in `CompanionScreensRouteTests`.

The key is `external`, not `carplay`, and it carries the bound display's
size. `DisplayKind.carPlay` names the **plane** — the wire query stays
`?display=carplay` — but that plane binds *the best external display*,
whatever the I/O → External Displays menu attached. That menu offers
CarPlay alongside several plain resolutions, and they are not
interchangeable: on an iOS 27 beta runtime the plain resolutions attach
and stream while the CarPlay entry attaches nothing. Labelling the pane
"CarPlay" while it shows an 800×480 TVOut is a small lie, so the size
travels and the rail reports what it actually bound.

Absence is an answer, not an error — a device with neither is the
common case, so only an unknown udid is a failure (404). Both probes
fail closed: a CarPlay plane that won't bind reads as "no CarPlay", and
an unreadable pairing table reads as "no watch", because a rail that
can't say what's attached should offer nothing rather than offer a pane
that can't open.

## "Available" means bindable, not named

There are two different questions here and they give different answers:

| Question | Asked by | Answers "yes" when |
| --- | --- | --- |
| Is a CarPlay screen listed? | `ExternalDisplays.isCarPlayConnected` | Connected Screens names one |
| Can we stream it? | `Display.resolve()` | a framebuffer port actually binds |

A device can sit in the gap: **registered, with no framebuffer behind
it.** That happens when a display was enabled and its host window has
since gone — `simctl io <udid> enumerate` still lists the screen with
its size and type, but there is no `IOSurface port:` block under it, and
`simctl io <udid> screenshot --display <id>` fails with *"Timeout
waiting for screen surfaces"*. Apple's own tooling can't get a frame
either; it isn't a baguette problem.

The route asks the second question — the same `resolve()` the stream
performs — so the rail and the stream cannot disagree. Trusting the
first one is what produced the original symptom: a lit rail button
opening a pane that could never paint.

## When a stream can't bind anyway

The pane also handles being wrong. `streamWS` writes
`{"ok":false,"error":…}` on the socket and closes when `bind` throws,
and the pane renders that under the frame with the same instructions the
rail's card carries, plus the server's verbatim error
(`noMatchingFramebuffer(carPlay)`) to search for. That answer used to go to
`console.log` and nowhere else, which is what made the black rectangle
so confusing.

Browser-facing only. It reports what the host has attached to a device,
which is the sort of thing a plugin should have to declare a capability
for, and no capability covers it — so it rides the browser-trust check
alone and is not plugin-reachable.

## The map template's nav bar and the edge flag

The wire `tap` and the browser differed by one thing. The browser's touch source
classifies a point at `y / height ≤ 0.15` as the top band and
streams `touch1-*` with `edge: "top"`; `tap` had no way to carry
that hint, so its message went out with the edge bytes zeroed. It
can carry it now:

```sh
printf '{"type":"tap","x":742,"y":44,"width":800,"height":480,"edge":"top"}\n' \
  | baguette input --udid <UDID> --display carplay
```

That makes the wire `tap` byte-for-byte what the browser sent. Whether
the flag is what CarPlay keys on has not been confirmed on a head
unit — it is the measured difference, not a measured cause. The bar
auto-hides, so expect the first tap to wake it and a second ~700 ms
later to land, as it did in the browser. If a plain mouse click on
the same button in the web UI *also* works, the flag is not the
explanation: the mouse source's band is `0.07`, so that click ships
an unflagged `tap`.

## Watch buttons

Both buttons ride the ordinary `button` envelope down the watch's own socket — `DeviceButton` already carried
`digital-crown` / `side-button` / `left-side-button` on HID page 12, so
nothing new was needed on the wire.

## The rail re-probes when the page regains focus

Attaching a display happens in another application, and there is no
event for it. So the rail looks again whenever the page comes back to
the foreground, which is exactly the moment you return from
Simulator.app. Before this, an attached display "wasn't there" until a
full reload or a **Check again** press.

It only *acts* when the answer differs (`CompanionScreens.sameAs`).
`refresh()` closes and reopens panes, so re-rendering on an unchanged
probe would tear down and rebuild live streams every time you tabbed
back. Both `focus` and `visibilitychange` fire together in some
browsers, so an in-flight latch collapses them into one request.

## Simulator.app hosts the display; baguette only streams it

An external display exists for as long as **Simulator.app's window for
it** does. Quit Simulator.app and the guest tears the display down —
`Discarding pending display`, `Invalidating screen controller: (null)` —
and the pane goes with it. baguette attaches to the framebuffer; it does
not host the screen and cannot keep one alive.

This is worth knowing because it explains a whole class of confusion:
a device whose Connected Screens still lists a CarPlay screen with no
`IOSurface` behind it is one whose host window has gone. Everything
downstream — the black pane, `simctl screenshot` timing out on the
screen, the rail reporting nothing attached — follows from that.

## Layout

Both rails share one right-edge stack (`.right-rails`) so they can't
overlap. That container is deliberately centred with
`justify-content: center` on a full-height box rather than
`transform: translateY(-50%)`: a transformed element becomes the
containing block for `position: fixed` descendants, and the plugin
panel and its flyout are both fixed and mounted inside it.

How much of the window each pane gets is one set of variables on
`#simNativeView`, keyed off `data-companions` (a space-separated list
of the open panes) and the window width:

| | device | each companion |
| --- | --- | --- |
| nothing open | `96vw` | — |
| one pane | `46vw` | `42vw` |
| both panes | `30vw` | `29vw` |
| ≤ 960px (stacked) | `92vw` | `92vw` |

Below 960px the row becomes a column, so height becomes the contended
axis instead and the two share it 55 / 45 in the phone's favour.

## Why an external display is usually blank

This is the confusing part, and it is mostly **not** baguette.

An external display in the iOS simulator shows nothing until something
on the device draws to it. iOS does not mirror the phone onto it — an
app has to put a scene or window on the external screen. So the default
state of a freshly attached plain-resolution display is black, in
Simulator.app's own window as much as in baguette's pane. If the window
is blank in Simulator.app, there is no framebuffer, and there is nothing
for any streamer to carry.

CarPlay is the exception worth separating out: its dashboard is system
UI and should appear on its own. A blank *CarPlay* display is therefore
a real runtime problem rather than a missing app — and the guest says so
plainly if you ask it:

```
xcrun simctl spawn <udid> log show --last 20m --style compact \
  --predicate 'category == "Session" AND subsystem == "com.apple.CarPlayApp"'
```

On a wedged device that reads:

```
didConnectIdentity:Car[2-21], is car display: YES
Session not yet available
willDisconnectIdentity:Car[2-21]
Discarding pending display: … CADisplay.name = TVOut; pixelSize = {800, 480}
Invalidating screen controller: (null)
```

The display attaches and CarPlay recognises it as a car display, but no
CarPlay **session** comes up, so the screen controller stays `(null)`,
nothing is ever drawn, and the display is dropped a minute or two later.
Black is the honest output of that: baguette is faithfully streaming a
framebuffer nobody rendered to.

Two things that log also settles:

- The CarPlay display is backed by `PurpleTVOut` — the CarPlay entry and
  the plain resolutions are the same TVOut plane wearing different
  identities. The plain ones connect as `AirPlay[…], is car display: NO`,
  which is why they attach reliably and stay blank; the CarPlay one
  connects as `is car display: YES` and needs the session.
- Repeated Disabled → CarPlay cycling is not free. Each attach changes
  the display's seed and modes, and a reconfiguration mid-setup is
  exactly what "Discarding pending display" is reporting. If CarPlay is
  wedged, cold-boot the device rather than cycling the menu again.

That also explains the intermittency. A framebuffer port only carries a
surface while something is compositing to it, and
`SimulatorKitFramebuffers.sizedFramebuffers` drops any port it can't size —
in practice, any port with no live surface, because `FramebufferDefaultSize`
reads its fallback keys off the port while the enumerate output shows
them alongside the descriptor's surface. So the set of ports the binder
sees changes from moment to moment: catch it while something has just
painted and the bind succeeds; ask a second later and the plane reports
nothing attached.

Deliberately not "fixed" by making surfaceless ports bind: that would
trade a clear "nothing attached" for a black rectangle, which is the
symptom this whole feature exists to stop showing you.

## Xcode 27: no Simulator.app, and CarPlay doesn't come up

Investigated 2026-10-01 on Xcode 27.0 (27A259), iOS 27.0 and iOS 26.4
runtimes, iPhone 18 Pro / iPhone 17 Pro. Everything here was found by
experiment; the spike code isn't in the repo. **Nothing in this section
has shipped** — `enableCarPlay()` still scripts the menu and fails on
Xcode 27.

### Why the attach fails

Xcode 27 ships **DeviceHub.app instead of Simulator.app**
(`Xcode.app/Contents/Applications/DeviceHub.app`, bundle
`com.apple.dt.Devices`). `SimulatorMenuExternalDisplayPanel` scripts
`application "Simulator"`, which no longer exists, so `osascript` exits 1
with `Can't get application "Simulator" (-1728)` before any permission
matters. The adapter discards stderr, so the pane says "grant Automation +
Accessibility" — wrong cause. `CarPlayExtraOptions` in
`com.apple.iphonesimulator` is read by nothing in Xcode 27 either.

DeviceHub has no I/O → External Displays. Its only CarPlay is
`DeviceKit.framework/PlugIns/CarPlaySimulator.devicekitplugin` — Apple's
CarPlay Simulator for **real iPhones**: it links MobileDevice, CoreDevice,
MobileBluetooth and iAP2MessageKit, and no CoreSimulator or SimulatorKit.
Xcode 27.1 beta is the same.

### What Simulator.app's menu actually did

Not a CarPlay feature of its own — three host-side steps, all reachable
without it:

| Step | Call | Status on Xcode 27 |
| --- | --- | --- |
| Turn the profile's CarPlay screen on, with a CarPlay description | `SimScreen setCurrentMode:pixelSize:carPlayProperties:…` + `setPowerState:` | ✅ works — see the ordering trap below |
| Build the CarPlay digitizer | `IndigoHIDMessageToCreateCarPlayService(hasTouch)` | ✅ already in `warmServices` |
| Host a window that asks for frames | `SimScreen registerScreenCallbacksWithUUID:…` | ✅ registers, but 0 frames arrive |

The screens come from the device type's `capabilities.plist` `displays`:
every iPhone profile declares `screenID 3`, `displayType = carPlay`,
`displayName = Wireless`, 720×480, `powerState 0`, `hasDigitizer = false`.
They are **pre-created and powered off**; `simctl io <udid> screenConfig
--display=3 power on` (an undocumented `simctl io` op) lights one. The
`com.apple.framebuffer.server` port's descriptor implements
`SimScreenAdapter`; its screens accept any mode in 320×200…3840×2160 at
@1x/@2x/@3x, so Apple's recommended sizes (748×456, 768×1024, 800×480 @2x,
1920×720 @3x) all fit.

**Creating a screen is not possible.** `createScreenWithProperties:…`
answers `Invalid properties or mode`: `SimRenderServer` `swift_dynamicCastClass`es
both arguments to its own classes, so only properties it vends via
`creatableScreenProperties` are accepted — and that list is empty for every
profile (nothing populates `_creatableDisplays`). Only the declared screens
can be switched on.

**Ordering trap:** `setPowerState:` sends `newCarPlayProperties=nil` and
wipes a description set earlier (`SimRenderServer`'s `UpdateScreen` log
shows both). Set power first, then `setCurrentMode:…carPlayProperties:`.
The dictionary keys are `SimCarPlayPropertyKey{Stark,HasTouchScreen,
HasTouchScreenLoFi,HasHomeButton,HasBackButton,HasWheel,HasWheelBump,HasPad,
OEMProtocolNames}`, exported by `CoreSimDeviceIO`.

### Why the guest still shows nothing

1. **The screen is classed AirPlay.** The guest's QuartzCore maps
   framebuffer types onto display kinds in `-[CAWindowServer
   _detectSimDisplays]`: type 1 → TVOut, **2 and 3 → wireless**, 4 → a
   third kind; there is no CarPlay kind. backboardd then tags it
   `AirPlay` (`CADisplay.tag` 4). FrontBoard's
   `FBSCADisplayToDisplayTypes` turns tag bit `0x20` into type 3, and
   `-[FBSDisplayIdentity isCarDisplay]` is just `type == 3` — so CarPlayApp
   logs `didConnectIdentity:AirPlay[3-n], is car display: NO`. On iOS 27
   backboardd *did* tag it `(car)` by itself once a synthetic session
   (below) existed — `evaluateDisplay(WirelessDisplayModeDidChange)`; on
   iOS 26.4 it stayed AirPlay. `-[CAWindowServerDisplay setTag:0x20]`
   inside backboardd also works.
2. **No CarPlay session exists.** CarPlayApp (DashBoard.framework) waits
   for `DBSessionController sessionDidConnect:`, fed by CarKit's
   `CARSessionStatus`, whose `CARSession` is built
   `initWithFigEndpoint:` — an **AirPlay endpoint**. carkitd has an iOS 27
   `acquireSyntheticCarPlaySessionWithDescriptor:reply:` on
   `com.apple.carkit.service` (entitlements `com.apple.private.carkit` and
   `com.apple.springboard.testautomation`, both honoured when linked into a
   simulator binary's `__TEXT,__entitlements`; descriptor
   `{deviceID, screens:[{identifier}], extraHostProperties:{screens:[…]}}`,
   torn down when the caller exits). It starts a session with a car at
   `fe80::1%lo0` port 7000 and dies at
   `com.apple.carkit.sessionRequestHandler … No such process`: the AirPlay
   sender daemon is not in the simulator runtime (its frameworks are;
   `AirPlaySenderService.xpc` is an empty bundle).
3. **Forcing it gets as far as scenes.** With a stand-in `CARSession`
   injected into CarPlayApp (configuration built by CarKit's own
   `initWithSessionStatusOptions:propertySupplier:` from `uniqueID`,
   `details.width/height/hasTouchScreen…`) and `sessionDidConnect:` /
   `sessionController:didConnectSession:` driven by hand, DashBoard builds
   its wallpaper scene and input routing on `Car[3-1]`. It still renders
   nothing — because of 4.
4. **No external screen renders pixels under Xcode 27.** Not CarPlay,
   not plain TVOut mirroring the phone, on iOS 27 or 26.4, through
   `simctl io screenshot`, baguette's capture, or a frame subscription.
   backboardd reports the display on and cloning; the host IOSurface stays
   black. DeviceKit tracks `displayIdentifiersWithFramebufferRequests` and
   reaches non-primary displays through a video stream
   (`receiveMirroredDisplayByIdentifier`), so Xcode 27 likely needs a
   request baguette doesn't make yet. **This blocks every simulator
   CarPlay route**; it's the next thing to crack.

### Being the car: PlayPort and its family

Tested 2026-10-02 on macOS 27 with a USB-attached iPhone 13 Pro Max
(iOS 27). Scripts and logs weren't committed.

[PlayPort](https://github.com/youcci/playport) streams real-iPhone CarPlay
into a browser, and its frame is exactly the CarPlay screen: it plays the
**car**, tells the phone the size it wants in its AirPlay `/info` reply,
and the phone encodes only that screen as H.264. Nothing is cropped,
because there is no window. It is a JVM port of
[DiPlay](https://github.com/shihabal3amri/DiPlay) / xcertplay;
[LoopLink](https://github.com/umarz317/LoopLink) is the same receiver as an
Android head-unit app. All of them are GPL-3.0.

**They can't help the simulator.** A receiver needs a phone that sends
AirPlay, and the simulator runtime has no AirPlay sender (carkitd's
synthetic session dies at `No such process`, above), and no iAP2,
accessory or Bluetooth daemon either.

**With a real iPhone it works end to end; the accessory identity is
what decides it.** Run step by step on this Mac with PlayPort unchanged,
first with a self-signed `identity.pk8` / `certificate.p7b`, then with an
Apple-issued pair (`O=Apple Inc., OU=Apple Accessories`):

| Step | Result |
| --- | --- |
| PlayPort advertises `_airplay._tcp` | ✅ (on a spare `--airplay-port`; macOS's AirPlay Receiver holds 7000) |
| `bt-bridge` finds the phone's "Wireless iAP v2" SDP record | ✅ only after a fresh `performSDPQuery` — it reads the Mac's cached records, and a stale cache reports "does not expose the iAP2 service" |
| RFCOMM channel opens, iAP2 link comes up | ✅ |
| The phone accepts the accessory certificate | self-signed: ❌ `AuthenticationFailed`, the phone shows **Accessory Not Supported**. Apple-issued: ✅ `wireless bootstrap accepted` |
| Wi-Fi handoff | ✅ only with the passphrase: the phone refuses a handoff to a secured network without one (`passphrase is required for secured Wi-Fi`), even a network it already knows. macOS also hides the SSID from a process without Location Services, so both are passed explicitly |
| AirPlay `pair-setup` / `pair-verify` / `auth-setup`, encrypted control | ✅ the phone connects from its Wi-Fi address |
| CarPlay session | ✅ `iPhone14,3`, iOS 27.0, about 4 s after start |
| Video over PlayPort's `/ws` | ✅ H.264 1280×720 at ~27 fps (216 frames in 8 s); the first frame decodes to the bare CarPlay screen |

That is the frame the pane wants: 1280×720 and nothing around it, against
758×443 from cropping the CarPlay Simulator window (below). The resolution
is whatever the receiver asks for in `/info`.

The phone accepts only an Apple-issued accessory certificate. The pair
PlayPort documents was extracted from Carlinkit dongle firmware and is
shared publicly. Apple can revoke it in any iOS update, and it can't be
redistributed. baguette doesn't fetch or ship it; whoever runs the
receiver supplies their own and keeps it out of the repo.

**USB doesn't avoid this.** Wired CarPlay runs the same iAP2 challenge over
the cable, and the car's port must act as a USB *device* while the phone
acts as host. A Mac's ports are host-only, which is why PlayPort supports
only wireless, and why DiPlay's wired mode runs only on Android head units.

The protocol side would port. CryptoKit, CommonCrypto and attaswift/BigInt
reproduced PlayPort's X25519, Ed25519, HKDF-SHA512, ChaCha20-Poly1305,
AES-CTR, SRP-6a (3072-bit) and P-256 identity signing byte for byte. On
the platform side, `NWListener` Bonjour, VideoToolbox (decoding PlayPort's
avcC + Annex B frames to IOSurface-backed buffers) and IOBluetooth RFCOMM
all worked. A Swift port of GPL code stays GPL, so it could only ship as
a separate helper process that loads a user-supplied identity.

**Without an identity**, what works over USB is Apple's CarPlay Simulator, which
attaches through Apple's own device connection and authenticates with
Apple-signed credentials. Capturing its window is the
[head-unit](../head-unit/design.md) design. To get only the CarPlay
screen, crop the capture with `SCStreamConfiguration.sourceRect`. The
screen has no accessibility element. Accessibility gives the toolbar (top
52 pt) and the knob strip (from 527 pt), and the screen's exact edges come
from the first frame: rows and columns where most pixels differ from the
margin colour under the toolbar. Measured: 758×443 at ~27 fps on a 1×
display.

## Known limits, and why

- **Portrait externals are rejected.** `acceptsExternal` requires
  landscape — strictly wider than tall, so a square surface is out too —
  and ≥ 50,000 px². The landscape rule is what keeps a portrait phone
  plane out of the external pane; mirroring SpringBoard there is worse
  than showing nothing because it looks like it worked. There is no
  longer an upper size bound — 1080p and 4K externals bind fine.
- **The CarPlay menu entry may attach nothing while the plain
  resolutions work** (iOS 27.0 beta). The rail reports either as an
  "External display" and names its size, so there's nothing to change on
  this side — but it does mean CarPlay's *brand chrome* (the
  `carplay-frames/` registry) may be dressing a screen that isn't
  CarPlay.
- **On Xcode 27 the attach can't work at all** — there is no Simulator.app
  to script — and even a screen lit by hand stays black. See
  [Xcode 27](#xcode-27-no-simulatorapp-and-carplay-doesnt-come-up).
- **CarPlay streams MJPEG regardless of the format picker.** It is a mostly
  static screen and H.264 starves without an IDR cadence the guest
  doesn't produce; MJPEG paints the first seed and holds it.
- **The crown presses but doesn't turn.** Rotation is a separate HID
  axis that baguette doesn't drive. **The scroll wheel does nothing over a
  watch pane:** `WheelGestureSource` emits a two-finger pan, which watchOS
  ignores in a list. Only a plain press is sent; the double-press (Wallet)
  and the holds (Siri on the crown, power menu on the side button) would need
  a `duration` and a repeat, which the buttons don't offer yet.
- **Nothing is pushed from the host.** The rail asks: on page load, on focus
  (`bindFocusReprobe`), and on **Check again**. Open panes are remembered in
  `localStorage` (`baguette.companionScreens`).
