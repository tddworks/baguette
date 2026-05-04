# `baguette` CLI reference

All commands print JSON when there's structured data to return; one-shots
return `{"ok":true}` / `{"ok":false,"error":"…"}`. Errors go to stderr.

## Discovery — `list`

```bash
baguette list                  # human table (Booted ●  iPhone 17 Pro Max  iOS 26.4  <UDID>)
baguette list --json           # {"running":[…], "available":[…]}
```

Each device entry: `{ id, name, state, runtime, isBooted }`. Use `id`
(the UDID) for every other command. `state` is "Booted" or "Shutdown".

To pick the first running iPhone:

```bash
baguette list --json \
  | jq -r '.running[] | select(.name | startswith("iPhone")) | .id' \
  | head -1
```

## Lifecycle — `boot` / `shutdown`

```bash
baguette boot     --udid <UDID>
baguette shutdown --udid <UDID>
```

Headless boot — the CoreSimulator framework spins the device up without
opening Simulator.app. `boot` is idempotent: an already-booted device
returns `{"ok":true}`.

## Screen geometry — `chrome layout`

```bash
baguette chrome layout --udid <UDID>           # JSON
baguette chrome layout --device-name "iPhone 17 Pro Max"
```

Returns:

```json
{
  "composite": {"width": 552, "height": 1115},
  "screen":    {"width": 438, "height": 954, "x": 57, "y": 81},
  "innerCornerRadius": 55,
  "buttons": [...]
}
```

The `screen.width` / `screen.height` are the values you pass as `width` /
`height` on every gesture. `composite` is the bezel image dimensions.

## One-shot gestures

Same wire format as `baguette input`, one gesture per process. Use these
in shell scripts where you don't need streaming throughput.

```bash
baguette tap   --udid X --x 219 --y 478 --width 438 --height 954 [--duration 0.05]
baguette swipe --udid X --startX 219 --startY 760 --endX 219 --endY 190 \
                       --width 438 --height 954 [--duration 0.3]
baguette pinch --udid X --cx 219 --cy 478 --startSpread 60 --endSpread 240 \
                       --width 438 --height 954 [--duration 0.6]
baguette pan   --udid X --x1 175 --y1 478 --x2 263 --y2 478 \
                       --dx 0 --dy 200 --width 438 --height 954 [--duration 0.5]
baguette press --udid X --button home              # home | lock | power | volume-up | volume-down | action
baguette press --udid X --button action --duration 1.2   # long-press → "Hold for Ring"
baguette key   --udid X --code KeyA --modifiers shift,command [--duration 0.2]
baguette type  --udid X --text "hello world"
```

`x` / `y` etc. are device points (see `wire-protocol.md` for the
coordinate convention). `width` / `height` come from `chrome layout`.

### Hardware buttons — `press`

```bash
baguette press --udid X --button home                       # short tap
baguette press --udid X --button power --duration 2.5       # Siri / SOS hold
baguette press --udid X --button volume-up
```

| Button        | iOS effect                  | Long-hold (≥ ~0.8 s)              |
|---------------|-----------------------------|-----------------------------------|
| `home`        | Home / app switcher         | n/a                               |
| `lock`        | Sleep / wake                | n/a                               |
| `power`       | Sleep / wake                | Siri (~1.5 s) / SOS slider (~5 s) |
| `volume-up`   | Volume up                   | Accessibility shortcut            |
| `volume-down` | Volume down                 | Accessibility shortcut            |
| `action`      | iPhone 15 Pro action button | "Hold for Ring" / silent flip     |

`--duration <seconds>` is optional (default ~100 ms). `siri` is
explicitly rejected — it crashes `backboardd` through every known
Indigo path. See [`docs/features/buttons.md`](../../../docs/features/buttons.md).

### Keyboard — `key` / `type`

```bash
# Single keystroke. `--code` is a W3C KeyboardEvent.code.
baguette key --udid X --code KeyA                          # types 'a'
baguette key --udid X --code KeyA --modifiers shift        # 'A'
baguette key --udid X --code KeyA --modifiers shift,command --duration 0.2

# Multi-character text (US ASCII only).
baguette type --udid X --text "hello world"
baguette type --udid X --text "Login: alice@example.com"
```

Supported codes: `KeyA`–`KeyZ`, `Digit0`–`Digit9`, `Enter`, `Escape`,
`Backspace`, `Tab`, `Space`, `ArrowUp/Down/Left/Right`, US punctuation
(`Minus`, `Equal`, `BracketLeft`, …). Modifiers: `shift`, `control`,
`option`, `command` (comma-separated on the CLI). Phase-1 limits:
**no IME, no emoji, no accented characters** — those need
`KeyboardNSEvent` (phase 2). See
[`docs/features/keyboard.md`](../../../docs/features/keyboard.md).

## Streaming gestures — `input`

```bash
baguette input --udid <UDID>                # reads stdin, writes acks per line
```

Use for sequences. Reading stops on EOF. Pair with `tee` for logging:

```bash
{ echo '{"type":"button","button":"home"}'
  echo '{"type":"tap","x":219,"y":478,"width":438,"height":954}'
} | baguette input --udid X | tee /tmp/baguette-acks.log
```

## One-shot screenshot — `screenshot`

```bash
baguette screenshot --udid <UDID>                              # → JPEG on stdout
baguette screenshot --udid <UDID> --output /tmp/shot.jpg
baguette screenshot --udid <UDID> --quality 0.6 --scale 2 > thumb.jpg
```

| Flag       | Default | Effect                                                       |
|------------|---------|--------------------------------------------------------------|
| `--output` | stdout  | Write JPEG bytes to a file instead of stdout (CLI only).     |
| `--quality`| `0.85`  | JPEG lossy compression (0.0 – 1.0).                          |
| `--scale`  | `1`     | Integer downscale divisor: 1 = native, 2 = half, 3 = third.  |

Equivalent HTTP route during `baguette serve`:

```
GET http://localhost:8421/simulators/<UDID>/screenshot.jpg[?quality=0.6][?scale=2]
```

Same defaults, same bytes — the route and the CLI share `ScreenSnapshot.capture`.

**Failure modes:**
- **2 s timeout / `Failure.timeout`.** SimulatorKit only emits a frame
  on a screen change. A booted-but-idle simulator (lock screen with no
  visible clock tick, headless test runner waiting on input) may never
  produce a frame. Wake the screen with a gesture before capturing:
  ```bash
  baguette tap --udid X --x 1 --y 1 --width "$W" --height "$H"
  sleep 0.2
  baguette screenshot --udid X --output /tmp/shot.jpg
  ```
- **Unknown UDID.** HTTP returns `404 application/json {"ok":false,"error":"unknown udid: <udid>"}`;
  CLI exits non-zero with the same message on stderr.

**Limits:** JPEG only (no PNG / WebP / AVIF yet); raw framebuffer (no
bezel composite — that's a browser-side concern via `bezel.png`).

## Live frame stream — `stream`

```bash
baguette stream --udid <UDID> --format mjpeg --fps 60
baguette stream --udid <UDID> --format avcc  --fps 60      # H.264 NAL units
```

Writes the live encoded stream to stdout. Pipe to `ffplay` or a
recording sink. For a single still image use `baguette screenshot`
above — it has no encoder warm-up cost and respects a clean 2 s
timeout. `stream | head -c …` is *not* the snapshot path; the live
stream pipeline interferes with concurrent gestures.

## Standalone web UI — `serve` (for humans, not agents)

```bash
baguette serve [--host 127.0.0.1] [--port 8421]
# → http://localhost:8421/simulators            (device list)
# → http://localhost:8421/simulators/<UDID>     (focus mode — 1 sim, fullscreen)
# → http://localhost:8421/farm                  (multi-device dashboard)
```

Agents typically don't need this — `baguette input` is the programmatic
path. Mention it once if a human asks how to interact with the sim
themselves while you work.

## Bezel rasterisation — `chrome composite`

```bash
baguette chrome composite --udid <UDID>            > bezel.png
baguette chrome composite --device-name "iPhone 17 Pro Max" > bezel.png
```

Returns the device chrome (rounded glass + buttons) as a PNG, suitable
for compositing under a captured screenshot.

## Exit codes

`0` on success. `1` on any error; the JSON error body explains. Errors
that come from SimulatorHID (wrong UDID, device not booted, malformed
gesture) return `{"ok":false,"error":"…"}` and exit `1` — parse stdout,
not just the exit code.