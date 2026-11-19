---
description: How baguette finds the Duo's lit panel, why its digitizer is 0x40000000|screenId and 0x32 is only a slot, how the hinge is read and driven, why its keys bypass Indigo, and how the page draws V68.usdz. Read before touching foldable support.
---

# iPhone Duo: design

iPhone Duo (`com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, `iPhone19,4`,
codename `V68`; SpringBoard calls it *Butterfly*) is one device with **two
integrated panels**, and that broke two assumptions baguette had made since day
one: "the largest portrait framebuffer is the phone" and "the phone's digitizer
is `0x32`". Found on Xcode 27.1 beta / iOS 27.1.

## Path

- Every phone-plane entry point (`tap` / `swipe` / `input`, `screenshot`,
  `stream`, `serve`, `record`, `describe-ui`, `chrome layout`) → the lit panel,
  from `HingeAngle.litPanel`.
- **Read**: `GuestHinge` → `HingeControl read-angle` / `watch-angle` in the
  guest (CoreMotion), only when `IntegratedPanels.several`.
- **Drive**: `baguette hinge`, `POST /devices/<UDID>/hinge`, the page's
  `set_pose` → `Hinge.fold(to:over:)` → `GuestHingeMotor` → `HingeControl serve`
  in the guest (`Injected/HingeControl`) → private `HID.framework`'s
  `HIDVirtualEventService` (see [hinge](../hinge/README.md)).
- **Keys**: `FoldableInput` → `DeviceKeys` → `HingeControl button` in the guest.
- **Bind**: framebuffer (`ConnectedScreens.binding(kind: .phone, litPanel:)`),
  digitizer (`DisplayTouchTarget.resolve` → `IndigoHIDTouchTarget.panel(screenId:)`),
  chrome (`Simulator.chrome(in:)`), tap space, AX point size
  (`DisplayBinding.pointSize(scale:)`), and the page's rotation.

## Getting one

The device type needs `minRuntimeVersion 27.1`, so it does not exist until an
iOS 27.1 runtime is installed. The profile is `createByDefaultForRuntimeVersions
≥ 27.1`, which is why `xcodebuild -downloadPlatform` auto-creates one Duo.

## What the host sees

`capabilities.plist` declares two `integrated` displays; `simctl io enumerate`
lists both under Connected Screens, each with a live
`com.apple.framebuffer.display` port and an IOSurface:

| | `primary` (cover) | `primary-1` (unfolded) |
|---|---|---|
| Screen ID | 1 | 3 |
| Name | `LCD` | `LCD-1` |
| Pixels | 1398 × 2034 @3x → 466 × 678 pt | 2007 × 2853 @3x → 669 × 951 pt |
| Chrome | `phone15` | `phone14` |
| Digitizer sender | `ACEFADE00000007` | `ACEFADE00000009` |
| At boot | lit, SpringBoard's `Main` display | **dark** — guest sets `display_id=3 … target_state=off` |

Both panels report `Power state: On` and `UI Orientation: Portrait` from the
host, so nothing on the host side says which one is lit. The guest does:
SpringBoard runs a `SBCoverDisplayConfigurationTransformer`, lights the cover,
and turns the unfolded panel off. **The Duo boots folded.**

The usual decoys are there too: `tvOut` and `carPlay` at 720×480 and the
7680×4320 `scene` port. Both chrome bundles ship a baked `PhoneComposite`, so
the bezel path is unaffected.

**Leave screen power alone.** `simctl io screenConfig` has only `power` and
`geometry`. Powering `primary-1` on lights nothing (the guest's pose decides);
powering it *off* crash-loops SpringBoard.

## The hinge

The hinge decides which panel is lit: SpringBoard lights one from the angle
Device Hub's pose picker sets (closed ≈3°, open ≈130°). baguette both drives
and reads it; how, byte for byte, is in [hinge/design.md](../hinge/design.md).
What matters here is the one number the panel binding keys on:
`HingeAngle.litPanel` puts the swap at 90°, and only a device with more than
one portrait panel (`IntegratedPanels.several`) ever asks, so a phone pays
nothing.

## Framebuffer: the lit panel

`ConnectedScreens.binding(kind: .phone, litPanel:)` binds the port whose
Connected Screen CoreSimulator names `primary` (cover) or `primary-1`
(unfolded) according to the hinge; a device with only a primary gets it
whatever the hinge says, and output without names falls through to the shape
rule unchanged. The binding also carries the screen's `UI Orientation`, because
the open pose puts SpringBoard in landscape by itself.

Framebuffer enumeration is serialised process-wide: SimulatorKit has raised
`NSFileHandle … Bad file descriptor` out of two enumerations at once.

## Digitizer: the lit panel's own registration, not the shared slot

This is the one that needed the disassembler. In `SimulatorHID` (shipped with
CoreSimulator, loaded into every runtime's backboardd),
`-[SimHIDVirtualServiceManager createDigitizerForTargetID:withDisplayUID:isBuiltIn:]`
does three things:

1. builds `com.apple.SimulatorHID.ScreenTouchService.<displayUUID>`;
2. registers it in `allServices` under the **targetID the host's create message
   carried** — which it insists has "the ScreenID mask bit", i.e.
   `0x40000000 | screenId`;
3. if `isBuiltIn`, *also* stores it under the constant `@50` (`0x32`) and calls
   `setBuiltInDigitizerService:`, which overwrites.

So `0x32` was never a digitizer of its own. It is a **slot**, owned by the last
built-in panel created. Every single-panel device creates one built-in panel and
the slot is it. The Duo creates two — screen 1, then screen 3 — both built-in,
and the slot ends on screen 3. backboardd confirms it: a tap sent to `0x32`
arrives on `ACEFADE00000009`, the sender bound to LCD-1's display UUID. **On the
Duo, `0x32` is not the cover.**

The panels' own keys are `0x40000001` (cover) and `0x40000003` (unfolded); the
former is the `1073741825` that has sat in the guest's published known-targets
list all along, which [companion screens](../companion-screens/README.md) had
read as a near-miss. `DisplayTouchTarget.resolve(kind: .phone, connectedScreenId:)`
returns `IndigoHIDTouchTarget.panel(screenId:)` for the bound (lit) panel and
the slot when none is bound.

The rule from the CarPlay work stands, sharpened: **a target is a
registration.** `panel(screenId:)` is only ever fed a screen id that Connected
Screens lists as `Integrated`, because only those get a create-digitizer
message. Screen 2 is TVOut; `0x40000002` is still the number that takes the
guest down.

## Hardware keys: through `dtuhidd`, not Indigo

The Duo ignores the legacy Indigo button press and Indigo's keyboard
message alike; its hardware keys and keyboard keys go through `dtuhidd`'s
`mainScreenButtons` service instead, pressed by `HingeControl`.
The measured usages and the routing (`FoldableInput` → `DeviceKeys`) are in
[hinge/design.md](../hinge/design.md#the-hardware-keys-go-the-same-way).

## Chrome, tap space and accessibility

`DeviceProfile` reads both panels from `capabilities.plist`: the cover is the
profile's own `phone15` / 466×678, the unfolded panel is `primary-1`'s
`phone14` / 669×951. `Chromes.assets(forDeviceName:panel:)` serves either, and
`Simulator.chrome(in:)` picks by `litPanel(in:)`, so `chrome.json`,
`definition.json`, `bezel.png` and `chrome layout --udid` all describe the lit
panel. `describe-ui` frames come back in the lit panel's point space
(`DisplayBinding.pointSize(scale:)`); in landscape they are mapped through a
portrait point size, as for a rotated iPhone.

## The page shows the book, in 3D

Device Hub does not draw the Duo with a 2D chrome at all. Its device view is
`CoreDevicePopDeviceKitExtension`, a plug-in in `DeviceKit.framework` that
renders Apple's own model of the device — `V68.usdz`, inside the plug-in's
resources — with RealityKit: a skinned book (31 joints, the crease a run of 23
of them) whose clips `l_over_r`, `r_over_l` and `book_close` shut it, plus
`power_button`, `volumeup_button`, `volumedown_button` and `photo_button` for
the keys. Three of its materials are screens: `CvyXbAGXoolRUYl` (unfolded),
`YqugYDOqMSOpqyA` (cover) and `AGmjnWHbZiRqzbR` (the cover camera). The flat
chromes (`phone14` / `phone15`) have no sides, hinge or keys; they are what the
CLI's `chrome` verbs and the `bezel.png` routes still serve.

baguette's page does the same, on its existing RealityKit pipeline
([3D rendering](../3d-rendering/README.md)). `Models3D/iphone-duo/definition.json`
names the asset by its path inside the selected Xcode (`asset.xcodeResource` —
read from Xcode the way the 2D chromes are read from
`/Library/Developer/DeviceKit`, never copied), the two screen materials, the
quarter turn the unfolded framebuffer needs on the mesh (`textureRotation: 270`),
the rest rotation that stands the authored model up, the shutting clip and the
joints that carry the buttons:

```json
"fold": {"clip": "l_over_r", "shutTime": 5.0,
         "coverMaterial": "YqugYDOqMSOpqyA",
         "coverTextureSize": {"width": 1398, "height": 2034},
         "openPoseDegrees": 130}
```

A booted Duo's page opens the live 3D stream straight on (`fixed`: no orbiting,
no stage tools; the cube button turns the book and sets it back) and never shows
the flat chrome; a shut-down Duo still gets the flat chrome for its power card.
The 3D socket binds **both** panels (`RenderedFoldable`) and the shared hinge,
and poses the book at the hinge's angle (`FoldPose`): the clip runs from flat at
its start to shut at `shutTime`, and because it raises the left half alone the
whole device turns back by half the fold above the open pose — the centred bend
Device Hub draws — handing over as the book shuts so the cover ends facing the
camera. With no hinge reading the book is shown shut, as the device boots, until
the hinge speaks. The angle is the hinge's own reading, except during a sweep
this `serve` plays (`POST /hinge`, `set_pose`). The book plays that sweep as
commanded, at 60 Hz, then settles on the reading (`PosedHinge`). The readings
can arrive seconds late on a loaded host. The lit screen, its texture and the
`pieces` follow the posed angle across 90°.

Input goes through `screen_quad` as on a phone, but a bent screen is not one
quad: the server sends `pieces` — the two halves of the unfolded screen or the
cover — each with its corners in the framebuffer's own order and the part of the
buffer it shows (`FoldedScreenProjection`), so the page maps a click straight
into framebuffer space without an orientation of its own. The model's buttons
come along as `buttons` (`at` on the body, `control` beside it), and the page
draws the controls where Device Hub does — a grey glyph (speaker −/+, lock,
camera) shown while the pointer is on the stage, lit under the pointer; pressing
one sends the ordinary `button` envelope.

**Orientation.** The framebuffer maps onto the panel the way the panel is built,
so whatever the guest draws — landscape-left in the open pose, portrait on the
cover — reads right without the page knowing, and touches land in buffer space
whatever the interface orientation. The book *stands* the way the page turns it:
the rotate button rolls the model a quarter turn per step of the interface cycle
(`InterfaceRoll`, measured against Device Hub: the unfolded panel in *Portrait
Upside Down* stands the book with its left half up), as it turns a phone's flat
chrome, and tells the guest the orientation it asked for. The orientation setter does not read the
guest's orientation back: `simctl io enumerate` says `Ambiguous` for a dark or
turning panel, and backboardd's `OrientationDevice` log has it but is unused. A
rotation made in Device Hub is its own, and the page's button brings the two
into step.

**Pose picker.** A pick sends `{"type":"set_pose","hingeDegrees":0}` on the 3D
socket → `Hinge.fold`, swept over Device Hub's 0.8 s by `HingeControl` inside the
guest; the book plays the sweep as it goes and SpringBoard swaps panels.
`screen_quad` carries `pose: {hingeDegrees}` so the nearest pose lights up. The
**hinge slider** sends `{"type":"set_pose","hingeDegrees":72,"duration":0}`
a few times a frame at most, and the hinge goes straight to the thumb (no
sweep); pose requests on a socket play in order and skip what the burst has
already passed, so the hinge catches up to the thumb rather than replaying its
path. Released, the slider follows the hinge again.
