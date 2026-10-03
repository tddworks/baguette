---
description: Render the simulator screen on a real Apple 3D device model — live in the serve page's 3D viewport, or as a one-shot PNG from the CLI or HTTP. Use for marketing shots, App Store assets or demoing an app on a posed device.
---

# 3D device rendering

Live rendering of the simulator screen on a real Apple device model. The
primary surface is an interactive 3D stream in the focused simulator view;
one-shot PNG rendering remains available for automation and export. Every
flag: [commands.md#baguette-render-3d](../../commands.md#baguette-render-3d).

Based on [`benmcdowell/3dsg`](https://github.com/benmcdowell/3dsg), but
data-driven: models are definitions you can add ([models.md](models.md)).

## Quick start

Capture the current simulator frame and infer the model from its device type:

```bash
baguette render-3d \
  --udid 5A1B… \
  --variant finish=space-black \
  --rotation=-30,45,30 \
  --size appstore-6.9 \
  --output device.png
```

Render an existing image by selecting a model explicitly:

```bash
baguette render-3d \
  --screen screenshot.png \
  --device iphone-17-pro \
  --variant finish=deep-blue \
  --output device.png
```

Exactly one of `--udid` and `--screen` is required; `--device` is inferred
with `--udid`. Unknown devices, model IDs, variant sets and variant choices
fail explicitly — baguette never substitutes a visually similar model.

On the `serve` page, the focus-mode **cube** button switches the main
viewport between the 2D stream and the live 3D stream (it's also the way
back). The inspector carries camera presets, variants, rotation and PNG
export; hiding it keeps the stream live.

- **Pose** (default): drag rotates the model, Option-drag or the wheel
  dollies the camera, double-click returns to Front at 100%.
- **Interact**: the canvas takes the same gestures as the 2D screen.
  Single-finger tap, drag and the edge bands are accurate at any rotation;
  two-finger pinch/pan and the Option-hover preview are most accurate near
  Front.

## `--size` and `--fit`

`--size` takes the [capture-size](../capture-size/README.md) vocabulary —
presets (`appstore-6.9`, `square`, `16:9`, …), `WIDTHxHEIGHT`, or a bare
ratio like `3:2`. Omit it for the captured screenshot's own pixel size
(`native`).

- **Ratios resolve against the captured screen, not the rendered
  device.** `--size square` on a 1290 × 2796 capture asks for a
  2796 × 2796 canvas, then the device is framed inside it — a squarely
  framed device rather than a tall device with bars.
- **Nothing downscales.** A ratio grows the binding axis. Use an explicit
  `WIDTHxHEIGHT` when you want a bounded output.

**`--fit` here is a different axis from `--fit` everywhere else.** On
`screenshot` and `record`, fit says how the frame sits inside the
output canvas. On `render-3d` it says how the *screenshot* sits on the
device's screen surface — a UV placement on the mesh, not a canvas
placement. That is why its default is `cover` rather than `contain`:
an app screenshot letterboxed inside a phone display would look like a
bug. Canvas placement in 3D is the camera's job.

## Exporting from the page

The inspector's export, the panel's *Save Frame* and the toolbar's
*Screenshot* (while 3D is open) all POST the current pose, variants, glass
setting and picked capture size to `render-3d.png` and save what comes
back — rendered fresh at full resolution with no codec in the path, so the
live stream is a preview of the export rather than its source. On a booted
iPhone 17 Pro Max that is 1320 × 2868 at native and a true 1290 × 2796 at
`appstore-6.9`. The file carries the size slug like every other capture:
`iphone-17-pro-max-3d-appstore-6.9-1290x2796.png`.

- `fit` is always sent as `cover`; `size` is omitted for `native`.
- **Zoom is not sent** — the export always frames at 1×; the panel warns
  in the console when the live zoom differs.
- **A failure still saves something**: the panel logs `[3d] lossless
  render failed, saving the live frame instead` and saves the live canvas
  as `<model-id>-live-3d.png`.
- The bezel toggle is suppressed while 3D is open. Recording can't
  re-render, so it crops the stage instead — see
  [Recording the 3D stage](../recording/README.md#recording-the-3d-stage).

### Stream density

The live stream always renders at the **stage's own shape** (framing is
the camera's job); a picked capture size changes only its density:

| pick | long side | a 924 × 652 stage streams at |
| --- | --- | --- |
| `native` | the stage's own pixels, bounded 480–1600 | 924 × 652 |
| any size | the whole 2560 budget | 2560 × 1806 |

The extra pixels are for the recorder, which crops the stage to the
target's shape; the render is close to free (0.67 s at 924 × 652 vs 0.72 s
at 3200 × 2258 on an M-series Mac) and the live view only gets smoother.
The socket restarts only when a pick crosses the native/sized line — at
most once a session.

## HTTP / WebSocket

```http
POST /simulators/:udid/render-3d.png
Content-Type: application/json
```

```json
{"rotation":{"x":-30,"y":45,"z":30},"variants":{"finish":"space-black"},
 "size":"appstore-6.9","fit":"cover","background":"transparent","screenGlass":false}
```

`"size"` also accepts the object form `{ "width": 1200, "height": 900 }`.
Omitting it gives the captured screen's own dimensions. The response is
`image/png`; defaults are the CLI's.

| Status | Meaning |
|--------|---------|
| `400` | Malformed render options or an unknown variant selection |
| `404` | Unknown simulator UDID or no installed definition matches it |
| `422` | The matched definition cannot render the requested configuration |
| `500` | Frame capture, model loading, asset download, or RealityKit rendering failed |

`GET /simulators/:udid/3d-model.json` returns the resolved model ID, display
name, and public variant-set metadata (what the inspector is built from). USD
prim paths, raw scene-node names, and asset URLs are never accepted from the
browser.

### Live 3D socket

```http
GET /simulators/:udid/stream.3d.<mjpeg|avcc>?rotation=-8,18,0&variant=finish:deep-blue&width=1200&height=1200&size=square&fit=cover&background=%23eef1f5&screenGlass=true
Upgrade: websocket
```

`variant` is repeatable; validation precedes subscription. For interaction while
moving the camera, use [atomic geometry/video frames](frames.md). `width`×`height` (default 960 × 960) is the *source box*
`size=` resolves against, rounded up to even dimensions:
`?size=appstore-6.9` yields 1290 × 2796, `?width=1280&height=720&size=square`
yields 1280 × 1280. The first frame is slower while the model loads.

It is the ordinary stream socket — gestures and stream controls use the
same envelopes ([wire.md](../../wire.md)), in simulator device points —
plus one camera message, which re-renders without reconnecting:

```json
{"type":"set_3d_camera","rotation":{"x":-8,"y":32,"z":0},"zoom":1.2}
```

On connect and after every `set_3d_camera` the server pushes where the
screen's corners land in the rendered image, `[topLeft, topRight,
bottomRight, bottomLeft]`, normalized `0,0` top-left to `1,1`
bottom-right:

```json
{"type":"screen_quad","corners":[[0.32,0.11],[0.71,0.09],[0.74,0.88],[0.29,0.91]]}
```

A foldable's `screen_quad` also carries `pieces`, `buttons`, `litPanel`
and `pose`; `set_3d_camera` may name an `orientation`; and `set_pose`
moves the hinge ([Hinge](../hinge/README.md)). Variant changes reconnect
the socket.

## Gotchas

- **A release binary can't find the models on its own.** A `./Baguette`
  built by `build.sh` has no resource bundle beside it and nothing creates
  the application-support directory, so `render-3d` 404s until you set
  `BAGUETTE_3D_MODEL_DIR` yourself (`swift run` is unaffected):

  ```bash
  BAGUETTE_3D_MODEL_DIR=Sources/Baguette/Resources/Models3D \
    ./Baguette render-3d --udid 5A1B… -o device.png
  ```

- The live stream is bounded by what the browser asks for (480–1600 per
  side from the UI, 4096 hard cap); `size=` shapes that box, it doesn't
  lift it. Submission-sized output comes from the PNG route.
- AVCC requires browser WebCodecs support, like the normal focused stream.
- Browser PNG export is a server round-trip that costs a fresh render;
  a 4xx/5xx falls back to the live frame, as above.
- The farm view has no 3D: a render per tile is too expensive.

## See also

- [models.md](models.md) — model bundles, the definition schema, variants, adding a model
- [design.md](design.md) — color accuracy, the render pipeline, frame handling, known limits
- [Capture size](../capture-size/README.md) · [iPhone Duo](../iphone-duo/README.md) · [Device twin](../device-twin/README.md)
