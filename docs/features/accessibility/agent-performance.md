---
description: Domain design for what an agent reads and waits for on a simple flow — a short read, `fill`, and how long a typed key is held — with each law on one owner and the benchmark evidence.
---

# Agent performance — "read the screen, fill the field, see what it shows"

**Status:** BUILT, uncommitted, 2026-11-06. Every slice below is in the working tree with its tests. The numbers under [Results](#results) were measured, in a short run. iPhone Duo is unverified (see [Open questions](#8--open-questions)).

This document owns **the design of three changes until they ship**. Then each fact moves to its one home: laws to `CANONICAL_MODEL`, usage to a `fill` feature README, the measured hold to [keyboard](../keyboard/design.md).

| For | Read |
|---|---|
| The tree, the words, the laws and their owners | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |
| How a tap by name finds its element | [accessibility design](design.md) |
| `type` and its US-ASCII limit | [keyboard](../keyboard/README.md) |
| The path around that limit | [paste](../paste/README.md) |

---

## What the product already says

```text
  describe-ui              the read; its full tree stays as it is
  "the short answer"       the skill's word for what --then-describe-ui prints
  affordances.type         a focused text field, already listed by name
  --label                  a name, part of a label, or an identifier
  type · paste             enter text; "`ok` = sent, not landed"
```

So the words exist. An agent can't ask for the short answer without acting, and no verb says "this field now holds this text".

## The one sentence

**An agent reads the short answer, tells a field what it should hold, and hears what the field shows.**

```text
 App (parses, calls, prints)         Domain (decides)                    Roles
 describe-ui --short ─┐
 {"type":"describe_ui",├─> DescribeUI ◇ ──────────────────────────────> Accessibility
  "short":true} ───────┘      └ AXNode.agentSummary (exists)
 fill ────────────────┐
 {"type":"fill",…} ───┴─> Fill ◇ ─ execute ─┬ AXTarget.wait (exists) ─> Accessibility
                                            ├ AXNode.textField → TextField ◇
                                            ├ TypeText ◇ ─────────────> Input
                                            └ Paste ◇ (exists) ───────> Pasteboard, Input
```

## What is wrong today

Measured through the [simulator-use benchmark](https://simulator-use.dev/benchmarks) harness ([`bench/`](https://github.com/NoMac-app/simulator-use/tree/main/bench), MIT): sign in to a small SwiftUI form on an iPhone 17 Pro, iOS 27.0, Device Hub closed. Median of 10 sign-ins.

| | baguette | simulator-use (published) | Our rank of 9 |
|---|---|---|---|
| Tokens per sign-in | 2,877 | 194 | 5th |
| Sign-in time | 8.15 s | 3.50 s | 6th |
| Batched sign-in | 6.34 s, 2,738 tokens | 2.87 s, 179 tokens | 5th on both |
| Read the screen | 0.68 s, 1,323 tokens | 0.19 s, 72 tokens | 8th on time |
| Tap | 1.07 s, 67 tokens | 0.68 s, 17 tokens | 6th on time |
| Type into a field | 3.22 s, 75 tokens | 1.14 s, 14 tokens | 7th on time |
| Signed in | 10 of 10 | 10 of 10 | tied |

This is our own run, not a listing. We ran on a 14-core M4 Pro with 64 GB, and the published board on a 6-core virtual M5 Pro with 8 GB, so times aren't directly comparable and probably flatter us. simulator-use wrote the benchmark, and a small form is the best case for a compact read.

| Cost | The evidence |
|---|---|
| Reads are 92% of the tokens | two `describe-ui` at about 1,320 tokens each: 2,067 characters of status bar and about 1,745 of null or default fields |
| A short answer exists but only after acting | `tap --then-describe-ui` answers in 67 tokens through `AXNode.agentSummary` |
| Typing is 34% of the time | 2.76 s; `IndigoHIDInput` holds every key for 100 ms when no duration is given, and `TypeText` gives none |
| `ok` doesn't mean the text arrived | `type` answers `{"ok":true}` when sent; nothing reads the field back |
| An agent can't replace a field's text | no verb clears; every caller writes tap, then type, then checks |
| Noise an agent pays for and the benchmark doesn't count | one stderr line per typed key; about 2,270 bytes per sign-in, roughly 570 tokens |

Key hold, measured on `baguette input` with 20 runs of `gary@example.com` per row, on a fresh app:

| Hold | Exact text | Time per character |
|---|---|---|
| 100 ms (today) | 20 of 20 | 104 ms |
| 50 ms | 20 of 20 | 54 ms |
| 30 ms | 20 of 20 | 34 ms |
| 20 ms | 20 of 20 | 24 ms |

Also measured: Cmd+A then Backspace clears a normal and a secure field; an empty field's value reads as its placeholder (`Email`); after a tap, `focused` follows the field that took it (`email` false, `password` true).

Not measured: iPhone Duo, Device Hub open, a slower Mac.

---

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **short read** | the screen as the short answer: what can be done and what it says | the full tree from `describe-ui` |
| **fill** | make one named text field hold this text, and say what it shows | `type`, which sends keys to whatever has focus |
| **text field** | something on screen that holds text an agent can replace, secure or not | a text *label*, or a button named `Email` |
| **shows** | what the field reads back as now | what was sent; `ok` on `type` means only that |
| **reformatted** | shows the same letters and digits with other punctuation (`(555) 123`) | **differs**, where the letters or digits changed |
| **key hold** | how long one typed key stays down | the duration asked of a single `key` press |

`AXNode` isn't renamed and "field" stays a word for `TextField` only: `Field` in the code is the wire's field extractor.

## 2 · The tree

Additions to [CANONICAL_MODEL §1](../../CANONICAL_MODEL.md#1--the-tree), marked `+`:

```text
Simulator  ◆
 ├── input → Input  ◆
 │    └── Gesture  ◇
 │         TypeText  ◇                 + owns the key hold
 │    + Fill  ◇                        the one verb that must see the screen, type and paste;
 │                                       not a Gesture, for the same reason Paste isn't
 │    + FillOutcome  ◇                 every way a fill ends, each a case with its data
 ├── accessibility → Accessibility  ◆
 │    ├── AXNode  ◇                    + textField: TextField? · agentSummary (exists)
 │    ├── + TextField  ◇               shows what · secure or not · focused or not
 │    ├── + FieldReading  ◇            exact · reformatted · differs
 │    ├── + DescribeUI  ◇              screen · short · point; which read was asked for
 │    └── AXTarget.Found  ◇            + refusal: why a name reached nothing
 └── pasteboard → Pasteboard  ◆
      └── Paste  ◇                     unchanged
```

No new `@Mockable` role: `Accessibility`, `Input` and `Pasteboard` already exist, and the `Simulator` already hands them out. `Fill` takes them as arguments, as `Paste.execute(pasteboard:input:)` does, because a `baguette input` session has already bound its plane's `Input`. Only roles cross a fence; no adapter does.

### `TextField` — one field on screen

> **Pointable as:** the box you type your email into.

| | |
|---|---|
| **Owns** | what counts as a text field, and whether it shows what it was told to |
| **Built by** | `node.textField`, `nil` for anything else, so nothing else can be filled |
| **It answers** | `reading(of: text) → FieldReading` · `shows` · `isFocused` |
| **Never** | a command: it's a value from one read. Never compared by the caller |

A secure field is role `AXSecureTextField` *or* subrole `AXSecureTextField`; the benchmark's `SecureField` reads as role `AXTextField`. A secure field's reading compares character counts, because its value is dots. It's never `reformatted`.

What building it changed from the design: `Fill` focuses with a touch when the field is on screen, and presses only when it's off screen or the touch didn't focus it, because a press rewalks the whole tree (about 0.5 s). `FillOutcome` supplies the answer's fields and the App only serializes them, as `AXNode.agentSummary` does. A hit-test read-back was tried and dropped: 0.94 s against 0.35 s for a tree read.

### `Fill` — "this field should hold this text"

> **Pointable as:** the request, as the agent says it: *fill email with gary@example.com*.

| | |
|---|---|
| **Owns** | the order of a fill and when it may stop or retry |
| **Tell it** | `execute(accessibility:pasteboard:input:) async → FillOutcome` |
| **Parses** | `Fill.parse(dict)`, using `Field`, like every other wire value |
| **Never** | JSON, a sleep it can't be given, or a second copy of a rule `AXTarget`, `TypeText` or `TextField` already owns |

Order: find the element; refuse if it isn't a text field; focus it; clear; enter; read back; retry once with paste if needed.

- **Focus:** touch once with `Tap` when the field is on screen, else press; poll until the same name is focused; try the other way only after a touch; else stop with nothing typed.
- **Enter:** `TypeText` when it can be typed, otherwise `Paste`. `Fill` asks `TypeText`; it doesn't test for ASCII itself.
- **The same field afterwards:** `AXTarget.find(name, in:)` again. A label or identifier doesn't change as text arrives.
- **Timing:** `Fill.Timing`, all zero in tests, as `LabelTap.Timing` is.

### `FillOutcome` — how a fill ended

| Case | Carries | Means |
|---|---|---|
| `filled` | name, shows | exact or reformatted; the answer shows which text is there |
| `cleared` | name | asked for empty text; a read-back would only see the placeholder |
| `differs` | name, shows, wanted | still wrong after the retry |
| `notATextField` | name | nothing typed |
| `neverFocused` | name | nothing typed |
| `inputTaken` | name | a miss, and Device Hub is attached; says to run `baguette heal` |
| `unreachable` | `AXTarget.Refusal` | missing, ambiguous or disabled; nothing typed |
| `failed` | message | a role threw, or a key didn't send |

### `DescribeUI` — which read was asked for

> **Pointable as:** the `describe-ui` request itself.

| | |
|---|---|
| **Owns** | that a short read is of a screen, not a point, and that `x` and `y` come together |
| **Built by** | `DescribeUI.parse(x:y:short:) throws`, called by the CLI and the wire alike |
| **It answers** | `read(from: accessibility) → AXNode?` · `json(of:style:)` · `wireFields(of:)` |
| **Never** | a case the caller switches over |

## 3 · The tells

```swift
// The App parses, calls and prints. No decision is left here.
let outcome = await fill.execute(accessibility: sim.accessibility(), pasteboard: sim.pasteboard(), input: sim.input())
print(AXAffordance.json(outcome.answer))                // the App serializes; the words are the outcome's

// `Fill` asks the value; it doesn't read role strings or compare text.
guard let field = node.textField else { return .notATextField(name) }
switch field.reading(of: text) { … }

// `TypeText` keeps its one rule; `Fill` never tests for ASCII.
if let typed = TypeText(typeable: text) { typed.execute(on: input) } else { paste }

// The App doesn't branch on which read it was.
let answer = describe.json(of: try describe.read(from: sim.accessibility()), style: style)
```

The answers on the wire, from `FillOutcome.answer`:

```json
{"ok":true,"filled":"email","value":"gary@example.com"}
{"ok":false,"error":"email shows \"gary\", not \"gary@example.com\"","value":"gary"}
{"ok":false,"error":"Remember me isn't a text field, so nothing was typed"}
```

The `baguette input` session calls `FillDispatch` beside `PasteDispatch`, and `FillCommand` uses the same dispatch, so there's one pipeline. Not on the stream WebSocket or the browser.

## 4 · Invariants (each law, one owner)

Additions to [CANONICAL_MODEL §3](../../CANONICAL_MODEL.md#3--the-laws-on-the-node-that-owns-them):

| # | Law | Owner |
|---|---|---|
| 1 | only a text field can be filled; anything else types nothing | `AXNode.textField` |
| 2 | a fill types nothing until the field it named has focus | `Fill` |
| 3 | a fill always clears first, because an empty field reads as its placeholder | `Fill` |
| 4 | `ok` from a fill means the field shows the text, not that it was sent | `Fill` · `FillOutcome` |
| 5 | a fill retries once with paste, because entering the same text again leaves the same result; a tap never retries | `Fill` |
| 6 | a password stays off the shared pasteboard unless it can't be typed | `Fill` |
| 7 | a secure field is compared by its number of characters; other punctuation is reformatted, not different | `TextField` |
| 8 | a fill that didn't land says Device Hub has the input when it does, and asks only after a miss | `Fill` |
| 9 | a typed key is held 30 ms, because a burst needs it short; a single key press keeps its own hold | `TypeText` |
| 10 | a short read is of a screen, not a point; `x` and `y` come together | `DescribeUI` |
| 11 | an app the guest helper just woke gets a moment to show more than the status bar | `AXFrontmostRead` |

Existing laws stay with their owners and aren't repeated: the short answer's content (`AXNode.agentSummary`, `AXAffordance`), finding by name (`AXTarget`), what can be typed (`KeyboardKey.decompose`, `TypeText.parse`), a Duo's keys (`FoldableInput`).

Finding, for CANONICAL §6 and its own change: `LabelTap` and `ThenDescribe` hold a law and assemble JSON in the App. `Fill` doesn't copy that shape. They move later, not here.

### Technique, not domain

Quiet logs have no node in the tree, because nobody names them. `Logger.swift` gains `trace(_:)`, printed only with `BAGUETTE_VERBOSE=1`, with the decision pure and tested as `TerminalStyle.shouldColorize` is. Only `[hid]` and `[ax]` progress lines in Infrastructure move to it; failures keep `log`. `ServeCommand` sets the variable at start, so its output stays as it is. The Domain gains no logging.

## 5 · What dies

- **`AXAffordance`'s private `textRoles`:** the rule moves to `TextField`, and `affordances.type` asks `node.textField`.
- **`LabelTap`'s inline "nothing matches" and "is disabled" wording:** it moves to `Found.refusal`, so a tap and a fill can't drift.
- **Separate `x`/`y` handling in `DescribeUICommand` and `DescribeUIDispatch`.** One behaviour changes: a wire `describe_ui` with only `x` is an error, not a whole-tree read. That follows the existing law that an unknown value is never a fallback.

Not touched: `IndigoHIDInput`'s message path and any private symbol; its 100 ms default still serves a single `key`.

## 6 · Build sequence (test-first, each slice green)

0. **`CANONICAL_MODEL` first:** the tree lines, the laws, the §2 rows, the §6 row. Applied on approval.
1. **Key hold.** `TypeText.execute` passes the hold. *Pinned: `should hold each typed key for 30 ms`, `should keep a single key press at its own hold`.*
2. **Quiet logs.** *Pinned: `should stay silent about progress unless verbose`, `should always print a failure`.* Re-run the benchmark.
3. **`DescribeUI`, then `--short`.** *Pinned: `should answer a short read with what can be done and what the screen says`, `should leave how to act out of a short read`, `should refuse a short read at a point`, `should keep the whole tree when a read isn't short`, `should refuse a point with only one coordinate`.* Re-run.
4. **`TextField` and `FieldReading`.** *Pinned: `should be a text field when it holds text`, `should not be a text field when it's a switch`, `should read a secure field by its number of characters`, `should call other punctuation reformatted`, `should say a field differs when a letter changed`.*
5. **`Found.refusal`.** *Pinned: `should say why when no element matches a name`, `should say why when several elements match a name`, `should say why when an element is disabled`.*
6. **`Fill`,** against `MockAccessibility`, `MockInput` and `MockPasteboard`. *Pinned: `should fill a text field and answer with what it shows`, `should type nothing when the element isn't a text field`, `should type nothing when a field never takes focus`, `should touch a field when a press doesn't focus it`, `should clear a field before entering text`, `should paste when the text can't be typed`, `should paste once when a field shows something else`, `should report what a field shows when it still differs after a paste`, `should keep a password off the pasteboard when it can be typed`, `should only clear when the text is empty`.*
7. **Wiring.** `FillDispatch`, `FillCommand`, `input`, `RootCommand`, parsing tests, a smoke test on a booted sim. Re-run.
8. **Docs.** A `fill` README, the hold into keyboard's design, `wire.md`, `skills/baguette`, `CHANGELOG`, `make docs`; then this file shrinks to what has no other home.

### Results

Measured with the benchmark harness, 3 runs per step, median. Before: 10 sign-ins, Device Hub closed. After: 3 sign-ins, Device Hub open and healed first. Tokens don't depend on the Mac or on Device Hub. Times are on one M4 Pro, in different conditions, so they're indicative.

| | Before | After | simulator-use (published) |
|---|---|---|---|
| Tokens per sign-in | 2,877 | **219** | 194 |
| Batched tokens | 2,738 | **218** | 179 |
| Sign-in time | 8.15 s | **5.14 s** | 3.50 s |
| Batched time | 6.34 s | **4.72 s** | 2.87 s |
| Read the screen | 0.68 s, 1,323 tokens | 0.51 s, 53 tokens | 0.19 s, 72 tokens |
| Tap | 1.07 s, 67 tokens | 0.80 s, 67 tokens | 0.68 s, 17 tokens |
| Type into a field | 3.22 s, 75 tokens | 1.56 s, 14 tokens | 1.14 s, 14 tokens |
| Signed in | 10 of 10 | 3 of 3 | 10 of 10 |

On tokens that's 2nd of 9. The first read after a launch with Device Hub open went from 12 of 12 empty to 0 of 12, and now takes about 3.4 s.

Most of the time gain after typing came from one finding: a tree read took about 280 ms, and only 30–70 ms of it was reading the tree. The rest was finding the same `SimDevice` up to three times per read, at about 70 ms each. `CoreSimulators` now remembers a found device for 5 s, which speeds every read, settle poll, press and key. The rest of the gap is mostly process startup, which is what the long-lived step below would address.

### Re-running

Build `examples/swiftui-demo` from the simulator-use repo with `xcodegen`, and add `bench/tools/baguette.mjs`:

```js
import { execFileSync } from "node:child_process";
const B = process.env.BAGUETTE_BIN;
export default {
  id: "baguette", name: "baguette", kind: "cli",
  version: () => execFileSync(B, ["--version"], { encoding: "utf8" }).trim(),
  async read(ctx) { await ctx.cli(B, ["describe-ui", "--udid", ctx.udid, "--short"]); },
  async tap(ctx, what) { await ctx.cli(B, ["tap", "--udid", ctx.udid, "--label", what, "--then-describe-ui"]); },
  async type(ctx, field, text) { await ctx.cli(B, ["fill", "--udid", ctx.udid, "--label", field, "--text", text]); },
};
```

Add `async setup(ctx) { await ctx.cli(B, ["heal", "--udid", ctx.udid]); }` when Device Hub is open. The baseline read with `describe-ui`, and entered text with `tap --label … --then-describe-ui` then `type`. A batched run needs `ctx.cli` to pass stdin, so the steps reach one `baguette input` session.

Before running on a shared Mac, empty `LEFTOVERS` in `bench/run.mjs` and skip its Device Hub block. As shipped, the harness kills other tools' processes by name and quits Device Hub.

```sh
node bench/run.mjs --tool baguette --udid <UDID> --out <DIR> --reads 3 --taps 3 --types 3 --flows 3
```

## 7 · Not in this design

- A tap answer that lists only what changed. It's the next token step, and what passing 194 needs.
- A long-lived process per device, as a daemon or `baguette mcp`: the biggest time step, and its own decision because it changes how agents run baguette. Measured, with the HTTP API: [`baguette mcp`](mcp.md).
- Detecting a settled screen from the screen buffer, and reusing a read while pixels hold still.
- Folding the on-screen keyboard in `affordances`, where about 40 keys are listed while it's up.
- `wait`, listing only the alert in front, and marking unreadable content.

Not copying from simulator-use: its XCTest automation session, which its engine needs and our accessibility path doesn't, and replacing press-by-name with touch.

## 8 · Open questions

1. **Does iPhone Duo type reliably at 30 ms?** Unverified. `FoldableInput.key` honours a duration, so `TypeText`'s hold reaches `dtuhidd`. A fresh Duo on the Xcode 27.1 beta read `the display cannot provide a fresh screen target` on this build and on Homebrew's 0.2.6, so the check couldn't run. If keys drop, `FoldableInput` owns a floor, since it's the Duo's keys that differ; `TypeText` gets no branch.
2. **Does a search field count as a text field?** Unverified. `TextField` takes `AXTextField`, `AXTextArea` and `AXSecureTextField`, as `AXAffordance` did. Read a real search bar, then add the role in one place if it needs it.
3. ~~**Where does `Fill` run?**~~ **ANSWERED: on the main actor.** `Fill.execute` is `@MainActor`, because its touch uses IndigoHID. `baguette input` calls it with `await`.
4. ~~**Should the rules live in an App dispatcher beside `LabelTap`?**~~ **ANSWERED: no.** The App parses and calls, so the rules are on `Fill` and `TextField`, and the App only projects to JSON. Settled by review of the first draft.
5. ~~**Should `Fill` be a method on `Simulator`?**~~ **ANSWERED: no.** A `baguette input` session has already bound its plane's `Input`, so `Fill` takes roles, as `Paste` does.
6. **Is an attached Device Hub always a dead input?** Measured twice: Device Hub opened after a boot left keys and touches dead (`dtuhidd.active` 1, and `heal` fixed it); booting with it already open also read 1, and a fill worked without healing. So `inputTaken` is only ever asked after a miss. That answer is unit-tested; the failure wasn't reproduced on a device after it was added.

## 9 · What Skylark found

Booking on `examples/Skylark` with `fill` and `--short` completed first time, and settled two questions. A search bar is role `AXTextField`, subrole `AXSearchField`, so it can be filled. And two bugs, both fixed test-first:

- **An answer could mix two screens.** UIKit puts a pushed page at its final position as the slide starts, and removes the old page about half a second later, so the tree looks still while both are in it. 5 of 5 answers after a push held the old screen's text. Traced per kind of change: pushes had 4–9 elements across the left edge, and pops, tab switches, sheets and value changes had none; a closing sheet left the tree empty for about 0.4 s. `AXSettle` now waits out those two shapes, up to 1 s, so other changes keep their speed.
- **An unnamed field wasn't in `visible`.** `AXTarget.visibleNames` listed only labelled elements, so a fill by a placeholder failed without naming the field. Now it lists text fields too. A placeholder isn't a name, because a field with text no longer shows it.

## 10 · With and without the skills

Six fresh agents booked on `examples/Skylark`, 3 with `baguette` and `baguette-test-app` and 3 with only the CLI, on Sonnet 5.5, from a folder outside the repo, given only the task sentence. Correct bookings were read from the simulator afterwards.

| | With skills | Without |
|---|---|---|
| Booked correctly | 3 of 3 | 3 of 3 |
| Time, median | 49 s | 52 s |
| Commands, median | 9 | 11 |
| Cost, median | $0.063 | $0.062 |
| Characters of tool output, median | 6,546, plus 7,532 of skill | 18,625 |
| Learned the CLI from | the skill | `--help`, 2–3 calls |

Three runs is too few to separate small differences. What the transcripts show plainly:

- **Nobody used `--short`, `fill` or `baguette input`.** `launch` and `tap --then-describe-ui` already answer in short form, and the search bar can be skipped by choosing from the list, so this task doesn't exercise `fill`.
- **Every with-skill agent loaded only `baguette-test-app`.** So the session advice in `baguette`'s SKILL.md was never read, and this run says nothing about it.
- **The answers teach the tool.** Without a skill, agents reached `tap --label … --then-describe-ui` from `--help` and `how`, and then used it the same way.
- **A long answer can lose the next step.** Two agents cut the seat map at 1,500 characters and lost `Continue with 3F`, last in `tap`, then spent another read finding it.

## 11 · What can be done next

Every answer says what can be done next and how: each verb has one command and the names it takes, inside `affordances`. This replaces the names and the separate `how` from `0189949d`, and sections above that mention `how` or `visible` describe the earlier shape.

```json
"tap":{"command":"baguette tap --udid U --label '<name>' --then-describe-ui","names":["Sign In"]}
```

A finished command per control was built and measured first, and dropped:

| Measured on the benchmark, 3 runs | Names and `how` | A command per control | A command per verb |
|---|---|---|---|
| Short read of the sign-in form | 53 | 197 | 112 |
| Sign-in | 219 | 1,127 | 726 |
| Seat map | about 470 | about 3,400 | about 490 |
| Skylark booking, with skills, median cost | $0.063 | $0.083 | see section 13 |

Most of the sign-in's rise from 219 is that `fill` now answers with what's next; `--no-then-describe-ui` leaves it out.

`command` sorts ahead of `names`, and names sort as a person would, so an answer cut short keeps the command and `Continue with 3F`. Each slider keeps its own finished command, because each drag starts from its own value; that drag hasn't been run on a real slider.

Not done: `tap`, `swipe`, `type` and `press` without `--then-describe-ui` still answer only `ok`, and a screen with nothing but scrolling offers no `swipe`.

## 12 · A task that needs typing

Six more fresh agents, set up as in section 10, on the benchmark's form: "Sign in as josé@example.com with the password secret1, and confirm it worked." `type` rejects the `é`.

| | With skills | Without |
|---|---|---|
| Signed in | 3 of 3 | 3 of 3 |
| Time, median | 21 s | 21 s |
| Commands, median | 3 | 5 |
| Cost, median | $0.044 | $0.036 |
| Characters read, median | 3,714, plus 7,422 of skill | 7,907 |

- **All six used `fill`, first try.** None tried `type` or `paste`.
- **The offers weren't what taught it.** Agents without skills ran `fill --help` before their first answer, having seen `fill` in `baguette --help`; agents with skills had it from the skill.
- **Agents trim the offers.** All three without skills chose `--no-then-describe-ui` on their fills, and two with skills filtered the tap's answer down with `jq`, dropping `affordances`.
- **Nobody opened a `baguette input` session,** in these six or the previous six.
- **Four of six took a screenshot** to confirm the result the answer already gave.

