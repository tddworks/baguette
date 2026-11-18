---
description: Set a booted simulator's simulated GPS — pin a point, run a route between waypoints, walk it with a joystick, or clear back to live. Use when testing an app that reads CoreLocation (maps, geofences, course of travel).
---

# Location

Pin a single latitude/longitude, run a moving route between waypoints, drive
the device around with a joystick, or clear back to the device's live
location. It's the same mechanism as Simulator's **Features ▸ Location** menu,
with a map picker in the page.
Every flag: [commands.md#baguette-location](../../commands.md#baguette-location).

## Quick start

```bash
baguette location set   --udid <UDID> 37.3318,-122.0312
baguette location start --udid <UDID> --speed 260 37.629538,-122.395733 40.628083,-73.768254
baguette location walk  --udid <UDID> --bearing 90 --speed 1.4 37.3349,-122.0090
baguette location clear --udid <UDID>
```

`walk` heads off from a position and keeps going, driving `CLLocation.course`
from the travel. Stop it with `location set` (pins it) or `location clear`
(drops the override).

In the browser, the focus-mode **Location** card (map-pin toolbar button) has
a map: click to drop a pin and **Set location**; switch to **Route** and drop
two or more waypoints to **Start route**; or switch to **Walk** and drive the
device live.

### Positions are one `lat,lon` token

The position is a single `lat,lon` **token**, not two `--lat` / `--lon` flags,
so a western longitude like `-122.03` isn't read as an option. For a
coordinate whose **latitude** starts with `-`, pass `--` first:

```bash
baguette location set --udid "$U" -- -37.8136,144.9631     # Melbourne
```

## Walk mode (the joystick)

Two control schemes share one heading:

- **The thumbstick is absolute.** Drag it and the device points where you
  pushed — angle = heading, deflection = speed. It's a compass rose.
- **The keyboard is relative — tank controls.** `W`/`S` drive
  forward/reverse along the heading the device *already* has; `A`/`D` sweep
  that heading at 90°/s, including while standing still. Hold `W` and `D`
  together to drive an arc. Arrows mirror WASD; `Shift` boosts ×3.

A speed preset picks the ceiling — Walk 1.4 · Run 3.5 · Cycle 6 · Drive 13.4 ·
Highway 29 m/s. The heading persists when you stop: the compass holds its
bearing, `A`/`D` can pivot it on the spot, and `W` then drives along it. `S`
reverses like backing a car — the device still *faces* the same way, but
`CLLocation.course` reports the reverse (the readout marks it `⟲`).

**Replay.** Walking records a trail (sampled every 4 m). Stop, and **Replay**
retraces it as a route, at the speed preset selected *at replay time* — so you
can retrace a footpath at Highway speed. Grabbing the stick or hitting a key
cancels a replay.

**Search** geocodes a place name via OpenStreetMap Nominatim and recentres the
map. **Locate me** centres on the **host Mac's** real position, not the
device's.

## HTTP

`POST /devices/:udid/location` (a simulator also answers under `/simulators/:udid/location`) accepts three shapes: a `waypoints` array is
a route; a `bearing` is a walk vector; otherwise a bare `latitude`/`longitude`
pair is a single-point `set`.

```json
{ "latitude": 37.3318, "longitude": -122.0312 }
```

```json
{
  "waypoints": [
    { "latitude": 37.629538, "longitude": -122.395733 },
    { "latitude": 40.628083, "longitude": -73.768254 }
  ],
  "speed": 260,
  "distance": 1000
}
```

```json
{ "latitude": 37.3349, "longitude": -122.0090, "bearing": 90, "speed": 1.4 }
```

Route `speed` / `distance` / `interval` are optional; a walk needs both
`bearing` (compass degrees, normalised onto the circle, so `-90` and `270` are
the same heading) and `speed` (m/s). Posting a single point pins the device and
drops `course` back to `-1` — "no longer travelling".

`DELETE /devices/:udid/location` clears the override (no body).

A malformed body, an out-of-range point (lat ∉ ±90 or lon ∉ ±180), a route
with fewer than two valid waypoints, or a walk with a missing / non-positive
speed returns `400` with `{"ok":false,"error":…}` — rejected loudly, never
silently dropped.

## Course is not heading

`CLLocation.course` (direction of travel) is drivable. **`CLHeading` (the
compass) is not, by anything.** The simulator has no magnetometer —
`CLLocationManager.headingAvailable()` returns `false`, an app calling
`startUpdatingHeading` receives nothing, and no simctl verb or private API
changes that. If you need a compass reading, shim it inside the app under test
(e.g. swizzling `CLLocationManager` in a debug build).

## Gotchas

- **`course` is skewed on diagonal bearings.** iOS derives it on a flat
  lat/lon grid, so a due-NE walk reports ~51.5° instead of 45° at lat 37 (0°
  at the equator, ~18° at lat 60). Cardinal bearings are exact. Positions are
  truthful; the skew is Apple's and unfixable without lying about position —
  see [design.md](design.md#the-course-gotcha-worth-preserving).
- **No device read-back.** `simctl location` is write-only, so there's no
  `GET …/location`; the page's "locate me" is the Mac's GPS, not the device's.
- **Walk drift between sends.** The device can lag the page's pin by one spawn
  latency (~430 ms × speed) mid-leg — bounded, not cumulative, and releasing
  the stick snaps the device exactly onto the pin. Turning is where it shows
  most: the pin traces a smooth arc while the device walks straight legs.
- **Replay uses one speed for the whole route.** A walk whose speed varied
  replays at a constant one.
- **Set / start / walk / clear only.** Named drive scenarios (`simctl location
  run`) aren't wired yet.
- **Map tiles and search need network.** OSM tiles and Nominatim are fetched at
  runtime; offline, the card still renders and the readout still works, but
  tile imagery won't load. Respect Nominatim's 1 req/sec usage policy.

## See also

- [design.md](design.md) — why walk sends a vector not positions, the measured timings, the course skew, the locale trap
- [motion](../motion/README.md)
