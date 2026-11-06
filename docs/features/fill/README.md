---
description: Make one named text field hold some text, in any language, and hear what it shows. Use instead of tap then type when an agent fills a form, because `ok` means the field shows the text.
---

# Fill

`baguette fill` finds a text field by name, focuses it, clears it, enters the text and reads the field back. Every flag: [commands.md#baguette-fill](../../commands.md#baguette-fill).

## Quick start

```bash
baguette fill --udid <UDID> --label email --text 'gary@example.com'
```

```json
{"affordances":{"tap":{"command":"baguette tap --udid <UDID> --label '<name>' --then-describe-ui","names":["Sign In"]}, …},
 "filled":"email","ok":true,"text":[…],"value":"gary@example.com","values":{…}}
```

Like any answer, it says what can be done next. `--no-then-describe-ui` (`"then_describe_ui":false`) leaves that out, for a script or a step you're already sure of.

`--label` takes a name from `affordances`, part of a label, or an identifier, as [`tap --label`](../../commands.md#baguette-tap) does. An empty `--text` clears the field.

On a `baguette input` session:

```json
{"type":"fill","label":"email","text":"gary@example.com"}
```

A form is one session, and one answer per line:

```bash
( echo '{"type":"fill","label":"email","text":"gary@example.com"}'
  echo '{"type":"fill","label":"password","text":"secret1"}'
  echo '{"type":"tap","label":"Sign In","then_describe_ui":true}'
) | baguette input --udid <UDID>
```

## What the answer means

| Answer | Meaning |
|---|---|
| `"ok":true` | the field shows the text; `value` is what's there, with other punctuation if the field reformatted it |
| `"ok":false` and `value` | something was entered, and the field shows something else |
| `"ok":false` without `value` | nothing was typed; `error` says why |

A secure field's `value` is its dots, and an error gives only the expected length, never the password.

## Gotchas

- **Opening Device Hub takes the input.** Keys then land nowhere, and where `type` says `"ok":true`, `fill` answers `"ok":false` and says Device Hub has the input. Run [`baguette heal`](../device-hub/README.md), which restarts SpringBoard and ends running apps.
- **Text can land on the pasteboard.** Text the US keyboard can't type goes through [paste](../paste/README.md), and a mismatch gets one paste retry. That replaces the simulator's pasteboard. A password is pasted only when it can't be typed.
- **It focuses with a real touch** when the field is on screen, and presses through accessibility otherwise or if the touch didn't focus it.
- **It retries once, and `tap` never does.** A second `Pay` could pay twice; entering the same text again leaves the same result.
- **A field that reformats gets the retry too,** so a phone-number field costs one extra paste before it counts as filled.
- **Not on the stream WebSocket or the browser,** only the CLI and `baguette input`.

## See also

[keyboard](../keyboard/README.md) · [paste](../paste/README.md) · [accessibility](../accessibility/README.md) · [design](../accessibility/agent-performance.md)
