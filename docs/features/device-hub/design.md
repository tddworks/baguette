---
description: Root cause of Xcode 27 Device Hub's dtuhidd shadowing baguette's legacy Indigo input services, the verified two-step repair and its ordering, detection timing, and what was ruled out.
---

# Device Hub — design

## Path

- `baguette boot` (unless `--no-heal`), `POST /devices/:udid/boot` →
  `InputSurface.healAfterBoot`; `baguette heal` → `InputSurface.heal`;
  `baguette input` startup and `serve`'s stream WebSocket → `InputSurface.shadowed`
  → advisory.
- `InputSurface` (`shadowed` · `ready` · `reclaim`) → guest commands over
  `Subprocess`: `notifyutil -g/-s`, `launchctl kickstart`, `launchctl list`
  (polled until SpringBoard is back under a new pid, then a 2 s settle).
- Integration-only: the real spawn, and checking whether Device Hub is running
  on the host (`NSRunningApplication`, `com.apple.dt.Devices`).

## What actually breaks

Device Hub runs a guest daemon per device, `dtuhidd`
(`CoreSimulator.framework/…/Platforms/iphoneos/usr/libexec/dtuhidd`,
launchd label `com.apple.coredevice.dtuhidd`). On start it registers
its own CoreDevice virtual HID services inside backboardd —
`mainTouchscreen(0x101)`, `touchscreen(0x104)`, `mainKeyboard`,
`mainScreenButtons` — and publishes one Darwin notify state:

```
com.apple.coredevice.dtuhidd.active = 1
```

backboardd's `SimHIDVirtualServiceManager` (the `SimulatorHID` library
that hosts the legacy Indigo services `IndigoHIDInput` sends to through
`SimDeviceLegacyHIDClient`) watches that state. On `dtuhidd state
changed to active` it **disconnects** `ExternalKeyboardService`,
`MainScreenButtonsService` and the main-display `ScreenTouchService`.

The iOS 27 runtime then never gets them back. Its lazy reconnect —
`Connecting dtuhidd-suppressed service due to IndigoHID event` on the
next Indigo message — re-adds the **same, already-invalidated**
`IOHIDServiceRef`: the guest log shows `Service added` and `Service
removed` for it in the same millisecond, `digitizer attached` never
follows, and SimulatorHID records the service as connected so it never
tries again. Every later event goes to a service backboardd doesn't
have. Two consequences:

- **Touch is a boot-order race.** If SimulatorHID initialises *before*
  dtuhidd flips the state (typically ~100 ms apart), it connects the
  touch service, then disconnects it → dead. If dtuhidd is already
  active at init, the touch service is *born suppressed* and the first
  baguette tap lazily creates a fresh one → works, even though it is
  not the main-display digitizer. Booting headless and opening Device
  Hub afterwards always takes the first branch.
- **Buttons and keyboard are dead whenever Device Hub has attached.**
  Those two services are always connected at init and always
  disconnected on activation — no race, no priming trick.

The reporter's workaround ("send any event before Device Hub attaches")
works for touch because SimulatorHID skips disconnecting the touch
service when it has already seen an Indigo event. It does nothing for
buttons, and there is no boot-time window for it when Device Hub is
already running.

## The repair (`InputSurface.reclaim`)

Two guest commands, in this order:

```bash
xcrun simctl spawn <UDID> notifyutil -s com.apple.coredevice.dtuhidd.active 0
xcrun simctl spawn <UDID> launchctl kickstart -k system/com.apple.backboardd
```

The new backboardd's SimulatorHID initialises reading "no Device Hub"
and connects every legacy service; the legacy touch service becomes the
main-display digitizer. dtuhidd notices its HID clients died
(`notification: terminated, reactivating`) and re-registers its own
services alongside (`*** already have a main display digitizer`) — the
same coexistence as the reporter's primed scenario, where both Device
Hub and baguette keep working. Verified on iOS 27.0 (24A434): taps land,
`press home` produces `Button began/finished` from the legacy sender.

Order matters. Clearing the state *after* the restart would hand the
new backboardd an active→inactive edge, and on iOS 27 that edge is
exactly the connect→disconnect that kills a service. Clearing it alone,
without the restart, reconnects nothing usable — the dead services are
already marked connected.

The state stays `0` until dtuhidd itself restarts, i.e. until the user
quits and relaunches Device Hub. At that point `shadowed` reads `1`
again, the advisory comes back, and `baguette heal` repairs it again.

## Detection

`xcrun simctl spawn <UDID> notifyutil -g com.apple.coredevice.dtuhidd.active`
printing `… 1` is the whole signal. It is one guest round-trip (~300 ms)
and it is exact: `1` means Device Hub attached during this backboardd's
life, which is precisely the condition that needs healing (buttons are
gone regardless of how the touch race went). Xcode 26 runtimes never
publish the key and read as `0`; so does a device that is shut down.

`baguette boot` has one more subtlety: `Simulator.boot()` returns as
soon as the device *state* flips. launchd starts SpringBoard and
backboardd within a second of that, dtuhidd publishes its state a
second later, and the home screen is many seconds out. So the boot
path first blocks on `simctl bootstatus -b`, then — only if Device Hub
is running on the host (`com.apple.dt.Devices`) — waits up to ten
seconds for the state to appear before deciding there is nothing to
heal. On a warm boot `bootstatus` returns ~1.3 s after `boot`, which is
too close to dtuhidd's ~2 s to trust on its own.

Ground truth when investigating, rather than the reporter's
"did Settings launch" probe (which is confounded by whatever icon sits
at the tapped point):

```bash
xcrun simctl spawn <UDID> log show --last 30s \
  --predicate 'process == "backboardd" AND category == "TouchEvents" AND eventMessage CONTAINS "presence: touching"'
```

## What this is not

- **Not a change to how input is sent.** baguette still speaks the
  legacy Indigo port. Device Hub itself uses CoreDevice +
  `UniversalHID.framework`, which reaches dtuhidd's `IndigoHIDServer`
  over guest XPC (`com.apple.coredevice.feature.remote.hid.digitizer`
  and siblings). Adopting that transport is the durable fix — Apple is
  clearly retiring the legacy services — but it is a separate
  reverse-engineering effort; Xcode 27's SimulatorKit still ships only
  `SimDeviceLegacyHIDClient`.
- **Not `baguette lifetime`.** That writes Simulator.app's preferences
  (`com.apple.iphonesimulator`); Device Hub ignores them, and quitting
  Device Hub shuts every booted device down. No Device Hub equivalent
  has been found yet.
- **Not prevention.** SimulatorHID reacts to state *changes*, so
  forcing the state to `0` during boot still yields the fatal
  connect→disconnect once dtuhidd flips it. Heal after the fact.
