---
description: Fold or unfold iPhone Duo's hinge to a pose or angle, and read the angle back, from the CLI, HTTP or the page's pose picker. Use when testing an app across the Duo's folded and unfolded panels.
---

# Hinge (iPhone Duo)

iPhone Duo folds. `baguette hinge` moves its hinge — Device Hub's pose
picker from the CLI, the HTTP route and the page — and reads it back.
Every flag: [commands.md#baguette-hinge](../../commands.md#baguette-hinge).

## Quick start

```bash
baguette hinge --udid <UDID>                    # {"ok":true,"angleDegrees":130.0}
baguette hinge --udid <UDID> --pose closed      # 0°   sweeps over 0.8 s
baguette hinge --udid <UDID> --pose open        # 130° Device Hub's book pose
baguette hinge --udid <UDID> --pose flat        # 180°
baguette hinge --udid <UDID> --angle 95 --duration 1.2
```

On the `serve` page, the pose picker under a booted Duo offers closed,
open and flat, beside a hinge slider (see
[iPhone Duo](../iphone-duo/README.md)). SpringBoard swaps panels as the
hinge moves, and the page, the lit panel and the chrome all follow.

## HTTP / WebSocket

```http
POST /devices/<udid>/hinge?pose=open
POST /devices/<udid>/hinge?angle=95&duration=1.2
GET  /devices/<udid>/hinge                  (or /simulators/<udid>/hinge)
```

The `POST` blocks for the sweep and answers `{"ok":true}`; `400` for a
pose that is not `closed`/`open`/`flat`, an angle off 0–180 or a
duration off 0–60 s; `404` for an unknown udid; `500` when the device
could not be driven (no `HingeControl` shipped, guest refused); `504`
when the guest helper timed out, so the fold may have landed. A phone
answers the `GET` with `foldable:false` and has nothing to drive.

On the 3D socket the picker sends:

```json
{"type":"set_pose","hingeDegrees":130}
```

and the book plays the sweep as it is commanded, at 60 Hz, then settles
on the hinge's reading. It lights the panel the pose calls for, as
SpringBoard does once the device gets there. A `POST` does the same for
every 3D socket on the device. A fold made anywhere else is drawn from
the hinge samples. A `set_pose` off the hinge or over 60 s is answered
`{"ok":false,"error":…}` with the `POST`'s `400` message.

The other way, a foldable's stream socket (`/simulators/<UDID>/stream`)
sends every sample the hinge sweeps through, so a page can draw the fold
at the device's angle:

```json
{"type":"hinge","angleDegrees":130.0}
```

## Rotation

```bash
baguette orientation --udid <UDID> portrait
baguette orientation --udid <UDID> portrait-upside-down
baguette orientation --udid <UDID> landscape-left
baguette orientation --udid <UDID> landscape-right
```

The command and HTTP orientation route rotate the physical device. An app
can keep its interface locked, and the inner display has different axes
from the device, so successful dispatch need not change the app's layout.
The command exits 1 (HTTP `500`) when the device cannot be identified or its
orientation event cannot be delivered, and 3 (HTTP `504`) when the Duo's
guest pose helper timed out: the change may have landed before the helper's
deadline, and will not land later. `baguette hinge` does the same for a fold.
Read the device state before retrying. See [design.md](design.md) for the
Duo-specific dispatch and completion behavior.

## Hardware keys

On iPhone Duo the legacy button press is ignored by SpringBoard, so
baguette presses a foldable's volume, power / lock, and action keys
through the same guest-side route Device Hub uses. `baguette press`,
`POST …/input` and the page's buttons work unchanged; `home` and the
edge gestures still take the legacy path. Single-panel devices are
untouched.

## Gotchas

- Device Hub and baguette both feed the same hinge; whoever sent last
  wins, and Device Hub's picker shows its own last pick, not the
  device's angle, until it next reads the hinge.
- `HingeControl` needs the iOS 27.1 simulator's private `HID.framework`
  to accept a virtual service from an unentitled process, and CoreMotion
  to hand it the hinge angle, which both do; a future runtime may not.
- The guest's hinge reading goes silent after a SpringBoard restart
  (`baguette heal`); driving still works, reading it back resumes once
  Device Hub or baguette moves the pose again.
- Sweeps queue behind one another. The first pose spawns the guest
  helper; later ones cost no spawn (~0.9 s round trip for Device Hub's
  0.8 s sweep).
- A `serve` page's 3D book plays only the folds that `serve` itself
  drives. A fold from Device Hub or from `baguette hinge`, which runs in
  its own process, reaches the book through the hinge samples, and on a
  loaded host those can arrive seconds late.

## See also

- [design.md](design.md) — how the hinge and keys are driven through `dtuhidd`'s virtual HID services, measured payloads, packaging
- [iPhone Duo](../iphone-duo/README.md) — lit panel, 3D model, pose picker
- [Buttons](../buttons/README.md)
