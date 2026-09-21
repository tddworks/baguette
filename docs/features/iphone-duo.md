# iPhone Duo (Xcode 27.1, iOS 27.1)

Xcode 27.1 beta ships the first foldable simulator, **iPhone Duo**
(`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, `iPhone19,4`,
codename `V68`; SpringBoard calls it *Butterfly*). It is one device
with **two integrated panels**, and that broke two assumptions
baguette had made since day one: "the largest portrait framebuffer is
the phone" and "the phone's digitizer is `0x32`". This page is what the
device looks like from the host, what baguette does about it, and what
the beta does not let anyone do yet.

## Getting one

The device type needs `minRuntimeVersion 27.1`, so it does not exist
until an iOS 27.1 runtime is installed — Xcode 27.0's `simctl` lists
the type but refuses to create it (`Incompatible device`), and 27.1's
refuses until the runtime lands (`Invalid runtime`).

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
xcodebuild -downloadPlatform iOS            # iOS 27.1 Simulator, 7.85 GB
xcrun simctl create 'iPhone Duo' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-Duo \
  com.apple.CoreSimulator.SimRuntime.iOS-27-1
```

Installing the runtime through `xcodebuild -downloadPlatform` also
auto-creates one Duo (the profile is `createByDefaultForRuntimeVersions
≥ 27.1`), so the explicit `create` is only needed when the runtime was
added some other way. Then `baguette boot --udid <UDID>` as usual —
the Device Hub heal from [`device-hub.md`](device-hub.md) applies to
this device like any other iOS 27 one.

## What the host sees

`capabilities.plist` declares two `integrated` displays; `simctl io
enumerate` lists both under Connected Screens, each with a live
`com.apple.framebuffer.display` port and an IOSurface:

| | `primary` (cover) | `primary-1` (unfolded) |
|---|---|---|
| Screen ID | 1 | 3 |
| Name | `LCD` | `LCD-1` |
| Pixels | 1398 × 2034 @3x → 466 × 678 pt | 2007 × 2853 @3x → 669 × 951 pt |
| Chrome | `phone15` | `phone14` |
| Digitizer sender | `ACEFADE00000007` | `ACEFADE00000009` |
| At boot | lit, SpringBoard's `Main` display | **dark** — guest sets `display_id=3 … target_state=off` |

Both panels report `Power state: On` and `UI Orientation: Portrait`
from the host, so nothing on the host side says which one is lit. The
guest does: SpringBoard runs a `SBCoverDisplayConfigurationTransformer`,
lights the cover, and turns the unfolded panel off. **The Duo boots
folded, and this beta has no way to unfold it** — see the last section.

The usual decoys are there too: `tvOut` and `carPlay` at 720×480 and
the 7680×4320 `scene` port. Both chrome bundles ship a baked
`PhoneComposite`, so the bezel path is unaffected.

## What baguette does

Every phone-plane entry point (`tap` / `swipe` / `input`, `screenshot`,
`stream`, `serve`, `record`, `describe-ui`, `chrome layout`) follows
the **lit** panel. Which one that is comes from the hinge.

### The hinge is read, not driven

Device Hub folds and unfolds the Duo from the pose picker at the bottom
of its window. It streams the angle into the guest as HID reports
(`UniversalHID` → `dtuhidd` → `kIOHIDEventTypeHingeAngle` → CoreMotion
→ SpringBoard's pose provider), and SpringBoard decides which panel to
light. baguette reads that angle back with

```bash
xcrun devicectl device motion hinge-angle --device <UDID> --timeout 5
```

whose first sample is the current angle and lands in ~0.3 s;
`DevicectlHinge` takes it and terminates the monitor. `HingeAngle.
litPanel` puts the swap at 90°: Device Hub's closed pose reads ≈3°,
its open pose ≈130°. Only a device with more than one portrait panel
(`IntegratedPanels.several`) ever asks — a phone pays nothing.

`GET /simulators/<udid>/hinge` reports it:

```json
{"ok":true,"foldable":true,"angleDegrees":130.0,"litPanel":"secondary","orientation":"landscape-left"}
```

### Framebuffer: the lit panel

`ConnectedScreens.binding(kind: .phone, litPanel:)` binds the port
whose Connected Screen CoreSimulator names `primary` (cover) or
`primary-1` (unfolded) according to the hinge; a device with only a
primary gets it whatever the hinge says, and output without names falls
through to the shape rule unchanged. The binding also carries the
screen's `UI Orientation`, because the open pose puts SpringBoard in
landscape by itself.

### Digitizer: the lit panel's own registration, not the shared slot

This is the one that needed the disassembler. In
`SimulatorHID` (shipped with CoreSimulator, loaded into every
runtime's backboardd),
`-[SimHIDVirtualServiceManager createDigitizerForTargetID:withDisplayUID:isBuiltIn:]`
does three things:

1. builds `com.apple.SimulatorHID.ScreenTouchService.<displayUUID>`;
2. registers it in `allServices` under the **targetID the host's
   create message carried** — which it insists has "the ScreenID mask
   bit", i.e. `0x40000000 | screenId`;
3. if `isBuiltIn`, *also* stores it under the constant `@50` (`0x32`)
   and calls `setBuiltInDigitizerService:`, which overwrites.

So `0x32` was never a digitizer of its own. It is a **slot**, owned by
the last built-in panel created. Every single-panel device creates one
built-in panel and the slot is it. The Duo creates two — screen 1, then
screen 3 — both built-in, and the slot ends on screen 3. backboardd
confirms it: a tap sent to `0x32` arrives on `ACEFADE00000009`, the
sender bound to LCD-1's display UUID.

The panels' own keys are `0x40000001` (cover) and `0x40000003`
(unfolded); the former is the `1073741825` that has sat in the guest's
published known-targets list all along, which
[`companion-screens.md`](companion-screens.md) had read as a near-miss.
`DisplayTouchTarget.resolve(kind: .phone, connectedScreenId:)` returns
`IndigoHIDTouchTarget.panel(screenId:)` for the bound (lit) panel and
the slot when none is bound.

The rule from the CarPlay work stands, sharpened: **a target is a
registration.** `panel(screenId:)` is only ever fed a screen id that
Connected Screens lists as `Integrated`, because only those get a
create-digitizer message. Screen 2 is TVOut; `0x40000002` is still the
number that takes the guest down.

### Chrome, tap space and accessibility

`DeviceProfile` reads both panels from `capabilities.plist`: the cover
is the profile's own `phone15` / 466×678, the unfolded panel is
`primary-1`'s `phone14` / 669×951. `Chromes.assets(forDeviceName:panel:)`
serves either, and `Simulator.chrome(in:)` picks by `litPanel(in:)`,
so `chrome.json`, `definition.json`, `bezel.png` and `chrome layout
--udid` all describe the lit panel. `chrome layout --device-name
"iPhone Duo" --panel unfolded` reads the open layout by name, for a
device that is folded or not booted. `describe-ui` frames come back in
the lit panel's point space (`DisplayBinding.pointSize(scale:)`).

### The page draws it from its 2D frames, with the 3D book one click away

A booted Duo's page is posed by the hinge (`BookPose`,
`baguette/hinge/book-pose.js`):

| Hinge | The page shows | Stream |
|---|---|---|
| ≤ 5° (shut) | the cover's flat chrome, `phone15` | `panel=primary` |
| ≥ 178° (flat) | the unfolded panel's flat chrome, `phone14` with its crease | `panel=secondary` |
| between | the unfolded device as a **book** (`BookView`) | `panel=secondary`, plus the cover for the book's back |

The book is drawn from the flat view's own frames: each rAF, the
unfolded device (bezel, live frame through the panel's mask, crease) is
drawn into two canvases, one per half, and CSS 3D turns them about the
crease in perspective — above the open pose both halves share the bend,
below it the left half folds over onto the right (the angles
`FoldPose` gives the 3D model). Each half has a body: a dozen slices
of the device's own outline stacked behind its screen, shaded from a
lit front to a dark back and drawn once, so a tilted half shows a
rounded rim and costs nothing per frame. The crease is a faint
hairline flat and deepens with the fold (`BookPose.creaseOpacity`).
The left half's back carries the cover,
live, from a second stream pinned to it into a canvas nobody sees; so
closing turns the cover toward the viewer, black until the guest lights
it, as on the device. The book shifts sideways as it narrows so it
stays centred. Taps on the tilted halves land where they look: each
half carries 1×1 markers at the screen's corners, and the page inverts
their projected quad (`ScreenQuad.locate`) into the unfolded panel's
tap space; the cover on the back is not tappable.

Crossing into or out of the cover swaps chrome and stream in place,
carrying the last picture across: opening starts the book with the
cover's last frame on its back, and shutting fades the book out over
the cover's flat chrome. Under the device sits Device Hub's pose bar
(`FoldBar`, `baguette/hinge/fold-bar.js`): Closed (0°), Open (130°),
Flat (180°) and the hinge slider, which the hinge follows as it is
dragged — the same `set_pose` bursts the 3D socket takes. The stream
socket pushes every hinge sample (`{"type":"hinge","angleDegrees":130.0}`)
and the page re-poses on each. The guest turns the unfolded panel to
landscape by itself, so the page starts it at landscape-left and, once
the hinge goes quiet, asks `GET /hinge` which way it faces; the book is
only drawn for a vertical crease (landscape). The cube button opens the
3D book (below) straight on and closes back to the flat view.

**Which panel is lit is the guest's call, not a function of the
angle.** `HingeAngle.litPanel` splits at 90°, which agrees with
SpringBoard at the three poses. In between, SpringBoard keeps
hysteresis, measured on iOS 27.1 by reading its `CADisplayStateDidChange`
log after each move. Opening from shut, it lights the unfolded panel
almost at once and keeps the cover on until somewhere between 80° and
100°. Closing from open, it keeps the unfolded panel lit down to
somewhere between 60° and 80°. The book sidesteps this by showing both
panels at once; the server's own binding for a stream without `panel=`
still follows the 90° rule.

### The 3D book

Device Hub does not draw the Duo with a 2D chrome at all. Its device
view is `CoreDevicePopDeviceKitExtension`, a DeviceKit plug-in that
renders Apple's own model of the device — `V68.usdz`, inside the
plug-in's resources — with RealityKit: a skinned book (31 joints, the
crease a run of 23 of them) whose clips `l_over_r`, `r_over_l` and
`book_close` shut it, plus `power_button`, `volumeup_button`,
`volumedown_button` and `photo_button` for the keys. Three of its
materials are screens: `CvyXbAGXoolRUYl` (unfolded), `YqugYDOqMSOpqyA`
(cover) and `AGmjnWHbZiRqzbR` (the cover camera). The flat chromes
(`phone14` / `phone15`) are what the CLI's `chrome` verbs and the
`bezel.png` routes still serve.

baguette's cube button does the same, on its existing RealityKit
pipeline ([`3d-rendering.md`](3d-rendering.md)). `Models3D/iphone-duo/
definition.json` names the asset by its path inside Xcode
(`asset.xcodeResource` — read from Xcode the way the 2D chromes are
read from `/Library/Developer/DeviceKit`, never copied). The selected
Xcode is tried first, then every other `/Applications/Xcode*.app`:
`V68.usdz` ships only in the 27.1 beta, and `xcode-select` usually
still names the release. The definition also names the two
screen materials, the quarter turn the unfolded framebuffer needs on
the mesh (`textureRotation: 270`), the rest rotation that stands the
authored model up, the shutting clip and the joints that carry the
buttons:

```json
"fold": {"clip": "l_over_r", "shutTime": 5.0,
         "coverMaterial": "YqugYDOqMSOpqyA",
         "coverTextureSize": {"width": 1398, "height": 2034},
         "openPoseDegrees": 130}
```

The cube opens the Duo's live 3D stream straight on (`fixed`: no
orbiting, no stage tools), standing the way the flat view was turned;
the cube again returns to the flat chrome. The 3D socket binds **both**
panels (`RenderedFoldable`) and the shared hinge, and poses the book
from every sample (`FoldPose`): the clip runs from flat at its start
to shut at `shutTime`, and because it raises the left half alone the
whole device turns back by half the fold above the open pose — the
centred bend Device Hub draws — handing over as the book shuts so the
cover ends facing the camera. With no hinge reading the book is shown
shut, as the device boots, until the hinge speaks.

Input goes through `screen_quad` as on a phone, but a bent screen is
not one quad: the server sends `pieces` — the two halves of the
unfolded screen or the cover — each with its corners in the
framebuffer's own order and the part of the buffer it shows
(`FoldedScreenProjection`), so the page maps a click straight into
framebuffer space without an orientation of its own. The model's
buttons come along as `buttons` (`at` on the body, `control` beside
it), and the page draws the controls where Device Hub does, shown
while the pointer is on the stage; pressing one sends the ordinary
`button` envelope.

**Orientation.** The framebuffer maps onto the panel the way the
panel is built, so whatever the guest draws — landscape-left in the
open pose, portrait on the cover — reads right without the page
knowing, and touches land in buffer space whatever the interface
orientation. The book *stands* the way the page turns it: the
rotate button rolls the model a quarter turn per step of the interface
cycle (`InterfaceRoll`, measured against Device Hub: the unfolded
panel in *Portrait Upside Down* stands the book with its left half
up), as it turns a phone's flat chrome, and tells the guest the
orientation it asked for. Nothing is read back — a rotation made in
Device Hub is its own, and the page's button brings the two into step.

**Pose picker.** Under the book sits Device Hub's picker — the flat
view's `FoldBar` — shut, open
(130°), flat. A pick moves the device's own hinge there
(`{"type":"set_pose","hingeDegrees":0}` on the 3D socket → `Hinge.fold`,
swept over Device Hub's 0.8 s by `HingeControl` inside the guest — see
[`hinge.md`](hinge.md)); SpringBoard swaps panels and the book follows
the hinge samples as it goes. `screen_quad` carries `pose:
{hingeDegrees}` so the nearest pose lights up. Beside the three poses
sits Device Hub's **hinge slider**: dragging it sends
`{"type":"set_pose","hingeDegrees":72,"duration":0}` a few times a
frame at most, and the hinge goes straight to the thumb (no sweep);
pose requests on a socket play in order and skip what the burst has
already passed, so the hinge catches up to the thumb rather than
replaying its path. Released, the slider follows the hinge again.

**Hardware keys.** The controls beside the device are drawn as Device
Hub draws them — a grey glyph (speaker −/+, lock, camera) that shows
while the pointer is over the stage and lights under the pointer — and
they work: on the Duo the legacy Indigo press is ignored by SpringBoard,
so a foldable's input presses these keys through the guest the way
Device Hub does (`FoldableInput` → `DeviceKeys` → `HingeControl button`;
see [`hinge.md`](hinge.md)).

Known gaps: the hinge's motion stream can stop after a SpringBoard
restart (`baguette heal`) — `devicectl` then reports nothing until
Device Hub moves the pose — and the shared hinge remembers such
silence for three seconds rather than making every caller wait it
out. Framebuffer enumeration is serialised process-wide: SimulatorKit
has raised `NSFileHandle … Bad file descriptor` out of two
enumerations at once.

## Coordinates

Same convention as everywhere else — device points, in the lit panel's
space. `baguette chrome layout --udid <UDID>` reports the cover's
466 × 678 while folded, and that is what to pass as `--width` /
`--height`. `describe-ui` frames come back in the same space.

## Driving the hinge from baguette

`baguette hinge --udid <UDID> --pose open` and `POST
/simulators/<udid>/hinge` — see [`hinge.md`](hinge.md) for the route
into the guest (`HingeControl`, the pose events Device Hub's `dtuhidd`
dispatches, reproduced). The SpringBoard shim tried first (swizzling
`CMAngleManager` to feed fabricated `CMAngle`s) worked too but needed an
injected dylib and a SpringBoard restart; it is not shipped.

## What the beta cannot do yet

- **Device Hub's picker has three poses**; Apple's Duo guidance lists
  six (closed, tent, open landscape, book, open portrait, laptop).
  `baguette hinge --angle` sets any angle 0–180; what SpringBoard makes
  of the ones between is the runtime's business. `simctl io
  screenConfig` has only `power` and `geometry` (powering `primary-1`
  on lights nothing; the guest's pose decides).
- **`describe-ui` in landscape** maps frames through a portrait point
  size, as it always has for a rotated iPhone; the open pose is
  landscape, so expect the same skew there.
