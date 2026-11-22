---
description: Read or set a simulator's light/dark appearance, Increase Contrast and Dynamic Type text size from the CLI, HTTP or the a11y plugin. Use for an accessibility pass or to check layouts at large text sizes.
---

# Interface settings — appearance, contrast, text size

The three accessibility-display settings a simulator exposes: light / dark
**appearance**, **Increase Contrast**, and **content size** (Dynamic Type).
Available from the CLI, over HTTP, and — through the bundled a11y plugin — as
a picker in the browser. Every flag:
[commands.md#baguette-interface](../../commands.md#baguette-interface).

## Quick start

```bash
baguette interface appearance --udid <UDID>            # read
baguette interface appearance --udid <UDID> dark       # set
baguette interface contrast   --udid <UDID> enabled
baguette interface text-size  --udid <UDID> accessibility-large
baguette interface text-size  --udid <UDID> increment  # one step up
```

Each leaf both reads and writes, mirroring `xcrun simctl ui` — pass a value to
set it, omit it to print the current one.

In the browser, the bundled **a11y** plugin contributes a *Display & Text
Size* panel next to its audit. Clicking a row applies the change and the panel
re-renders from the fresh state; the selected option carries no action, since
re-applying what's already set would spawn simctl to change nothing. A device
that isn't booted reads `unknown` for all three, and the panel says "boot the
device" rather than drawing a picker where nothing looks selected.

## Workflows

### An accessibility pass

The three travel together because an accessibility pass uses them together:
flip to dark, turn contrast up, push text to an accessibility size, then
re-run `describe-ui` and see what broke. The five accessibility text sizes are
where layouts actually fail.

```bash
baguette interface appearance --udid <UDID> dark
baguette interface contrast   --udid <UDID> enabled
baguette interface text-size  --udid <UDID> accessibility-extra-extra-extra-large
baguette describe-ui --udid <UDID>
```

## Values

**appearance** — `light`, `dark`

**contrast** — `enabled`, `disabled`

**text-size** — `increment`, `decrement`, or one of twelve categories,
smallest first:

```text
extra-small  small  medium  large  extra-large
extra-extra-large  extra-extra-extra-large
accessibility-medium  accessibility-large  accessibility-extra-large
accessibility-extra-extra-large  accessibility-extra-extra-extra-large
```

The last five are the "Larger Accessibility Sizes" range.

### Reading is forgiving, writing is not

A read can answer two things that aren't values:

| Answer | Means |
|---|---|
| `unknown` | Nothing answered — usually the device isn't booted |
| `unsupported` | The runtime or platform has no such setting |

**Neither is an error.** simctl prints them and exits 0, and a caller that
asked before boot deserves "can't tell" rather than a failure or a guessed
`light`. They are equally **not instructions**: there is no argv that means
"make it unknown", so trying to set one is refused before anything spawns:

```bash
$ baguette interface appearance --udid <UDID> unknown
Usage: baguette interface appearance --udid <udid> [<value>]
```

## HTTP

```http
GET  /devices/:udid/interface.json        all three   (or /simulators/:udid/…)
POST /devices/:udid/interface             set any subset
```

```bash
curl localhost:8421/devices/$UDID/interface.json
# {"appearance":"light","contentSize":"large","increaseContrast":"disabled"}

curl -X POST localhost:8421/devices/$UDID/interface \
     -H 'content-type: application/json' \
     -d '{"appearance":"dark","contentSize":"increment"}'
# {"appearance":"dark","contentSize":"extra-large","increaseContrast":"disabled"}
```

Every field is optional — change one setting without restating the others. A
`POST` answers with the **resulting** state, so a caller that just changed
something doesn't need a second round-trip and sees what actually landed
rather than what it asked for.

A body naming a value that can only be read (`unknown`, `unsupported`, or a
bad spelling) is refused whole with `400` rather than half-applied.

### When it isn't all-or-nothing

Each setting is its own `simctl ui` spawn and there is no transaction to roll
back, so a three-field body has three chances to fail partway. Two answers
admit that instead of pretending:

```json
{"ok": false, "applied": ["appearance"], "error": "simctlFailed(status: 3)"}
```

`500`, and the appearance *did* change — a caller that assumed nothing landed
would re-apply settings that are already set. Application stops at the first
failure, so anything after it was never attempted.

```json
{"ok": true, "applied": ["appearance", "contentSize"]}
```

`200`. Everything landed, but the read-back afterwards didn't answer, so there
is no resulting state to report. Retrying would only re-apply what already
worked.

Both are distinguishable from the normal answer by shape: a successful `POST`
returns the settings themselves (`appearance`, `contentSize`,
`increaseContrast`), never an `applied` list.

Plugins reach both routes under the **`interface`** capability. One
capability covers the family: a plugin that can darken the screen can already
restyle it, so splitting read from write would be a distinction without a
difference.

## Gotchas

- **Booted devices only.** Everything reads `unknown` on a shut-down
  simulator. simctl offers no way to pre-seed the setting.
- **No watch / TV coverage checked.** `unsupported` is handled, but the values
  above are verified against iOS 26 runtimes only.
- **Content size can't be read back as a step.** After `increment` the device
  reports a category; there's no "one larger than default" state to
  round-trip.
- **Three spawns per read.** simctl has no combined query, so
  `interface.json` costs three `simctl ui` spawns. Fine for a panel; don't put
  it in a frame loop.

## See also

- [plugins](../plugins/README.md) — the `run` row action the a11y panel uses
- [accessibility](../accessibility/README.md) — `describe-ui`
