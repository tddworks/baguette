---
description: Why 3D rendering uses RealityKit and how it stays color-accurate — unlit screen pass, supersampling, calibrated exposure, cover glass — plus the render pipeline, screen-quad projection and live-frame handling. Read before touching 3D rendering.
---

# 3D device rendering — design

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

## Pipeline

```text
SimulatorKit Screen
      │ IOSurface frames
      ▼
RenderedScreen (Screen decorator)
  1. resolve model + verified asset once
  2. author variant overlay; load the model once per process, clone it
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

`DeviceCameraFraming` shares the 32° perspective lens, 15% bounds padding,
aspect fit, and distance-based zoom between the live and one-shot renderers.
This matches the camera model used by the reference ThreeDSGCore renderer and
avoids the severe foreshortening produced by the former orthographic
projection. `RenderedScreen` owns the conversational frame/render lifecycle
while the existing `MJPEGStream` and `AVCCStream` retain codec
responsibility. The irreducible URL download, filesystem, USD, IOSurface, and
RealityKit calls remain in Infrastructure.

This feature does not change the input roles, `IndigoHIDInput`, SimulatorKit HID
symbols, or `GestureRegistry`. It reuses the existing bidirectional stream
control WebSocket behavior.


Live frames: `RenderedScreen` produces codec-ready BGRA IOSurfaces, then the
selected existing stream emits either raw JPEG messages or AVCC
description/key/delta messages. Later frames reuse the same RealityKit stage,
camera, materials, screen texture, Metal targets, and renderer. Camera
changes update the retained scene and immediately re-render the latest
simulator surface without reconnecting; variant choices reconnect because
native USD variant selection happens when the model is loaded.

A stream's stage lives exactly as long as its socket; nothing it hands a
callback may hold the frame source that owns the stage (a foldable's pose
listener is given the pose rather than reading it off the book). The model
itself outlives the socket: RealityKit keeps the assets of every
`Entity.load` until the process exits, even for a file it has loaded before,
so `DeviceModelPrototypes` loads each asset + USD variants + scene definition
once and every stage clones it. Clones share meshes, so the one mesh edit —
turning a screen's texture coordinates — is made on the prototype.

## Screen quad

`screen_quad` is computed analytically by `RealityKitDeviceScene`
(`ScreenQuadProjection`, mirroring the same rotation and perspective-camera
math the renderer uses) rather than reading back GPU geometry. Interact mode
uses it to invert a canvas click into a screen-space point via bilinear
interpolation across the quad — see `page/internal/device-3d.js`'s `mapClientPoint`. It is a
flat rectangle, not a full ray cast against the GPU mesh — correct for the
planar displays every model authors so far, but two-finger pinch/pan and
the Option-hover preview still assume a 1:1 canvas crop and drift from the
true screen position away from Front.

## Foldable pose

A foldable's 3D socket binds both panels and the hinge, poses the clip at
`(180 − angle) / 180 · shutTime` and turns the whole device back by half the
fold above the open pose (`FoldPose`); `set_3d_camera`'s `orientation` rolls
the model to stand that way (`InterfaceRoll`). The angle is the hinge's
reading. During a sweep `serve` plays, it is that sweep's 60 Hz curve until
the readings catch up (`PosedHinge`, see
[Hinge design](../hinge/design.md#how-the-hinge-is-driven)). Each pose
recomposes the frame, and frame metadata carries the posed angle.

## Browser: frames, export and density

The live 3D canvas uses the same full viewport rectangle as the 2D simulator,
without a separate card, border, radius, or stage shadow. MJPEG and H.264
frames are opaque, so the browser sends the current light or dark page color
as the render background and reconnects the 3D stream when the theme changes.


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


Export used to call `toDataURL()` on the canvas the decoder paints into.
That canvas is the *decoded video frame*: whatever size the live stream
negotiated (clamped to 1600 px a side), already through JPEG or H.264 —
right for a preview, wrong for a marketing asset, and the old path could
only ever hand back something around 960 px and upscale. `downloadSnapshot`
used to composite the stage canvas, which is why picking App Store 6.9″ in
3D once produced a postage-stamp phone adrift on white: `contain` scaled
the empty stage, not the device in it. Framing a 3D shot is the camera's
job, and only the renderer has a camera; so it now delegates to
`Sim3DPanel.download`. The export request's `size` is *not* subject to the
live stream's 480–1600 bound; that bound belongs to the socket, not to the
route. `DeviceRenderOptions` has no zoom field, so fixing lost zoom needs a
new wire field plus camera work on the render path.

Stream density: the box is **scaled**, never clamped per side. The per-side
clamp this replaced turned a 3800 × 1240 stage into 1600 × 1240 — aspect
3.07 rendered as 1.29 — so the camera framed a different scene than the
stage was showing, and `object-fit: contain` letterboxed the difference back
out. `setCaptureSettings` restarts the socket only when a pick crosses the
native/sized line; switching between two sized presets, or changing fit,
background or the bezel, leaves it alone.

Pose/Interact and Reset controls sit outside the canvas gesture target, so
clicking a control is never captured as a pose or simulator gesture. As on
the 2D screen surface, explicit mouse and touch listeners with
document-level drag continuation keep drags active after leaving the model;
the implementation does not rely on Pointer Events or element capture in
Safari/WebKit.

## Known limits

- RealityKit rendering is macOS-only, main-actor bound (each frame hops to
  the main queue, like HID input), and remains an integration-tested boundary.
- `fit` on this route is `DeviceScreenFit` (UV placement on the mesh), not
  `CaptureFit`; there's no knob for canvas placement in 3D, which is why the
  capture-size picker hides its fit control while 3D is open.
