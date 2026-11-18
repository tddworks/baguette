---
description: Repair taps, swipes and button presses that report ok but never reach the device once Xcode 27's Device Hub attaches. Use when input silently stops working on an Xcode 27 simulator.
---

# Xcode 27's Device Hub and the input surface

Xcode 27 replaced Simulator.app with **Device Hub**, which attaches a HID daemon
of its own to every booted simulator. The iOS 27 runtime then tears down the
legacy input services baguette drives: `baguette tap` / `swipe` / `press` still
print `{"ok":true}` and the device never sees the event
([#77](https://github.com/tddworks/baguette/issues/77)). baguette heals it —
[`baguette boot`](../../commands.md#baguette-boot) does it unasked,
[`baguette heal`](../../commands.md#baguette-heal) does it on demand.

## Quick start

```bash
baguette boot --udid <UDID>            # boots, waits, heals if Device Hub attached
baguette heal --udid <UDID>            # heal a device booted some other way, or one
                                       # Device Hub was opened on later
```

`baguette boot --no-heal` opts out.

| Surface | What it does |
|---------|--------------|
| `baguette boot` | Boots, waits for the boot to finish, heals if Device Hub attached. |
| `baguette heal` | Heals on demand. |
| `POST /devices/<UDID>/boot` | Same heal as the CLI boot, after `{"ok":true}` is decided. |
| `baguette input` startup | One advisory on stderr naming `baguette heal` when the surface is shadowed. |
| `baguette serve` stream attach | Same advisory in the server log, per WebSocket. |

## Check whether a device is shadowed

```bash
xcrun simctl spawn <UDID> notifyutil -g com.apple.coredevice.dtuhidd.active
```

`… 1` means Device Hub attached during this backboardd's life, which is exactly
the condition that needs healing. Xcode 26 runtimes never publish the key and
read as `0`; so does a device that is shut down.

## HTTP

```
POST /devices/<UDID>/boot      → {"ok":true}, then heals if Device Hub attached
```

## Gotchas

- **Healing kills running apps.** It restarts backboardd, and SpringBoard with
  it. The device is not rebooted and is back in about four seconds. That's why
  `boot` does it unasked — nothing is running yet — while `input` / `serve`
  sessions only advise.
- **Buttons and keyboard are dead whenever Device Hub has attached.** Touch
  may or may not survive, depending on a ~100 ms boot race; don't read a
  working tap as "nothing to heal".
- **It comes back after relaunching Device Hub.** The healed state holds until
  dtuhidd itself restarts, i.e. until you quit and relaunch Device Hub. The
  advisory then returns, and `baguette heal` repairs it again.
- **It can't be prevented at boot.** Heal after the fact.
- **`baguette lifetime` doesn't apply.** It writes Simulator.app's preferences;
  Device Hub ignores them, and quitting Device Hub shuts every booted device
  down. No Device Hub equivalent has been found yet.

## See also

- [design.md](design.md) — the root cause, why the repair order matters, detection timing
- [buttons](../buttons/README.md) · [touches](../touches/README.md)
