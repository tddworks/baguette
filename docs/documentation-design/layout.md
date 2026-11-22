---
description: File-by-file detail of baguette's documentation layout, written from the reader's side. For each file: who opens it, the question they bring, a mockup, and what stays out.
---

# Layout in Detail

Companion to [the design](README.md). Each file below is described from the **reader's side**: who opens it, what question they have, and what they should see. Anything that doesn't answer that question belongs in a different file.

## Which file answers my question?

| I am… | …and I want to know | I open |
|---|---|---|
| Evaluating the tool | What is this? Can I see it drive a sim in a minute? | `README.md` |
| Upgrading | What changed? Will my scripts or plugin break? | `CHANGELOG.md` |
| Looking for a feature | Can baguette do X? Where is it documented? | `docs/README.md` |
| Using a feature | How do I do the job? What will bite me? | `docs/features/<x>/README.md` |
| Writing a script | What is the exact flag name? | `docs/commands.md` or `baguette <cmd> --help` |
| Writing a host plugin | What JSON goes over stdin / the WebSocket? | `docs/wire.md` |
| Calling `baguette serve` | Which routes exist? | `docs/serve.md` |
| Contributing | How do I build, test, and where does code go? | `CONTRIBUTING.md` → `docs/ARCHITECTURE.md` |
| Touching a feature's private-API path | Why is it built this way? What was tried? | `docs/features/<x>/design.md` |
| An agent working in this repo | What must I never do? | `AGENTS.md` |

---

## `CHANGELOG.md`

**Who:** someone upgrading via Homebrew, a host-plugin author whose integration broke, or someone checking whether their bug is fixed.

**Their questions, in order:**
1. **Will this break me?** Removed or incompatibly changed commands, routes and wire messages first, with what to do instead.
2. **Is my bug fixed?** They skim for the command or page control they use.
3. **What's new that I could use?**
4. **Where do I learn more?** One link.

They don't care which domain role, private symbol or HID usage page changed; that's for reviewers and lives in the PR and the feature's `design.md`.

### Rules

| Rule | Why (reader's view) |
|---|---|
| Keep a Changelog headings; **`Removed` and `Changed` come before `Added`**; one heading of each kind per release | Question 1 is answered before anything else |
| Anything that breaks existing use starts with **`Breaking:`** and says what to do instead | Plugin authors can grep for "Breaking" across versions |
| Each bullet starts with **what the user types or clicks** (`` `baguette hinge` ``, `` `POST /devices/<udid>/hinge` ``, the page's pose bar) | They're scanning for *their* entry point |
| Say the **effect**, not the implementation: "Duo's volume keys work", not "`FoldableInput` routes through `DeviceKeys`" | They can check the effect; they can't check the implementation |
| One bullet per user-visible change, **≤300 chars**; merge related fixes | Five bullets about one feature are one piece of news |
| Every bullet ends with its PR link; bullets that change how you use baguette also get `→ [docs](…)` | Two ways down: *how do I use it* and *why did it change* |
| `## [Unreleased]` is always at the top; the release workflow renames it | One edit per release, done by CI |
| Only the current minor lives here; each past minor is in `docs/changelog/<minor>.md` | The file stays ~50–150 lines for readers and for agents adding an entry |

### Before → after (real entries)

**Before (0.1.99):** a 1,100-char `Added` bullet mixes the new command with a domain protocol change, packaging, model-definition fields and a socket message change:

> - **`baguette hinge`** and `POST /devices/<udid>/hinge` fold iPhone Duo — `--pose closed|open|flat` or `--angle`, swept over Device Hub's 0.8 s — through `HingeControl`, a guest-side executable (the first non-dylib under `Injected/`) that reproduces the HID pose events Device Hub's `dtuhidd` dispatches. `docs/features/hinge/README.md` records the route. `Subprocess` gains `runInteractive` / `write` … Packaging: the homebrew formula needs one plain-link entry … Model definitions gain `asset.xcodeResource`, `scene.restRotation`, … the 3D socket's `screen_quad` gains `pieces`, `buttons` and `litPanel`, and `set_3d_camera` takes `orientation`.

A plugin author reading `screen_quad` has to find it in the last sentence of a bullet about folding.

**After:**

```markdown
## [0.1.99] - 2026-09-19

### Changed
- The 3D socket's `screen_quad` message adds `pieces`, `buttons` and `litPanel`; `set_3d_camera` accepts `orientation`. Existing fields are unchanged. → [wire](docs/wire.md#3d) ([#NN](…))

### Added
- `baguette hinge` and `POST /devices/<udid>/hinge` fold iPhone Duo to a pose (`closed`, `open`, `flat`) or an angle, swept like Device Hub. → [docs](docs/features/hinge/README.md) ([#NN](…))
- iPhone Duo's volume, power and camera-control keys work from the CLI, `POST …/input` and the page. ([#NN](…))
- A booted Duo's page draws Apple's own 3D model, posed live by the hinge. → [docs](docs/features/iphone-duo/README.md) ([#NN](…))
```

`Subprocess.runInteractive`, the `Injected/` executable, the formula entry and the model-definition fields go to the PR and `hinge/design.md`, their one home.

**Before (0.1.99, second `### Added`):** "baguette follows the Duo's hinge" — 900 chars naming `devicectl device motion hinge-angle`, `0x40000003`, `phone14`, 669×951 and the re-bootstrap.

**After:**

```markdown
### Fixed
- iPhone Duo: `screenshot`, `stream`, `serve` and taps follow the lit panel as the device folds and unfolds, instead of showing the dark inner panel in black. → [docs](docs/features/iphone-duo/README.md) ([#NN](…))
```

It was a bug from the user's side (black screen, taps landing nowhere), so it's `Fixed`, not `Added`.

**Old entries:** wording left as it is and moved unchanged to `docs/changelog/<minor>.md`.

### What the file looks like

```markdown
# Changelog
Format: Keep a Changelog · Versioning: SemVer

## [Unreleased]

---

## [0.2.0] - 2026-09-22

### Changed
* fix(pasteboard): write through devicectl before simctl pbcopy by @EYHN in https://github.com/tddworks/baguette/pull/84

---

## Older releases

[0.1](docs/changelog/0.1.md)
```

---

## `README.md` (≤150 lines)

**Who:** someone who found the repo from a link, Homebrew, or an agent recommendation.
**Their question:** *What is this, is it for me, and can I see it drive a simulator in a minute?*

```markdown
# baguette                                         ← logo + badges
Headless iOS simulator control — taps, gestures, streaming, a web UI —
on iOS 26+, where idb / AXe stopped working.       ← 2-line pitch

## Demo                                            ← the existing GIF / video

## Install                                         ← brew + 1 line → troubleshooting in CONTRIBUTING
brew install baguette

## Quick start                                     ← ~15 lines
baguette serve                     # web UI at http://127.0.0.1:8421/devices
baguette tap --udid <UDID> --x 200 --y 400 --width 402 --height 874
baguette screenshot --udid <UDID> -o shot.png

## What it covers                                  ← one row per feature, each → its doc
| Area | What you can do |
| Touches | Tap, swipe, pinch, multi-finger streaming → [docs](docs/features/touches/README.md) |
| Hinge | Fold iPhone Duo from the CLI or the page → [docs](docs/features/hinge/README.md) |
…

## More                                            ← links, nothing else
Docs index · Commands · Wire protocol · Architecture · Contributing · Changelog

## License
```

**Not here:** the CLI list, routes, wire JSON, source tree, testing, or the iOS 26 story. Each has one home, listed in [the design](README.md#readmemd-150-lines).

---

## `docs/README.md` (generated)

**Who:** a user who knows *what job* they have but not which command does it.
**Their question:** *Can baguette do X, and where is it documented?*

Built by `make docs` from each feature doc's `description`. Never edited by hand; CI fails if it's stale.

```markdown
# baguette docs
<!-- GENERATED by `make docs` from docs/features/*/README.md frontmatter. Do not edit. -->

Start with the [README](../README.md). For exact flags, see [commands](commands.md).

| Feature | What it's for |
|---|---|
| [accessibility](features/accessibility/README.md) | Read the frontmost app's accessibility tree. Use to find what to tap. |
| [buttons](features/buttons/README.md) | Press Home, Lock, volume and the action button. … |
| [shake](features/shake/README.md) | Deliver a motion shake, like Simulator.app's Device → Shake. … |
…

Guides: [wire protocol](wire.md) · [serve routes](serve.md) · [architecture](ARCHITECTURE.md)
```

**Alphabetical, not grouped.** Grouping needs a `group:` field in every doc plus a rule for picking one. Ctrl-F across 32 one-line descriptions is enough until people get lost.

---

## `docs/features/<x>/README.md` (≤200 lines)

**Who:** a user, or an agent following the `baguette` skill, about to do a job with one feature.
**Their question:** *How do I get this done, and what will surprise me?*

They **don't** need flag tables (`--help`), the dispatch path, or why `notifyutil` was chosen. Mockup of today's `shake.md` (115 lines, a quarter of it layering and dispatch) after the move:

````markdown
---
description: Deliver a motion shake to a booted simulator, like Simulator.app's Device → Shake. Use when testing shake-to-undo or a shake-to-report menu.
---

# Shake

The frontmost app gets `motionBegan` / `motionEnded` with `.motionShake`.
Every flag: [commands.md#baguette-shake](../../commands.md#baguette-shake).

## Quick start
```bash
baguette shake --udid <UDID>
```
Or click the shake button in the `serve` toolbar, next to Home.

## HTTP
| Method | Path |
|---|---|
| POST | `/devices/<UDID>/shake` |

## Gotchas
- iOS only; watchOS and tvOS have no shake.
- It's a device action, not a gesture: there's no `baguette input` verb for it.
- The simulator must be booted; an unknown UDID fails instead of doing nothing.

## See also
[design.md](design.md) — why it goes through `notifyutil` · [buttons](../buttons/README.md)
````

About 30 lines instead of 115. The dispatch path and layering move to `shake/design.md`; nothing is lost.

**When it outgrows 200 lines:** move a user-facing topic to `<topic>.md` next to it and link from "See also". Research always goes to `design.md`.

---

## `docs/features/<x>/design.md`

**Who:** a contributor, or an agent in the `baguette-implement-feature` skill, about to change how a feature talks to the simulator.
**Their question:** *Why is it this way, and what already failed?*

This is the file that has no asc-cli equivalent, because baguette's hard knowledge isn't in the code: it's which private call works on which Xcode and why. It holds, per feature:

- **The path**: entry points → domain role → the irreducible private call, in one short list (not a file map).
- **The recipe and its constants**, with where each was measured: e.g. hinge `0xFF61`/`0x5B`, the HID targets the guest publishes, `IndigoHIDMessageForMouseNSEvent`'s 9 arguments.
- **Ordering that matters**: e.g. `notifyutil -s … 0` *then* `kickstart backboardd`.
- **Dead ends**: what was tried and why it doesn't work (`IndigoHIDTargetForScreen`, powering `primary-1` off), so nobody tries it again.
- **Known limits**, in full. AGENTS.md keeps one line that links here.

No budget: it's tier 3 and read on demand. It still links instead of copying: the wire shape is in `docs/wire.md`, the flags in `docs/commands.md`.

---

## `docs/commands.md` (generated)

**Who:** a script author who needs the exact flag, or an agent checking a flag without a shell.
**Their question:** *What's the exact spelling, and is it required?*

Generated by `make docs` from `baguette --experimental-dump-help`, so it is exactly what the binary accepts:

````markdown
<!-- GENERATED by `make docs` from `baguette --experimental-dump-help`. Do not edit. -->
# Command reference — baguette 0.2.0

## baguette hinge
Fold or read iPhone Duo's hinge.

```
baguette hinge --udid <udid> [--pose <pose>] [--angle <angle>]
```

| Flag | Required | Description |
|---|---|---|
| `--udid` | yes | Simulator UDID |
| `--pose` | no | closed, open or flat |
````

To improve a description, edit the `help:` string in Swift. That one edit fixes `--help`, this file, the skill and every link to it.

---

## `docs/wire.md`

**Who:** a host-plugin author driving `baguette input` over stdin, or a page talking to the stream WebSocket.
**Their question:** *What exact JSON do I send, and what comes back?*

The README's "Wire protocol" section and `skills/baguette/references/wire-protocol.md`, merged: the gesture envelopes and stream-control messages `baguette input` and the stream WebSocket share, one section per message, coordinates in device points, one example each. Gesture feature docs (touches, buttons, double-tap…) link to `wire.md#<message>` instead of repeating it. Messages that belong to one feature (camera, logs, hinge, location) stay in that feature's README; `wire.md` lists them with a link.

## `docs/serve.md`

**Who:** someone calling `baguette serve` over HTTP.
**Their question:** *Which routes exist and what do they return?*

The README's route tree and "one bidirectional WebSocket per stream", moved: one row per route, linking to the feature README that documents it. `docs/ARCHITECTURE.md` keeps the *why*; this keeps the table.

## `docs/ARCHITECTURE.md`

**Who:** a contributor or curious user asking *how a tap becomes a `UITouch`*.

Unchanged, and the one home for the layer diagram and the iOS 26 story (the README's "Why this works on iOS 26.4" moves here). Feature docs no longer draw their own layering.

## `CONTRIBUTING.md`

**Who:** a first-time contributor.
**Their question:** *How do I build, run the tests, and open a PR that gets merged?*

```markdown
# Contributing
## Build & test          make · swift test · make test-web · Xcode 26.4.1+ on Apple Silicon
## Troubleshooting       moved from the README's Install section
## How code is organised 3 lines + link to docs/ARCHITECTURE.md
## Rules                 TDD first, named abstractions (link to AGENTS.md)
## Docs                  the update-rules table, by link to docs/documentation-design/
```

## `AGENTS.md` (≤100 lines, ≤12k chars)

**Who:** an AI agent at the start of *every* session in this repo.
**Its question:** *What must I always or never do here?*

```markdown
# AGENTS.md
## TDD is non-negotiable      ← unchanged gate + naming + adapter split
## Build & test               ← ~8 lines
## Architecture               ← 3 layers, MainActor rule, points-not-normalized (~15 lines)
## Known limits               ← one line each → design.md
- Xcode 27 Device Hub shadows the legacy input surface; `baguette heal` repairs it → features/device-hub/design.md
- A HID target is only a constant some create-service message registered, never computed → features/companion-screens/design.md
- iPhone Duo: the hinge picks the lit panel; keys go through dtuhidd, not Indigo → features/iphone-duo/design.md
- CoreMotion only by injection; only apps launched after arming see it → features/motion/design.md
…
## When you are…             ← pointers, loaded only when relevant
- adding a feature  → baguette-implement-feature skill
- touching docs     → docs/documentation-design/
```

**Moved out:** the long limit write-ups (to each feature's `design.md`), extensibility hot spots and JS testing conventions (to the `baguette-implement-feature` skill), the route summary (to `docs/serve.md`).
