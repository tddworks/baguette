# Live unified-log stream

Stream the booted simulator's unified log to stdout, a WebSocket, or
a downstream tool — line-by-line, in real time, with the same filter
vocabulary `xcrun simctl spawn <udid> log stream` accepts. Two
entry points share one dispatch path:

- `baguette logs --udid <UDID> [--level …] [--style …] [--predicate …] [--bundle-id …]` —
  CLI; writes to stdout; SIGINT (Ctrl-C) tears down cleanly.
- `WS /simulators/:udid/logs?level=&style=&predicate=&bundleId=` — one
  socket per consumer; server emits one `{"type":"log","line":"…"}` text
  frame per emitted line.

This is the time-domain counterpart to `describe-ui` and
`screenshot.jpg`: where a screenshot tells an agent what the screen
looks like *now*, the log stream tells it what the simulator is
*doing* over time — predicates, errors, life-cycle transitions, app
trace points.

## Wire JSON — request

```
WS /simulators/<UDID>/logs?level=info&style=compact
WS /simulators/<UDID>/logs?bundleId=com.apple.MobileSafari
WS /simulators/<UDID>/logs?level=debug&predicate=subsystem%20%3D%3D%20%22com.apple.UIKit%22
```

Filter is fixed at connect time — restart the socket to change it.
URL-encode `predicate` values that include spaces or quotes.

To stop early, the client may send `{"type":"stop"}`; otherwise the
stream runs until the socket closes or the simulator dies.

## Wire JSON — server frames

```json
{ "type": "log_started" }
{ "type": "log", "line": "2026-05-06 11:56:13.835 Df locationd[5526:…] @ClxSimulated, Fix, 1, …" }
{ "type": "log_stopped", "reason": "client closed" }
```

The `line` carries one log entry verbatim — whatever `log stream
--style <style>` produced for that line. With `--style json` or
`--style ndjson` each `line` is a JSON document the consumer can
re-parse on its end.

## CLI

```bash
baguette logs --udid <UDID>                              # info-and-above, default style
baguette logs --udid <UDID> --level debug                # everything including debug-level chatter
baguette logs --udid <UDID> --style json                 # one JSON object per line
baguette logs --udid <UDID> --bundle-id com.apple.MobileSafari
baguette logs --udid <UDID> --predicate 'subsystem == "com.apple.UIKit"'
baguette logs --udid <UDID> | grep -i error              # composes with shell pipelines
```

| Flag           | Default   | Effect                                                            |
|----------------|-----------|-------------------------------------------------------------------|
| `--level`      | `info`    | `default` \| `info` \| `debug`. Each is "include events at-or-above". |
| `--style`      | `default` | `default` \| `compact` \| `json` \| `ndjson` \| `syslog`.         |
| `--predicate`  | unset     | Raw `NSPredicate` passed to `log stream --predicate` verbatim.    |
| `--bundle-id`  | unset     | Shorthand → `process == "<id>"`. Combines with `--predicate` via `AND`. |

`--level` is **slimmer than macOS host `log`**: only `default`,
`info`, `debug`. The simulator's iOS-runtime `log` binary does NOT
accept `notice` / `error` / `fault` (the host one does) — so we
reject them at the wire to fail fast. To filter on severity above
`default`, use a predicate like `messageType == "error"` instead.

## Dispatch path

```
CLI / WS  →  Simulator.logs()  →  LogStream port
                                          │
                                          ▼
                             SimDeviceLogStream
                             (Infrastructure/Logs/)
                                          │
                       fork+exec `xcrun simctl spawn │ <udid> log stream …`
                                          │
                                          ▼
                              host child process
                                          │
                                          ▼  (CoreSimulator XPC)
                              simulator's launchd
                                          │
                                          ▼
                           `/usr/bin/log stream` running as
                           the simulator's user (uid 501)
```

### Why shell out instead of calling SimDevice.spawn directly

The CoreSimulator framework exposes
`-[SimDevice spawnWithPath:options:terminationQueue:terminationHandler:pid:error:]`
and the spawn options dictionary keys (`arguments`, `environment`,
`stdin`, `stdout`, `stderr`, `standalone`, `binpref`, …) are
documented in symbol form. A direct call from our process *almost*
works on iOS 26 — the spawn succeeds, the pid comes back, the pipe
gets bytes — but the spawned `log` binary aborts with:

```
log: mbr_check_membership_ext(): Input/output error
log: Must be admin to run 'stream' command
```

`xcrun simctl spawn` issues the same SimDevice call and works fine.
The difference is bootstrap context: `simctl` is Apple-signed and
`com.apple.CoreSimulator.CoreSimulatorService` accepts it as a
privileged caller, so the spawned process inherits a context where
`log`'s `mbr_check_membership_ext("admin", …)` succeeds. Direct
calls from non-Apple-signed processes don't get that context, the
membership check fails with EIO, and `log stream` refuses to run.

Shelling out via `Process(executableURL: /usr/bin/xcrun, arguments:
["simctl", "spawn", udid] + filter.argv)` sidesteps the gap. simctl
is guaranteed installed alongside the device set we're already
targeting, so there's no extra dependency. SIGTERM via
`Process.terminate()` cleanly stops both simctl and its child.

If the entitlement dance around direct spawn ever gets resolved,
the adapter is one file (`SimDeviceLogStream.swift`) and the
behaviour is fully captured by the `LogStream` port — swap the
implementation, run the same tests, ship.

## Threading & lifecycle

- `Pipe.fileHandleForReading.readabilityHandler` runs on a private
  background queue — we line-split there and dispatch each line to
  the consumer's `onLine` callback verbatim. The CLI calls
  `FileHandle.standardOutput.write` (thread-safe); the WS path
  enqueues through an `AsyncStream<String>` with bounded
  buffering (2048 lines) so a slow client can't OOM the server.
- `Process.terminationHandler` fires on a Foundation-internal
  queue when the child exits — we collapse non-zero exits into
  `LogStreamError.nonZeroExit(code:)` and route to `onTerminate`.
- `stop()` is idempotent. The CLI's SIGINT handler installs a
  one-shot continuation guard so termination from any source
  (signal, child exit, `onTerminate`) ends the await exactly once.

## Adding a new flag

To pass a new `log stream` flag through (e.g. `--source`,
`--timeout`, `--type`):

1. **Domain.** Extend `LogFilter` with the field, default, and
   project it into `argv` after the existing flags.
2. **Tests.** Pin the new arg ordering in
   `LogFilterTests.argv projects …`.
3. **CLI.** Add an `@Option` in `LogsCommand` and forward it.
4. **WS.** Pull it from query string in `LogsRouteOptions.from`.
5. **Doc.** Add a row to the table above.

The dispatcher / spawn path doesn't need to change — argv is
opaque to it.

## Known limits

- **Live stream only.** No historical `log show` queries (no
  predicate-based replay of the on-disk store). Use
  `xcrun simctl spawn <udid> log show …` directly.
- **One filter per stream.** Changing the filter requires
  restarting the WS / re-issuing the CLI — by design (cheap and
  unambiguous).
- **No backpressure feedback to the producer.** A WS client that
  falls 2048 lines behind drops further lines silently
  (`AsyncStream.bufferingNewest`). Phase 2 would emit a
  `{"type":"log_dropped","count":N}` envelope when this happens;
  for now, slow consumers see truncated output.
- **`--level` is iOS-runtime narrow.** `default | info | debug`
  only — host-`log` `notice / error / fault` are rejected.

## Further reading

- `Sources/Baguette/Domain/Logs/{LogFilter,LogStream}.swift` — the
  value type + port.
- `Sources/Baguette/Infrastructure/Logs/SimDeviceLogStream.swift` —
  the simctl-shellout adapter with the entitlement-context note.
- `xcrun simctl spawn <udid> log help stream` — the upstream
  surface we project onto.
