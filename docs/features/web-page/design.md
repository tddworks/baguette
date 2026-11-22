---
description: The device page's JavaScript, laid out the way the Swift is — a device model, device families, the server's wire, and one composition root — so a new panel, device or ability is a new file, not an edit to a 3,500-line script.
---

# The device page — design

**Status:** slices 1–3 BUILT: the page loads its first ES modules
(`families/families.js`, `families/mac/share.js`), each device is built by its
family (`Families.device` → Simulator · Phone · Android · MacDisplay) with the
roles it has — `frame`, `badge`, `describe`, `share` so far — and the device
page no longer reads a device's kind (a test holds it). The rest of the page
still runs from `sim-native.js` through the `window.Baguette._…` bridges;
slices 4–10 move it (§6).

| For | Read |
|---|---|
| the gesture interpreter and the SDK parts (`baguette/`) | [baguette-sdk](../baguette-sdk/design.md) — kept, moved under `device/` |
| what each ability does on the server | [devices](../devices/design.md) |
| the stream formats and WebRTC | [stream](../stream/), [webrtc](../webrtc/design.md) |
| the farm page | [device-farm](../device-farm/design.md) — a second page on the same layers |

## 1 · What is wrong today

Measured on `main` (6a7a173d):

| Fact | Cost |
|---|---|
| `sim-native.js` is **3,472 lines**; the page's 69 top-level functions span boot, handheld mode, the stream session, CarPlay, the watch, power, the toolbar, the chrome pickers, nine panels, the Mac share and recording | every feature edits the same file; nothing in it is tested on its own (`sim-native-style.test.js` checks only its CSS) |
| Adding a panel touches **five** places: its module, a `toggleX()` in `sim-native.js`, `wireActions()`, `DeviceAbilities.NEEDS`, `sim.html`'s script list | not open for extension: a new panel edits the composition root and a table that names every control |
| `toggleLogs`, `toggleCamera`, `toggleNetwork`, `toggleNotify`, `toggleDefaults`, `toggleLocation`, `toggleStatusBar` are the same 20 lines — find the sheet, flip `data-*`, mark the button, lazy-mount the panel | one rule ("a panel opens in its sheet, mounted once") written seven times |
| Names say `sim-` (`sim-native`, `sim-logs`, `sim-camera`, `sim-network`, …) for a page that shows simulators, phones, Android and Mac displays | the name lies about the domain; the Mac code (`watchMacShare`, `mountPointer`, `mountMacFrameButton`) sits inside "sim" |
| The page decides a device's behaviour by asking what it is: `deviceMode` (`kind.reality !== 'simulated'`) 6×, `devicePlatform === 'macOS'`, `sharedMac()` — framing, booting, turning, the pointer, companions and sharing each branch on it | a new kind of device (Android, a TV) edits every branch; the behaviour of one kind is spread across the whole page instead of living in one place |
| 67 `<script>` tags in a fixed order; modules reach each other through `window.X` | load order is a hidden dependency graph; nothing is private — every helper is reachable from everywhere |

The Swift side solved the same problem: roles named for the domain, families
that never import each other, `Internal/` for implementations, `System/` for
the bare outside call. The page should read the same way.

## 2 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **Device** | what `/devices/<id>/device.json` says: id, name, kind (platform · reality · model), abilities | a part (the screen, a button) |
| **Ability** | a name the server lists (`logs`, `camera`, `orientation`, `pointer`, …): what the device can do | a control — the button that uses it |
| **Page** | the device page: one device, its view, its toolbar and its panels. The composition root | the farm page, which shows many devices |
| **View** | the device's live screen on the page: its picture (a session) and its input (gestures) | a panel |
| **Session** | how the picture arrives: a stream socket (AVCC, MJPEG) or WebRTC (WHEP) | the device |
| **Panel** | something a toolbar button opens in a sheet beside the view: logs, camera, network, defaults, notifications, location, status bar, accessibility, 3D, plugins | the toolbar |
| **Control** | a toolbar button; it shows only when its device has the ability it needs | the ability |
| **Family** | simulator, phone, Android, Mac display: builds the Device for its kind, and decides how each of its roles behaves | the device model every family shares |
| **Role** | one thing a device does on the page — framed, powered, turned, pointed at, its companion screens — the same name for every family, behaving its family's way | an ability, which only says whether the server can |
| **Wire** | every route and socket the page talks to | a session (one kind of wire use) |

## 3 · The aggregate, from the root down

```
Page ◆ (page/device-page.js — composition root, the only file that knows them all)
├── Device ◆                 built by its Family from device.json; the page only talks to its roles
│   ├── id · name · kind · abilities ◇
│   ├── frame ◆              how it is framed: bezel · picked chrome · Mac frame · none
│   ├── power ◆?             booting it — only a family whose devices boot has one
│   ├── orientation ◆?       turning it — the device turns, or follows the viewer, or has none
│   ├── pointer ◆?           a pointer the page draws (a Mac's, in its real shape)
│   ├── companions ◆?        its other screens (CarPlay, the paired watch)
│   └── share ◆?             being shared to the viewer's own screen (a Mac's)
├── View                      the screen: a Session for its picture, the SDK's parts for input
│   └── Session ◆            StreamSession | WhepSession — start · stop · send; picked by StreamFormat
├── Toolbar                   one Control per Panel the Device can use; folds when narrow
│   └── Control              shows iff device.abilities has panel.needs
├── Panels ◆                  every Panel registered; opened in its Sheet, mounted once
│   └── Panel ◆ (role)       name · needs · icon · label · mount(host, device) → { close() }
│       logs · camera · network · defaults · notify · location · statusBar · accessibility · 3d · plugins
└── Capture                   snapshot, recording, gallery — of whatever the View shows
```

`?` marks a role a family may leave out. **Absent, never disabled:** a
device that can't boot has no `power`, so there is no power card to hide — the
Swift rule "an ability never appears on a type that cannot perform it".

### Device ◆ and its Family — the stable domain

> **Pointable as:** "this iPhone simulator", "my iPhone on the cable", "the
> Studio Display" — the thing the page shows, behaving as its kind does.

The page never asks what a device is. It tells the device's roles what it
wants, and each family answers its own way:

| Role | Simulator | Phone (iOS, physical) | Android | Mac display |
|---|---|---|---|---|
| `frame` | its own bezel (`definition.json`) | a chrome the user picks (DeviceKit) | a chrome the user picks | a Mac frame that fits, or none |
| `power` | boots, with the power card | — (on when listed) | — | — |
| `orientation` | turns when asked | — (turns itself) | — | follows the viewer (a share reshapes) |
| `pointer` | — | — | — | drawn locally, the Mac's real shape, hovers |
| `companions` | CarPlay, the paired watch | — | — | — |
| `share` | — | — | — | turns with the viewer, ends when they leave |

```js
// families/families.js — the one place that knows every family; the page asks it once.
const device = Families.device(listing, wire);    // Simulator | Phone | Android | MacDisplay

// page/device-page.js — tells roles, never asks the kind.
view.frame(device.frame);
if (device.power) powerCard.follow(device.power);
if (device.orientation) rotate.drive(device.orientation);
device.pointer?.follow(view);
device.share?.follow(view);
```

A new kind of device is **one new family**: a folder under `families/` and one
line in `families.js`. The page, the panels and the other families don't
change — the same open-closed shape as Swift's `Devices` → family → `Device`.

| | |
|---|---|
| **Owns** | which roles its devices have, and how each behaves |
| **Tell it** | `Families.device(listing, wire)` → a Device |
| **Never** | checks another family's kind; is imported by another family; lets the page branch on `kind` |

### Panel ◆ — the role that makes the page open

> **Pointable as:** the logs sheet, the camera sheet — a thing you open from
> the toolbar and close again.

| | |
|---|---|
| **Owns** | its name, the ability it needs, its toolbar icon and label, how to mount itself into a host for a device |
| **Tell it** | `mount(host, device)` → a handle with `close()` |
| **It answers** | `needs` — so the toolbar, not the panel, decides whether to show its control |
| **Never** | reaches into the page's DOM outside its host; knows another panel; is named in the composition root |

```js
// panels/logs-panel.js — the whole wiring a panel needs; nothing else is edited.
export const logsPanel = {
  name: 'logs', needs: 'logs', label: 'Logs', icon: ICON,
  mount(host, device) { return new LogView(host, { udid: device.id, level: 'info' }); },
};
```

## 4 · Layout — the Swift shape, in the browser

```
Resources/Web/
├── device/                ≈ BaguetteDevice: what every device page shares, imports nothing of ours
│   ├── device.js          Device ◇ (from device.json), abilities
│   ├── panel.js           the Panel role and Panels (registry + sheet rules)
│   ├── gestures/  parts/  the SDK's interpreter and parts (today's baguette/), unchanged inside
│   └── internal/          implementations (sheet, fold, …) — imported only from device/
├── wire/                  ≈ the server's routes: transport, StreamSession, WhepSession, device.json
│   └── internal/
├── families/              ≈ Devices/<Family>: each builds its Device; never import each other
│   ├── families.js        the one list of families: listing → Device
│   ├── simulator/         Simulator: bezel frame, power, orientation, companions (CarPlay, watch), hinge
│   ├── phone/             Phone: picked chrome
│   ├── android/           Android: picked chrome
│   └── mac/               MacDisplay: Mac frames, pointer, share
├── panels/                one file per Panel: logs, camera, network, defaults, notify,
│                          location, status-bar, accessibility, 3d, plugins
├── capture/               snapshot, recording, gallery (today's capture/, recorder, capture-gallery)
└── page/                  ≈ Commands/Server: the roots — device-page.js, device-list.js, farm/
```

**Imports flow inward**, as in Swift: `page/` → `panels/`, `families/*` →
`wire/`, `capture/` → `device/`. `device/` imports nothing of ours; families
never import each other; a folder's `internal/` is imported only from inside
that folder (a test enforces it, as `scripts/check-boundaries.py` does for
Swift).

**Why `families/`, not `devices/`:** the server routes `/devices/:udid/…`, so a
file at `/devices/mac/share.js` would read as device `mac`. Every folder is
also listed in `Server.staticAssetSubdirectories` (its test checks the list
against the disk).

**ES modules, not IIFEs.** `<script type="module" src="/page/device-page.js">`
replaces the 67 tags: imports *are* the dependency graph, a file's private
functions are private, and `internal/` means something. No bundler — every
browser the page supports loads modules natively, and `node --test` imports
them directly (no `vm` loader). During the move, a module may still read an
old `window.X`, and an old IIFE may be given a module's export through
`window` — so the page works at every slice.

### Sharing this Mac, from the devices page

Today a viewer opens a separate page, `/mac/share`, to share this Mac to their
device. The share belongs on the **devices page** instead, beside the Mac's
displays it creates one of: a **Share this Mac here** card, with the same room
and use choices, that makes the display and opens it — the same page the
viewer picks every other device from. Its code is the Mac family's
(`families/mac/share.js`), shown only when the server shares the Mac.

**Kept for compatibility:** `/mac/share` (the page) and `/mac/shares` (the API)
stay as they are; the old page becomes a thin page over the same module.

## 5 · Invariants — each law, one owner

| Law | Owner |
|---|---|
| a control shows only when its device has the ability its panel needs | `Toolbar` (from `panel.needs`; `DeviceAbilities.NEEDS` dies) |
| a panel opens in its sheet, mounted once, kept mounted while closed; its control shows it open | `Panels` (one sheet rule, not seven `toggleX`) |
| a device has a role only when its family can perform it — absent, never disabled | each Family |
| the page never branches on a device's kind; only `families.js` reads it | `Families` |
| the composition root is the only file that names every panel | `page/device-page.js` |
| `device/` imports nothing of ours; families don't import each other; `internal/` stays inside its folder | the boundary test |
| the page's behaviour is unchanged by the move | each slice's tests, and the page checked by hand |

## 6 · Build sequence (test-first; the page works after every slice)

| Slice | What | Pins |
|---|---|---|
| 1 BUILT | this doc; ES modules proven on the first one: `mac-share.js` → `families/mac/share.js`, still reachable as `window.Baguette._MacShare` for the old scripts; its tests import it directly; the boundary test | the share page and a shared display work as before; a module test runs without the `vm` loader |
| 2 BUILT | `Device` and `Families` in `device/` and `families/`: each family builds its Device with the roles it has (frame, power, orientation, pointer, companions, share) — wrapping today's code, the page still calling it | Families' tests: a simulated iOS listing is a Simulator with power and orientation; a physical one a Phone with neither; a macOS one a MacDisplay with pointer and share |
| 3 BUILT | the page tells roles instead of asking the kind: every `deviceMode` / `devicePlatform` / `sharedMac()` branch goes | no `kind` read outside `families.js` (the boundary test) |
| 4 | `Panel` and `Panels` (registry, sheet rule); **logs** moves to `panels/logs-panel.js`; `toggleLogs` and its `NEEDS` entry die | Panels' tests: opens in its sheet, mounted once, control marked |
| 5 | the other panels, one per slice: camera, network, defaults, notify, location, status bar, accessibility, 3D, plugins | each: its toggle and `NEEDS` entry die |
| 6 | `Toolbar` built from `Panels` filtered by `Device.abilities`; `DeviceAbilities` dies | a phone shows no logs control; a Mac display no rotate |
| 7 | each family's role code moves into its folder: `families/mac/` (share, frames, pointer), `families/simulator/` (companions, power card, hinge, bezel), `phone/`, `android/` | each family's tests through its roles |
| 8 | `wire/`: StreamSession, WhepSession, transport, device.json; `capture/` gathered | — |
| 9 | the share on the devices page: a **Share this Mac here** card on the list, from `families/mac/share.js`; `/mac/share` kept as a thin page over it | sharing from the devices page lands on the shared display, as `/mac/share` did |
| 10 | what is left of `sim-native.js` is `page/device-page.js`'s composition; `sim-` names gone; `sim.html` loads one module | `sim-native.js` is deleted |

Each slice is its own commit; slices 1–3 (the stable domain) are one PR, the rest can follow.

## 7 · Open questions

- **The farm page** (`farm/`) and the list (`sim-list.js`) — same layers, later
  slices, or left as they are? They're second roots on the same `device/` and
  `wire/`.
- **`sim-stream.js`** (the sidebar page): still reached, or dead? To check
  before slice 8.
- **The template** (`sim-native.html`, 3,800 lines of markup and CSS fetched
  at boot): split by the same folders (each panel's markup and CSS beside its
  module), or kept whole until the JS is done?
