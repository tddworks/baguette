# Atomic 3D frames

Use `/simulators/:udid/stream.3d.mjpeg?frameMetadata=1` or
`stream.3d.avcc?frameMetadata=1` when the viewer maps interactions onto a
moving device model. Streams without the option keep their existing wire format.

Atomic MJPEG and H.264 share a 20 FPS render limit. Simulator callbacks, both
foldable panels, hinge changes and camera refresh requests enter the same
scheduler before any scene rendering or encoding. Bursts retain the latest
pending state; the last update still renders when the source becomes idle.

## MJPEG

Each binary WebSocket message contains exactly one complete frame:

```text
[u32 big-endian JSON byte length][UTF-8 JSON][JPEG bytes]
```

The JSON is at most 64 KiB and the JPEG at most 16 MiB:

```json
{"version":1,"frameId":42,"placement":{"type":"screen_quad","corners":[[0.32,0.11],[0.71,0.09],[0.74,0.88],[0.29,0.91]],"sourcePixelSize":{"width":1206,"height":2622},"textureTransform":{"scaleX":1,"scaleY":1,"offsetX":0,"offsetY":0}}}
```

`frameId` is a positive JavaScript-safe integer, strictly increasing within
one connection. Gaps are permitted: slow MJPEG readers lose whole old frames.
`placement: null` means the renderer has no screen geometry/source surface
for this frame; display it without permitting screen interaction.

## H.264

AVCC uses the same JSON length prefix, followed by one AVCC tag and its
payload (without the legacy AVCC length prefix). JSON remains capped at
64 KiB; tag and payload together are at most 16 MiB.

```text
[u32 big-endian JSON byte length][UTF-8 JSON][1-byte AVCC tag][payload]
```

Codec descriptions have no visual frame identity:

```json
{"version":2,"type":"description"}
```

Their tag is `1` and payload is the avcC parameter set. Visual frames use
tag `2` (keyframe), `3` (delta) or `4` (initial JPEG seed):

```json
{"version":2,"type":"frame","frameId":42,"placement":null}
```

Visual IDs strictly increase across the connection, including after codec
reconfiguration. The seed and first H.264 frame have separate IDs but the
same captured placement. Description packets do not reset IDs. Decode every
H.264 reference frame, associate its placement with the decoder timestamp,
and update hit geometry only when that decoded image is actually painted.

Only unsubmitted renders can be replaced. Encoded reference frames are never
dropped: a client exceeding the 32 MiB pending-message budget receives an
error and the connection closes. Encoding uses the live 3D stream's 20 fps
low-latency preset without B-frames. VideoToolbox setup, submission and output
failures terminate the stream instead of leaving stale interactive geometry.
Apple's low-latency rate control forbids lookahead and frame reordering; this
path does not request the optional `MaxFrameDelayCount` property, which the
hardware encoder may reject. See [compression properties](https://developer.apple.com/documentation/videotoolbox/compression-properties).

## Placement and lifecycle

Placement uses the existing `screen_quad` corner order. Foldables carry
`pieces`, `buttons`, `litPanel` and `pose` instead of a single `corners` array.
`sourcePixelSize` is the actual lit simulator panel's raw framebuffer size,
not the rendered output dimensions. `textureTransform` describes cover,
contain or stretch fitting. After inverse-projecting a quad (and applying
a piece's `u`/`v` range), map mesh UV to source UV:

```text
sourceU = meshU * scaleX + offsetX
sourceV = meshV * scaleY + offsetY
```

Reject source UV outside `[0,1]` (letterboxing), back-facing/degenerate
quads, and ambiguous overlapping pieces. Consumers must also match the
frame's source dimensions and panel to the currently controlled device.
The mapping targets raw framebuffer coordinates; do not rotate it again
using the guest's interface orientation.

Pixels and placement are captured during one serialized render operation.
JPEG encoding completes before the render surface can be reused. H.264 copies
that surface before returning, retains one encoding and one latest unsubmitted
snapshot, and captures placement in the corresponding encoding callback.
Transport never separates geometry from pixels.
No separate `screen_quad` text messages are emitted in this mode. Render or
encoding errors produce an error response and terminate the stream.
