---
description: Deliver a remote notification (an APNs payload) to an app on a booted iOS simulator from the CLI, HTTP or the serve toolbar. Use when testing notification-driven navigation end to end with tap and describe-ui.
---

# Remote notifications

`baguette notify` hands an app a remote notification as if APNs had sent it:
your payload, `aps` plus any app-defined fields (`deep_link`, …), byte for
byte. No APNs credentials or device token are involved. Every flag:
[commands.md#baguette-notify](../../commands.md#baguette-notify).

Success means **the simulator accepted the notification**. It doesn't prove a
banner appeared, that anyone tapped it, or that your app navigated anywhere.
Every success reply carries an `expectation` line saying what to look for
next.

## Quick start

```bash
cat > order.json <<'EOF'
{
  "aps": {
    "alert": {"title": "Order update", "body": "Tap to view your order"},
    "sound": "default"
  },
  "deep_link": "example://orders/123"
}
EOF

baguette notify --udid <UDID> --bundle-id com.example.app --file order.json
cat order.json | baguette notify --udid <UDID> --bundle-id com.example.app --stdin --json
```

`--bundle-id` can be left off when the payload carries a top-level
`"Simulator Target Bundle"`. If both are given, the flag wins.

In `baguette serve`, the bell button in the focus toolbar opens a card with
an app field and a payload editor (prefilled with the example above). It
remembers your last app and payload, and shows the server's `expectation`
or error after each send.

## Workflow: inject, tap, verify

1. **Background the app.** iOS shows no banner for an app in the foreground
   unless the app presents one itself (`userNotificationCenter(_:willPresent:)`).
   ```bash
   baguette press --udid <UDID> --button home
   ```
2. **Deliver.**
   ```bash
   baguette notify --udid <UDID> --bundle-id com.example.app --file order.json --json
   ```
3. **Find the banner.** It's in the accessibility tree, labelled
   `"<APP NAME>, now, <title>, <body>"`:
   ```bash
   baguette describe-ui --udid <UDID> | jq '.. | objects | select(.label? // "" | contains("Order update")) | .frame'
   # {"x": 8, "y": 58.7, "width": 386, "height": 66}
   ```
4. **Tap its centre** (device points, the same units as the frame):
   ```bash
   baguette tap --udid <UDID> --x 201 --y 92 --width 402 --height 874
   ```
5. **Verify the destination.** `baguette describe-ui --udid <UDID>` now shows
   whichever screen your app opened for `deep_link`.

Banners auto-dismiss after a few seconds. If you miss one, open Notification
Center (`baguette press --button pull-down-to-notification-center`) and tap
it there.

## What the payload asks for

`presentation` in the reply is read off `aps`:

| `aps` carries | iOS does | `presentation` |
|---|---|---|
| `alert` (string or `{title, subtitle, body}`), `badge`, `sound` | shows it, if the app is authorized | `{"alert":…, "badge":…, "sound":true, "silent":false}` |
| only `content-available: 1` | shows nothing; wakes the app in the background (`application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`), possibly later | `{"silent":true, "wakesInBackground":true}` |
| none of the above | nothing visible, and no background wake | `{"silent":true, "wakesInBackground":false}` |

## HTTP

```
POST /devices/<UDID>/notify?bundleId=com.example.app        body: the payload
     (a simulator also answers under /simulators/<UDID>/notify)
  → {"ok":true,"app":"com.example.app","presentation":{…},"expectation":"Delivered: …"}
    400 malformed payload (the reason, e.g. payload needs an "aps" object)
    404 unknown udid
    409 the app isn't allowed notifications (see Gotchas)
    500 simctl refused it for another reason (simctl's own message)
```

The route serves the browser only (same trust check as the other cards). It
isn't a plugin capability.

## Gotchas

- **Authorization comes first.** The app must have asked for, and been
  granted, notification permission (`UNUserNotificationCenter.requestAuthorization`).
  An app that never asked is refused by the simulator ("Source is not
  authorized", `UNErrorDomain` 2003): `notify` says so in one line, exits 1,
  and the route answers 409. Launch the app, accept its prompt once (`tap`
  works), then deliver again. `simctl privacy` has no notifications service
  to grant it ahead of time. An app that isn't installed gets the same
  refusal.
- **Foreground apps get no banner by default.** Background the app first
  (step 1), or have your app present foreground notifications.
- **Payloads are checked before delivery**, against simctl's own rules: a
  top-level JSON object, an `aps` object, and 4096 bytes at most. Each
  failure is named precisely (exit 1 / HTTP 400).
- **Remote notifications only.** VoIP, complication and File Provider pushes
  aren't supported by the simulator.
- **iOS only**, on a booted device.

## See also

- [deep-links](../deep-links/README.md): open the destination directly with
  `openurl` to test routing without a notification
- [accessibility](../accessibility/README.md): `describe-ui`
- [buttons](../buttons/README.md): `press`, Notification Center
