---
description: Why baguette's location drives simctl location the way it does — walk as a projected route, the measured spawn timings, locationd's flat-grid course skew, the missing magnetometer, and the locale trap.
---

# Location — design

## Path

- `baguette location set|start|walk|clear`, `POST|DELETE /devices/:udid/location` (or `/simulators/…`)
  and the page's Location card → the `Location` domain role (`set` / `start` /
  `clear`) → `xcrun simctl location <udid> set|start|clear` through the shared
  `Subprocess` collaborator. A non-zero exit becomes
  `LocationError.simctlFailed(status:)`.
- Not a SimulatorHID path: it's the same mechanism as Simulator's
  **Features ▸ Location** menu — a one-shot subprocess.
- There is **no walk-specific Infrastructure**: a walk *is* a route once
  projected (`LocationWalk.route(horizon:)` → `[origin, position(after: horizon)]`),
  so it reuses the `start` path end to end.

## Projections

- `Coordinate.argument` → `"<lat>,<lon>"` (the `set` token and each
  route waypoint).
- `Coordinate.projected(bearing:metres:)` → the great-circle destination
  point; total by construction (`asin` bounds the latitude, the longitude
  wraps across the antimeridian rather than overflowing).
- `LocationWalk.route(horizon:)` → `[origin, position(after: horizon)]`
  at the walk's speed. The far waypoint **is** `position(after:)`, so the
  browser's dead-reckoned pin and the device's interpolated track trace
  the same line and can't disagree.
- `LocationRoute.startArguments` → the equals-form flags (`--speed=…`,
  `--distance=…`, `--interval=…`) in a stable order, then the waypoint
  tokens.
- The position is a single `lat,lon` token because a western/southern
  coordinate begins with `-`, and ArgumentParser would read `-122.03` as an
  unknown option. The comma-joined token sidesteps that and stays symmetric
  with the `start` waypoints.

## Body discrimination order

`POST /devices/:udid/location` checks `waypoints`, then `bearing`, then a
bare point. The order matters — a walk body carries `latitude`/`longitude` too, so
`bearing` has to be read **before** the bare-point branch, or every
joystick vector would silently parse as a stationary point and the device
would never move.

## Walk mode

**Heading is persistent state, not a property of the current vector.**
The device still points somewhere when it's standing still: the compass
holds its bearing, `A`/`D` can pivot it on the spot, and `W` then drives
along it. (Deriving the needle from the live vector meant it swung back
to north the instant you released the stick — and slewed there, since the
needle animates. If the compass ever resets on stop again, that's the
regression.)

### Replay

Walking records a trail, sampled every 4 m rather than every animation
frame (60 fps would be thousands of points — a bloated polyline and a
request body far past the server's 64 KB cap; past 500 points the trail
halves its own resolution rather than dropping its tail). Stop, and
**Replay** retraces it.

The recorded trail *is* a `{waypoints,speed}` route body — the exact
shape Route mode already posts — so replay reuses the existing
`simctl location start` path with **no new wire and no new Swift**.

Speed comes from the preset **at replay time**, not from what you
originally walked: `start` takes one speed for a whole route, so a
varying-speed walk can't be reproduced exactly anyway — and picking at
replay time means you can retrace a footpath at Highway speed, which
turns out to be the useful part. Grabbing the stick or hitting a key
cancels a replay.

## Why walk sends a vector, not positions

The obvious joystick — POST a new point every animation frame — fails
twice over, and both failures are measured, not theoretical:

- **`set` is too slow.** Each `xcrun simctl location … set` spawn costs
  **~277 ms** (measured mean over consecutive calls), capping the tick
  rate near **3.6 Hz**. Visibly jerky, and a spawn storm besides.
- **`set` can't express direction.** A pinned point is *stationary*:
  locationd reports it with `course = -1` and `speed = -1`. No amount of
  re-pinning makes an app see a direction of travel.

A two-waypoint `start` route fixes both. It's **fire-and-forget** — the
spawn returns in ~430 ms while the *daemon* interpolates smoothly for as
long as the route lasts — and because the device genuinely travels the
leg, locationd **derives** course and speed from the motion. So the
joystick sends its **vector** (origin + bearing + speed) only when the
vector *changes*; `LocationWalk` projects that into a route whose far
waypoint sits `LocationWalk.defaultHorizon` (600 s of travel) ahead along
the bearing.

Measured behaviour that makes this work:

| Action | Result |
| --- | --- |
| `start` with a 220 s route | returns in ~430 ms; daemon runs it in the background |
| second `start` mid-route | retargets in **~200 ms**, no glitch (`course 90 → 0`) |
| `set` during a route | stops it; `speed,-1 course,-1` |
| `start -` (stdin waypoints) | **buffers to EOF** — cannot stream a joystick |

The browser dead-reckons its pin locally (mirroring
`Coordinate.projected` — same formula, same earth radius) so the map
animates at 60 fps while the wire stays near-silent: sends are throttled
to ≥250 ms apart, skipped when the bearing moved <2° or the speed <0.1
m/s, latest-wins if one is in flight, and re-sent every 30 s so a held
stick never runs out of road.

**Walk drift between sends.** Each vector change re-origins the device
at the browser's reckoned position, so the device can lag by one spawn
latency (~430 ms × speed) mid-leg. It's bounded, not cumulative, and
releasing the stick snaps the device exactly onto the pin. Turning is
where it shows most: the pin traces a smooth arc while the device
walks straight legs between sends.

## The course gotcha worth preserving

**iOS 26's locationd derives `CLLocation.course` on a flat lat/lon grid.**
It computes `atan2(Δlongitude, Δlatitude)` on raw degrees, ignoring that
meridians converge toward the poles (the missing `cos(latitude)` factor).

Measured at Apple Park (lat 37.33): a geodesically-correct due-**NE**
route reports **`Course,51.52`** instead of 45°. The flat prediction is
51.54° — the observed value matches the bug, not the intent.

- Cardinal bearings (N/S/E/W) are **immune** — one delta is zero, so the
  missing factor cancels. `Course,90.00` for due east, exactly.
- The skew scales as `1/cos(latitude)`: **0° at the equator**, ~6.5° at
  lat 37, ~18° at lat 60.
- The device's **movement is on a true globe** — due-north and due-east
  routes at the same `--speed` cover identical real ground. Only the
  derived course is flat.

That last point is why this can't be fixed: correct positions
mathematically *force* a wrong course, because the platform derives
course *from* those positions with broken maths. You can have a truthful
track or a truthful course, never both.

**baguette keeps positions truthful.** `Coordinate.projected` stays a
proper great-circle projection, so you always move exactly where you
steer, and every app reading position gets the truth. The course skew is
Apple's bug, documented here rather than papered over by deliberately
walking the device off-course. Heading still *follows* the stick — it
just isn't exact on diagonals away from the equator. Don't "fix" it by
projecting the device off-course.

## Course is not heading

`CLLocation.course` (direction of travel) is drivable. **`CLHeading`
(the compass) is not, by anything.** The simulator has no magnetometer:

```
CLLocationManager.headingAvailable() == false
```

An app calling `startUpdatingHeading` receives nothing in the simulator,
and no simctl verb or private API changes that. Only `CLLocation.course`
is drivable, via a travelled `location start` route. If you need a compass
reading in a simulator, it has to be shimmed inside the app under test
(e.g. swizzling `CLLocationManager` in a debug build) — that lives in the
app, not in baguette.

## The locale gotcha worth preserving

simctl mandates `.` as the decimal separator and `,` as the field
separator. `Coordinate.argument` is built from Swift's
**locale-independent** `Double` interpolation — it never routes through a
locale-aware formatter, which on a German/French locale would emit a
decimal comma and split `"48,8584,2,2945"` into garbage. There's a unit
test pinning the dot-decimal projection so this can't regress.

## Where the map comes from

The browser panel uses **Leaflet 1.9.4**, vendored under
`Resources/Web/vendor/leaflet/` (served at `/vendor/leaflet/…`) — no
bundler, no CDN, consistent with the rest of the web UI. The map
**tiles** are fetched from OpenStreetMap (`tile.openstreetmap.org`) at
runtime; that's the one piece that needs network. Offline, the card
still renders and the readout still works, but tile imagery won't load.
The pin is a CSS `divIcon`, so no Leaflet marker PNG assets are vendored.

## Why there's no "read the device's current location"

`simctl location` is write-only — `set` / `start` / `clear`, with no
"get". (`simctl location <udid> list` enumerates named *scenarios*, not
the active position.) So baguette deliberately exposes **no**
`GET …/location` and the `Location` protocol has no `read()`: there is
no supported way to query what the device is currently simulating.
"Locate me" reports the Mac's GPS, not the device's. This is the one
asymmetry with the status-bar surface, which *can* read back via
`simctl status_bar list`.

## Not yet wired

`simctl location` also has `run <scenario>` (named Apple drive scenarios
from `simctl location <udid> list`). It would be a `run` on `Location`
projecting `["simctl","location",udid,"run",scenario]`, a `location run`
subcommand, and a `{"scenario":"…"}` body on the POST route.
