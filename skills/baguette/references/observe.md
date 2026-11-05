# Observe — see and verify what happened

Read when: checking the screen after acting, finding an element to tap,
reading the app's logs, recording a video, or rendering a marketing image.
Flags: that command's `## baguette <cmd>` section of `commands.md`.

## Screenshot — the default check

```bash
baguette screenshot --udid <X> --output /tmp/frame.jpg      # or > /tmp/frame.jpg
baguette screenshot --udid <X> --scale 2 --output /tmp/half.jpg
baguette screenshot --udid <X> --size appstore-6.9 --output shot.png
```

`--scale` is an integer divisor (2 halves each side); `--size` / `--fit` /
`--background` frame it for a store listing; `--format png|jpg` defaults to the
`--output` extension, else jpg, and an explicit `--format` wins. Then `Read` the image. `--metadata-output geom.json` writes the
frame's pixel geometry (crop, letterbox) beside it.

SimulatorKit only emits a frame when the screen changes, so an idle device
can time out (`Failure.timeout`). Nudge it first:

```bash
read W H < <(baguette describe-ui --udid <X> | jq -r '.screen | "\(.width) \(.height)"')
baguette tap --udid <X> --x 1 --y 1 --width "$W" --height "$H"; sleep 0.2
```

HTTP during `serve`: `GET /simulators/<X>/screenshot.jpg?quality=&scale=`; on
an open stream socket, `{"type":"snapshot"}` sends a keyframe now.

## Find what to tap: `describe-ui`

```bash
baguette describe-ui --udid <X>                  # whole accessibility tree
baguette describe-ui --udid <X> --x 200 --y 400  # the element at a point
```

After a tap, `tap --describe-ui` returns this same tree once the screen settles,
so you rarely need a separate read.

The root is the frontmost app's node; every node has the same fields, and
the root also carries `screen`:

```json
{"role": "AXApplication", "label": "Settings", "identifier": null, "value": null,
 "frame": {"x": 0, "y": 0, "width": 402, "height": 874},
 "screen": {"width": 402, "height": 874, "orientation": "portrait", "target": {…}},
 "children": [{"role": "AXButton", "label": "Sign In", "frame": {…}, …}]}
```

Frames are in the same device points as `tap`, so an element's centre goes
straight into one:

```bash
baguette describe-ui --udid <X> | jq -r '.. | objects | select(.label? == "Sign In")
  | .frame | "\(.x + .width/2) \(.y + .height/2)"' | head -1
```

Match on `identifier` when the app sets one; `label` is the visible text. The outer `screen`
object (size, orientation, lit panel) can be handed to
`input --expected-screen`. In landscape, frames can skew; check against a
screenshot. A field without an accessibility element may not appear.

## Watch over time

```bash
baguette record --udid <X> --output run.mp4 --duration 10   # H.264; omit --duration, stop with Ctrl-C
baguette stream --udid <X> --format mjpeg --fps 10           # frames on stdout (mjpeg | avcc)
baguette logs   --udid <X> --bundle-id com.example.app --style compact
```

`logs` streams the unified log until Ctrl-C: `--level default|info|debug`,
`--style default|compact|json|ndjson|syslog`, `--predicate`. WebSocket:
`/simulators/<X>/logs?level=&style=&predicate=&bundleId=`. A stream's output
is not a single image; use `screenshot` for one frame.

## Presentation images on a 3D device

```bash
baguette render-3d --udid <X> --variant finish=deep-blue --rotation=-8,18,0 \
  --size 1200x1200 --output /tmp/device.png
baguette render-3d --screen shot.png --device <model-id> --output device.png
```

One-shot renders; gestures still target the live screen. The live 3D streams
take `frameMetadata=1` to bind hit geometry to each frame. See
[3D rendering](https://github.com/tddworks/baguette/blob/main/docs/features/3d-rendering/frames.md).
