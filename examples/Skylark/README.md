# Skylark

A small flight-booking app for testing how an agent drives a simulator with
baguette. It makes no network calls and takes no real payment.

```bash
./build.sh <UDID>
baguette launch --udid <UDID> --bundle-id dev.baguette.skylark --relaunch --describe-ui
```

Give an agent this task:

> Book the fastest flight to Tokyo Haneda, window seat near the front, pay with the saved card.

The right answer is `Orbit 3`, seat `3F`, paid with `Visa ending 4242`, and the
last screen says so.

## What it tests

| On screen | Why it's hard |
|---|---|
| `See all` | Plain text you can tap, so its role doesn't say it's tappable |
| `Swap` | An image that acts as a button |
| Floating tab bar | Found only by the hit-test sweep |
| `Search flights`, `Pay` | Disabled until an earlier step is done |
| Flight rows | The fastest is sixth and the dearest; the centre of a row is blank and ignores a tap |
| Seat map | 120 small targets, and the front window seats are mostly taken |
| Saved card | Not preselected |

The blank row centre is deliberate to keep: a frame's centre isn't always
tappable, and an agent has to notice when a tap changes nothing.
