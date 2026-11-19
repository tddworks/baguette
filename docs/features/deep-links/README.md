---
description: Open a URL on a booted simulator and list the URL schemes its installed apps answer to. Use when testing deep-link routing, or to find which custom scheme reaches your app instead of Safari.
---

# Deep links

Open a URL on a booted simulator and watch it land in your app, plus the
inventory of what's openable there in the first place. Every flag:
[commands.md#baguette-openurl](../../commands.md#baguette-openurl) ·
[commands.md#baguette-schemes](../../commands.md#baguette-schemes).

## Quick start

```bash
baguette openurl --udid <UDID> 'myapp://profile/42'
baguette schemes --udid <UDID>
```

In the browser it's a plugin panel, not a toolbar button — it isn't part of
baguette's own surface, so you install it:

```bash
baguette bakery add tddworks/baguette
baguette plugin install deeplink
```

## The `https://` trap

This is the one thing baguette says that `simctl openurl`, `idb open` and
Maestro's `openLink` don't.

A custom scheme (`myapp://…`) is dispatched to the app that registered it. An
`https://` **universal link is not**. The simulator hands it to Safari rather
than resolving the associated domain to an installed app, so the dispatch
succeeds and your app never opens:

```console
$ baguette openurl --udid <UDID> 'https://example.com/profile/42'
[baguette] Warning: https:// lands in Safari on the simulator, not your app.
If an app claims the domain, iOS then shows an "Open in …?" dialog that needs a
tap, so this never completes unattended. For an automated check, use the app's
custom scheme — `baguette schemes` lists them.
[baguette] Opened https://example.com/profile/42 on iPhone 17 Pro
```

Every other tool performs that silently, which leaves you to guess whether
your entitlement, your `apple-app-site-association` file or the simulator is
at fault. baguette names the case, so both the CLI and the panel say it out
loud before anyone starts debugging the wrong thing.

Nothing here *blocks* the https link — it's still the right thing to open
when you're testing what a person sees. It just isn't a check that can run
unattended, because the "Open in …?" dialog needs a tap.

## Listing schemes

```console
$ baguette schemes --udid <UDID>
myapp://                 My App
com.example.myapp://     My App
exp+myapp://             My App
calshow://               Calendar

$ baguette schemes --udid <UDID> --json
[ { "app": "My App", "bundleId": "com.example.MyApp",
    "scheme": "myapp", "url": "myapp://" } ]
```

Ordering is specified, not dictionary iteration. One app routinely registers
three schemes — a readable one, a reverse-DNS alias, and a dev-client scheme
injected by tooling (`exp+…`) — and only the first is what anyone means to
type. So matches are ranked: schemes *starting* with what was typed before
ones merely containing it, then an app's own scheme before its aliases, then
alphabetically, so the list never reshuffles between keystrokes.

## The plugin panel

`deeplink` declares one capability, `open-url`, which
`baguette plugin show deeplink` prints before you install anything.

Its panel opens with every scheme on the device listed, so "what can I even
open here?" is answered before you type. The list is **completion, not a
launcher**: clicking `account://` puts it in the field with the caret after
it, ready for the path — a bare scheme with no path is almost never what
anyone means to open. Typing narrows the list, and a suggestion you've typed
past stays visible so it doesn't disappear mid-URL. Enter (or **Open**) is
what actually opens.

The field completes as you type: the rest of the best match is drawn greyed
after the caret, and `Tab` (or `→` at the end) accepts it. Links you've opened
before come first — having used `account://hello`, typing `acc` offers that
back rather than the bare scheme, and `↑` / `↓` walks the last 25. That
history lives in the browser: the plugin never sees what you typed before,
only what you submit.

## HTTP

| Route | Answers |
|---|---|
| `POST /devices/:udid/openurl?url=<encoded>` | `{"ok":true,"routing":"app"}`, or `"browser"` with a `warning` |
| `GET /devices/:udid/schemes.json[?q=…]` | `{"schemes":[{"scheme","completion","app","bundleId"}]}` |

```bash
curl -X POST 'localhost:8421/devices/<UDID>/openurl?url=myapp%3A%2F%2Fprofile%2F42'
curl 'localhost:8421/devices/<UDID>/schemes.json?q=my'
```

`?q=` narrows and ranks against what's been typed; omit it for the whole
inventory. Both routes are reachable by a plugin holding the `open-url`
capability, and by a trusted browser, under either spelling. Failures answer
`{"ok":false,"error":…}` — `400` for something that isn't a URL, `404` for an
unknown udid, `500` when simctl itself failed.

## Gotchas

- **`https://` never reaches your app on the simulator.** See above. This is
  simulator behaviour, not something baguette can route around.
- **No live server-side completion in the panel.** A plugin command is a
  subprocess with a ten-second budget, so re-running it per keystroke is the
  wrong shape. The panel fetches the inventory once when it opens and filters
  those rows in the page as you type.
- **A scheme is not a guarantee.** `listapps` reports what an app
  *registered*; whether it does anything useful with a given path is the
  app's business.
- **`open-url` is not `apps`.** That capability installs software; this one
  only launches what is already there, so a plugin that fires deep links
  doesn't have to be trusted to put an executable on the device.

## See also

- [design.md](design.md) — how the schemes are found without private API
- [plugins](../plugins/README.md) — bakeries, install, capabilities
