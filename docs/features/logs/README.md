---
description: Stream a booted simulator's unified log line by line to stdout or a WebSocket, filtered by level, predicate or bundle id. Use when an agent needs to see what the simulator is doing over time, not just what the screen shows.
---

# Live unified-log stream

Stream the booted simulator's unified log in real time, with the same filter
vocabulary `xcrun simctl spawn <udid> log stream` accepts. It's the time-domain
counterpart to `describe-ui` and `screenshot.jpg`: a screenshot says what the
screen looks like *now*; the log says what the simulator is *doing* —
predicates, errors, life-cycle transitions, app trace points.
Every flag: [commands.md#baguette-logs](../../commands.md#baguette-logs).

## Quick start

```bash
baguette logs --udid <UDID>                              # info-and-above, default style
baguette logs --udid <UDID> --level debug                # everything including debug-level chatter
baguette logs --udid <UDID> --style json                 # one JSON object per line
baguette logs --udid <UDID> --bundle-id com.apple.MobileSafari
baguette logs --udid <UDID> --predicate 'subsystem == "com.apple.UIKit"'
baguette logs --udid <UDID> | grep -i error              # composes with shell pipelines
```

Ctrl-C (SIGINT) tears down cleanly. `--bundle-id` is shorthand for
`process == "<id>"` and ANDs with `--predicate` when both are given.

## WebSocket

One socket per consumer. The filter is fixed at connect time — restart the
socket to change it. URL-encode `predicate` values that include spaces or quotes.

```
WS /devices/<UDID>/logs?level=info&style=compact
WS /devices/<UDID>/logs?bundleId=com.apple.MobileSafari
WS /devices/<UDID>/logs?level=debug&predicate=subsystem%20%3D%3D%20%22com.apple.UIKit%22
   (a simulator also answers under /simulators/<UDID>/logs)
```

Server frames:

```json
{ "type": "log_started" }
{ "type": "log", "line": "2026-05-06 11:56:13.835 Df locationd[5526:…] @ClxSimulated, Fix, 1, …" }
{ "type": "log_stopped", "reason": "client closed" }
```

The `line` carries one log entry verbatim — whatever `log stream --style
<style>` produced for that line. With `style=json` or `style=ndjson` each
`line` is a JSON document the consumer can re-parse on its end.

To stop early, send `{"type":"stop"}`; otherwise the stream runs until the
socket closes or the simulator dies.

## Gotchas

- **`--level` is iOS-runtime narrow: `default`, `info`, `debug` only.** Each
  is "include events at-or-above". The simulator's iOS-runtime `log` binary
  does NOT accept `notice` / `error` / `fault` (the host one does), so baguette
  rejects them up front. To filter on severity above `default`, use a
  predicate like `messageType == "error"`.
- **Styles:** `default`, `compact`, `json`, `ndjson`, `syslog`.
- **Live stream only.** No historical `log show` queries (no predicate-based
  replay of the on-disk store). Use `xcrun simctl spawn <udid> log show …`
  directly.
- **One filter per stream.** Changing the filter means restarting the
  WebSocket / re-issuing the CLI — by design (cheap and unambiguous).
- **Slow WebSocket clients lose lines silently.** A client that falls 2048
  lines behind drops further lines (newest are kept); there's no
  `log_dropped` notice yet.

## See also

- [design.md](design.md) — why it shells out to `simctl spawn` instead of calling `SimDevice.spawn`
- `xcrun simctl spawn <udid> log help stream` — the upstream surface baguette projects onto
