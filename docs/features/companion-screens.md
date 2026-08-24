# Companion screens

A simulator can drive more than its own glass. Two of those extra
screens are worth looking at next to the phone:

- **CarPlay** — an external display the host attaches to the *same*
  device. It is a second framebuffer plane on the same udid, reached
  with `?display=carplay`.
- **Apple Watch** — not a plane at all. A paired watch is a device of
  its own, with its own udid, its own boot state and its own
  framebuffer, so it streams down the ordinary phone-display route
  against that udid.

In focus mode (`/simulators/<udid>`) both are offered from the
**screens rail** on the right edge, above the plugins rail.

## Why it is a rail and not a pane that's just there

The CarPlay pane used to mount on every page load. That was worse than
clutter: `?display=carplay` doesn't only *read* the CarPlay plane, it
asks the host to **attach one** (`ExternalDisplays.enableCarPlay()`,
which drives Simulator.app's I/O → External Displays menu). So opening
a device's tab to look at it changed the device.

Nothing is asked for now until you open a pane, and the rail only
offers a screen the host already reports as attached — so the enable
path is never reached by accident.

## What the rail shows

Every screen keeps a slot whether or not it is there. A rail that hid
what you don't have could never tell you it exists, and "how do I get
one of these?" is the question a new user actually has.

| State | Slot | Click |
| --- | --- | --- |
| attached / booted | lit | opens the pane |
| paired watch, not booted | dimmed | **Boot** button, then opens the pane |
| not there | dimmed | how to attach one, plus **Check again** |

The instructions are the real ones:

- **CarPlay** — Simulator.app → I/O → External Displays → CarPlay.
- **Apple Watch** — create a watch simulator in Xcode, then
  `xcrun simctl pair <watch-udid> <phone-udid>`.

Which panes you had open is remembered in `localStorage`
(`baguette.companionScreens`). A remembered pane whose screen has since
gone away is skipped rather than opened onto a dead socket.

## The route

```
GET  /simulators/:udid/companion-screens.json   what's attached
POST /simulators/:udid/carplay-display          attach one, answer what it can do
```

`udidParam` reads the udid **positionally** — the second-to-last path
segment — so the attach route is `…/:udid/carplay-display` and not the
tidier-looking `…/:udid/companion-screens/carplay`. A route that buries
the udid deeper still compiles and still matches; it just answers
`unknown udid: companion-screens` forever. `Server.udid(inPath:)` is
that rule as a pure function, and the route paths are pinned against it
in `CompanionScreensRouteTests`.

```json
{
  "external": { "available": true, "width": 800, "height": 480 },
  "watch": {
    "available": true,
    "udid": "…",
    "name": "Apple Watch Series 11 (46mm)",
    "state": "Booted"
  }
}
```

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

### "Available" means bindable, not named

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

### When a stream can't bind anyway

The pane also handles being wrong. `streamWS` writes
`{"ok":false,"error":…}` on the socket and closes when `bind` throws,
and the pane renders that under the frame with the same instructions the
rail's card carries, plus the server's verbatim error
(`noMatchingPort(carPlay)`) to search for. That answer used to go to
`console.log` and nowhere else, which is what made the black rectangle
so confusing.

Browser-facing only. It reports what the host has attached to a device,
which is the sort of thing a plugin should have to declare a capability
for, and no capability covers it — so it rides the browser-trust check
alone and is not plugin-reachable.

### Where the pieces live

| Layer | Type | Job |
| --- | --- | --- |
| Domain | `CompanionScreens` | the answer, and its JSON projection |
| Domain | `PairedWatch` / `WatchPairing` | one phone's side of the pairing table |
| Domain | `SimctlPairs` | pure parser over `simctl list pairs -j` |
| Infrastructure | `SimctlWatchPairing` | the spawn, and nothing else |
| Infrastructure | `HostExternalDisplays` | the CarPlay probe (pre-existing) |
| Web | `screens/companion-screens.js` | availability + instructions as a value |
| Web | `sim-screens.js` | the rail, the card, the remembered choice |

`sim-screens.js` owns the buttons and the state card. It does **not**
own the streams — opening a pane calls back into `sim-native.js`, which
owns every `StreamSession` on the page.

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

## Driving it from a terminal (agents)

The browser panes are one consumer; the CLI is the other. Two commands
take `--display phone|carplay` and bind through the same
`StreamDisplayPlan` the stream uses:

```sh
# one frame from the CarPlay plane (enables the display first)
baguette screenshot --udid <UDID> --display carplay -o carplay.png

# gestures against the CarPlay digitizer, over the stdin pipe
baguette input --udid <UDID> --display carplay < gestures.jsonl
```

CarPlay fails closed — if the plane has no framebuffer behind it the
command exits with `noMatchingPort(carPlay)` rather than silently
showing the phone. An unrecognized value (`--display carply`) is a
validation error, never a quiet fallback to phone, and so is an empty
one: `--display "$PLANE"` with nothing in `$PLANE` stops the command
rather than taking the phone behind your back. Omitting the flag is how
you ask for the default. Both commands reject the value before they look
for the device, so a broken command line reports itself rather than the
udid. The watch needs no flag: it is its own udid, so the ordinary
commands point at it.

## Driving the watch

A watch pane has no bezel chrome to hang overlay buttons off, so the two
hardware buttons sit in a pill under it. Both ride the ordinary `button`
envelope down the watch's own socket — `DeviceButton` already carried
`digital-crown` / `side-button` / `left-side-button` on HID page 12, so
nothing new was needed on the wire.

| You want | Do this |
| --- | --- |
| tap something | click it |
| scroll a list | **drag** on the face |
| back to the watch face / app grid | **Crown** (press again for the grid) |
| Control Centre | **Side** |
| Siri, Wallet, power menu | not reachable — those are hold and double-press |

Verified against a real paired Series 11: tap launches an app, Crown
walks face → grid, Side opens Control Centre, drag scrolls Settings.

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

So `DisplayTouchTarget` returns constants for both planes and consults
nothing. And `warmServices` fails closed: if the CarPlay service cannot
be created, `ensureWarm` returns no client and every gesture is dropped,
because dispatching to an unregistered target is not a degraded mode —
it is a dead simulator.

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
| `0x40000001` | `1` plus an invented `0x40000000` flag | registered by *something else* → CarPlay's taps drove the phone |
| **`1`** | what the create message actually registers | works |

Along the way two real bugs were fixed that were not this bug: a session
held one digitizer target for its whole life, and three fallbacks turned
"we don't know" into confident wrong answers — `?? cachedBinding()`,
`?? 0` for the screen id, and worst, `?? IndigoHIDTouchTarget.phone`,
which redirected an external plane's gestures onto the phone.

The lesson worth carrying: **`IndigoHIDTargetForScreen` is a trap.** It
is a real SimulatorKit export, it takes exactly the argument you have,
and it returns a plausible number that no service has registered.


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

## Known limits

- **The CarPlay menu entry may attach nothing while the plain
  resolutions work.** Observed on an iOS 27.0 beta: I/O → External
  Displays → CarPlay registers a screen with no framebuffer behind it,
  and no window appears; the other resolutions in the same menu attach
  normally and stream fine. So if the pane won't come up, pick a
  resolution rather than CarPlay. The rail reports either as an
  "External display" and names its size, so there's nothing to change on
  this side — but it does mean CarPlay's *brand chrome* (the
  `carplay-frames/` registry) may be dressing a screen that isn't
  CarPlay.
- **Portrait externals are rejected.** `acceptsExternal` requires
  landscape — strictly wider than tall, so a square surface is out too —
  and ≥ 50,000 px². The landscape rule is what keeps a portrait phone
  plane out of the external pane; mirroring SpringBoard there is worse
  than showing nothing because it looks like it worked. There is no
  longer an upper size bound — 1080p and 4K externals bind fine.
- **`POST /carplay-display` needs Automation + Accessibility permission**
  for whatever launched `baguette serve`, since it drives Simulator.app's
  menus. Without it the route answers 500 with that instruction. It is
  granted per-terminal, so a baguette started from a different shell may
  need it again.
- **The crown presses but doesn't turn.** Rotation is a separate HID
  axis that baguette doesn't drive, so the usual watchOS scroll gesture
  isn't available. Dragging on the face scrolls instead.
- **The scroll wheel does nothing over a watch pane.** `WheelGestureSource`
  emits a two-finger pan, which watchOS ignores in a list. Drag instead.
  Reaching for the wheel is the instinctive move, so this one surprises.
- Only a plain press is sent. The double-press (Wallet) and the holds
  (Siri on the crown, power menu on the side button) would need a
  `duration` and a repeat, which the buttons don't offer yet.
- CarPlay streams MJPEG regardless of the format picker. It is a mostly
  static screen and H.264 starves without an IDR cadence the guest
  doesn't produce; MJPEG paints the first seed and holds it.
- Nothing is pushed from the host. Attaching a display in Simulator.app
  raises no event the browser can see, so the rail asks: on page load, on
  focus (`bindFocusReprobe`, above), and whenever you press **Check
  again**.

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
`SimulatorKitFramebufferPorts.sizedPorts` drops any port it can't size —
in practice, any port with no live surface, because `PortDefaultSize`
reads its fallback keys off the port while the enumerate output shows
them alongside the descriptor's surface. So the set of ports the binder
sees changes from moment to moment: catch it while something has just
painted and the bind succeeds; ask a second later and the plane reports
nothing attached.

Deliberately not "fixed" by making surfaceless ports bind: that would
trade a clear "nothing attached" for a black rectangle, which is the
symptom this whole feature exists to stop showing you.
