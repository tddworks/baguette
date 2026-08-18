# 3D device rendering

Live rendering of the simulator screen on a real Apple device model. The
primary surface is an interactive 3D stream in the focused simulator view;
one-shot PNG rendering remains available for automation and export:

- `WS /simulators/:udid/stream.3d.mjpeg` and `.avcc` load the matched model
  once and continuously map SimulatorKit frames onto its screen material.
- `baguette render-3d` captures a booted simulator, or accepts an existing
  screenshot, and writes a PNG.
- `POST /simulators/:udid/render-3d.png` captures the current simulator frame
  and returns a PNG using the same model/render-plan vocabulary.

The cube toolbar button switches the main device viewport between the existing
low-latency 2D stream and the live server-rendered 3D stream. It does not open
a duplicate preview card. The 3D socket remains bidirectional: gestures and
stream controls use the same JSON envelopes as the ordinary stream.

The rendering approach is based on
[`benmcdowell/3dsg`](https://github.com/benmcdowell/3dsg), but device support is
data-driven. Scene node names, screen geometry, device matching, and USD
variant selections live in model definitions rather than Swift enums.

## Color accuracy

Rendering uses **RealityKit** (`RealityRenderer`), the same engine Quick Look
uses for `device.usdz` previews, so authored finishes tone-map the way the
model's own preview does. SceneKit rendered the identical USDZ visibly wrong:
its lack of filmic tone mapping kept bright metal at the authored hue
(dark saturated orange) where Quick Look rolls it toward gold, and no
environment intensity could fix both glass and aluminum at once — measured
against Quick Look sample zones, SceneKit bottomed out at roughly twice the
color error RealityKit starts at.

Two details keep the pipeline honest:

- **The screen is exempt from scene lighting and tone mapping.** Simulator
  frames land on an `UnlitMaterial(applyPostProcessToneMap: false)`, so a
  96-gray simulator pixel leaves the composed frame as 96-gray. Body and
  screen are effectively separate passes: PBR with tone mapping for the
  device, exact passthrough for the app.
- **The unlit screen pass needs its own antialiasing.** RealityKit's 4× MSAA
  covers lit geometry but skips the tone-map-exempt screen pass, so the
  screen content edge stair-steps on tilted poses. Each frame therefore
  renders at 2× and is Lanczos-downscaled into the codec ring (capped at
  4096 px per side), restoring blended edge coverage everywhere — verified
  by an edge-coverage test that counts intermediate pixels across the
  bezel-to-content boundary.
- **Cover-glass reflections are opt-in.** `screenGlass` clones the display
  geometry into a black dielectric layer at zero opacity, lifted a hair along
  the display normal, so only fresnel-weighted reflections composite over the
  unlit screen. The glass carries its own HDR streak environment through a
  per-entity image-based light — body lighting and screen pixels stay exactly
  as calibrated, and the default (off) output is byte-identical to before the
  feature existed. Dragging the pose sweeps the streak band across the glass.
- **Exposure is calibrated, not eyeballed.** `DeviceStudioLighting` feeds one
  equirectangular studio image to RealityKit
  (`EnvironmentResource(equirectangular:)`) with `intensityExponent = 1.5`,
  the measured minimum of the per-zone color error against Quick Look's
  rendering of the same asset. The calibration is pinned by tests.

## CLI

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

Exactly one of `--udid` and `--screen` is required. `--device` is required
with `--screen` and inferred from the simulator when `--udid` is used.
`--output` defaults to stdout, matching `baguette screenshot`.

| Flag | Default | Meaning |
|------|---------|---------|
| `--udid` | — | Capture this booted simulator |
| `--screen` | — | Use an existing PNG or JPEG |
| `--device` | inferred | Installed model definition ID |
| `--variant <set>=<choice>` | definition defaults | Repeatable model variant selection |
| `--rotation X,Y,Z` | `0,0,0` | Device rotation in degrees |
| `--size <spec>` | source dimensions | Output size: a preset, `WIDTHxHEIGHT`, or `W:H` |
| `--fit cover\|contain\|stretch` | `cover` | Screenshot placement on the screen surface |
| `--background transparent\|#RRGGBB` | `transparent` | Output canvas |
| `--screen-glass` | off | Composite a reflective cover glass over the screen |
| `--output`, `-o` | stdout | PNG destination |

Unknown devices, model IDs, variant sets, and variant choices fail explicitly.
Baguette never substitutes a visually similar model.

### `--size` speaks the shared capture vocabulary

`--size` used to be literal pixels only. It now takes anything
[`capture-size.md`](capture-size.md) defines — the preset
names (`appstore-6.9`, `square`, `16:9`, …), `WIDTHxHEIGHT` exactly as
before, or a bare ratio like `3:2`. The default is unchanged: omit it
and you get the captured screenshot's own pixel size, which is what
`native` means.

Two consequences specific to 3D:

- **Ratios resolve against the captured screen, not the rendered
  device.** `--size square` on a 1290 × 2796 capture asks for a
  2796 × 2796 canvas, then the device is framed inside it. The camera
  fits the model to whatever canvas comes out, so a square request
  gives you a squarely-framed device rather than a tall device with
  bars.
- **Nothing downscales.** As everywhere else in the vocabulary, a
  ratio grows the binding axis. Use an explicit `WIDTHxHEIGHT` when
  you want a bounded output.

Unknown values fail the same way they always did — non-zero exit,
`invalid --size`, no substitution. There are no new error codes here.

**`--fit` here is a different axis from `--fit` everywhere else.** On
`screenshot` and `record`, fit says how the frame sits inside the
output canvas. On `render-3d` it says how the *screenshot* sits on the
device's screen surface — a UV placement on the mesh, not a canvas
placement. That is why its default is `cover` rather than `contain`:
an app screenshot letterboxed inside a phone display would look like a
bug. The name is shared because the three modes mean the same thing
(fill and crop / fit and pad / distort); the surface they act on is
not.

## HTTP

```http
POST /simulators/:udid/render-3d.png
Content-Type: application/json
```

```json
{
  "rotation": {
    "x": -30,
    "y": 45,
    "z": 30
  },
  "variants": {
    "finish": "space-black"
  },
  "size": "appstore-6.9",
  "fit": "cover",
  "background": "transparent",
  "screenGlass": false
}
```

`"size"` accepts either a string spec — `"appstore-6.9"`, `"square"`,
`"1200x900"`, `"3:2"` — or the original object form:

```json
{ "size": { "width": 1200, "height": 900 } }
```

Both are supported and the object form is unchanged, so anything
already POSTing to this route keeps working. Omitting `"size"` gives
the captured screen's own dimensions. A bad spec is a `400` with the
existing `invalid 3D render options` message; the string form did not
introduce a new error branch.

The response is `image/png`. Defaults are the same as the CLI. Error branches:

| Status | Meaning |
|--------|---------|
| `400` | Malformed render options or an unknown variant selection |
| `404` | Unknown simulator UDID or no installed definition matches it |
| `422` | The matched definition cannot render the requested configuration |
| `500` | Frame capture, model loading, asset download, or RealityKit rendering failed |

The model metadata used to build the browser inspector is exposed separately:

```http
GET /simulators/:udid/3d-model.json
```

It returns the resolved model ID, display name, and public variant-set metadata.
USD prim paths, raw scene-node names, and asset URLs are not accepted from the
browser.

## Live 3D WebSocket

```http
GET /simulators/:udid/stream.3d.<mjpeg|avcc>
Upgrade: websocket
```

Initial render configuration is supplied as public query parameters:

```text
?rotation=-8,18,0
&variant=finish:deep-blue
&width=1200
&height=1200
&size=square
&fit=cover
&background=%23eef1f5
&screenGlass=true
```

`size=` is optional and takes the same vocabulary as everywhere else.
It composes with — rather than replaces — `width=` / `height=`, which
still work exactly as before: the requested `width`×`height` (default
960 × 960) is the *source box* the size resolves against, and the
result is then rounded up to even dimensions for the H.264 4:2:0
path. So `?size=appstore-6.9` yields 1290 × 2796, and
`?width=1280&height=720&size=square` yields 1280 × 1280.

That layering matters because the browser is already choosing
`width` / `height` from the CSS size of the stage (clamped 480–1600
per side, hard-capped at 4096). `size=` shapes that box; it does not
lift the bound. Asking a live stream for a 2796-px-tall App Store
canvas is legal and expensive — the one-shot PNG route is the better
tool for a submission-sized asset.

`variant` is repeatable. The server validates model, variant, rotation, output
size, fit, and background before subscribing to the simulator screen.
`RenderedScreen` produces codec-ready BGRA IOSurfaces, then the selected
existing stream emits either raw JPEG messages or AVCC description/key/delta
messages. The first frame can take longer because the model and asset are
loaded; later frames reuse the same RealityKit stage, camera, materials,
screen texture, Metal targets, and renderer.

Client-to-server text frames reuse the ordinary stream channel:

```json
{"type":"tap","x":219,"y":478,"width":438,"height":954}
{"type":"set_fps","fps":20}
{"type":"set_scale","scale":1}
{"type":"set_3d_camera","rotation":{"x":-8,"y":32,"z":0},"zoom":1.2}
```

Variant changes reconnect the 3D socket with a new validated render
configuration. Camera changes update the retained scene and immediately
re-render the latest simulator surface without reconnecting. Gestures remain
in simulator device points and are dispatched through the existing
`GestureDispatcher` and `Input`; no new HID dialect is introduced.

The server pushes one control message back on the same socket, on connect and
after every `set_3d_camera`:

```json
{"type":"screen_quad","corners":[[0.32,0.11],[0.71,0.09],[0.74,0.88],[0.29,0.91]]}
```

`corners` is `[topLeft, topRight, bottomRight, bottomLeft]`, each an
`[x, y]` pair normalized to the rendered output image (`0,0` top-left,
`1,1` bottom-right) — where the device's screen mesh currently lands for the
active camera pose. `RealityKitDeviceScene` computes it analytically
(`ScreenQuadProjection`, mirroring the same rotation and perspective-camera
math the renderer uses) rather than reading back GPU geometry. Interact mode
uses it to invert a canvas click into a screen-space point via bilinear
interpolation across the quad — see `sim-3d.js`'s `mapClientPoint`.

## Model bundles

A model is a directory containing one versioned definition and either a local
USDZ asset or a verified download descriptor:

```text
iphone-17-pro/
├── definition.json
└── device.usdz
```

Definitions are resolved in precedence order:

1. `BAGUETTE_3D_MODEL_DIR`
2. `~/Library/Application Support/com.tddworks.baguette/3d-models`
3. bundled definitions under `Resources/Models3D`

An ID found in a higher-precedence directory replaces the same ID below it.
Two definitions at the same precedence that match one simulator are an error.

The third entry is the one that surprises people: "bundled definitions" means
the SPM resource bundle, which sits beside the binary in `.build/`. `build.sh`
copies only the binary to `./Baguette`, so a release build has no bundle to
read and nothing creates the application-support directory either — a fresh
`./Baguette render-3d` 404s until `BAGUETTE_3D_MODEL_DIR` points somewhere.
`swift run` is unaffected. See Known limits.

The asset block may contain `file`, or `downloadURL` plus a required SHA-256,
or both. A local file wins. Downloaded assets are staged to a temporary name,
verified, and atomically moved into the application-support cache.

Apple USDZ binaries should not be committed to this repository until their
redistribution terms have been verified. Bundled definitions may point at the
same Apple-hosted assets used by 3dsg.

## Definition schema

```json
{
  "schemaVersion": 1,
  "id": "macbook-pro-14-inch",
  "displayName": "MacBook Pro 14-inch",
  "matches": {
    "simulatorDeviceTypes": [],
    "deviceNames": ["MacBook Pro 14-inch"]
  },
  "asset": {
    "file": "macbook-pro-14-in-space-black-variant.usdz",
    "downloadURL": "https://example.invalid/model.usdz",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "scene": {
    "rootNode": "XCnTRSzLPcVVRyt",
    "screenNode": "Screen",
    "screenMaterial": "ScreenMaterial",
    "nativeOrientation": "landscape",
    "textureSize": {
      "width": 3024,
      "height": 1964
    },
    "usesScreenOverlay": false
  },
  "variantSets": [
    {
      "id": "finish",
      "displayName": "Device finish",
      "primPath": "/XCnTRSzLPcVVRyt",
      "usdName": "Color",
      "default": "space-black",
      "choices": [
        {
          "id": "space-black",
          "displayName": "Space Black",
          "usdValue": "Space_Black",
          "previewColor": "#2f3033"
        },
        {
          "id": "silver",
          "displayName": "Silver",
          "usdValue": "Silver",
          "previewColor": "#d3d4d5"
        }
      ]
    }
  ]
}
```

`id` and choice IDs are baguette's stable public vocabulary.
`usdName`, `usdValue`, and `primPath` are private model instructions. Render
requests select only declared public IDs, so callers cannot author arbitrary
USD paths.

A definition is rejected when:

- `schemaVersion` is unsupported;
- IDs are empty or duplicated;
- dimensions are not positive;
- a variant default does not name one of its choices;
- a downloaded asset has no valid SHA-256;
- neither a local file nor a download URL is present.

## Variants

Variants use one public set/choice vocabulary with two definition strategies:
`"kind": "usd"` (the default) authors a native USD variant selection, while
`"kind": "materials"` applies a declared map of authored material names to
hex colors, replacing the material's base texture so the declared finish is
exact rather than a tint multiplied into the original texture. The latter supports models such as Matte's iPhone 17 Pro, whose
Cosmic Orange, Deep Blue, and Silver appearances are material adjustments
rather than native USD variants. One model may expose independent finish,
keyboard, stand, Pencil, or other sets.

When a request omits a set, its declared default is applied. For a USD set, the
renderer creates a temporary USDA overlay that sublayers the USDZ and pins the
selection before RealityKit loads the scene. Material selections are applied to
the loaded entity tree. Changing a variant reloads that model; the UI renders on
control commit rather than on every pointer-move event.

Bundled local models currently cover iPhone 17, iPhone Air, iPhone 17 Pro,
iPhone 17 Pro Max, iPad Pro 11/13-inch M4, Apple Watch Series 11 42/46mm, and
Apple Watch Ultra 3. The MacBook Pro 14-inch definition demonstrates a
downloaded, SHA-256-verified model with a native USD finish variant.

## Pipeline

```text
SimulatorKit Screen
      │ IOSurface frames
      ▼
RenderedScreen (Screen decorator)
  1. resolve model + verified asset once
  2. author variant overlay and load the entity once (RealityKit)
  3. fit a 32° perspective camera to the complete model once
  4. build studio lighting, screen material and renderer once
  5. blit each IOSurface into one persistent LowLevelTexture
  6. render 2× supersampled (plus engine 4× MSAA on lit geometry)
  7. Lanczos-downscale into a bounded Metal target ring
  8. publish a codec-ready BGRA IOSurface
      │
      ▼
VideoFrameDimensions + VideoFrameScaler
      │
      ├──▶ MJPEGStream ─▶ JPEG messages ─┐
      └──▶ AVCCStream  ─▶ H.264 messages ├──▶ Focus-mode 3D viewport
                                         ┘

CLI / PNG export
      │
      ▼
RealityKitDeviceRenderer
  decodes the screen image and drives the same live stage for one frame
```

`DeviceRenderPlan`, `DeviceCameraFraming`, `VideoFrameDimensions`, live-stream
option parsing, definition parsing, device matching, defaults, and variant
validation live in Domain and are unit-covered. `DeviceCameraFraming` shares
the 32° perspective lens, 15% bounds padding, aspect fit, and distance-based
zoom between the live and one-shot renderers. This matches the camera model
used by the reference ThreeDSGCore renderer and avoids the severe
foreshortening produced by the former orthographic projection.
`LiveDeviceModels` implements the `DeviceModels` aggregate collection.
`RenderedScreen` owns the conversational frame/render lifecycle while the
existing `MJPEGStream` and `AVCCStream` retain codec responsibility. The
irreducible URL download, filesystem, USD, IOSurface, and RealityKit calls
remain in Infrastructure.

This feature does not change `Input`, `IndigoHIDInput`, SimulatorKit HID
symbols, or `GestureRegistry`. It reuses the existing bidirectional stream
control WebSocket behavior.

## Browser behavior

The focus-mode cube button changes the main viewport itself. In 3D mode the
live rendered device occupies the same central stage as the normal device,
while a compact right inspector carries camera presets, variants, advanced
rotation, and PNG export. On narrow windows the inspector becomes a bottom
sheet. Hiding the inspector does not close the socket or remove the model:
pose, zoom, variant, decoder, and stream remain live, and a stage button opens
the inspector again. The cube toolbar button is the explicit way to leave 3D
and return to the 2D stream.

The live 3D canvas uses the same full viewport rectangle as the 2D simulator,
without a separate card, border, radius, or stage shadow. MJPEG and H.264
frames are opaque, so the browser sends the current light or dark page color
as the render background and reconnects the 3D stream when the theme changes.

### Exporting a PNG from the browser

The inspector's export button used to call `toDataURL()` on the canvas
the decoder paints into. That canvas is the *decoded video frame*: it
is whatever size the live stream negotiated (clamped to 1600 px a
side) and it has already been through JPEG or H.264. It was exactly
the picture on screen, which is the right thing for a preview and the
wrong thing for a marketing asset.

Export now POSTs to `/simulators/:udid/render-3d.png` with the current
pose, variant selection, and glass setting, plus the picked capture
size, and saves the PNG that comes back. Same scene, same camera,
rendered fresh at full resolution with no codec in the path — the live
stream becomes a preview of the export rather than its source. On a
booted iPhone 17 Pro Max that is 1320 × 2868 at native and a true
1290 × 2796 at `appstore-6.9`, where the old path could only ever hand
back something around 960 px and upscale.

Four details of the request are worth knowing:

- **`fit` is always sent as `cover`**, never the toolbar's fit. On this
  route `fit` places the screenshot on the device *mesh* (see above),
  so forwarding the picker's `contain` would letterbox the app inside
  the phone's display.
- **`size` is omitted for `native`**, and for a ratio preset when the
  stream size isn't known yet — the server then renders at the screen's
  own pixels. A resolved size is *not* subject to the live stream's
  480–1600 clamp; that bound belongs to the socket, not to the route.
- **Zoom is not sent.** `DeviceRenderOptions` has no zoom field, so the
  export always frames at 1×. The panel warns in the console when the
  live zoom differs, rather than silently saving a differently-framed
  image.
- **A failure still saves something.** If the route is missing or
  answers non-2xx, the panel logs `[3d] lossless render failed, saving
  the live frame instead` and falls back to `toDataURL` of the live
  canvas, named `<model-id>-live-3d.png` so the file itself says which
  path produced it. Concurrent saves are ignored while one is in
  flight.

**Both save buttons take this path.** The panel's own *Save Frame* and
the focus-mode toolbar's *Screenshot* produce the same file when 3D is
open — `downloadSnapshot` delegates to `Sim3DPanel.download` rather
than compositing the stage canvas. It used to composite, which is why
picking App Store 6.9″ in 3D once produced a postage-stamp phone
adrift on white: `contain` scaled the empty stage, not the device in
it. Framing a 3D shot is the camera's job, and only the renderer has a
camera.

**Recording is the one capture that can't take this path**, because a
video has no one-shot re-render to delegate to. It crops the stage's
margins instead — see [Recording the 3D stage](recording.md#recording-the-3d-stage).

The saved file carries the size slug like every other capture (see
[`capture-size.md`](capture-size.md)):
`iphone-17-pro-max-3d-appstore-6.9-1290x2796.png`, with the dimensions
read from what actually came back rather than what was asked for. The
bezel toggle is suppressed while 3D is open — the frame already
contains a device, so wrapping it in DeviceKit chrome would draw a
phone around a phone.

Recording the 3D stage is the same story with the same reasoning
inverted: a recording *is* the decoded stream, so it stays browser-side
and simply turns the bezel off. See [`recording.md`](recording.md).

The 3D stage follows an explicit two-mode interaction model:

- **Pose** (default): drag rotates the persistent model, Option-drag or the
  wheel dollies the perspective camera, and double-click returns to Front at
  100%. Camera changes re-render the retained simulator frame on the existing
  WebSocket; they never reload the model or restart MJPEG/AVCC.
- **Interact**: the canvas binds the same `Screen` and `PointerInterpreter` as
  the 2D simulator. Normal drag, long press, edge gestures, Option-drag pinch,
  Option-Shift-drag two-finger pan, and wheel gestures therefore share one
  browser and wire implementation. Single-finger tap, drag, and the
  home-indicator/notification-center edge bands are pose-accurate at any
  rotation: the server pushes `screen_quad` (§ Live 3D WebSocket) — where the
  screen mesh's four corners land in the rendered image — after every camera
  update, and the browser inverse-maps clicks through that quad instead of
  treating the whole canvas as a 1:1 screen crop. Two-finger pinch/pan and the
  Option-hover preview still use plain canvas-relative coordinates (they pivot
  around the screen center, not the edges) and stay most accurate near Front.

Pose/Interact and Reset live on the stage so direct manipulation remains
available with the inspector hidden. Their controls sit outside the canvas
gesture target, so clicking a control is never captured as a pose or simulator
gesture. As on the 2D screen surface, explicit mouse and touch listeners with
document-level drag continuation keep drags active after leaving the model; the
implementation does not rely on Pointer Events or element capture in
Safari/WebKit. Exact Tilt/Turn/Roll controls are collapsed under Advanced
rotation.

Decoded 3D frames follow the same paint discipline as the stable 2D
`StreamSession`: decoding replaces one pending frame, and the browser
compositor loop paints the latest frame. The panel does not draw directly from
the decoder callback because Safari/WebKit can retain the previous canvas
backing image even while new frames are decoded.

The browser requests up to 2× CSS-pixel resolution (capped at 1600 pixels per
side) so Retina displays retain authored model and screen detail. Frames are
rendered 2× supersampled and Lanczos-downscaled before either codec sees
them; H.264 and MJPEG therefore receive identical geometry and antialiased
edges.

The implementation also shares that session directly: `Sim3DPanel` supplies
the `/stream.3d.<format>` URL and 3D control callbacks to `StreamSession`; it
does not own a second WebSocket, decoder, FPS counter, or paint loop. Thus 2D
and 3D have identical AVCC/MJPEG lifecycle and browser compatibility behavior.

The stream deduplicates frames by IOSurface identity and seed together. A 3D
render rotates through three persistent IOSurface-backed Metal targets. This
triple buffer bounds allocation while keeping the GPU producer and codec
consumer off the same target during normal real-time operation. Separate
targets can have the same seed, so identity and seed must both participate in
frame deduplication. After Metal finishes rendering, the scene publishes the
write through IOSurface before the shared JPEG or VideoToolbox encoder reads it.
Live output dimensions are rounded up to even values for the H.264 4:2:0
hardware path; MJPEG uses the same aligned dimensions so switching codecs does
not resize the stage. Reconfigured scale output is aligned again after division
so downscaling cannot produce an odd codec dimension. The scaler also publishes
its Core Image GPU copy before VideoToolbox retains the pixel buffer for
asynchronous encoding.

The socket accepts the same input envelopes as the normal stream, so toolbar,
keyboard, pasteboard, and programmatic controls do not require a second
connection. Variant choices may reconnect because native USD variant
selection happens when the model is loaded; ordinary posing never does.

The farm view is intentionally out of scope: rendering a separate 3D
image for every live farm tile is too expensive and adds no control value.

## Adding a model

1. Create a model directory with `definition.json`.
2. Add a local `device.usdz`, or declare `downloadURL` and `sha256`.
3. Run `baguette models validate <directory>`.
4. Copy it into the application-support model directory or point
   `BAGUETTE_3D_MODEL_DIR` at its parent.
5. Run `baguette models list` and render a known screenshot before adding
   simulator-name matching.

## Known limits

- Live 3D supports the existing MJPEG and H.264/AVCC stream formats. AVCC
  requires browser WebCodecs support, matching the normal focused stream.
- The live stream's dimensions are still bounded by what the browser asks
  for (480–1600 per side from the UI, 4096 hard cap). `size=` shapes that
  box; it does not lift the bound. Submission-sized output comes from the
  one-shot PNG route, not from the stream.
- Browser PNG export is a server round-trip, so it costs a fresh render and
  fails the way the route fails (a 4xx/5xx surfaces as an export error)
  rather than always producing *something* the way `toDataURL` did.
- Interact mode maps clicks through the projected screen quad (a flat
  rectangle), not a full ray cast against the GPU mesh — correct for the
  planar displays every model authors so far, but two-finger pinch/pan and
  the Option-hover preview still assume a 1:1 canvas crop and drift from the
  true screen position away from Front.
- **Zoom is lost when you save.** `DeviceRenderOptions` carries no zoom
  field, so the one-shot render always frames the device at 1× even when
  the live view is dollied in. The panel logs a console warning rather than
  quietly handing you a differently-framed image. Fixing it needs a new
  wire field plus camera work on the render path; it is deliberately out of
  this release.
- **A release binary can't find the models on its own.** Definitions resolve
  from `BAGUETTE_3D_MODEL_DIR`, then
  `~/Library/Application Support/com.tddworks.baguette/3d-models`, then
  bundled definitions — but a `./Baguette` built by `build.sh` has no
  resource bundle beside it and nothing creates the application-support
  directory, so `render-3d` 404s until you set `BAGUETTE_3D_MODEL_DIR`
  yourself:

  ```bash
  BAGUETTE_3D_MODEL_DIR=Sources/Baguette/Resources/Models3D \
    ./Baguette render-3d --udid 5A1B… -o device.png
  ```

  `swift run` picks the bundle up; the copied release binary does not.
  This has cost more than one person an hour.
- **`fit` is not `CaptureFit` here.** On this route `fit` is
  `DeviceScreenFit` — the UV placement of the app screenshot on the device's
  screen *mesh*. Forwarding a capture-size picker's canvas fit into a 3D
  render letterboxes the app inside the phone's display. Canvas placement
  in 3D is the camera's job, and there is no knob for it, which is why the
  picker hides the control while 3D is open.
- Model definitions depend on opaque node/material names that Apple may change
  when replacing an asset at the same URL; SHA-256 verification prevents an
  unnoticed replacement.
- RealityKit rendering is macOS-only, main-actor bound (each frame hops to
  the main queue, like HID input), and remains an integration-tested boundary.
- Models without a declared and measurable screen surface cannot be used.
- USD variants are chosen before RealityKit loads the scene; changing them
  requires a model reload.
