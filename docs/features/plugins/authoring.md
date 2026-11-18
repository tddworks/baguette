---
description: The plugin-author contract for baguette — the baguette-plugin.json manifest, the command's environment and JSON answer, run / prompt / control panels, capabilities, and a bakery's baguette.json menu. Use when writing or publishing a plugin.
---

# Writing a plugin

Everything a plugin author needs: what baguette reads from your directory,
what your command receives and must print, and what it may call. Installing
and trusting plugins is in [the README](README.md). A complete working bakery
lives in [`examples/expo-bakery/`](../../../examples/expo-bakery/).

## Local authoring

Point baguette at a directory of plugins without installing anything:

```bash
baguette serve --plugin-dir ./my-plugins       # rail picks them up
baguette plugin run a11y:audit --udid <UDID> --plugin-dir ./my-plugins
baguette plugin validate path/to/plugin        # check a manifest before publishing
```

`--plugin-dir` is repeatable and shadows an installed plugin of the same name.

## Anatomy of a plugin

A plugin is a directory containing `baguette-plugin.json`:

```jsonc
{
  "name": "a11y",
  "version": "1.0.0",
  "apiVersion": 1,                    // baguette refuses a newer contract
  "description": "Accessibility audit for the current screen",
  "icon": "accessibility",            // optional — the plugin's rail glyph
  "capabilities": ["describe-ui"],    // enforced — see below
  "contributes": {
    "commands": [
      { "id": "audit", "title": "Run audit", "run": ["/usr/bin/python3", "bin/audit.py"] }
    ],
    "panels": [
      { "id": "audit", "title": "Accessibility", "icon": "accessibility",
        "when": "simulator.booted",
        "body": { "kind": "list", "source": "audit", "rowAction": "highlight" } }
    ]
  }
}
```

- **`run`** is an argv resolved against the plugin's own directory
  (its cwd when spawned). Prefer an absolute interpreter path or a bare
  one baguette finds via `PATH` (`["node", "bin/x.js"]`).
- **`icon`** names one baguette ships: `accessibility`, `reload`,
  `link`, `list`, `bell`, `wrench`, `lock`, `globe`, `camera`, `clock`,
  `document`, `play`, `puzzle`. Arbitrary markup never renders — a
  manifest is untrusted text destined for a protected page, so the name
  is resolved against this list and nothing else survives.

  A name baguette doesn't know **draws `puzzle` instead of failing the
  plugin**, so one written against a newer baguette still works on an
  older one. `baguette plugin validate` reports the substitution, since
  the likelier cause is a typo than a glyph from the future.
- **Top-level `icon`** is the glyph for the plugin *as a whole* — the one
  the rail shows when its tools are collapsed. Optional: omit it and the
  plugin wears the icon of the first panel it contributes.
- **`apiVersion`** is the contract the manifest was written against.
  baguette refuses a *newer* one outright rather than guessing at shapes
  it can't interpret. Omitting it means **1**, permanently — that's what
  manifests written before the field existed meant, and it stays true
  whatever this build happens to support.
- **`when`**: `simulator.booted`, or omit for "always".
- **`body.kind`** is `list` (the only widget today). `rowAction` says
  what clicking a row does:
  - `highlight` — box the row's `frame` on the live screen
  - `tap` — tap the centre of the row's `frame` on the device
  - `copy` — put the row's `copy` string on the clipboard
  - `run` — invoke the command named by the row's `run`, passing its
    `args`, and re-render the panel from the answer
  - `fill` — put the row's `fill` text into the panel's own `prompt`,
    focus it, and leave the caret at the end. The list becomes
    completion rather than a launcher: clicking `account://` gives you
    that scheme in the box ready for the path, instead of opening a bare
    scheme nobody meant. It deliberately does **not** submit

  A row missing what the action needs isn't clickable: no `frame` for
  `highlight` / `tap`, no `copy` for `copy`, no `run` for `run`, no
  `fill` for `fill`. An unknown `rowAction` is inert rather than
  resolved to the nearest match.
- **`body.prompt`** adds a text field above the rows — see
  [Panels you can type into](#panels-you-can-type-into--bodyprompt).
- **`body.control`** makes rows tickable — see
  [Panels you can tick](#panels-you-can-tick--bodycontrol).

Contributions are namespaced by plugin: `a11y:audit`. Two plugins can
both ship a `reload`.

## The command contract

When a panel opens, baguette runs its `source` command. The command
receives context in its **environment** (and the same as JSON on stdin):

| Env var | Meaning |
|---|---|
| `BAGUETTE_URL` | Origin of the running server — call it instead of re-spawning `baguette` |
| `BAGUETTE_UDID` | The focused device (absent when none) |
| `BAGUETTE_TOKEN` | Session token; send it as `X-Baguette-Token` on plugin-API calls |

The command prints **one JSON object** on stdout and exits:

```json
{
  "ok": true,
  "rows": [
    { "title": "Button has no label", "subtitle": "AXButton",
      "severity": "error",
      "frame": { "x": 24, "y": 380, "width": 44, "height": 44 } }
  ]
}
```

- `severity` is `info` | `warn` | `error` (default `info`).
- `frame` is **flat** — `x`/`y`/`width`/`height` in **device points**,
  the same space as gesture coordinates, so `rowAction: "tap"` aims at
  its centre with no conversion. Omit the frame and a `highlight` /
  `tap` row isn't clickable.
- `copy` is the string a `rowAction: "copy"` row puts on the clipboard.
- `fill` is the string a `rowAction: "fill"` row types into the panel's
  `prompt`. Kept separate from `title` because a title is display text —
  truncating, decorating or translating it would otherwise silently
  change what gets typed.
- `state` / `value` / `group` make a row a **tickable control** — see
  [Panels you can tick](#panels-you-can-tick--bodycontrol). A row with no
  `state` is an ordinary row, which is how headings survive in a panel
  full of switches.
- `run` names one of *this plugin's* command ids, and `args` is an
  object handed to it — see below. `args` without `run` is an error, not
  a silently-inert row.
- `{ "ok": false, "message": "…" }` reports the plugin's own failure;
  baguette shows the message. Printing non-JSON is an error, not an
  empty result — a panel that renders nothing reads as "all clear".

**A command has ten seconds.** A button that never returns is
indistinguishable from a hung UI, so the host bounds it rather than
trusting authors to. At the deadline the command gets `SIGTERM`, and two
seconds later `SIGKILL` — trapping the first only buys that grace period,
it doesn't buy forever. Write cleanup handlers to be quick, and don't
hold work open across the deadline expecting to finish it.

The capability token is revoked the moment the command ends, however it
ended. A child that outlived its parent's request has no credentials.

## Panels you can operate — `rowAction: "run"`

The other three row actions are things the *host* does with a row's
data. `run` hands control back to the plugin, which is what turns a
panel from a report into a control surface:

```jsonc
// manifest
{ "id": "display", "title": "Display & Text Size", "icon": "wrench",
  "body": { "kind": "list", "source": "display", "rowAction": "run" } }
```

```json
// what the command prints
{ "ok": true, "rows": [
  { "title": "● Light" },
  { "title": "○ Dark", "run": "display", "args": { "appearance": "dark" } }
] }
```

Clicking *Dark* calls `display` again with those `args`. The command
applies the change and prints the new state; the panel re-renders from
that answer — so what you see is what the device reports, not what the
click assumed. The already-selected row carries no `run`, so re-applying
a setting doesn't cost a subprocess.

`args` arrive in the **stdin context**, not the environment (env values
are strings, so a nested object would have to be flattened and parsed
back):

```json
{ "command": "a11y:display", "url": "…", "token": "…", "udid": "…",
  "args": { "appearance": "dark" } }
```

The field is **absent** when no row invoked the command, so a command
written before `run` existed sees exactly the context it always did.

A row can only name a command in its own plugin — the plugin id comes
from the panel's own `source`, never from the row — and this is still an
HTTP call to the same command endpoint the panel opens with. No plugin
code runs in the page.

## Panels you can type into — `body.prompt`

Every panel above is a *report*: the host runs a command and draws what
comes back. Some tools need the other direction — a deep link is
interesting precisely because nobody has typed it yet, and a list of
rows has nowhere to put a value that doesn't exist.

```jsonc
{ "id": "open", "title": "Deep Links", "icon": "link",
  "body": { "kind": "list", "source": "open", "rowAction": "fill",
            "prompt": { "arg": "url", "placeholder": "myapp://path",
                        "submit": "Open", "filter": true,
                        "complete": true, "history": true } } }
```

Submitting invokes the panel's **own** `source` command with what was
typed, under the key `arg` names:

```json
{ "command": "deeplink:open", "url": "…", "token": "…", "udid": "…",
  "args": { "url": "myapp://profile/42" } }
```

That is exactly the path `rowAction: "run"` already takes — same body,
same endpoint — so this adds a widget, not an execution model. Still one
command per panel, still no plugin code in the page. The command tells
the two cases apart by whether `args` arrived: absent means "just show
me what's there".

- **`arg`** is required. A field that submitted into nowhere would look
  like a working control and do nothing, so a manifest without it is
  refused at `baguette plugin validate` rather than drawn.
- **`submit`** is the button's label; it defaults to `Run`.
- **`placeholder`** is the greyed hint. Both are manifest text, so the
  host sets them with `setAttribute` / `textContent` — a plugin still
  supplies no markup.
- **`filter`** narrows the rows already on screen as you type, matching
  over `title` and `subtitle`. It does **not** re-run the command: a
  command is a subprocess with a ten-second budget, so per-keystroke
  invocations are the wrong shape, but the rows it already returned are
  right there. Omit it and the list stays a fixed reference.

  A row you have typed *past* stays visible — once the field starts with
  a row's own text, that row keeps matching. Otherwise picking
  `account://` and then typing the path would make the suggestion vanish
  at the next character and leave the list reading "Nothing matches" for
  the rest of the URL, fighting the thing it exists to help with.
- **`complete`** finishes the word: the rest of the best candidate is
  drawn greyed after the caret, and `Tab` — or `→` at the end of the
  field — accepts it. A list you have to point at is slower than a bar
  that completes. `Esc` dismisses the suggestion without clearing what
  you typed.

  Completion appends to what you typed rather than swapping the
  candidate in, so `ACC` completes to `ACCount://hello`: the bar
  finishes your word instead of rewriting it under the caret.
- **`history`** remembers what you submit and puts it on `↑` / `↓`.
  It is also the *first* completion source, ahead of the rows — having
  opened `account://hello`, typing `acc` offers that back rather than the
  bare `account://` scheme, because a link you actually used is a better
  guess than one that merely exists.

  Kept by the browser in `localStorage`, per panel, capped at 25. It is a
  convenience for the person typing, not state the plugin owns: it never
  rides the wire, and **a plugin never sees what you typed before** — only
  what you submit to it.

An empty field submits nothing rather than spending a subprocess to be
told it was empty. What you typed survives the re-render, so tweaking a
path and firing again doesn't mean retyping the URL.

`prompt` is **additive**, which is why `apiVersion` stays 1: a baguette that
predates it ignores the key and renders the plain list. For a well-written
plugin that's a working panel with one affordance missing, not a broken one —
so keep the rows useful on their own.

## Panels you can tick — `body.control`

A settings list needs rows that are *on* or *off*. The row says what's on,
and the manifest says what on looks like — don't draw `●` / `○` into titles
(why: [design.md](design.md#why-ticks-arent-glyphs)):

```jsonc
{ "id": "display", "title": "Display & Text Size", "icon": "wrench",
  "body": { "kind": "list", "source": "display",
            "control": { "kind": "radio", "arg": "settings", "submit": "Apply" } } }
```

```json
{ "ok": true, "rows": [
  { "title": "Appearance" },
  { "title": "Light", "state": "on",  "value": "appearance:light", "group": "appearance" },
  { "title": "Dark",  "state": "off", "value": "appearance:dark",  "group": "appearance" }
] }
```

- **`control.kind`** is `switch` | `checkbox` | `radio`. Purely
  cosmetic — grouping is yours, since the panel re-renders from your own
  answer after every submit. An unknown kind is a **parse error**, not a
  fallback: a checkbox silently drawn as a switch would misrepresent
  whether ticking two at once is allowed, and that's a lie about
  behaviour rather than a substituted picture.
- **`control.arg`** is required, and is the key the ticked values arrive
  under.
- **`state`** is `on` | `off`, and is what the **device** last reported —
  never what the user has clicked since.
- **`value`** is what a ticked row submits. Required alongside `state`;
  a tick carrying nothing is a control you can't act on.
- **`group`** says which options a `radio` is exclusive within. This is
  what lets one panel ask more than one question: without it, picking
  "Dark" would unpick the text size. Rows naming no group share one
  implicit group. Meaningless for `switch` / `checkbox`.
- A row with **no `state`** isn't a control — so section headings and
  plain notes keep rendering as themselves, and an ordinary
  `rowAction` row still works beside the ticks.

### Ticking is local; submitting is one call

A tick costs **no subprocess**. The panel accumulates ticks and sends
them together when the submit button is pressed:

```json
{ "command": "a11y:display", "args": { "settings": ["appearance:dark", "contentSize:large"] } }
```

**Always an array**, including for `radio`, which yields one element —
one shape means you write one branch rather than discovering a scalar
case by reading this page twice. An empty array is a real instruction
("turn all of these off"), not a no-op.

The cost of batching is that between the tick and the answer, a row shows
state the device hasn't confirmed. The host draws those rows as
**pending** rather than letting them look settled, and the button counts
them (`Apply (2)`). When your answer comes back, the panel rebuilds every
tick from it — so a setting the device refused snaps back to the truth
instead of staying stuck the way it was clicked.

Relative actions don't belong in a batch. `display.py` keeps *Smaller* /
*Larger* as `rowAction: "run"` rows, because ticking a relative change
and applying it later would apply it from wherever the value had got to
by then, not from where it was when you clicked.

Like `prompt`, `control` is additive, so `apiVersion` stays 1 — an older
baguette ignores it and renders a plain list.

## Capabilities

A plugin may only do what its manifest declared. `capabilities` is a
closed set, and it is **enforced**, not documentation:

| Capability | Grants |
|---|---|
| `describe-ui` | `GET /devices/:udid/describe-ui.json` |
| `input` | `POST /devices/:udid/input` — gestures, keys, buttons |
| `screenshot` | `GET /devices/:udid/screenshot.jpg` |
| `logs` | `WS /devices/:udid/logs` |
| `interface` | `GET /devices/:udid/interface.json`, `POST /devices/:udid/interface` — appearance, contrast, text size |
| `status-bar` | `GET`/`POST`/`DELETE /devices/:udid/status-bar` |
| `location` | `POST`/`DELETE /devices/:udid/location` |
| `apps` | `POST /devices/:udid/apps` — install an app |
| `media` | `POST /devices/:udid/media` — add photos / videos |
| `open-url` | `POST /devices/:udid/openurl`, `GET /devices/:udid/schemes.json` — open a deep link, list registered schemes |
| `simulators` | `GET /simulators.json` |

Each route answers under `/devices/:udid/…` and, for a simulator, its old
`/simulators/:udid/…`; a grant covers both.

`apps` and `media` are deliberately separate: one puts a picture in the
photo library, the other puts an executable on the device. A plugin that
seeds test images shouldn't have to be trusted to install software.

`open-url` sits apart from `apps` for the same reason in the other
direction — it only launches software that is already there. Reading and
opening are one capability rather than two, on the `interface`
precedent: a plugin that can open *any* URL isn't meaningfully
restrained by hiding the list of which ones an app registered.

The browser's drag-and-drop endpoint, `POST /simulators/:udid/files`,
takes either and works out which from the file — convenient for a person
who picked the file, useless as a boundary. It is reachable by **no**
capability, so plugins use the two routes above and say which power they
mean.

**Least privilege by default**: a manifest that declares nothing gets
nothing. An unknown capability is a parse error, so typos surface at
`baguette plugin validate` rather than as a confusing runtime `403`.

That table is the *whole* plugin surface. Routes it doesn't name —
booting a device, orientation, the camera source, the drag-and-drop
upload, installing another plugin — are reachable by no capability at
all, so no manifest can ask for them. A route added to baguette later is
closed to plugins until someone puts it in the table: the drift direction
is always toward less authority, never more.

Each command invocation is handed its **own** token carrying exactly that
plugin's declared set, revoked the moment the command exits. The check runs
in front of every route. A plugin that didn't declare `input` gets

```json
{"ok":false,"error":"this plugin did not declare the \"input\" capability"}
```

with HTTP `403` — even though its token is otherwise valid, and even
though it could read the accessibility tree a moment earlier. Presenting
a stale or invented token is refused too, rather than being treated as
"no token".

`logs` is the one WebSocket route, so its refusal is a failed upgrade
(`400`) rather than a `403` carrying that JSON — there's no body to put
it in once the handshake is turned down.

Capabilities govern the plugin API, not your process — see
[What capabilities are not](README.md#what-capabilities-are-not).

### Sending input

`POST /simulators/:udid/input` takes the same gesture envelope the
stream socket and `baguette input` accept ([wire.md](../../wire.md)) — so ⌘R to reload a React
Native bundle is:

```json
{"type":"key","code":"KeyR","modifiers":["command"]}
```

See [`examples/expo-bakery/`](../../../examples/expo-bakery/) for a complete
working bakery built on this.

## Publishing — a bakery menu

A **bakery** is any git repo that supplies plugins. You trust a bakery
once, then install any plugin it offers. A repo becomes a bakery by
adding a `baguette.json` at its root — its *menu*:

```jsonc
{
  "name": "tddworks/baguette-plugins",           // optional display name
  "description": "Official baguette plugins",
  "plugins": [
    { "name": "a11y", "path": "plugins/a11y" },   // path → dir with baguette-plugin.json
    { "name": "expo", "path": "tools/expo" }
  ]
}
```

`path` is repo-relative and must stay inside the repo. The rest of the
repo can be anything — a bakery doesn't have to be a dedicated project.
